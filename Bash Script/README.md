# Certificate Discovery Bash Script

A bash script that scans an OpenShift cluster and generates a CSV file with certificate details.

## Overview

The `get-all-cluster-certificates.sh` script discovers all certificates in an OpenShift cluster by scanning secrets and configmaps across all namespaces. It generates a CSV file with detailed certificate information including:

- Issuer information
- Validity periods and expiration dates
- SHA256 fingerprints
- Platform vs User management status
- TLS Registry annotations
- CA categorization (Service-CA, Platform-CA, Cluster-Proxy CA, etc.)
- Commands to reproduce certificate details

## Prerequisites

- `oc` command line tool installed and configured
- `jq` for JSON parsing
- `openssl` for certificate parsing
- `python3` for CSV fingerprint post-processing
- Cluster admin or sufficient permissions to list secrets and configmaps across all namespaces
- Linux or macOS (`date -d` on GNU, `date -j` on BSD)

## Usage

```bash
# Ensure you are logged into your OpenShift cluster
oc login <your-cluster-url>

# Run the scanner
bash get-all-cluster-certificates.sh

# Inspect the output CSV (created in the current directory)
open all-cluster-certificates.csv
```

## Output

The script generates `all-cluster-certificates.csv` in the current directory with the following columns:

- **Secret/ConfigMap**: Resource type
- **Name**: Secret or configmap name
- **Namespace**: Kubernetes namespace
- **Owning component**: `openshift.io/owning-component` (Jira component). If empty: `no owner` when the OpenShift TLS collector requires it, otherwise `not required: <skip reason>` (injected CA replica, not a platform namespace, revisioned, hashed, or not InspectSecret/InspectConfigMap)
- **Owning description**: `openshift.io/description`
- **Data Fields**: Keys that held certificate material (`tls.crt`, `ca.crt`, `ca-bundle.crt`, …)
- **Validity (years)** / **Actual Expiry** / **Fingerprint**: Parsed from the first PEM
- **Managed Status**: Platform-Managed (Auto-Rotated), Platform-Managed (10-Year, Not Auto-Rotated) for kube-apiserver / installer / HyperShift signers that never refresh, or User-Managed (Not Auto-Rotated). A 10-year lifetime alone is not enough (CNO `ovn-ca` / `signer-ca` still rotate).
- **Managed Details**: Issuer and rotation notes
- **CA**: CA category
- **TLS Registry annotations**: `openshift.io/owning-component`, `openshift.io/description`, refresh annotations
- **OC Describe Command** / **OpenSSL Command**: Commands to inspect the same object

## Requirements

- **Permissions**: Cluster admin or sufficient RBAC permissions to:
  - List secrets across all namespaces
  - List configmaps across all namespaces
  - Get infrastructure configuration

## Installation of Dependencies

**macOS:**
```bash
brew install jq openssl
```

**Linux (RHEL/CentOS/Fedora):**
```bash
dnf install jq openssl
```

**Linux (Debian/Ubuntu):**
```bash
apt-get install jq openssl
```

## Related Components

See the `Container/` directory for a web-based version of this certificate discovery tool that provides the same functionality through a web interface.

## License

Apache-2.0



