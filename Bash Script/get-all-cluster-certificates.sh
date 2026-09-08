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

# First PEM in a bundle. One sed, reused by a single openssl parse.
extract_first_pem() {
    local cert_data="$1"
    if [[ "$cert_data" == *"-----BEGIN CERTIFICATE-----"* ]]; then
        printf '%s\n' "$cert_data" | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' | head -n 200
    else
        printf '%s\n' "$cert_data"
    fi
}

# One openssl invocation for subject/issuer/dates/fingerprint. Sets CERT_*.
# CA:TRUE uses -ext basicConstraints (cheap); -text only if that flag is missing.
parse_cert_once() {
    CERT_FINGERPRINT=""
    CERT_ISSUER="N/A"
    CERT_SUBJECT=""
    CERT_CN=""
    CERT_NOT_BEFORE=""
    CERT_NOT_AFTER=""
    CERT_VALIDITY_DAYS=0
    CERT_VALIDITY_YEARS=""
    CERT_IS_CA=false
    local cert_data="$1"
    [[ -z "$cert_data" ]] && return 1
    local first_cert
    first_cert=$(extract_first_pem "$cert_data")
    [[ -z "$first_cert" ]] && return 1

    local out line
    out=$(printf '%s\n' "$first_cert" | openssl x509 -noout -subject -issuer -startdate -enddate -fingerprint -sha256 2>/dev/null) || return 1
    while IFS= read -r line; do
        case "$line" in
            subject=*) CERT_SUBJECT="${line#subject=}" ;;
            issuer=*) CERT_ISSUER="${line#issuer=}" ;;
            notBefore=*) CERT_NOT_BEFORE="${line#notBefore=}" ;;
            notAfter=*) CERT_NOT_AFTER="${line#notAfter=}" ;;
            *Fingerprint=*|*fingerprint=*)
                CERT_FINGERPRINT="${line#*=}"
                CERT_FINGERPRINT="${CERT_FINGERPRINT//:/}"
                CERT_FINGERPRINT=$(printf '%s' "$CERT_FINGERPRINT" | tr '[:lower:]' '[:upper:]')
                ;;
        esac
    done <<< "$out"
    [[ -z "$CERT_ISSUER" ]] && CERT_ISSUER="N/A"

    CERT_CN=$(printf '%s\n' "$CERT_SUBJECT" | sed -n 's/.*[Cc][Nn] *= *//p' | sed 's/,.*//' | head -1)

    local bc_ext=""
    bc_ext=$(printf '%s\n' "$first_cert" | openssl x509 -noout -ext basicConstraints 2>/dev/null || true)
    if [[ "$bc_ext" == *"CA:TRUE"* ]]; then
        CERT_IS_CA=true
    elif [[ "$bc_ext" == *"CA:FALSE"* || "$bc_ext" == *"CA:false"* ]]; then
        CERT_IS_CA=false
    elif printf '%s\n' "$first_cert" | openssl x509 -noout -text 2>/dev/null | grep -q 'CA:TRUE'; then
        CERT_IS_CA=true
    fi

    if [[ -n "$CERT_NOT_BEFORE" && -n "$CERT_NOT_AFTER" ]]; then
        local start_epoch expiry_epoch
        start_epoch=$(date -d "$CERT_NOT_BEFORE" +%s 2>/dev/null || date -j -f "%b %d %H:%M:%S %Y %Z" "$CERT_NOT_BEFORE" +%s 2>/dev/null || echo "")
        expiry_epoch=$(date -d "$CERT_NOT_AFTER" +%s 2>/dev/null || date -j -f "%b %d %H:%M:%S %Y %Z" "$CERT_NOT_AFTER" +%s 2>/dev/null || echo "")
        if [[ -n "$start_epoch" && -n "$expiry_epoch" && "$start_epoch" -gt 0 && "$expiry_epoch" -gt 0 ]]; then
            CERT_VALIDITY_DAYS=$(( (expiry_epoch - start_epoch) / 86400 ))
            CERT_VALIDITY_YEARS=$((CERT_VALIDITY_DAYS / 365))
        fi
    fi
    return 0
}

is_ten_year_lifetime() {
    local validity_days="${1:-0}"
    [[ "$validity_days" =~ ^[0-9]+$ ]] || return 1
    # OpenShift ~10y is 3650 days; floor so leap/rounding still counts. Rotating
    # signers that reuse HyperShift names are 30d–5y.
    [[ "$validity_days" -ge 3285 ]]
}

