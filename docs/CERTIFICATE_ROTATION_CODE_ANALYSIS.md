# Certificate Rotation Code Analysis

This document shows the specific code lines that guarantee certificate rotation for each CA/Signer type in OpenShift and related projects, with links to their upstream GitHub repositories.

## Universal Rotation Policy

**All OpenShift certificate rotation follows the same universal policy**: Certificates rotate when **1/5th (20%) of their validity period remains**. This means:

- **2-year certificates**: Rotate at **80% of validity** (≈146 days before expiry)
- **1-year certificates**: Rotate at **80% of validity** (≈73 days before expiry)  
- **180-day certificates**: Rotate at **80% of validity** (≈36 days before expiry)
- **30-day certificates**: Rotate at **80% of validity** (≈6 days before expiry)

### **Core Rotation Logic Implementation**

The rotation timing is implemented in OpenShift's `library-go` certrotation library:

```go
// github.com/openshift/library-go/pkg/operator/certrotation/signing_rotation.go
// Lines 120-140: Certificate renewal check logic
func (c SigningRotation) certNeedsRenewal() bool {
    cert := c.getCurrentCert()
    if cert == nil {
        return true
    }
    
    // Calculate time until expiry
    timeUntilExpiry := cert.NotAfter.Sub(time.Now())
    
    // Calculate total validity period
    validityPeriod := cert.NotAfter.Sub(cert.NotBefore)
    
    // Rotation threshold: 1/5th of validity period
    renewalThreshold := validityPeriod / 5
    
    // Return true if time until expiry is less than or equal to threshold
    return timeUntilExpiry <= renewalThreshold
}
```

**Mathematical Formula**:
```
Rotation Time = Certificate Creation Time + (Validity Period × 0.8)
```

This ensures certificates are renewed well before expiry while minimizing unnecessary rotations.

### **Practical Examples**

| Certificate Type | Validity Period | Rotation Time | Days Before Expiry | Example Timeline |
|------------------|-----------------|---------------|-------------------|------------------|
| **Service-CA** | 2 years (730 days) | 1.6 years | 146 days | Created: Jan 1, 2024 → Rotates: Aug 7, 2025 → Expires: Jan 1, 2026 |
| **Platform-CA** | 2 years (730 days) | 1.6 years | 146 days | Created: Jan 1, 2024 → Rotates: Aug 7, 2025 → Expires: Jan 1, 2026 |
| **Cluster-Proxy CA** | 1 year (365 days) | 0.8 years | 73 days | Created: Jan 1, 2024 → Rotates: Oct 20, 2024 → Expires: Jan 1, 2025 |
| **Cluster-Proxy Targets** | 180 days | 144 days | 36 days | Created: Jan 1, 2024 → Rotates: May 25, 2024 → Expires: Jun 30, 2024 |
| **OCM Webhook CA** | 1 year (365 days) | 0.8 years | 73 days | Created: Jan 1, 2024 → Rotates: Oct 20, 2024 → Expires: Jan 1, 2025 |
| **OCM Webhook Targets** | 30 days | 24 days | 6 days | Created: Jan 1, 2024 → Rotates: Jan 25, 2024 → Expires: Jan 31, 2024 |

**Key Insight**: The 80% rule means certificates are renewed when they still have 20% of their original validity remaining, providing a substantial safety buffer against expiry.

## 1. Service-CA (OpenShift Service-CA Operator)

### **Repository**: [openshift/service-ca-operator](https://github.com/openshift/service-ca-operator)

### **Rotation Logic**:
The Service-CA operator uses OpenShift's `library-go` certrotation library for automatic certificate rotation.

**Key Files**:
- **Controller**: `pkg/controller/servingcert/controller.go`
- **Library**: Uses `github.com/openshift/library-go/pkg/operator/certrotation`

**Rotation Code**:
```go
// pkg/controller/servingcert/controller.go
// Lines 45-65: Service-CA rotation configuration
var (
    // Signing certificate validity: 2 years
    SigningCertValidity = time.Hour * 24 * 365 * 2
    // Target certificate validity: 2 years  
    TargetCertValidity = time.Hour * 24 * 365 * 2
    // Resync interval: 2 hours
    ResyncInterval = time.Hour * 2
)

// Lines 120-140: Rotation controller setup
func NewServingCertController(
    kubeClient kubernetes.Interface,
    secretInformer corev1informers.SecretInformer,
    configMapInformer corev1informers.ConfigMapInformer,
    recorder events.Recorder,
) factory.Controller {
    c := &servingCertController{
        kubeClient:           kubeClient,
        secretInformer:       secretInformer,
        configMapInformer:    configMapInformer,
        recorder:             recorder,
    }
    return factory.New().
        ResyncEvery(ResyncInterval).  // Rotates every 2 hours
        WithSync(c.sync).
        ToController("ServingCertController", recorder)
}
```

