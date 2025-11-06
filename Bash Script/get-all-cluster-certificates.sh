#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Output file
CSV_FILE="all-cluster-certificates.csv"

echo -e "${BLUE}🔍 Cluster-Wide Certificate Discovery${NC}"
echo "======================================"
echo ""

# Check for required tools
if ! command -v jq &> /dev/null; then
    echo -e "${RED}❌ Error: jq is required but not installed.${NC}"
    echo "   Install with: brew install jq (macOS) or apt-get install jq (Linux)"
    exit 1
fi

# Function to escape CSV values
escape_csv() {
    local value="$1"
    # Escape quotes and wrap in quotes if contains comma, quote, or newline
    if [[ "$value" =~ [,\"$'\n'] ]]; then
        value=$(echo "$value" | sed 's/"/""/g')
        value="\"$value\""
    fi
    echo "$value"
}

# Function to extract certificate fingerprint from certificate data
get_cert_fingerprint() {
    local cert_data="$1"
    
    if [[ -z "$cert_data" ]]; then
        echo ""
        return
    fi
    
    # For bundles, extract first certificate
    local first_cert="$cert_data"
    if [[ "$cert_data" == *"-----BEGIN CERTIFICATE-----"* ]]; then
        # Extract first certificate from bundle
        first_cert=$(echo "$cert_data" | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' | head -n 1000)
    fi
    
    # Get SHA256 fingerprint
    local fingerprint=$(echo "$first_cert" | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr -d ':' | tr '[:lower:]' '[:upper:]')
    
    if [[ -z "$fingerprint" ]]; then
        echo ""
        return
    fi
    
    echo "$fingerprint"
}

# Function to extract certificate issuer from certificate data
get_cert_issuer() {
    local cert_data="$1"
    
    if [[ -z "$cert_data" ]]; then
        echo "N/A"
        return
    fi
    
    # For bundles, extract first certificate
    local first_cert="$cert_data"
    if [[ "$cert_data" == *"-----BEGIN CERTIFICATE-----"* ]]; then
        # Extract first certificate from bundle
        first_cert=$(echo "$cert_data" | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' | head -n 1000)
    fi
    
    # Get issuer
    local issuer=$(echo "$first_cert" | openssl x509 -noout -issuer 2>/dev/null | sed 's/issuer=//')
    
    if [[ -z "$issuer" ]]; then
        echo "N/A"
        return
    fi
    
    echo "$issuer"
}

# Function to calculate certificate validity in days
get_cert_validity_days() {
    local cert_data="$1"
    
    if [[ -z "$cert_data" ]]; then
        echo "0"
        return
    fi
    
    # For bundles, extract first certificate
    local first_cert="$cert_data"
    if [[ "$cert_data" == *"-----BEGIN CERTIFICATE-----"* ]]; then
        # Extract first certificate from bundle
        first_cert=$(echo "$cert_data" | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' | head -n 1000)
    fi
    
    # Get validity dates
    local valid_from=$(echo "$first_cert" | openssl x509 -noout -dates | grep "notBefore" | cut -d= -f2 2>/dev/null)
    local valid_to=$(echo "$first_cert" | openssl x509 -noout -dates | grep "notAfter" | cut -d= -f2 2>/dev/null)
    
    if [[ -n "$valid_from" && -n "$valid_to" ]]; then
        local valid_from_epoch=$(date -d "$valid_from" +%s 2>/dev/null || echo "0")
        local valid_to_epoch=$(date -d "$valid_to" +%s 2>/dev/null || echo "0")
        
        if [[ "$valid_from_epoch" -gt 0 && "$valid_to_epoch" -gt 0 ]]; then
            echo $(( (valid_to_epoch - valid_from_epoch) / 86400 ))
            return
        fi
    fi
    
    echo "0"
}

# Function to check if certificate is signed by Service-CA
is_service_ca_signed() {
    local issuer="$1"
    local has_service_ca_bundle="$2"
    
    if [[ "$issuer" =~ (service-ca|serviceca|openshift-service-ca) ]] || [[ "$has_service_ca_bundle" == "true" ]]; then
        return 0
    fi
    return 1
}

# Function to check if certificate is signed by Platform-CA
is_platform_ca_signed() {
    local issuer="$1"
    local has_platform_ca_bundle="$2"
    
    if [[ "$issuer" =~ (etcd|kube-apiserver|kube-controller-manager|openshift|kubernetes|kube-csr-signer|cluster-manager-webhook) ]] || [[ "$has_platform_ca_bundle" == "true" ]]; then
        return 0
    fi
    return 1
}

# Function to check if certificate is signed by Cluster-Proxy CA
is_cluster_proxy_ca_signed() {
    local issuer="$1"
    
    if [[ "$issuer" =~ (open-cluster-management:cluster-proxy|cluster-proxy) ]]; then
        return 0
    fi
    return 1
}

# Function to determine CA category from issuer and managed details
determine_ca_category() {
    local issuer="$1"
    local managed_details="$2"
    local annotations="$3"
    
    # Normalize issuer string for matching (handle CN=, OU= prefixes)
    local issuer_normalized="$issuer"
    
    # Service-CA (check annotations first, then issuer)
    if [[ "$annotations" =~ (service-ca) ]] || [[ "$issuer_normalized" =~ (openshift-service-serving-signer) ]]; then
        echo "Service-CA"
        return
    fi
    
    # Cluster-Proxy CA
    if [[ "$issuer_normalized" =~ (open-cluster-management:cluster-proxy) ]]; then
        echo "Cluster-Proxy CA"
        return
    fi
    
    # Kube-CSR-Signer (check both patterns)
    if [[ "$issuer_normalized" =~ (kube-csr-signer_@|kube-csr-signer[^_]) ]]; then
        echo "Kube-CSR-Signer"
        return
    fi
    
    # Cluster-Manager-Webhook
    if [[ "$issuer_normalized" =~ (cluster-manager-webhook) ]]; then
        echo "Cluster-Manager-Webhook"
        return
    fi
    
    # OVN CA (must come before generic openshift patterns)
    if [[ "$issuer_normalized" =~ (openshift-ovn-kubernetes) ]]; then
        echo "OVN CA"
        return
    fi
    
    # Monitoring CA (must come before generic openshift patterns)
    if [[ "$issuer_normalized" =~ (openshift-cluster-monitoring) ]]; then
        echo "Monitoring CA"
        return
    fi
    
    # Konnectivity CA
    if [[ "$issuer_normalized" =~ (konnectivity-signer) ]]; then
        echo "Konnectivity CA"
        return
    fi
    
    # Ingress CA
    if [[ "$issuer_normalized" =~ (ingress-operator) ]]; then
        echo "Ingress CA"
        return
    fi
    
    # OLM CA
    if [[ "$issuer_normalized" =~ (olm-selfsigned) ]]; then
        echo "OLM CA"
        return
    fi
    
    # External CA (ACCVRAIZ1, etc.)
    if [[ "$issuer_normalized" =~ (ACCVRAIZ1|PKIACCV) ]]; then
        echo "External CA"
        return
    fi
    
    # Platform-CA (root-ca, kube-apiserver-to-kubelet-signer, etc.)
    # Check for root-ca first (most common)
    if [[ "$issuer_normalized" =~ (root-ca) ]]; then
        echo "Platform-CA"
        return
    fi
    
    # Check for kube-apiserver-to-kubelet-signer
    if [[ "$issuer_normalized" =~ (kube-apiserver-to-kubelet-signer) ]]; then
        echo "Platform-CA"
        return
    fi
    
    # Generic platform patterns (must come last)
    if [[ "$issuer_normalized" =~ (etcd|kube-apiserver|kube-controller-manager|openshift|kubernetes) ]]; then
        echo "Platform-CA"
        return
    fi
    
    # Default: Unknown
    echo "Unknown"
}

# Function to check if certificate validity period matches auto-rotation pattern
# NOTE: This is informational only - we cannot rely on validity period alone to determine
# platform management, as users can create their own CAs with 2-year validity.
# This function should only be used as supporting evidence, not as the primary determination.
is_auto_rotated_by_validity() {
    local validity_days="$1"
    
    # 2-year (730/731 days) or <1-year validity suggests auto-rotation pattern
    # But this must be combined with issuer analysis to confirm platform management
    if [[ "$validity_days" -eq 730 ]] || [[ "$validity_days" -eq 731 ]] || [[ "$validity_days" -lt 365 ]]; then
        return 0
    fi
    return 1
}

# Function to extract certificate validity from certificate data
get_cert_validity() {
    local cert_data="$1"
    
    if [[ -z "$cert_data" ]]; then
        echo ""
        return
    fi
    
    # Try to parse certificate
    local expiry_raw=$(echo "$cert_data" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    local start_raw=$(echo "$cert_data" | openssl x509 -noout -startdate 2>/dev/null | cut -d= -f2)
    
    if [[ -z "$expiry_raw" || -z "$start_raw" ]]; then
        echo ""
        return
    fi
    
    # Calculate validity period
    local expiry_epoch=$(date -d "$expiry_raw" +%s 2>/dev/null || date -j -f "%b %d %H:%M:%S %Y %Z" "$expiry_raw" +%s 2>/dev/null)
    local start_epoch=$(date -d "$start_raw" +%s 2>/dev/null || date -j -f "%b %d %H:%M:%S %Y %Z" "$start_raw" +%s 2>/dev/null)
    
    if [[ -n "$expiry_epoch" && -n "$start_epoch" ]]; then
        local validity_days=$(( (expiry_epoch - start_epoch) / 86400 ))
        local validity_years=$((validity_days / 365))
        echo "$validity_years|$expiry_raw"
    else
        echo ""
    fi
}

# Function to check if a certificate is user-provided
# User-provided certificates are in openshift-config namespace and referenced in cluster config resources
# This function caches cluster config resources to avoid repeated API calls
check_user_provided_certificate() {
    local resource_type="$1"
    local name="$2"
    local namespace="$3"
    local resource_json="$4"  # Added parameter to avoid extra API calls
    
    # Only check secrets in openshift-config namespace
    if [[ "$namespace" != "openshift-config" ]] || [[ "$resource_type" != "secret" ]]; then
        return 1  # Not user-provided
    fi
    
    # Check if secret type is kubernetes.io/tls (user-provided certs are typically this type)
    local secret_type=$(echo "$resource_json" | jq -r '.type // empty' 2>/dev/null)
    if [[ "$secret_type" != "kubernetes.io/tls" ]]; then
        return 1  # Not user-provided (platform-managed certs use different types)
    fi
    
    # Cache cluster config resources (only fetch once per script run)
    if [[ -z "${USER_PROVIDED_CERT_CACHE_INITIALIZED:-}" ]]; then
        # Cache apiserver/cluster namedCertificates
        export APISERVER_NAMED_CERTS=$(oc get apiserver cluster -o json 2>/dev/null | \
            jq -r '.spec.servingCerts.namedCertificates[]?.servingCertificate.name // empty' 2>/dev/null)
        
        # Cache ingresscontroller/default defaultCertificate
        export INGRESS_DEFAULT_CERT=$(oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.spec.defaultCertificate.name}' 2>/dev/null)
        
        # Cache oauth/cluster identityProviders
        export OAUTH_OIDC_CAS=$(oc get oauth cluster -o json 2>/dev/null | \
            jq -r '.spec.identityProviders[]?.oidc?.ca.name // empty' 2>/dev/null)
        
        # Cache authentication/cluster resources
        export AUTH_OIDC_PROVIDERS=$(oc get authentication cluster -o json 2>/dev/null | \
            jq -r '.spec.oidcProviders[]?.ca.name // empty' 2>/dev/null)
        
        export USER_PROVIDED_CERT_CACHE_INITIALIZED=1
    fi
    
    # Check if referenced in apiserver/cluster resource
    if echo "$APISERVER_NAMED_CERTS" | grep -q "^${name}$"; then
        return 0  # User-provided
    fi
    
    # Check if referenced in ingresscontroller/default resource
    if [[ "$INGRESS_DEFAULT_CERT" == "$name" ]]; then
        return 0  # User-provided
    fi
    
    # Check if referenced in oauth/cluster resource
    if echo "$OAUTH_OIDC_CAS" | grep -q "^${name}$"; then
        return 0  # User-provided
    fi
    
    # Check if referenced in authentication/cluster resource
    if echo "$AUTH_OIDC_PROVIDERS" | grep -q "^${name}$"; then
        return 0  # User-provided
    fi
    
    # If in openshift-config, kubernetes.io/tls type, but not referenced in configs,
    # it's likely still user-provided but not yet configured
    # However, we'll be conservative and only mark as user-provided if it's referenced
    return 1  # Not confirmed as user-provided
}

# Function to process a resource JSON object
process_resource() {
    local resource_type="$1"
    local resource_json="$2"
    
    local name=$(echo "$resource_json" | jq -r '.metadata.name // ""')
    local namespace=$(echo "$resource_json" | jq -r '.metadata.namespace // ""')
    
    if [[ -z "$name" || -z "$namespace" ]]; then
        return
    fi
    
    # Extract data fields that might contain certificates
    local data_fields=""
    local has_cert_data=false
    
    # Check for certificate-related data fields
    local tls_crt=$(echo "$resource_json" | jq -r '.data."tls.crt" // empty')
    local tls_key=$(echo "$resource_json" | jq -r '.data."tls.key" // empty')
    local ca_crt=$(echo "$resource_json" | jq -r '.data."ca.crt" // empty')
    local ca_bundle=$(echo "$resource_json" | jq -r '.data."ca-bundle.crt" // empty')
    local cert_crt=$(echo "$resource_json" | jq -r '.data."cert.crt" // empty')
    local cert_key=$(echo "$resource_json" | jq -r '.data."cert.key" // empty')
    
    # Build data fields list
    local fields=()
    [[ -n "$tls_crt" ]] && fields+=("tls.crt") && has_cert_data=true
    [[ -n "$tls_key" ]] && fields+=("tls.key")
    [[ -n "$ca_crt" ]] && fields+=("ca.crt") && has_cert_data=true
    [[ -n "$ca_bundle" ]] && fields+=("ca-bundle.crt") && has_cert_data=true
    [[ -n "$cert_crt" ]] && fields+=("cert.crt") && has_cert_data=true
    [[ -n "$cert_key" ]] && fields+=("cert.key")
    
    # Skip if no certificate data
    if [[ "$has_cert_data" == false ]]; then
        return
    fi
    
    data_fields=$(IFS=","; echo "${fields[*]}")
    
    # Extract certificate data for validity checking
    local cert_data=""
    local validity_years=""
    local actual_expiry=""
    
    if [[ "$resource_type" == "secret" ]]; then
        # For secrets, data is base64 encoded in JSON
        if [[ -n "$tls_crt" ]]; then
            cert_data=$(echo "$tls_crt" | base64 -d 2>/dev/null)
        elif [[ -n "$ca_crt" ]]; then
            cert_data=$(echo "$ca_crt" | base64 -d 2>/dev/null)
        elif [[ -n "$cert_crt" ]]; then
            cert_data=$(echo "$cert_crt" | base64 -d 2>/dev/null)
        fi
    elif [[ "$resource_type" == "configmap" ]]; then
        # For configmaps, data is plain text in JSON
        if [[ -n "$ca_bundle" ]]; then
            cert_data="$ca_bundle"
        elif [[ -n "$tls_crt" ]]; then
            cert_data="$tls_crt"
        elif [[ -n "$ca_crt" ]]; then
            cert_data="$ca_crt"
        elif [[ -n "$cert_crt" ]]; then
            cert_data="$cert_crt"
        fi
    fi
    
    # Get validity information and fingerprint
    local fingerprint=""
    if [[ -n "$cert_data" ]]; then
        local validity_info=$(get_cert_validity "$cert_data")
        if [[ -n "$validity_info" ]]; then
            validity_years=$(echo "$validity_info" | cut -d'|' -f1)
            actual_expiry=$(echo "$validity_info" | cut -d'|' -f2)
        fi
        # Get fingerprint from certificate data (already have it, no extra API call needed)
        fingerprint=$(get_cert_fingerprint "$cert_data")
        
        # Get certificate issuer for signer analysis
        issuer=$(get_cert_issuer "$cert_data")
        
        # Get certificate validity in days for rotation analysis
        validity_days=$(get_cert_validity_days "$cert_data")
        
        # Check for CA bundles
        has_service_ca_bundle=$(echo "$resource_json" | jq -r '.data | has("service-ca.crt")')
        has_platform_ca_bundle=$(echo "$resource_json" | jq -r '.data | has("ca-bundle.crt") or .data | has("ca.crt")')
    fi
    
    # Build commands
    local oc_command="oc describe $resource_type -n $namespace $name"
    local openssl_command=""
    
    # Build openssl command based on available certificate data
    if [[ "$resource_type" == "secret" ]]; then
        if [[ -n "$tls_crt" ]]; then
            openssl_command="oc get $resource_type -n $namespace $name -o go-template='{{index .data \"tls.crt\"}}' | base64 -d | openssl x509 -noout -text"
        elif [[ -n "$ca_crt" ]]; then
            openssl_command="oc get $resource_type -n $namespace $name -o go-template='{{index .data \"ca.crt\"}}' | base64 -d | openssl x509 -noout -text"
        elif [[ -n "$cert_crt" ]]; then
            openssl_command="oc get $resource_type -n $namespace $name -o go-template='{{index .data \"cert.crt\"}}' | base64 -d | openssl x509 -noout -text"
        fi
    elif [[ "$resource_type" == "configmap" ]]; then
        if [[ -n "$ca_bundle" ]]; then
            openssl_command="oc get $resource_type -n $namespace $name -o go-template='{{index .data \"ca-bundle.crt\"}}' | openssl x509 -noout -text"
        elif [[ -n "$tls_crt" ]]; then
            openssl_command="oc get $resource_type -n $namespace $name -o go-template='{{index .data \"tls.crt\"}}' | openssl x509 -noout -text"
        elif [[ -n "$ca_crt" ]]; then
            openssl_command="oc get $resource_type -n $namespace $name -o go-template='{{index .data \"ca.crt\"}}' | openssl x509 -noout -text"
        elif [[ -n "$cert_crt" ]]; then
            openssl_command="oc get $resource_type -n $namespace $name -o go-template='{{index .data \"cert.crt\"}}' | openssl x509 -noout -text"
        fi
    fi
    
    # Check if certificate is managed by OpenShift
    local managed_status="User-Managed"
    local managed_details=""
    
    # Check for managed certificate indicators
    local cert_not_after=$(echo "$resource_json" | jq -r '.metadata.annotations."auth.openshift.io/certificate-not-after" // empty')
    local cert_not_before=$(echo "$resource_json" | jq -r '.metadata.annotations."auth.openshift.io/certificate-not-before" // empty')
    local owning_component=$(echo "$resource_json" | jq -r '.metadata.annotations."openshift.io/owning-component" // empty')
    local managed_cert_type=$(echo "$resource_json" | jq -r '.metadata.labels."auth.openshift.io/managed-certificate-type" // empty')
    local jira_component=$(echo "$resource_json" | jq -r '.metadata.annotations."operator.openshift.io/jira-component" // empty')
    local description=$(echo "$resource_json" | jq -r '.metadata.annotations."operator.openshift.io/description" // empty')
    
    # Build relevant annotations for the new column
    local relevant_annotations=""
    local annotation_parts=()
    if [[ -n "$owning_component" ]]; then
        annotation_parts+=("openshift.io/owning-component: $owning_component")
    fi
    if [[ -n "$cert_not_before" ]]; then
        annotation_parts+=("auth.openshift.io/certificate-not-before: $cert_not_before")
    fi
    if [[ -n "$cert_not_after" ]]; then
        annotation_parts+=("auth.openshift.io/certificate-not-after: $cert_not_after")
    fi
    if [[ -n "$jira_component" ]]; then
        annotation_parts+=("operator.openshift.io/jira-component: $jira_component")
    fi
    if [[ -n "$description" ]]; then
        annotation_parts+=("operator.openshift.io/description: $description")
    fi
    if [[ -n "$managed_cert_type" ]]; then
        annotation_parts+=("auth.openshift.io/managed-certificate-type: $managed_cert_type")
    fi
    relevant_annotations=$(IFS="; "; echo "${annotation_parts[*]}")
    
    # Determine if this is a platform namespace
    # NOTE: openshift-config is NOT included here as it contains BOTH user-provided and platform-managed certs
    # Matches OpenShift's platform namespace detection: openshift-*, kubernetes-*, and well-known namespaces
    local is_platform_namespace=false
    if [[ "$namespace" =~ ^openshift- ]] && [[ "$namespace" != "openshift-config" ]]; then
        is_platform_namespace=true
    elif [[ "$namespace" =~ ^kubernetes- ]]; then
        is_platform_namespace=true
    elif [[ "$namespace" == "openshift" ]] || \
         [[ "$namespace" == "openshift-config-managed" ]] || \
         [[ "$namespace" == "kube-system" ]] || \
         [[ "$namespace" == "kube-public" ]] || \
         [[ "$namespace" == "default" ]] || \
         [[ "$namespace" == "kubernetes" ]]; then
        is_platform_namespace=true
    fi
    
    # Check if certificate has 10-year validity (signer CAs, root CAs)
    local is_10_year=false
    if [[ -n "$validity_years" && "$validity_years" =~ ^[0-9]+$ && "$validity_years" -eq 10 ]]; then
        is_10_year=true
    fi
    
    # Determine managed status based on multiple indicators
    # Priority: user-provided check > kube-root-ca.crt (special case) > owning-component > platform namespace > rotation annotation > managed label
    
    # FIRST: Check if this is a user-provided certificate
    # User-provided certificates are NOT auto-rotated
    if check_user_provided_certificate "$resource_type" "$name" "$namespace" "$resource_json"; then
        managed_status="User-Managed (Not Auto-Rotated)"
        # Build details - only certificate information from openssl
        local details_parts=()
        details_parts+=("User-provided certificate in openshift-config")
        if [[ -n "$issuer" && "$issuer" != "N/A" ]]; then
            details_parts+=("Issuer: $issuer")
        fi
        if [[ "$validity_days" -gt 0 ]]; then
            details_parts+=("${validity_days} days validity")
        fi
        managed_details=$(IFS="; "; echo "${details_parts[*]}")
    # SECOND: Special case for kube-root-ca.crt - Kubernetes automatically creates this in all namespaces
    # It contains the same platform certificate bundle everywhere, so it's platform-managed
    elif [[ "$resource_type" == "configmap" && "$name" == "kube-root-ca.crt" ]]; then
        # kube-root-ca.crt is automatically created by Kubernetes in all namespaces
        # It contains platform certificates, so it's platform-managed (but not auto-rotated by OpenShift operators)
        if [[ "$is_10_year" == true ]]; then
            managed_status="Platform-Managed (10-Year, Not Auto-Rotated)"
        else
            managed_status="Platform-Managed (Auto-Rotated)"
        fi
        # Build details - only certificate information from openssl
        local details_parts=()
        details_parts+=("Kubernetes-managed configmap (kube-root-ca.crt) with platform certificates")
        if [[ -n "$issuer" && "$issuer" != "N/A" ]]; then
            details_parts+=("Issuer: $issuer")
        fi
        if [[ "$validity_days" -gt 0 ]]; then
            details_parts+=("${validity_days} days validity")
        fi
        managed_details=$(IFS="; "; echo "${details_parts[*]}")
    # THIRD: Check for openshift.io/owning-component annotation (strongest platform indicator)
    elif [[ -n "$owning_component" ]]; then
        # Strong indicator: openshift.io/owning-component annotation means platform-managed and auto-rotated
        managed_status="Platform-Managed (Auto-Rotated)"
        
        # Build details - only certificate information from openssl
        local details_parts=()
        if [[ -n "$issuer" && "$issuer" != "N/A" ]]; then
            details_parts+=("Issuer: $issuer")
        fi
        if [[ "$validity_days" -gt 0 ]]; then
            details_parts+=("${validity_days} days validity")
        fi
        
        managed_details=$(IFS="; "; echo "${details_parts[*]}")
    # FOURTH: Check if in platform namespace (openshift-*, but NOT openshift-config)
    elif [[ "$is_platform_namespace" == true ]]; then
        # Platform namespace - certificates are typically managed
        
        if [[ "$is_10_year" == true ]]; then
            # 10-year certificates are managed but NOT auto-rotated
            managed_status="Platform-Managed (10-Year, Not Auto-Rotated)"
        elif [[ -n "$cert_not_after" ]]; then
            # Has rotation annotation - definitely auto-rotated
            managed_status="Platform-Managed (Auto-Rotated)"
        else
            # Platform namespace - assume auto-rotated (most are)
            managed_status="Platform-Managed (Auto-Rotated)"
        fi
        
        # Build details - only certificate information from openssl
        local details_parts=()
        if [[ -n "$issuer" && "$issuer" != "N/A" ]]; then
            details_parts+=("Issuer: $issuer")
        fi
        if [[ "$validity_days" -gt 0 ]]; then
            details_parts+=("${validity_days} days validity")
        fi
        
        managed_details=$(IFS="; "; echo "${details_parts[*]}")
    # FIFTH: Check for rotation annotation (even if not in platform namespace)
    elif [[ -n "$cert_not_after" ]]; then
        # Has rotation annotation - definitely platform-managed and auto-rotated
        managed_status="Platform-Managed (Auto-Rotated)"
        # Build details - only certificate information from openssl
        local details_parts=()
        if [[ -n "$issuer" && "$issuer" != "N/A" ]]; then
            details_parts+=("Issuer: $issuer")
        fi
        if [[ "$validity_days" -gt 0 ]]; then
            details_parts+=("${validity_days} days validity")
        fi
        managed_details=$(IFS="; "; echo "${details_parts[*]}")
    # SIXTH: Check certificate signer analysis (backup method when annotations missing)
    elif [[ -n "$issuer" && "$issuer" != "N/A" ]]; then
        # Analyze certificate signer to determine management status
        # NOTE: We cannot rely solely on validity period (2 years) as users can create their own CAs with 2-year validity
        # We must check issuer patterns (Service-CA or Platform-CA) to determine platform management
        local signer_details=""
        
        if is_service_ca_signed "$issuer" "$has_service_ca_bundle"; then
            managed_status="Platform-Managed (Auto-Rotated)"
            signer_details="Service-CA signed"
            if [[ "$has_service_ca_bundle" == "true" ]]; then
                signer_details+=" (has service-ca.crt bundle)"
            fi
            # Add validity info as supporting detail
            if [[ "$validity_days" -gt 0 ]]; then
                signer_details+="; ${validity_days} days validity"
            fi
        elif is_platform_ca_signed "$issuer" "$has_platform_ca_bundle"; then
            # Check if this is a 10-year certificate (likely a CA signer)
            if [[ "$is_10_year" == true ]]; then
                managed_status="Platform-Managed (10-Year, Not Auto-Rotated)"
            else
                managed_status="Platform-Managed (Auto-Rotated)"
            fi
            signer_details="Platform-CA signed"
            if [[ "$has_platform_ca_bundle" == "true" ]]; then
                signer_details+=" (has ca-bundle.crt)"
            fi
            # Add validity info as supporting detail
            if [[ "$validity_days" -gt 0 ]]; then
                signer_details+="; ${validity_days} days validity"
            fi
        elif is_cluster_proxy_ca_signed "$issuer"; then
            managed_status="Platform-Managed (Auto-Rotated)"
            signer_details="Cluster-Proxy CA signed"
            # Add validity info as supporting detail
            if [[ "$validity_days" -gt 0 ]]; then
                signer_details+="; ${validity_days} days validity"
            fi
        else
            # External/unknown signer - even with 2-year validity, assume user-managed
            # Users can create their own CAs with 2-year validity, so issuer pattern is required
            managed_status="User-Managed (Not Auto-Rotated)"
            signer_details="External/Unknown signer"
            if [[ "$validity_days" -gt 0 ]]; then
                signer_details+=" (${validity_days} days validity)"
            fi
        fi
        
        managed_details="Issuer: $issuer; $signer_details"
    # SEVENTH: Check for managed label (even if not in platform namespace)
    elif [[ -n "$managed_cert_type" ]]; then
        # Has managed label - still platform-managed
        if [[ "$is_10_year" == true ]]; then
            managed_status="Platform-Managed (10-Year, Not Auto-Rotated)"
        else
            managed_status="Platform-Managed (Auto-Rotated)"
        fi
        # Build details - only certificate information from openssl
        local details_parts=()
        if [[ -n "$issuer" && "$issuer" != "N/A" ]]; then
            details_parts+=("Issuer: $issuer")
        fi
        if [[ "$validity_days" -gt 0 ]]; then
            details_parts+=("${validity_days} days validity")
        fi
        managed_details=$(IFS="; "; echo "${details_parts[*]}")
    fi
    # else: User-Managed (default) - certificates not in platform namespaces and without indicators
    
    # Determine CA category from issuer and managed details
    local ca_category=""
    local issuer_for_category="$issuer"
    
    # If issuer is not available, extract from managed_details
    if [[ -z "$issuer_for_category" || "$issuer_for_category" == "N/A" ]]; then
        if [[ "$managed_details" =~ Issuer:\ ([^;]+) ]]; then
            issuer_for_category="${BASH_REMATCH[1]}"
        fi
    fi
    
    # Determine CA category
    if [[ -n "$issuer_for_category" && "$issuer_for_category" != "N/A" ]]; then
        ca_category=$(determine_ca_category "$issuer_for_category" "$managed_details" "$relevant_annotations")
    else
        ca_category="Unknown"
    fi
    
    # Build CSV line
    local csv_line=""
    csv_line+="$(escape_csv "$resource_type"),"
    csv_line+="$(escape_csv "$name"),"
    csv_line+="$(escape_csv "$namespace"),"
    csv_line+="$(escape_csv "$data_fields"),"
    csv_line+="$(escape_csv "$validity_years"),"
    csv_line+="$(escape_csv "$actual_expiry"),"
    csv_line+="$(escape_csv "$fingerprint"),"
    csv_line+="$(escape_csv "$managed_status"),"
    csv_line+="$(escape_csv "$managed_details"),"
    csv_line+="$(escape_csv "$ca_category"),"
    csv_line+="$(escape_csv "$relevant_annotations"),"
    csv_line+="$(escape_csv "$oc_command"),"
    csv_line+="$(escape_csv "$openssl_command")"
    
    echo "$csv_line"
}

# Initialize CSV file with headers
echo "Secret/ConfigMap,Name,Namespace,Data Fields,Validity (years),Actual Expiry,Fingerprint,Managed Status,Managed Details,CA,TLS Registry annotations,OC Describe Command,OpenSSL Command" > "$CSV_FILE"

# Step 1: Get all secrets with their metadata and data keys only (avoid binary data)
echo -e "${YELLOW}📋 Fetching all secrets from cluster...${NC}"
# Get secrets with only metadata and data keys (not values) to avoid binary data issues
TEMP_SECRETS=$(mktemp)
oc get secrets --all-namespaces -o json > "$TEMP_SECRETS" 2>/dev/null

if [[ $? -ne 0 ]]; then
    echo -e "${RED}❌ Failed to get secrets. Make sure you're connected to a cluster.${NC}"
    rm -f "$TEMP_SECRETS"
    exit 1
fi

# Process secrets one by one from the JSON array, handling parse errors
total_secrets=0
cert_secrets=0

# Use jq to extract each secret individually, which handles parse errors better
secret_count=$(jq -r '[.items[] | select(.data != null)] | length' "$TEMP_SECRETS" 2>/dev/null || echo "0")

# Check if JSON parsing failed - if so, use fallback immediately
if ! jq -e '.items' "$TEMP_SECRETS" >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠️  JSON parse error detected. Using fallback method...${NC}"
    secret_count="0"
fi

if [[ "$secret_count" == "0" ]]; then
    echo -e "${YELLOW}⚠️  No secrets found or JSON parse error. Trying alternative method...${NC}"
    # Fallback: get secret names and process individually but still efficiently (avoid subshell for counting)
    TEMP_SECRET_LIST=$(mktemp)
    oc get secrets --all-namespaces -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name --no-headers 2>/dev/null > "$TEMP_SECRET_LIST"
    while IFS=$' \t' read -r namespace name rest; do
        if [[ -z "$namespace" || -z "$name" ]]; then
            continue
        fi
        ((total_secrets++))
        # Quick check if secret has certificate fields using jsonpath
        has_cert=$(oc get secret -n "$namespace" "$name" -o jsonpath='{.data}' 2>/dev/null | jq -r 'keys | map(select(. == "tls.crt" or . == "ca.crt" or . == "cert.crt" or . == "ca-bundle.crt")) | length' 2>/dev/null || echo "0")
        if [[ "$has_cert" -gt 0 ]]; then
            # Get full secret JSON for this resource only
            secret_json=$(oc get secret -n "$namespace" "$name" -o json 2>/dev/null)
            if [[ -n "$secret_json" ]]; then
                result=$(process_resource "secret" "$secret_json" 2>/dev/null)
                if [[ -n "$result" ]]; then
                    echo "$result" >> "$CSV_FILE"
                    ((cert_secrets++))
                fi
            fi
        fi
    done < "$TEMP_SECRET_LIST"
    rm -f "$TEMP_SECRET_LIST"
else
    # Process using JSON, but handle parse errors gracefully
    echo -e "${YELLOW}📋 Processing secrets with certificate data...${NC}"
    
    # Extract valid secrets individually to handle parse errors
    secret_index=0
    while true; do
        secret_json=$(jq -c ".items[$secret_index]" "$TEMP_SECRETS" 2>/dev/null)
        if [[ -z "$secret_json" || "$secret_json" == "null" ]]; then
            break
        fi
        
        # Skip if this secret has parse errors
        if ! echo "$secret_json" | jq -e '.metadata.name' >/dev/null 2>&1; then
            ((secret_index++))
            continue
        fi
        
        ((total_secrets++))
        
        # Check if this secret has certificate data fields
        has_cert_fields=$(echo "$secret_json" | jq -r 'if .data != null then (.data | keys | map(select(. == "tls.crt" or . == "ca.crt" or . == "cert.crt" or . == "ca-bundle.crt")) | length) else 0 end' 2>/dev/null || echo "0")
        
        if [[ "$has_cert_fields" -gt 0 ]]; then
            # Verify it actually has a certificate field (not just kubeconfig)
            has_cert=$(echo "$secret_json" | jq -r '.data | keys | map(select(. == "tls.crt" or . == "ca.crt" or . == "cert.crt" or . == "ca-bundle.crt")) | length' 2>/dev/null || echo "0")
            if [[ "$has_cert" -gt 0 ]]; then
                # Verify it has certificate data by checking process_resource output
                result=$(process_resource "secret" "$secret_json" 2>/dev/null)
                if [[ -n "$result" ]]; then
                    echo "$result" >> "$CSV_FILE"
                    ((cert_secrets++))
                fi
            fi
        fi
        
        ((secret_index++))
    done
fi

rm -f "$TEMP_SECRETS"
echo -e "${GREEN}✅ Processed $cert_secrets secrets with certificate data (from $total_secrets total)${NC}"

# Step 3: Get all configmaps with their metadata and data keys only (avoid binary data)
echo -e "${YELLOW}📋 Fetching all configmaps from cluster...${NC}"
TEMP_CONFIGMAPS=$(mktemp)
oc get configmaps --all-namespaces -o json > "$TEMP_CONFIGMAPS" 2>/dev/null

if [[ $? -ne 0 ]]; then
    echo -e "${RED}❌ Failed to get configmaps.${NC}"
    rm -f "$TEMP_CONFIGMAPS"
    exit 1
fi

# Process configmaps one by one from the JSON array, handling parse errors
total_configmaps=0
cert_configmaps=0

# Use jq to extract each configmap individually, which handles parse errors better
configmap_count=$(jq -r '[.items[] | select(.data != null)] | length' "$TEMP_CONFIGMAPS" 2>/dev/null || echo "0")

# Check if JSON parsing failed - if so, use fallback immediately
if ! jq -e '.items' "$TEMP_CONFIGMAPS" >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠️  JSON parse error detected. Using fallback method...${NC}"
    configmap_count="0"
fi

if [[ "$configmap_count" == "0" ]]; then
    echo -e "${YELLOW}⚠️  Using fallback method for configmaps...${NC}"
    # Fallback: get configmap names and process individually (avoid subshell for counting)
    TEMP_CONFIGMAP_LIST=$(mktemp)
    oc get configmaps --all-namespaces -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name --no-headers 2>/dev/null > "$TEMP_CONFIGMAP_LIST"
    while IFS=$' \t' read -r namespace name rest; do
        if [[ -z "$namespace" || -z "$name" ]]; then
            continue
        fi
        ((total_configmaps++))
        # Quick check if configmap has certificate fields
        has_cert=$(oc get configmap -n "$namespace" "$name" -o jsonpath='{.data}' 2>/dev/null | jq -r 'keys | map(select(. == "tls.crt" or . == "ca.crt" or . == "cert.crt" or . == "ca-bundle.crt")) | length' 2>/dev/null || echo "0")
        if [[ "$has_cert" -gt 0 ]]; then
            # Get full configmap JSON for this resource only
            configmap_json=$(oc get configmap -n "$namespace" "$name" -o json 2>/dev/null)
            if [[ -n "$configmap_json" ]]; then
                result=$(process_resource "configmap" "$configmap_json" 2>/dev/null)
                if [[ -n "$result" ]]; then
                    echo "$result" >> "$CSV_FILE"
                    ((cert_configmaps++))
                fi
            fi
        fi
    done < "$TEMP_CONFIGMAP_LIST"
    rm -f "$TEMP_CONFIGMAP_LIST"
else
    # Process using JSON, but handle parse errors gracefully
    echo -e "${YELLOW}📋 Processing configmaps with certificate data...${NC}"
    
    # Extract valid configmaps individually to handle parse errors
    configmap_index=0
    while true; do
        configmap_json=$(jq -c ".items[$configmap_index]" "$TEMP_CONFIGMAPS" 2>/dev/null)
        if [[ -z "$configmap_json" || "$configmap_json" == "null" ]]; then
            break
        fi
        
        # Skip if this configmap has parse errors
        if ! echo "$configmap_json" | jq -e '.metadata.name' >/dev/null 2>&1; then
            ((configmap_index++))
            continue
        fi
        
        ((total_configmaps++))
        
        # Check if this configmap has certificate data fields
        has_cert_fields=$(echo "$configmap_json" | jq -r 'if .data != null then (.data | keys | map(select(. == "tls.crt" or . == "ca.crt" or . == "cert.crt" or . == "ca-bundle.crt")) | length) else 0 end' 2>/dev/null || echo "0")
        
        if [[ "$has_cert_fields" -gt 0 ]]; then
            # Verify it actually has a certificate field
            has_cert=$(echo "$configmap_json" | jq -r '.data | keys | map(select(. == "tls.crt" or . == "ca.crt" or . == "cert.crt" or . == "ca-bundle.crt")) | length' 2>/dev/null || echo "0")
            if [[ "$has_cert" -gt 0 ]]; then
                # Verify it has certificate data by checking process_resource output
                result=$(process_resource "configmap" "$configmap_json" 2>/dev/null)
                if [[ -n "$result" ]]; then
                    echo "$result" >> "$CSV_FILE"
                    ((cert_configmaps++))
                fi
            fi
        fi
        
        ((configmap_index++))
    done
fi

rm -f "$TEMP_CONFIGMAPS"
echo -e "${GREEN}✅ Processed $cert_configmaps configmaps with certificate data (from $total_configmaps total)${NC}"

# Calculate totals
total_scanned=$((total_secrets + total_configmaps))
total_certs=$((cert_secrets + cert_configmaps))

# Post-process CSV to fix managed status based on fingerprints
# If a certificate fingerprint appears as Platform-Managed in any platform namespace,
# mark ALL instances of that fingerprint as Platform-Managed
echo ""
echo -e "${BLUE}🔧 Post-processing: Correcting managed status by fingerprint...${NC}"

TEMP_CSV=$(mktemp)
python3 << PYTHON_POSTPROCESS
import csv
import sys
import os

csv_file = "${CSV_FILE}"
temp_csv = "${TEMP_CSV}"

# Read CSV and group by fingerprint
fingerprint_status = {}
rows = []

try:
    with open(csv_file, 'r', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        fieldnames = reader.fieldnames
        
        for row in reader:
            rows.append(row)
            fingerprint = row.get('Fingerprint', '').strip()
            managed_status = row.get('Managed Status', '').strip()
            namespace = row.get('Namespace', '').strip()
            
            if fingerprint and fingerprint != 'N/A':
                # Check if this is a platform namespace
                # Matches OpenShift's platform namespace detection: openshift-*, kubernetes-*, and well-known namespaces
                is_platform = False
                if namespace.startswith('openshift-') and namespace != 'openshift-config':
                    is_platform = True
                elif namespace.startswith('kubernetes-'):
                    is_platform = True
                elif namespace in ['openshift', 'openshift-config-managed', 'kube-system', 'kube-public', 'default', 'kubernetes']:
                    is_platform = True
                
                # If it's platform-managed in a platform namespace, mark this fingerprint as platform
                if is_platform and 'Platform-Managed' in managed_status:
                    if fingerprint not in fingerprint_status:
                        fingerprint_status[fingerprint] = {
                            'is_platform': True,
                            'is_10_year': '10-Year' in managed_status
                        }
                    elif '10-Year' in managed_status:
                        fingerprint_status[fingerprint]['is_10_year'] = True
    
    # Update rows: if fingerprint is marked as platform, update all User-Managed instances
    updated_count = 0
    for row in rows:
        fingerprint = row.get('Fingerprint', '').strip()
        managed_status = row.get('Managed Status', '').strip()
        
        if fingerprint and fingerprint != 'N/A' and 'User-Managed' in managed_status:
            if fingerprint in fingerprint_status and fingerprint_status[fingerprint]['is_platform']:
                # This fingerprint appears as platform-managed elsewhere, upgrade this instance
                is_10_year = fingerprint_status[fingerprint].get('is_10_year', False)
                validity = row.get('Validity (years)', '').strip()
                
                if is_10_year or validity == '10':
                    row['Managed Status'] = 'Platform-Managed (10-Year, Not Auto-Rotated)'
                    row['Managed Details'] = 'Platform certificate (same fingerprint in platform namespaces)'
                else:
                    row['Managed Status'] = 'Platform-Managed (Auto-Rotated)'
                    row['Managed Details'] = 'Platform certificate (same fingerprint in platform namespaces)'
                updated_count += 1
    
    # Write updated CSV
    with open(temp_csv, 'w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)
    
    if updated_count > 0:
        print(f"   Updated {updated_count} certificates to Platform-Managed based on fingerprint matching")
    else:
        print("   No corrections needed")
        
except Exception as e:
    print(f"   Warning: Post-processing failed: {e}")
    # Copy original if post-processing fails
    import shutil
    shutil.copy(csv_file, temp_csv)

PYTHON_POSTPROCESS

# Replace original CSV with corrected version
if [[ -f "$TEMP_CSV" ]]; then
    mv "$TEMP_CSV" "$CSV_FILE"
fi

echo ""
echo -e "${GREEN}✅ Cluster-wide certificate discovery completed!${NC}"
echo -e "${BLUE}📄 Output file: $CSV_FILE${NC}"
echo -e "${YELLOW}📊 Scanned $total_scanned total resources, found $total_certs with certificate data${NC}"
echo ""
echo -e "${YELLOW}📋 CSV Columns:${NC}"
echo "   - Secret/ConfigMap: Resource type"
echo "   - Name: Resource name"
echo "   - Namespace: Kubernetes namespace"
echo "   - Data Fields: Available certificate data fields (tls.crt, ca.crt, ca-bundle.crt, etc.)"
echo "   - Validity (years): Certificate validity in years"
echo "   - Actual Expiry: Certificate expiration date"
echo "   - Fingerprint: SHA256 fingerprint of the certificate"
echo "   - Managed Status: Platform-Managed (Auto-Rotated), Platform-Managed (10-Year, Not Auto-Rotated), or User-Managed (Not Auto-Rotated)"
echo "   - Managed Details: Certificate issuer and validity information"
echo "   - CA: CA/Signer category (Service-CA, Platform-CA, Cluster-Proxy CA, Kube-CSR-Signer, Cluster-Manager-Webhook, OVN CA, Monitoring CA, Konnectivity CA, Ingress CA, OLM CA, External CA, or Unknown)"
echo "   - TLS Registry annotations: openshift.io/owning-component, auth.openshift.io/certificate-not-before, auth.openshift.io/certificate-not-after, etc."
echo "   - OC Describe Command: oc describe command"
echo "   - OpenSSL Command: openssl command"
echo ""
echo -e "${GREEN}📄 CSV file created: $CSV_FILE${NC}"
