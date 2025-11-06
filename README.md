# OpenShift Certificate Discovery

OpenShift cluster certificate discovery and analysis tools. This project provides two ways to discover and analyze certificates in your OpenShift cluster:

1. **Bash Script** - Command-line tool that generates a CSV file
2. **Container** - Web application running in the target cluster

Both tools use the same logic to discover certificates from secrets and configmaps across all namespaces, providing detailed information including:

- Issuer information
- Validity periods and expiration dates
- SHA256 fingerprints
- Platform vs User management status
- TLS Registry annotations
- CA categorization (Service-CA, Platform-CA, Cluster-Proxy CA, etc.)
- Commands to reproduce certificate details

## Option 1: Bash Script

The bash script (`Bash Script/get-all-cluster-certificates.sh`) scans your cluster and generates a CSV file with all certificate details.

### Prerequisites

- `oc` command line tool installed and configured
- `jq` for JSON parsing
- `openssl` for certificate parsing
- Cluster admin or sufficient permissions to list secrets and configmaps across all namespaces

### Installation of Dependencies

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

### Usage

```bash
# Ensure you are logged into your OpenShift cluster
oc login <your-cluster-url>

# Navigate to the Bash Script directory
cd Bash\ Script

# Run the scanner
bash get-all-cluster-certificates.sh

# Inspect the output CSV (created in the current directory)
open all-cluster-certificates.csv
```

### Output

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

### Required Permissions

- List secrets across all namespaces
- List configmaps across all namespaces
- Get infrastructure configuration

## Option 2: Container (Web Application)

The container-based web application (`Container/`) provides the same certificate discovery functionality through a web interface with OpenShift console styling. It runs as a deployment in your target cluster.

### Prerequisites

- OpenShift cluster access with **cluster-admin** privileges
  - Required to create ClusterRole and ClusterRoleBinding resources
  - If you don't have cluster-admin access, request a cluster administrator to deploy the application
- `oc` command line tool installed and configured
- Access to `registry.redhat.io` (for pulling the UBI9 Python base image)

### Deployment

#### Step 1: Prepare the Deployment

```bash
# Login to your OpenShift cluster
oc login <your-cluster-url>

# Verify you have cluster-admin privileges
oc auth can-i create clusterrole
oc auth can-i create clusterrolebinding
```

#### Step 2: Deploy the Application

```bash
# Navigate to the Container directory
cd Container

# Apply the deployment manifest
oc apply -f deploy.yaml
```

This creates:
- Namespace: `cert-discovery-app`
- ServiceAccount: `cert-discovery-sa`
- ClusterRole: `cert-discovery-role` (with permissions to list secrets/configmaps)
- ClusterRoleBinding: `cert-discovery-binding`
- Deployment: `cert-discovery-app` (Python Flask application)
- Service: `cert-discovery-service`
- Route: `cert-discovery-route` (OpenShift Route for external access)

#### Step 3: Wait for Deployment

Wait for the pod to be ready (this may take 1-2 minutes as it installs Python dependencies):

```bash
oc wait --for=condition=ready pod -l app=cert-discovery -n cert-discovery-app --timeout=300s
```

#### Step 4: Get the Application URL

```bash
oc get route cert-discovery-route -n cert-discovery-app -o jsonpath='https://{.spec.host}'
```

#### Step 5: Access the Web Interface

Open the URL from step 4 in your web browser. The page will automatically refresh every 5 minutes to show updated certificate information.

### Required Permissions

The application requires the following permissions, which are automatically configured:

**ClusterRole: `cert-discovery-role`**
- `get`, `list` on `secrets` (all namespaces)
- `get`, `list` on `configmaps` (all namespaces)
- `get`, `list` on `namespaces`
- `get` on `infrastructures` (config.openshift.io/v1)

These permissions are bound to the `cert-discovery-sa` ServiceAccount via a ClusterRoleBinding.

**Important:** Only users with **cluster-admin** privileges can create ClusterRole and ClusterRoleBinding resources. If you don't have cluster-admin access, you'll need to request a cluster administrator to deploy the application.

### Architecture

**Container Image:**
- Base: `registry.redhat.io/ubi9/python-311:latest`
- Python dependencies installed at runtime (Flask, kubernetes client, cryptography)

**Application Components:**
- Flask web server (port 8080)
- Kubernetes Python client (uses in-cluster service account configuration)
- Certificate parsing using cryptography library
- Application code stored in ConfigMap (no persistent storage required)

**Resource Requirements:**
- CPU: 200m request, 1000m limit
- Memory: 512Mi request, 2Gi limit

### API Endpoints

- `/` - Main web interface displaying all certificates in a table format
- `/health` - Health check endpoint (returns "OK" - used by readiness probe)
- `/api/certificates` - JSON API returning certificate data as JSON array

### Troubleshooting

#### Pod Not Starting

Check pod status:
```bash
oc get pods -n cert-discovery-app
```

Check pod logs:
```bash
oc logs -n cert-discovery-app -l app=cert-discovery --tail=50
```

Check events:
```bash
oc get events -n cert-discovery-app --sort-by='.lastTimestamp' | tail -10
```

#### Permission Errors

Verify RBAC is correctly configured:
```bash
oc auth can-i list secrets --as=system:serviceaccount:cert-discovery-app:cert-discovery-sa --all-namespaces
oc auth can-i list configmaps --as=system:serviceaccount:cert-discovery-app:cert-discovery-sa --all-namespaces
```

Both commands should return `yes`. If they return `no`, check that the ClusterRoleBinding was created correctly.

#### Application Not Discovering Certificates

If the web interface shows 0 certificates:
1. Check pod logs for errors
2. Verify the service account has the correct permissions (see above)
3. Ensure you're logged into the correct cluster
4. Check if there are any certificate parsing errors in the logs

#### Route Not Accessible

Check route status:
```bash
oc get route cert-discovery-route -n cert-discovery-app
oc describe route cert-discovery-route -n cert-discovery-app
```

Verify the service is working:
```bash
oc get svc cert-discovery-service -n cert-discovery-app
```

Test the service directly (from within the cluster):
```bash
oc run test-pod --image=curlimages/curl --rm -it --restart=Never -- curl http://cert-discovery-service.cert-discovery-app.svc.cluster.local/
```

### Uninstallation

To completely remove the application:

```bash
cd Container
oc delete -f deploy.yaml
```

This will remove:
- The deployment, service, and route
- The namespace `cert-discovery-app` and all resources within it
- The ClusterRole `cert-discovery-role`
- The ClusterRoleBinding `cert-discovery-binding`

**Note:** Removing ClusterRole and ClusterRoleBinding requires cluster-admin privileges.

## Documentation

Additional documentation is available in the `docs/` directory:

- **`docs/CERTIFICATE_ROTATION_CODE_ANALYSIS.md`**: Explains rotation policies (80% rule), links to upstream code, and shows exact lines that implement rotation across Service-CA, Platform-CA, Cluster-Proxy CA, HyperShift CSR signer, and OCM webhook signer.
- **`docs/OWNERSHIP_MD_GENERATION_ANALYSIS.md`**: Analysis of certificate ownership registry generation.
- **`docs/REFRESH_PERIOD_MD_GENERATION_ANALYSIS.md`**: Analysis of refresh period generation.

## Examples

Sample certificate discovery outputs are available in the `examples/` directory:

- **`examples/all-cluster-certificates.csv`**: Full CSV (cluster scan output)
- **`examples/all-cluster-certificates.sample.csv`**: Sample CSV (first 50 rows)

## License

Apache-2.0