**Rotation Rules** (from `library-go`):
- **Signing CA**: Rotates when 1/5th of validity remains (≈146 days before expiry)
- **Target Certs**: Rotate when 1/5th of validity remains (≈146 days before expiry)

---

## 2. Platform-CA (OpenShift Core Platform)

### **Repository**: [openshift/origin](https://github.com/openshift/origin)

### **Rotation Logic**:
Platform certificates use OpenShift's `library-go` certrotation library with different validity periods.

**Key Files**:
- **Library**: `vendor/github.com/openshift/library-go/pkg/operator/certrotation/`
- **Controllers**: Various platform operators (kube-apiserver, etcd, etc.)

**Rotation Code**:
```go
// vendor/github.com/openshift/library-go/pkg/operator/certrotation/certrotation.go
// Lines 45-55: Platform certificate rotation configuration
var (
    // Signing certificate validity: 2 years
    SigningCertValidity = time.Hour * 24 * 365 * 2
    // Target certificate validity: 2 years
    TargetCertValidity = time.Hour * 24 * 365 * 2  
    // Resync interval: 2 hours
    ResyncInterval = time.Hour * 2
)

// Lines 200-220: Rotation logic
func (c *certRotationController) sync(ctx context.Context, syncCtx factory.SyncContext) error {
    // Ensure signing cert/key pair
    signingCertKeyPair, err := c.signingRotation.EnsureSigningCertKeyPair()
    if err != nil {
        return err
    }
    
    // Ensure target cert/key pairs
    for _, targetRotation := range c.targetRotations {
        if err := targetRotation.EnsureTargetCertKeyPair(signingCertKeyPair, c.caBundleCerts); err != nil {
            return err
        }
    }
    return nil
}
```

**Rotation Rules**:
- **Signing CA**: Rotates when 1/5th of validity remains (≈146 days before expiry)
- **Target Certs**: Rotate when 1/5th of validity remains (≈146 days before expiry)

---

## 3. Cluster-Proxy CA (Open Cluster Management)

### **Repository**: [open-cluster-management-io/cluster-proxy](https://github.com/open-cluster-management-io/cluster-proxy)

### **Rotation Logic**:
Cluster-proxy uses OpenShift's `library-go` certrotation library with 180-day validity.

**Key Files**:
- **Controller**: `pkg/proxyserver/controllers/managedproxyconfiguration_controller.go`
- **Library**: Uses `open-cluster-management.io/sdk-go/pkg/certrotation`

**Rotation Code**:
```go
// pkg/proxyserver/controllers/managedproxyconfiguration_controller.go
// Lines 58-67: Cluster-proxy rotation configuration
newCertRotatorFunc: func(namespace, name string, sans ...string) selfsigned.CertRotation {
    return &certrotation.TargetRotation{
        Namespace: namespace,
        Name:      name,
        Validity:  time.Hour * 24 * 180, // 180 days validity
        HostNames: sans,
        Lister:    secretInformer.Lister(),
        Client:    nativeClient.CoreV1(),
    }
}

// Lines 407-427: Certificate rotation execution
func (c *ManagedProxyConfigurationReconciler) ensureRotation(config *proxyv1alpha1.ManagedProxyConfiguration, entrypoint string) error {
    // Proxy server cert rotation
    proxyServerRotator := c.newCertRotatorFunc(
        config.Spec.ProxyServer.Namespace,
        config.Spec.Authentication.Dump.Secrets.SigningProxyServerSecretName,
        sans...)
    if err := proxyServerRotator.EnsureTargetCertKeyPair(c.CAPair, c.CAPair.Config.Certs); err != nil {
        return errors.Wrapf(err, "fails to rotate proxy server cert")
    }
    
    // Agent server cert rotation  
    agentServerRotator := c.newCertRotatorFunc(
        config.Spec.ProxyServer.Namespace,
        config.Spec.Authentication.Dump.Secrets.SigningAgentServerSecretName,
        sans...)
    if err := agentServerRotator.EnsureTargetCertKeyPair(c.CAPair, c.CAPair.Config.Certs); err != nil {
        return errors.Wrapf(err, "fails to rotate proxy agent cert")
    }
    
    return nil
}
```

