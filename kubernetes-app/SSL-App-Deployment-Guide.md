# SSL-Enabled Application Deployment Guide for OpenShift

## Overview
This guide documents the complete process for deploying an SSL-enabled application in OpenShift with proper port configurations, service mapping, and ingress route setup.

## Key Components & Port Flow

```
External URL (HTTPS:443) 
    ↓
OpenShift Route (SSL Passthrough)
    ↓  
Service (Port 443 → targetPort 8443)
    ↓
Pod Container (containerPort 8443)
    ↓
Application (httpd listening on 0.0.0.0:8443)
```

## 1. Container Configuration

### Required Container Ports
When your application serves both HTTP and HTTPS, you **MUST** declare both ports in the deployment:

```yaml
spec:
  template:
    spec:
      containers:
      - name: httpd
        image: registry.redhat.io/rhel8/httpd-24:latest
        ports:
        - containerPort: 8080   # HTTP port
          protocol: TCP
        - containerPort: 8443   # HTTPS port (CRITICAL!)
          protocol: TCP
```

### ⚠️ Common Mistake
**DO NOT** omit the HTTPS containerPort declaration. Even if httpd is configured to listen on 8443, OpenShift networking requires the port to be explicitly declared.

## 2. Service Configuration

### SSL Service Setup
Configure the service to map external HTTPS traffic to the container's HTTPS port:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: platform-certs-status-service
  namespace: cert-status-app
  labels:
    app: platform-certs-status-monitor
spec:
  selector:
    app: platform-certs-status-monitor
  ports:
  - port: 443              # External service port
    targetPort: 8443       # Container port (must match containerPort)
    protocol: TCP
  type: ClusterIP
```

### Port Mapping Rules
- `port`: The port that other services/routes will connect to
- `targetPort`: Must match the `containerPort` in your deployment
- For SSL apps: Use 443 → 8443 (standard SSL ports)

## 3. Route Configuration

### SSL Passthrough Route
For applications that handle their own SSL termination (like httpd with SSL):

```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: platform-certs-status-route
  namespace: cert-status-app
  labels:
    app: platform-certs-status-monitor
spec:
  host: your-app.apps.cluster-domain.com  # Auto-generated if omitted
  tls:
    termination: passthrough               # Let the app handle SSL
  to:
    kind: Service
    name: platform-certs-status-service
    weight: 100
  # DO NOT specify spec.port for passthrough - let it use service port
```

### ⚠️ Critical Route Configuration
- **DO NOT** specify `spec.port.targetPort` in the route for passthrough SSL
- The route will automatically use the service's port (443)
- Use `termination: passthrough` when your app handles SSL certificates

## 4. Application SSL Configuration

### httpd SSL Setup
Ensure your httpd container is configured to serve HTTPS:

```apache
# /etc/httpd/conf.d/ssl.conf
Listen 0.0.0.0:8443 https
SSLEngine on
```

### Certificate Management
- For development: httpd can generate self-signed certificates
- For production: Use proper certificates or OpenShift certificate management

## 5. Deployment Command Sequence

### Step 1: Deploy the Application
```bash
oc apply -f deployment.yaml
```

### Step 2: Create the Service
```bash
oc apply -f service.yaml
```

### Step 3: Create the Route
```bash
oc apply -f route.yaml
```

### Step 4: Verify Configuration
```bash
# Check pod ports
oc get pod <pod-name> -o jsonpath='{.spec.containers[*].ports}' | jq .

# Check service endpoints
oc get endpoints <service-name>

# Check route configuration
oc describe route <route-name>
```

## 6. Troubleshooting Guide

### Issue: SSL Connection Errors
**Symptoms**: `SSL_ERROR_SYSCALL` or connection refused on HTTPS

**Check**:
1. Container has `containerPort: 8443` declared
2. Service has `port: 443` and `targetPort: 8443`
3. Route uses `termination: passthrough`
4. httpd is configured with `Listen 0.0.0.0:8443`

### Issue: Service Endpoints Empty
**Symptoms**: `oc describe route` shows `Endpoints: <none>`

**Solution**:
1. Verify pod labels match service selector
2. Ensure container ports are declared
3. Check if pods are ready (`2/2 Running`)

### Issue: Route Not Accessible
**Symptoms**: 503 Service Unavailable

**Check**:
1. Service selector matches pod labels
2. Service targetPort matches container port
3. Remove any incorrect `spec.port` configuration from route

## 7. Testing & Validation

### Local Testing (via Port Forward)
```bash
# Test HTTP port
oc port-forward service/<service-name> 8091:80 &
curl http://localhost:8091/

# Test HTTPS port  
oc port-forward service/<service-name> 8092:443 &
curl -k https://localhost:8092/
```

### External Route Testing
```bash
# Test the external route
curl -k https://<route-host>/
curl -k https://<route-host>/certs.html
```

### Log Verification
```bash
# Check application logs
oc logs deployment/<deployment-name> -c <container-name>

# Check for SSL configuration
oc exec deployment/<deployment-name> -c httpd -- grep -r "Listen.*8443" /etc/httpd/
```

## 8. Complete Example Manifests

### Deployment with Dual Ports
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: platform-certs-status-app
  namespace: cert-status-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: platform-certs-status-monitor
  template:
    metadata:
      labels:
        app: platform-certs-status-monitor
    spec:
      containers:
      - name: httpd
        image: registry.redhat.io/rhel8/httpd-24:latest
        ports:
        - containerPort: 8080   # HTTP
          protocol: TCP
        - containerPort: 8443   # HTTPS
          protocol: TCP
        resources:
          limits:
            cpu: 100m
            memory: 128Mi
          requests:
            cpu: 50m
            memory: 64Mi
```

### SSL Service
```yaml
apiVersion: v1
kind: Service
metadata:
  name: platform-certs-status-service
  namespace: cert-status-app
spec:
  selector:
    app: platform-certs-status-monitor
  ports:
  - port: 443
    targetPort: 8443
    protocol: TCP
  type: ClusterIP
```

### Passthrough Route
```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: platform-certs-status-route
  namespace: cert-status-app
spec:
  tls:
    termination: passthrough
  to:
    kind: Service
    name: platform-certs-status-service
    weight: 100
```

## 9. Key Success Factors

### ✅ Essential Requirements
1. **Container Ports**: Declare both 8080 and 8443 in deployment
2. **Service Mapping**: 443 → 8443 for HTTPS traffic
3. **Route Configuration**: Use passthrough termination, no targetPort specification
4. **Label Matching**: Pod labels must match service selector exactly
5. **Application Configuration**: httpd must listen on 0.0.0.0:8443

### ❌ Common Pitfalls to Avoid
1. Missing containerPort declaration for HTTPS
2. Incorrect service port mapping
3. Specifying targetPort in route configuration
4. Label mismatch between pods and service
5. httpd not configured for SSL

## 10. Production Considerations

### Security
- Use proper SSL certificates (not self-signed)
- Configure proper SSL ciphers and protocols
- Implement certificate rotation

### Monitoring
- Monitor certificate expiration dates
- Set up health checks for both HTTP and HTTPS endpoints
- Monitor route and service availability

### Scaling
- Consider using horizontal pod autoscaler
- Implement proper resource limits and requests
- Use persistent storage for certificate data if needed

---

**Created**: Based on troubleshooting the platform-certs-status-app deployment
**Last Updated**: July 25, 2025
**Version**: 1.0 