is_kas_no_rotate() {
    case "$1" in
        localhost-serving-signer|service-network-serving-signer|loadbalancer-serving-signer|localhost-recovery-serving-signer|localhost-recovery-serving-certkey) return 0 ;;
        *) return 1 ;;
    esac
}

is_installer_no_rotate() {
    case "$1" in
        admin-kubeconfig-signer|kubelet-bootstrap-kubeconfig-signer) return 0 ;;
        *) return 1 ;;
    esac
}

is_cno_operator_pki() {
    case "$1" in ovn-ca|signer-ca) return 0 ;; *) return 1 ;; esac
}

is_hypershift_ten_year_ca() {
    case "$1" in
        root-ca|etcd-signer|etcd-metrics-signer|konnectivity-signer|aggregator-client-signer|kas-aggregator-client-signer|kube-control-plane-signer|kube-apiserver-to-kubelet-signer|system-admin-signer|hcco-signer|kube-csr-signer|cluster-signer-ca|csr-signer) return 0 ;;
        *) return 1 ;;
    esac
}

is_known_non_rotate_cn() {
    case "$1" in
        kube-apiserver-localhost-signer|kube-apiserver-service-network-signer|kube-apiserver-lb-signer|localhost-recovery-serving-signer|kubelet-bootstrap-kubeconfig-signer|admin-kubeconfig-signer|kube-apiserver-to-kubelet-signer|kube-csr-signer|kube-control-plane-signer|root-ca|etcd-signer|etcd-metrics-signer|konnectivity-signer|aggregator-signer|hcco-signer) return 0 ;;
        *) return 1 ;;
    esac
}

is_injected_ca_bundle() {
    case "$1" in kube-root-ca.crt|openshift-service-ca.crt|service-ca.crt) return 0 ;; *) return 1 ;; esac
}

is_tls_registry_ns() {
    case "$1" in
        openshift-*|kubernetes-*|openshift|default|kube-system|kube-public|kubernetes) return 0 ;;
        *) return 1 ;;
    esac
}

is_operator_copied_bundle() {
    case "$1" in default-ingress-cert|assisted-trusted-ca-bundle|openshift-config-managed-trusted-ca-bundle|trusted-ca-bundle) return 0 ;; *) return 1 ;; esac
}

is_hypershift_referenced() {
    local resource_json="$1"
    echo "$resource_json" | jq -e '(.metadata.annotations // {}) | keys[]? | select(startswith("referenced-resource.hypershift.openshift.io/"))' >/dev/null 2>&1
}

determine_cert_role() {
    local resource_type="$1"
    local name="$2"
    local has_private_key="$3"
    local is_ca="$4"
    if is_injected_ca_bundle "$name"; then echo "ca-bundle"; return; fi
    if [[ "$resource_type" == "configmap" ]]; then echo "ca-bundle"; return; fi
    if [[ "$has_private_key" != "true" ]] && { [[ "$name" == *-signer ]] || is_hypershift_ten_year_ca "$name" || [[ "$is_ca" == "true" ]]; }; then
        echo "ca-bundle"; return
    fi
    if [[ "$name" == "localhost-recovery-serving-certkey" ]]; then echo "leaf"; return; fi
    if is_kas_no_rotate "$name" || [[ "$is_ca" == "true" ]] || [[ "$name" == *-signer ]] || [[ "$name" == *serving-signer* ]]; then
        echo "signer"; return
    fi
    echo "leaf"
}

# Sets NO_ROTATE_REASON. Return 0 if this secret will not auto-rotate.
classify_no_auto_rotate() {
    local name="$1"
    local cert_role="$2"
    local validity_days="$3"
    local injected="$4"
    local has_private_key="$5"
    local cn="$6"
    NO_ROTATE_REASON=""
    if is_cno_operator_pki "$name" || [[ "$injected" == "true" ]]; then
        return 1
    fi
    is_ten_year_lifetime "$validity_days" || return 1
    if is_kas_no_rotate "$name"; then
        NO_ROTATE_REASON="kas-10y"
        return 0
    fi
    if is_installer_no_rotate "$name"; then
        NO_ROTATE_REASON="installer-10y"
        return 0
    fi
    if [[ "$cert_role" == "ca-bundle" || "$has_private_key" != "true" ]]; then
        return 1
    fi
    if [[ "$cert_role" == "leaf" ]]; then
        return 1
    fi
    if is_hypershift_ten_year_ca "$name" || is_known_non_rotate_cn "$cn"; then
        NO_ROTATE_REASON="hypershift-10y"
        return 0
    fi
    return 1
}