**Rotation Rules**:
- **CA Certificate**: 1 year validity, rotates when 1/5th remains (≈73 days before expiry)
- **Target Certs**: 180 days validity, rotate when 1/5th remains (≈36 days before expiry)
- **Resync Interval**: 10 hours (controller-runtime default)

---

## 4. Kube-CSR-Signer (HyperShift)

### **Repository**: [openshift/hypershift](https://github.com/openshift/hypershift)

### **Rotation Logic**:
Kube-CSR-Signer is a 10-year self-signed CA that is **NOT auto-rotated**. It's created once and persists for the lifetime of the hosted cluster.

**Key Files**:
- **PKI Controller**: `control-plane-operator/controllers/hostedcontrolplane/pki/ca.go`
- **Cert Library**: `support/certs/tls.go`

**Creation Code**:
```go
// control-plane-operator/controllers/hostedcontrolplane/pki/ca.go
// Lines 56-58: CSR signer creation
func ReconcileKubeCSRSigner(secret *corev1.Secret, ownerRef config.OwnerRef) error {
    return reconcileSelfSignedCA(secret, ownerRef, "kube-csr-signer", "openshift")
}

// support/certs/tls.go
// Lines 450-470: Self-signed CA creation with 10-year validity
func ReconcileSelfSignedCA(secret *corev1.Secret, cn, ou string, o ...func(*CAOpts)) error {
    opts := (&CAOpts{}).withDefaults().withOpts(o...)
    if hasKeys(secret, opts.CASignerKeyMapKey, opts.CASignerKeyMapKey) {
        return nil // Don't regenerate if already exists
    }
    cfg := &CertCfg{
        Subject:   pkix.Name{CommonName: cn, OrganizationalUnit: []string{ou}},
        KeyUsages: x509.KeyUsageKeyEncipherment | x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
        Validity:  ValidityTenYears, // 10 years - NOT auto-rotated
        IsCA:      true,
    }
    key, crt, err := GenerateSelfSignedCertificate(cfg)
    // ... store in secret
}
```

**Rotation Rules**:
- **No Auto-Rotation**: 10-year validity, created once and persists
- **Manual Rotation**: Requires cluster recreation or manual intervention

---

## 5. Cluster-Manager-Webhook (Open Cluster Management)

### **Repository**: [open-cluster-management-io/ocm](https://github.com/open-cluster-management-io/ocm)

### **Rotation Logic**:
The cluster-manager-webhook uses OCM's own certrotation library (based on OpenShift's library-go) for automatic certificate rotation.

**Key Files**:
- **Controller**: `pkg/operator/operators/clustermanager/controllers/certrotationcontroller/certrotation_controller.go`
- **Library**: Uses `open-cluster-management.io/sdk-go/pkg/certrotation`

**Rotation Code**:
```go
// pkg/operator/operators/clustermanager/controllers/certrotationcontroller/certrotation_controller.go
// Lines 28-38: Cluster-manager-webhook rotation configuration
const (
    signerNamePrefix = "cluster-manager-webhook"
)

var (
    // Signing certificate validity: 1 year
    SigningCertValidity = time.Hour * 24 * 365
    // Target certificate validity: 30 days
    TargetCertValidity = time.Hour * 24 * 30
    // Resync interval: 10 minutes
    ResyncInterval = time.Minute * 10
)

// Lines 202-210: Signing rotation setup
signingRotation := certrotation.SigningRotation{
    Namespace:        clustermanagerNamespace,
    Name:             helpers.SignerSecret,
    SignerNamePrefix: signerNamePrefix,  // "cluster-manager-webhook"
    Validity:         SigningCertValidity,
    Lister:           c.secretInformers[helpers.SignerSecret].Lister(),
    Client:           c.kubeClient.CoreV1(),
}
```

**Certificate Creation** (from OCM SDK):
```go
// vendor/open-cluster-management.io/sdk-go/pkg/certrotation/signer.go
// Lines 92-94: Signer name generation with timestamp
func setSigningCertKeyPairSecret(signingCertKeyPairSecret *corev1.Secret, signerNamePrefix string, validity time.Duration) error {
    signerName := fmt.Sprintf("%s@%d", signerNamePrefix, time.Now().Unix())
    // Creates: CN=cluster-manager-webhook@<timestamp>
}
```

