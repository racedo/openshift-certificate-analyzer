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

# Update the ConfigMap with the latest application code
oc create configmap cert-discovery-app-code \
  --from-file=app.py=app.py \
  -n cert-discovery-app \
  --dry-run=client -o yaml | oc apply -f -

# Restart the deployment to pick up the updated code
oc rollout restart deployment/cert-discovery-app -n cert-discovery-app
```

This creates:
- Namespace: `cert-discovery-app`
- PersistentVolumeClaim: `cert-discovery-data` (10Gi, for historical data storage)
- ServiceAccount: `cert-discovery-sa`
- ClusterRole: `cert-discovery-role` (with permissions to list secrets/configmaps)
- ClusterRoleBinding: `cert-discovery-binding`
- Deployment: `cert-discovery-app` (Python Flask application)
- ConfigMap: `cert-discovery-app-code` (application code)
- Service: `cert-discovery-service`
- Route: `cert-discovery-route` (OpenShift Route for external access)

#### Step 3: Verify Deployment

Wait for the pod to be ready (this may take 1-2 minutes as it installs Python dependencies):

```bash
oc wait --for=condition=ready pod -l app=cert-discovery -n cert-discovery-app --timeout=300s
```

Verify the PersistentVolumeClaim is bound:

```bash
oc get pvc -n cert-discovery-app
```

Check that the database initialized successfully:

```bash
oc logs -n cert-discovery-app -l app=cert-discovery --tail=50 | grep -i database
```

You should see:
```
Database initialized successfully at /data/certificates.db
Database initialized and available for historical tracking
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
- Application code stored in ConfigMap
- **SQLite database** on PersistentVolume for historical certificate tracking
- **Background refresh thread** (5-minute interval) with automatic database saves

**Resource Requirements:**
- CPU: 200m request, 1000m limit
- Memory: 512Mi request, 2Gi limit
- Storage: 10Gi PVC (lvms-vg1 storage class)

### Features

**Real-time Certificate Discovery:**
- Scans all namespaces for certificates in secrets and configmaps
- Analyzes certificate properties (issuer, expiry, fingerprint)
- Classifies certificates as platform-managed vs user-managed
- Updates automatically every 5 minutes via background thread

**Historical Tracking:**
- Stores discovery results in SQLite database on persistent volume
- Tracks certificate changes over time (additions, removals, rotations)
- Provides audit trail for compliance requirements
- Survives pod restarts and maintains full history

### API Endpoints

**Current Data:**
- `/` - Main web interface displaying all certificates in a table format
- `/health` - Health check endpoint (returns "OK" - used by readiness probe)
- `/api/certificates` - JSON API returning current certificate data

**Historical Data:**
- `/api/history` - List all certificate discovery runs (last 100)
- `/api/history/<id>` - Get specific discovery run details
- `/api/changes` - Compare last two discovery runs (shows added/removed/changed certificates)

**Example:**
```bash
# Get current certificates
curl -k https://<route-url>/api/certificates | jq '.total'

# View discovery history
curl -k https://<route-url>/api/history | jq '.[0]'

# See what changed between last two scans
curl -k https://<route-url>/api/changes | jq
```

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

### Database and Historical Data

The application stores historical certificate discovery data in a SQLite database (`/data/certificates.db`) on a PersistentVolume. This enables:

**Certificate Change Tracking:**
- Compare certificates between discovery runs
- Identify certificate rotations (fingerprint changes)
- Track certificate additions and removals

**Query Historical Data:**
```bash
# Count total discovery runs
oc exec -n cert-discovery-app deployment/cert-discovery-app -- \
  sqlite3 /data/certificates.db "SELECT COUNT(*) FROM certificate_discoveries;"

# View recent discoveries
oc exec -n cert-discovery-app deployment/cert-discovery-app -- \
  sqlite3 /data/certificates.db \
  "SELECT id, timestamp, total_certificates FROM certificate_discoveries ORDER BY timestamp DESC LIMIT 5;"

# Check database integrity
oc exec -n cert-discovery-app deployment/cert-discovery-app -- \
  sqlite3 /data/certificates.db "PRAGMA integrity_check;"
```

**Storage Estimates:**
- ~1 KB per certificate record
- ~667 certificates per discovery run (typical cluster)
- 1 discovery every 5 minutes = 288 runs/day
- Daily storage: ~192 MB
- 30-day retention: ~5.8 GB

The 10Gi PVC provides ample space for several months of historical data.

### Updating the Application Code

If you modify `app.py`, update the running deployment:

```bash
cd Container

# Update ConfigMap with new code
oc create configmap cert-discovery-app-code \
  --from-file=app.py=app.py \
  -n cert-discovery-app \
  --dry-run=client -o yaml | oc apply -f -

# Restart deployment to pick up changes
oc rollout restart deployment/cert-discovery-app -n cert-discovery-app

# Wait for new pod to be ready
oc wait --for=condition=ready pod -l app=cert-discovery -n cert-discovery-app --timeout=300s
```

### Uninstallation

To completely remove the application:

```bash
cd Container
oc delete -f deploy.yaml
```

This will remove:
- The deployment, service, and route
- The PersistentVolumeClaim and all historical data
- The namespace `cert-discovery-app` and all resources within it
- The ClusterRole `cert-discovery-role`
- The ClusterRoleBinding `cert-discovery-binding`

**Note:** Removing ClusterRole and ClusterRoleBinding requires cluster-admin privileges.

**Warning:** Deleting the namespace will permanently delete the PersistentVolumeClaim and all historical certificate data. If you need to preserve the data, back up the database first:

```bash
# Backup database before deletion
oc exec -n cert-discovery-app deployment/cert-discovery-app -- \
  cat /data/certificates.db > certificates-backup.db
```

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