no_rotate_label() {
    case "$1" in
        kas-10y) echo "kube-apiserver 10-year signer" ;;
        installer-10y) echo "Installer 10-year signer" ;;
        hypershift-10y) echo "HyperShift 10-year CA" ;;
        *) echo "" ;;
    esac
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

    local name namespace secret_type tls_crt ca_crt ca_bundle cert_crt
    local has_tls_key has_cert_key has_service_ca_bundle has_platform_ca_bundle
    local cert_not_after cert_not_before owning_component managed_cert_type
    local jira_component description hs_ref is_revisioned is_hashed
    eval "$(printf '%s' "$resource_json" | jq -r '
      def a($k): (.metadata.annotations // {})[$k] // "";
      def l($k): (.metadata.labels // {})[$k] // "";
      [
        "name=\(.metadata.name // "" | @sh)",
        "namespace=\(.metadata.namespace // "" | @sh)",
        "secret_type=\(.type // "" | @sh)",
        "tls_crt=\(.data["tls.crt"] // "" | @sh)",
        "ca_crt=\(.data["ca.crt"] // "" | @sh)",
        "ca_bundle=\(.data["ca-bundle.crt"] // "" | @sh)",
        "cert_crt=\(.data["cert.crt"] // "" | @sh)",
        "has_tls_key=\(if (.data["tls.key"] // "") != "" then "true" else "false" end)",
        "has_cert_key=\(if (.data["cert.key"] // "") != "" then "true" else "false" end)",
        "has_service_ca_bundle=\(if (.data | has("service-ca.crt")) then "true" else "false" end)",
        "has_platform_ca_bundle=\(if (.data | has("ca-bundle.crt") or has("ca.crt")) then "true" else "false" end)",
        "cert_not_after=\(a("auth.openshift.io/certificate-not-after") | @sh)",
        "cert_not_before=\(a("auth.openshift.io/certificate-not-before") | @sh)",
        "owning_component=\(a("openshift.io/owning-component") | @sh)",
        "managed_cert_type=\(l("auth.openshift.io/managed-certificate-type") | @sh)",
        "jira_component=\(a("operator.openshift.io/jira-component") | @sh)",
        "description=\(a("operator.openshift.io/description") | @sh)",
        "hs_ref=\(if any((.metadata.annotations // {}) | keys[]; startswith("referenced-resource.hypershift.openshift.io/")) then "1" else "0" end)",
        "is_revisioned=\(if any((.metadata.ownerReferences // [])[]; ((.name // "") | startswith("revision-status-"))) then "true" else "false" end)",
        "is_hashed=\(if ((.metadata.labels // {}) | has("monitoring.openshift.io/hash")) then "true" else "false" end)"
      ] | join("\n")
    ' 2>/dev/null)" || return 1

    if [[ -z "$name" || -z "$namespace" ]]; then
        return 1
    fi
    
    # Extract data fields that might contain certificates
    local data_fields=""
    local has_cert_data=false
    
    # Build data fields list
    local fields=()
    [[ -n "$tls_crt" ]] && fields+=("tls.crt") && has_cert_data=true
    [[ "$has_tls_key" == "true" ]] && fields+=("tls.key")
    [[ -n "$ca_crt" ]] && fields+=("ca.crt") && has_cert_data=true
    [[ -n "$ca_bundle" ]] && fields+=("ca-bundle.crt") && has_cert_data=true
    [[ -n "$cert_crt" ]] && fields+=("cert.crt") && has_cert_data=true
    [[ "$has_cert_key" == "true" ]] && fields+=("cert.key")
    
    # Skip if no certificate data
    if [[ "$has_cert_data" == false ]]; then
        return 1
    fi
    
    data_fields=$(IFS=","; echo "${fields[*]}")
    
    # Extract certificate data for validity checking
    local cert_data=""
    local validity_years=""
    local actual_expiry=""
    local fingerprint=""
    local issuer="N/A"
    local validity_days=0
    
    if [[ "$resource_type" == "secret" ]]; then
        # For secrets, data is base64 encoded in JSON
        if [[ -n "$tls_crt" ]]; then
            cert_data=$(printf '%s' "$tls_crt" | base64 -d 2>/dev/null)
        elif [[ -n "$ca_crt" ]]; then
            cert_data=$(printf '%s' "$ca_crt" | base64 -d 2>/dev/null)
        elif [[ -n "$cert_crt" ]]; then
            cert_data=$(printf '%s' "$cert_crt" | base64 -d 2>/dev/null)
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
    
    CERT_CN=""
    CERT_IS_CA=false
    if [[ -n "$cert_data" ]]; then
        parse_cert_once "$cert_data"
        fingerprint="$CERT_FINGERPRINT"
        issuer="$CERT_ISSUER"
        validity_days="${CERT_VALIDITY_DAYS:-0}"
        validity_years="$CERT_VALIDITY_YEARS"
        actual_expiry="$CERT_NOT_AFTER"
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
    
    local has_private_key=false
    if [[ "$has_tls_key" == "true" || "$has_cert_key" == "true" ]]; then
        has_private_key=true
    fi
    local cn="$CERT_CN"
    local is_ca=false
    if [[ "$CERT_IS_CA" == "true" ]]; then
        is_ca=true
    fi
    local injected=false
    if is_injected_ca_bundle "$name"; then
        injected=true
    fi
    local cert_role
    cert_role=$(determine_cert_role "$resource_type" "$name" "$has_private_key" "$is_ca")
    local will_not_rotate=false
    local no_rotate_reason=""
    if classify_no_auto_rotate "$name" "$cert_role" "${validity_days:-0}" "$injected" "$has_private_key" "$cn"; then
        will_not_rotate=true
        no_rotate_reason="$NO_ROTATE_REASON"
    fi

    local platform_label="Platform-Managed (Auto-Rotated)"
    if [[ "$will_not_rotate" == true ]]; then
        platform_label="Platform-Managed (10-Year, Not Auto-Rotated)"
    fi
    local details="Issuer: ${issuer}; ${validity_days} days validity"

    # Same rules as Container/app.py: user-managed first, then injected copies,
    # then platform vs auto-rotate. owning-component does not imply rotation.
    if [[ "$hs_ref" == "1" ]] || \
       check_user_provided_certificate "$resource_type" "$name" "$namespace" "$resource_json"; then
        managed_status="User-Managed (Not Auto-Rotated)"
        will_not_rotate=false
        no_rotate_reason=""
        if [[ "$hs_ref" == "1" ]]; then
            managed_details="HyperShift named serving cert (HostedCluster references this Secret; you rotate it); $details"
        else
            managed_details="User-provided certificate in openshift-config; $details"
        fi
    elif is_injected_ca_bundle "$name"; then
        managed_status="Platform-Managed (Auto-Rotated)"
        managed_details="Injected CA replica (not the signer secret)"
    elif is_operator_copied_bundle "$name"; then
        managed_status="Platform-Managed (Auto-Rotated)"
        managed_details="Operator-copied platform bundle; $details"
    elif [[ -n "$owning_component" ]]; then
        managed_status="$platform_label"
        managed_details="$details"
    elif [[ "$is_platform_namespace" == true ]]; then
        managed_status="$platform_label"
        managed_details="$details"
    elif [[ -n "$cert_not_after" ]]; then
        managed_status="Platform-Managed (Auto-Rotated)"
        managed_details="$details"
    elif [[ -n "$issuer" && "$issuer" != "N/A" ]]; then
        local issuer_lower
        issuer_lower=$(printf '%s' "$issuer" | tr '[:upper:]' '[:lower:]')
        if [[ "$issuer_lower" == *service-ca* || "$issuer_lower" == *openshift-service-serving-signer* ]]; then
            managed_status="Platform-Managed (Auto-Rotated)"
            managed_details="Service-CA signed; ${validity_days} days validity"
        elif [[ "$issuer_lower" == *cluster-proxy* ]]; then
            managed_status="Platform-Managed (Auto-Rotated)"
            managed_details="Cluster-Proxy CA signed; ${validity_days} days validity"
        elif [[ "$issuer_lower" == *etcd* || "$issuer_lower" == *kube-apiserver* || \
                "$issuer_lower" == *kube-controller-manager* || "$issuer_lower" == *openshift* || \
                "$issuer_lower" == *kubernetes* || "$issuer_lower" == *kube-csr-signer* || \
                "$issuer_lower" == *cluster-manager-webhook* || "$issuer_lower" == *ingress-operator* || \
                "$issuer_lower" == *root-ca* || "$issuer_lower" == *konnectivity* || \
                "$issuer_lower" == *ovn* ]]; then
            managed_status="$platform_label"
            managed_details="Platform-CA signed; ${validity_days} days validity"
        elif [[ -n "$managed_cert_type" ]]; then
            managed_status="$platform_label"
            managed_details="$details"
        else
            managed_status="User-Managed (Not Auto-Rotated)"
            managed_details="$details"
        fi
    elif [[ -n "$managed_cert_type" ]]; then
        managed_status="$platform_label"
        managed_details="$details"
    else
        managed_status="User-Managed (Not Auto-Rotated)"
        managed_details="$details"
    fi
    if [[ "$will_not_rotate" == true && "$managed_status" == Platform-Managed* ]]; then
        local why
        why=$(no_rotate_label "$no_rotate_reason")
        if [[ -n "$why" ]]; then
            managed_details="${why}; ${managed_details}"
        fi
    fi

    
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
    
    local owner_col="$owning_component"
    local collector_needs=false
    local skip_reason=""
    if [[ "$injected" == true ]]; then
        skip_reason="injected CA replica ($name); collector skips kube-root-ca.crt / service-ca copies"
    elif ! is_tls_registry_ns "$namespace"; then
        skip_reason="$namespace is not an OpenShift platform namespace (openshift-*, kubernetes-*, kube-system, …)"
    elif [[ "$is_revisioned" == true ]]; then
        skip_reason="skipped: owner reference is revision-status-*"
    elif [[ "$is_hashed" == true ]]; then
        skip_reason="skipped: label monitoring.openshift.io/hash"
    elif [[ "$resource_type" == "secret" && -n "$tls_crt" ]]; then
        collector_needs=true
    elif [[ "$resource_type" == "configmap" && -n "$ca_bundle" ]]; then
        collector_needs=true
    elif [[ "$resource_type" == "secret" ]]; then
        skip_reason="not InspectSecret: no tls.crt or kubeconfig client cert"
    else
        skip_reason="not InspectConfigMap: no CA-bundle key or kubeconfig CA"
    fi
    if [[ -z "$owner_col" ]]; then
        if [[ "$collector_needs" == true ]]; then
            owner_col="no owner"
        else
            owner_col="not required: $skip_reason"
        fi
    fi

    # Build CSV line
    local csv_line=""
    csv_line+="$(escape_csv "$resource_type"),"
    csv_line+="$(escape_csv "$name"),"
    csv_line+="$(escape_csv "$namespace"),"
    csv_line+="$(escape_csv "$owner_col"),"
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
    
    echo "$csv_line" >> "$CSV_FILE"
    return 0
}

# Initialize CSV file with headers
echo "Secret/ConfigMap,Name,Namespace,Owning component,Data Fields,Validity (years),Actual Expiry,Fingerprint,Managed Status,Managed Details,CA,TLS Registry annotations,OC Describe Command,OpenSSL Command" > "$CSV_FILE"

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

total_secrets=0
cert_secrets=0

# Stream .items[] once. Do not use jq -c ".items[$i]" (that re-parses the
# whole dump once per secret — O(n²) on large clusters).
if ! jq -e '.items' "$TEMP_SECRETS" >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠️  JSON parse error detected. Using fallback method...${NC}"
    TEMP_SECRET_LIST=$(mktemp)
    oc get secrets --all-namespaces -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name --no-headers 2>/dev/null > "$TEMP_SECRET_LIST"
    while IFS=$' \t' read -r namespace name rest; do
        if [[ -z "$namespace" || -z "$name" ]]; then
            continue
        fi
        ((total_secrets++))
        has_cert=$(oc get secret -n "$namespace" "$name" -o jsonpath='{.data}' 2>/dev/null | jq -r 'keys | map(select(. == "tls.crt" or . == "ca.crt" or . == "cert.crt" or . == "ca-bundle.crt")) | length' 2>/dev/null || echo "0")
        if [[ "$has_cert" -gt 0 ]]; then
            secret_json=$(oc get secret -n "$namespace" "$name" -o json 2>/dev/null)
            if [[ -n "$secret_json" ]] && process_resource "secret" "$secret_json" 2>/dev/null; then
                ((cert_secrets++))
            fi
        fi
    done < "$TEMP_SECRET_LIST"
    rm -f "$TEMP_SECRET_LIST"
else
    echo -e "${YELLOW}📋 Processing secrets with certificate data...${NC}"
    total_secrets=$(jq '.items | length' "$TEMP_SECRETS" 2>/dev/null || echo "0")
    while IFS= read -r secret_json; do
        if process_resource "secret" "$secret_json" 2>/dev/null; then
            ((cert_secrets++))
        fi
    done < <(jq -c '.items[]? | select(.data != null) | select(.data | has("tls.crt") or has("ca.crt") or has("cert.crt") or has("ca-bundle.crt"))' "$TEMP_SECRETS")
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

total_configmaps=0
cert_configmaps=0

if ! jq -e '.items' "$TEMP_CONFIGMAPS" >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠️  Using fallback method for configmaps...${NC}"
    TEMP_CONFIGMAP_LIST=$(mktemp)
    oc get configmaps --all-namespaces -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name --no-headers 2>/dev/null > "$TEMP_CONFIGMAP_LIST"
    while IFS=$' \t' read -r namespace name rest; do
        if [[ -z "$namespace" || -z "$name" ]]; then
            continue
        fi
        ((total_configmaps++))
        has_cert=$(oc get configmap -n "$namespace" "$name" -o jsonpath='{.data}' 2>/dev/null | jq -r 'keys | map(select(. == "tls.crt" or . == "ca.crt" or . == "cert.crt" or . == "ca-bundle.crt")) | length' 2>/dev/null || echo "0")
        if [[ "$has_cert" -gt 0 ]]; then
            configmap_json=$(oc get configmap -n "$namespace" "$name" -o json 2>/dev/null)
            if [[ -n "$configmap_json" ]] && process_resource "configmap" "$configmap_json" 2>/dev/null; then
                ((cert_configmaps++))
            fi
        fi
    done < "$TEMP_CONFIGMAP_LIST"
    rm -f "$TEMP_CONFIGMAP_LIST"
else
    echo -e "${YELLOW}📋 Processing configmaps with certificate data...${NC}"
    total_configmaps=$(jq '.items | length' "$TEMP_CONFIGMAPS" 2>/dev/null || echo "0")
    while IFS= read -r configmap_json; do
        if process_resource "configmap" "$configmap_json" 2>/dev/null; then
            ((cert_configmaps++))
        fi
    done < <(jq -c '.items[]? | select(.data != null) | select(.data | has("tls.crt") or has("ca.crt") or has("cert.crt") or has("ca-bundle.crt"))' "$TEMP_CONFIGMAPS")
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
                    fingerprint_status[fingerprint] = {'is_platform': True}
    
    # Upgrade User-Managed copies of a platform PEM. Do not copy
    # "will not auto-rotate" onto CA-bundle replicas of a 10-year signer.
    updated_count = 0
    for row in rows:
        fingerprint = row.get('Fingerprint', '').strip()
        managed_status = row.get('Managed Status', '').strip()
        
        if fingerprint and fingerprint != 'N/A' and 'User-Managed' in managed_status:
            if fingerprint in fingerprint_status and fingerprint_status[fingerprint]['is_platform']:
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
echo "   - Owning component: Jira component, 'no owner', or 'not required: <collector skip reason>'"
echo "   - Data Fields: Available certificate data fields (tls.crt, ca.crt, ca-bundle.crt, etc.)"
echo "   - Validity (years): Certificate validity in years"
echo "   - Actual Expiry: Certificate expiration date"
echo "   - Fingerprint: SHA256 fingerprint of the certificate"
echo "   - Managed Status: Platform-Managed (Auto-Rotated), Platform-Managed (10-Year, Not Auto-Rotated) for platform signers that never refresh, or User-Managed (Not Auto-Rotated)"
echo "   - Managed Details: Certificate issuer and validity information"
echo "   - CA: CA/Signer category (Service-CA, Platform-CA, Cluster-Proxy CA, Kube-CSR-Signer, Cluster-Manager-Webhook, OVN CA, Monitoring CA, Konnectivity CA, Ingress CA, OLM CA, External CA, or Unknown)"
echo "   - TLS Registry annotations: openshift.io/owning-component, auth.openshift.io/certificate-not-before, auth.openshift.io/certificate-not-after, etc."
echo "   - OC Describe Command: oc describe command"
echo "   - OpenSSL Command: openssl command"
echo ""
echo -e "${GREEN}📄 CSV file created: $CSV_FILE${NC}"