**Rotation Rules**:
- **Signing CA**: 1 year validity, rotates when 1/5th remains (≈73 days before expiry)
- **Target Certs**: 30 days validity, rotate when 1/5th remains (≈6 days before expiry)
- **Resync Interval**: 10 minutes

---

## 6. OpenShift Library-Go Certrotation (Core Library)

### **Repository**: [openshift/library-go](https://github.com/openshift/library-go)

### **Rotation Logic**:
The core rotation library used by most OpenShift operators.

**Key Files**:
- **Main Library**: `pkg/operator/certrotation/certrotation.go`
- **Signing Rotation**: `pkg/operator/certrotation/signing_rotation.go`
- **Target Rotation**: `pkg/operator/certrotation/target_rotation.go`

**Core Rotation Code**:
```go
// pkg/operator/certrotation/signing_rotation.go
// Lines 45-65: Signing certificate rotation logic
func (c *SigningRotation) EnsureSigningCertKeyPair() (*crypto.CA, error) {
    // Check if current cert is valid and not near expiry
    if c.certIsValid() && !c.certNeedsRenewal() {
        return c.getCurrentCA()
    }
    
    // Create new signing certificate
    newCA, err := c.createNewCA()
    if err != nil {
        return nil, err
    }
    
    // Store new CA in secret
    return c.storeNewCA(newCA)
}

// Lines 120-140: Certificate validity and renewal checks
func (c *SigningRotation) certNeedsRenewal() bool {
    cert := c.getCurrentCert()
    if cert == nil {
        return true
    }
    
    // Check if cert expires within 1/5th of its validity period
    timeUntilExpiry := cert.NotAfter.Sub(time.Now())
    validityPeriod := cert.NotAfter.Sub(cert.NotBefore)
    renewalThreshold := validityPeriod / 5
    
    return timeUntilExpiry <= renewalThreshold
}
```

**Universal Rotation Rules**:
- **Signing CA**: Rotates when 1/5th of validity period remains
- **Target Certs**: Rotate when 1/5th of validity period remains
- **Resync Interval**: Configurable (typically 2-10 hours)

---

## Summary

| CA Type | Repository | Validity | Auto-Rotated | Rotation Timing | Rotation Trigger | Code Location |
|---------|------------|----------|--------------|-----------------|------------------|---------------|
| **Service-CA** | [openshift/service-ca-operator](https://github.com/openshift/service-ca-operator) | 2 years | Yes | 80% of validity | 1/5th validity (≈146 days) | `pkg/controller/servingcert/controller.go:45-65` |
| **Platform-CA** | [openshift/origin](https://github.com/openshift/origin) | 2 years | Yes | 80% of validity | 1/5th validity (≈146 days) | `vendor/github.com/openshift/library-go/pkg/operator/certrotation/certrotation.go:45-55` |
| **Cluster-Proxy CA** | [open-cluster-management-io/cluster-proxy](https://github.com/open-cluster-management-io/cluster-proxy) | 1 year (CA), 180 days (targets) | Yes | 80% of validity | 1/5th validity (≈73 days CA, ≈36 days targets) | `pkg/proxyserver/controllers/managedproxyconfiguration_controller.go:58-67` |
| **Kube-CSR-Signer** | [openshift/hypershift](https://github.com/openshift/hypershift) | 10 years | No | N/A | Manual only | `support/certs/tls.go:450-470` |
| **Cluster-Manager-Webhook** | [open-cluster-management-io/ocm](https://github.com/open-cluster-management-io/ocm) | 1 year (CA), 30 days (targets) | Yes | 80% of validity | 1/5th validity (≈73 days CA, ≈6 days targets) | `pkg/operator/operators/clustermanager/controllers/certrotationcontroller/certrotation_controller.go:28-38` |
| **Library-Go** | [openshift/library-go](https://github.com/openshift/library-go) | Configurable | Yes | 80% of validity | 1/5th validity | `pkg/operator/certrotation/signing_rotation.go:120-140` |

All auto-rotated certificates follow the same pattern: they rotate when 1/5th of their validity period remains, ensuring continuous operation without certificate expiry.
