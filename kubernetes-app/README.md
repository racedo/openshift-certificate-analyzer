# Kubernetes Certificate Status App

This directory contains all the Kubernetes/OpenShift deployment manifests for the certificate status application.

## Deployment Files

### 🚀 Main Application Deployments
- **`deploy-cert-status-app-simple.yaml`** - Main deployment (recommended)
- **`deploy-cert-status-app.yaml`** - Full-featured deployment
- **`deploy-cert-status-app-with-annotations.yaml`** - With refresh period annotations
- **`deploy-cert-status-app-with-rotation.yaml`** - With 80% rotation logic

### 🔧 Alternative Deployments
- **`deploy-cert-status-app-fixed.yaml`** - Simplified version
- **`deploy-cert-status-app-working.yaml`** - Working version
- **`deploy-cert-status-app-final.yaml`** - Final version

### 📊 Platform Certificate Deployments
- **`deploy-platform-certs-status-app.yaml`** - Platform certificates focus
- **`deploy-platform-certs-fresh.yaml`** - Fresh platform certificates

### 🧪 Test Deployments
- **`hello-world-*.yaml`** - Test applications for routing verification

## Documentation

### 📚 Guides and Documentation
- **`SSL-App-Deployment-Guide.md`** - Complete deployment guide
- **`README-scripts.md`** - Script documentation
- **`Corrected-80-Percent-Rotation-Update.md`** - Rotation logic documentation
- **`Source-Based-Certificate-Rotation-Update.md`** - Source-based rotation
- **`OpenShift-Console-Theme-Update.md`** - UI theme updates

## Quick Start

### Deploy the Certificate Status App
```bash
# Deploy the main application
oc apply -f deploy-cert-status-app-simple.yaml

# Check deployment status
oc get pods -n cert-status-app

# Get the route URL
oc get route -n cert-status-app
```

### Access the Application
```bash
# Get the application URL
oc get route cert-status-route -n cert-status-app -o jsonpath='{.spec.host}'

# Access via browser or curl
curl -k https://<route-url>/certs.html
```

## Application Features

- **Real-time certificate monitoring**
- **80% rotation calculation**
- **Refresh period annotations**
- **Comprehensive certificate coverage**
- **Clean web interface**
- **CSV export capability**

## Troubleshooting

### Common Issues
1. **Image Pull Errors**: Check registry connectivity
2. **Routing Issues**: Verify ingress controller status
3. **Permission Errors**: Ensure proper RBAC configuration
4. **Script Errors**: Check container logs

### Debug Commands
```bash
# Check pod status
oc get pods -n cert-status-app

# View container logs
oc logs -n cert-status-app -l app=cert-status-monitor

# Check service and route
oc get svc,route -n cert-status-app

# Port forward for testing
oc port-forward svc/cert-status-service 8080:8080 -n cert-status-app
```

## Architecture

The application consists of:
- **Namespace**: `cert-status-app`
- **Deployment**: Certificate monitoring pods
- **Service**: HTTP service on port 8080
- **Route**: HTTPS route for external access
- **ConfigMap**: Certificate checking script
- **RBAC**: ServiceAccount, ClusterRole, ClusterRoleBinding

## Customization

### Modify Certificate Namespaces
Edit the `check-certs.sh` script in the ConfigMap to add/remove namespaces.

### Update Refresh Periods
Modify the script to change rotation calculation percentages.

### Change UI Theme
Update the HTML/CSS in the ConfigMap for different styling.

