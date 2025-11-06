# Certificate Discovery Web App

A Python-based web application that provides cluster-wide certificate discovery and analysis through a web interface with OpenShift console styling.

## Overview

The Certificate Discovery Web App uses the same logic as the bash script in the `../Bash Script/` directory to discover and display all certificates in an OpenShift cluster. It provides a web-based interface that shows:

- All certificates from secrets and configmaps across all namespaces
- Certificate management status (Platform-Managed vs User-Managed)
- CA category classification (Service-CA, Platform-CA, Cluster-Proxy CA, etc.)
- TLS Registry annotations
- Certificate validity periods and expiration dates
- SHA256 fingerprints

## Prerequisites

- OpenShift cluster access with **cluster-admin** privileges
  - Required to create ClusterRole and ClusterRoleBinding resources
  - If you don't have cluster-admin access, request a cluster administrator to deploy the application
- `oc` command line tool installed and configured
- Access to `registry.redhat.io` (for pulling the UBI9 Python base image)

## Deployment

### Step 1: Prepare the Deployment

Ensure you have the deployment manifest (`deploy.yaml`) and are logged into your cluster:

```bash
# Login to your OpenShift cluster
oc login <your-cluster-url>

# Verify you have cluster-admin privileges
oc auth can-i create clusterrole
oc auth can-i create clusterrolebinding
```

### Step 2: Deploy the Application

```bash
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

### Step 3: Wait for Deployment

Wait for the pod to be ready (this may take 1-2 minutes as it installs Python dependencies):

```bash
oc wait --for=condition=ready pod -l app=cert-discovery -n cert-discovery-app --timeout=300s
```

### Step 4: Get the Application URL

```bash
oc get route cert-discovery-route -n cert-discovery-app -o jsonpath='https://{.spec.host}'
```

### Step 5: Access the Web Interface

Open the URL from step 4 in your web browser. The page will automatically refresh every 5 minutes to show updated certificate information.

## Required Permissions

The application requires the following permissions, which are automatically configured:

**ClusterRole: `cert-discovery-role`**
- `get`, `list` on `secrets` (all namespaces)
- `get`, `list` on `configmaps` (all namespaces)
- `get`, `list` on `namespaces`
- `get` on `infrastructures` (config.openshift.io/v1)

These permissions are bound to the `cert-discovery-sa` ServiceAccount via a ClusterRoleBinding.

**Important:** Only users with **cluster-admin** privileges can create ClusterRole and ClusterRoleBinding resources. If you don't have cluster-admin access, you'll need to request a cluster administrator to deploy the application.

## Architecture

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

## API Endpoints

- `/` - Main web interface displaying all certificates in a table format
- `/health` - Health check endpoint (returns "OK" - used by readiness probe)
- `/api/certificates` - JSON API returning certificate data as JSON array

## Troubleshooting

### Pod Not Starting

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

### Permission Errors

Verify RBAC is correctly configured:
```bash
oc auth can-i list secrets --as=system:serviceaccount:cert-discovery-app:cert-discovery-sa --all-namespaces
oc auth can-i list configmaps --as=system:serviceaccount:cert-discovery-app:cert-discovery-sa --all-namespaces
```

Both commands should return `yes`. If they return `no`, check that the ClusterRoleBinding was created correctly.

### Application Not Discovering Certificates

If the web interface shows 0 certificates:
1. Check pod logs for errors
2. Verify the service account has the correct permissions (see above)
3. Ensure you're logged into the correct cluster
4. Check if there are any certificate parsing errors in the logs

### Route Not Accessible

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

## Uninstallation

To completely remove the application:

```bash
oc delete -f deploy.yaml
```

This will remove:
- The deployment, service, and route
- The namespace `cert-discovery-app` and all resources within it
- The ClusterRole `cert-discovery-role`
- The ClusterRoleBinding `cert-discovery-binding`

**Note:** Removing ClusterRole and ClusterRoleBinding requires cluster-admin privileges.

## Development

### Local Development

To run the application locally for testing:

```bash
# Install dependencies
pip install -r requirements.txt

# Set KUBECONFIG to your cluster
export KUBECONFIG=/path/to/your/kubeconfig

# Run the application
python3 app.py
```

The application will be available at `http://localhost:8080`

### Building a Custom Image

If you want to build a custom container image:

```bash
# Build the image
podman build -t cert-discovery-app:latest -f Dockerfile .

# Tag for your registry
podman tag cert-discovery-app:latest <your-registry>/cert-discovery-app:latest

# Push to registry
podman push <your-registry>/cert-discovery-app:latest
```

Then update `deploy.yaml` to use your custom image instead of the runtime dependency installation approach.

## Related Components

See the `../Bash Script/` directory for the bash script version of this certificate discovery tool.

## Files

- `app.py` - Main Flask application with certificate discovery logic
- `deploy.yaml` - Kubernetes/OpenShift deployment manifest
- `requirements.txt` - Python dependencies
- `Dockerfile` - Container image definition (optional, currently uses runtime installation)

## License

Apache-2.0


