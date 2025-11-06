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
- Cluster admin or sufficient permissions to list secrets and configmaps across all namespaces

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

- **Namespace**: The namespace where the certificate was found
- **Name**: The name of the secret or configmap
- **Type**: Resource type (Secret or ConfigMap)
- **Key**: The key within the resource containing the certificate
- **Issuer**: Certificate issuer information
- **Valid From**: Certificate validity start date
- **Valid To**: Certificate expiration date
- **Validity Days**: Number of days until expiration
- **SHA256 Fingerprint**: Certificate fingerprint
- **Managed Status**: Platform-Managed or User-Managed classification
- **Managed Details**: Additional management details (rotation policy, etc.)
- **TLS Registry annotations**: Relevant TLS registry annotations
- **CA Category**: CA type classification
- **Reproduce Command**: Command to view the certificate details

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



