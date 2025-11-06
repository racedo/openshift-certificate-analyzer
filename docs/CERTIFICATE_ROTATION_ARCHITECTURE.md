# Certificate Rotation Architecture: Who is Responsible?

## Executive Summary

**Certificate rotation in OpenShift is a shared responsibility between library-go and operators/components:**

1. **library-go certrotation package** provides the **core rotation logic** (80% rule, timing calculations, certificate generation)
2. **Operators/Components** are responsible for **integrating** library-go and **running the rotation controllers**
3. **No manual intervention** is required - rotation is fully automated once properly integrated

## The Two-Layer Architecture

### Layer 1: library-go certrotation (Core Logic)

**Location**: `github.com/openshift/library-go/pkg/operator/certrotation`

**Responsibility**: Provides the **universal rotation framework** that all OpenShift components use.

**Key Components**:

1. **`RotatedSigningCASecret`** - Manages signing CA rotation
   - Implements the 80% validity threshold check
   - Generates new signing CAs when needed
   - Stores certificates in secrets with proper annotations

2. **`RotatedSelfSignedCertKeySecret`** - Manages target certificate rotation
   - Implements the 80% validity threshold check for target certs
   - Generates new certificates signed by the signing CA
   - Handles CA bundle updates

**Core Rotation Logic** (from `signer.go:168-179`):
```go
func needNewSigningCertKeyPair(secret *corev1.Secret, refresh time.Duration, refreshOnlyWhenExpired bool) (bool, string) {
    // ... validation checks ...
    
    validity := notAfter.Sub(notBefore)
    at80Percent := notAfter.Add(-validity / 5)  // 80% of validity
    if time.Now().After(at80Percent) {
        return true, fmt.Sprintf("past refresh time (80%% of validity): %v", at80Percent)
    }
    
    return false, ""
}
```

**Key Features**:
- ✅ **Universal 80% rule**: All certificates rotate when 1/5th (20%) of validity remains
- ✅ **Automatic timing**: Calculates rotation time based on certificate validity
- ✅ **Certificate generation**: Creates new certificates with proper cryptographic properties
- ✅ **Annotation management**: Adds TLS metadata annotations automatically
- ✅ **CA bundle management**: Maintains CA bundles with all valid certificates

### Layer 2: Operators/Components (Integration & Execution)

**Responsibility**: Each operator/component **integrates** library-go and **runs** the rotation controllers.

**What Operators Must Do**:

1. **Import library-go certrotation**
2. **Create rotation controllers** using library-go types
3. **Configure validity periods** (e.g., 2 years for Service-CA, 1 year for OCM)
4. **Set resync intervals** (e.g., 2 hours for Service-CA, 10 minutes for OCM)
5. **Run controllers** in their operator's control loop

## Service-CA Rotation: How It Works

### Architecture

```
Service-CA Operator
    │
    ├── Uses library-go certrotation
    │   ├── RotatedSigningCASecret (for Service-CA itself)
    │   └── RotatedSelfSignedCertKeySecret (for target certificates)
    │
    └── Controller runs every 2 hours
        └── Checks if certificates need rotation (80% rule)
            └── If yes, library-go generates new certificates
```

### Code Flow

1. **Service-CA Operator** (`openshift/service-ca-operator`):
   - Imports `github.com/openshift/library-go/pkg/operator/certrotation`
   - Creates a controller that uses `RotatedSigningCASecret` and `RotatedSelfSignedCertKeySecret`
   - Configures: 2-year validity, 2-hour resync interval

2. **Controller Execution**:
   - Every 2 hours, the controller's `sync()` function runs
   - Calls `EnsureSigningCertKeyPair()` from library-go
   - Library-go checks: "Is certificate at 80% of validity?"
   - If yes: Library-go generates new certificate
   - If no: Library-go returns existing certificate

3. **Automatic Rotation**:
   - **No operator code needed** for the rotation logic itself
   - Library-go handles all timing, generation, and storage
   - Operator just needs to call the library functions

### Example: Service-CA Operator Integration

```go
// Service-CA Operator creates rotation controller
func NewServingCertController(...) factory.Controller {
    // Configure rotation using library-go
    signingRotation := certrotation.RotatedSigningCASecret{
        Namespace: namespace,
        Name:      "signing-key",
        Validity:  time.Hour * 24 * 365 * 2,  // 2 years
        Refresh:   time.Hour * 24 * 365 * 2,   // 2 years
        Informer:  secretInformer,
        Lister:    secretInformer.Lister(),
        Client:    kubeClient.CoreV1(),
    }
    
    // Controller runs every 2 hours
    return factory.New().
        ResyncEvery(time.Hour * 2).
        WithSync(func(ctx context.Context, syncCtx factory.SyncContext) error {
            // Library-go handles all rotation logic
            ca, _, err := signingRotation.EnsureSigningCertKeyPair(ctx)
            return err
        }).
        ToController("ServingCertController", recorder)
}
```

**Key Point**: The Service-CA operator doesn't implement rotation logic - it just **uses** library-go's rotation functions.

## Platform-CA Rotation: How It Works

### Architecture

```
Platform Operators (etcd, kube-apiserver, etc.)
    │
    ├── Each operator uses library-go certrotation
    │   ├── RotatedSigningCASecret (for their signing CA)
    │   └── RotatedSelfSignedCertKeySecret (for their target certs)
    │
    └── Each operator runs its own controller
        └── Uses same library-go rotation logic
```

### Example: Etcd Operator

1. **Etcd Operator** creates rotation controllers for:
   - `etcd-signer` (signing CA)
   - `etcd-peer` (target certificate)
   - `etcd-serving` (target certificate)

2. **Each uses library-go**:
   ```go
   signingRotation := certrotation.RotatedSigningCASecret{
       Namespace: "openshift-etcd",
       Name:      "etcd-signer",
       Validity:  time.Hour * 24 * 365 * 2,  // 2 years
       // ... other config ...
   }
   ```

3. **Library-go handles rotation**:
   - Operator calls `EnsureSigningCertKeyPair()`
   - Library-go checks 80% rule
   - Library-go generates new certificate if needed
   - Operator doesn't need to know rotation details

## Open Cluster Management (OCM) Example

### Real Code from OCM

From `certrotation_controller.go:32-38`:
```go
// Follow the rules below to set the value of SigningCertValidity/TargetCertValidity/ResyncInterval:
//
// 1) SigningCertValidity * 1/5 * 1/5 > ResyncInterval * 2
// 2) TargetCertValidity * 1/5 > ResyncInterval * 2
var SigningCertValidity = time.Hour * 24 * 365  // 1 year
var TargetCertValidity = time.Hour * 24 * 30    // 30 days
var ResyncInterval = time.Minute * 10           // 10 minutes
```

**What OCM Does**:
1. **Configures validity periods** (1 year for CA, 30 days for targets)
2. **Sets resync interval** (10 minutes)
3. **Uses library-go** to create rotation objects:
   ```go
   signingRotation := certrotation.SigningRotation{
       Namespace:        clustermanagerNamespace,
       Name:             helpers.SignerSecret,
       Validity:         SigningCertValidity,  // 1 year
       // ... other config ...
   }
   ```

4. **Calls library-go functions**:
   ```go
   signingCertKeyPair, err := rotations.signingRotation.EnsureSigningCertKeyPair()
   ```

**What OCM Doesn't Do**:
- ❌ Implement rotation timing logic (library-go does this)
- ❌ Calculate 80% threshold (library-go does this)
- ❌ Generate certificates (library-go does this)
- ❌ Manage CA bundles (library-go does this)

## Answer to Your Question

### Q: Is the owner of the operator or component responsible for creating the rotation routine?

**A: Partially - they integrate library-go, but don't write rotation logic**

- **Operators/Components are responsible for**:
  - ✅ Importing library-go certrotation
  - ✅ Creating rotation controller objects
  - ✅ Configuring validity periods and resync intervals
  - ✅ Running controllers in their control loop
  - ✅ Calling library-go's `EnsureSigningCertKeyPair()` and `EnsureTargetCertKeyPair()`

- **Operators/Components are NOT responsible for**:
  - ❌ Implementing the 80% rotation rule (library-go does this)
  - ❌ Calculating rotation timing (library-go does this)
  - ❌ Generating certificates (library-go does this)
  - ❌ Managing CA bundles (library-go does this)

### Q: Is this part of library-go?

**A: Yes - the core rotation logic is entirely in library-go**

The `github.com/openshift/library-go/pkg/operator/certrotation` package provides:
- ✅ Universal rotation framework
- ✅ 80% validity threshold logic
- ✅ Certificate generation
- ✅ CA bundle management
- ✅ Annotation management
- ✅ Timing calculations

### Q: Is there automation within an OpenShift component taking care of it?

**A: Yes - but it's a combination of library-go + operator integration**

**The Automation Stack**:

1. **library-go certrotation** (Core automation):
   - Provides rotation functions
   - Implements 80% rule
   - Generates certificates automatically

2. **Operators** (Integration layer):
   - Create controllers using library-go
   - Run controllers in control loops
   - Configure validity periods

3. **Controller Framework** (Execution):
   - `factory.New()` creates controllers
   - `ResyncEvery()` sets check intervals
   - Controllers run automatically

**Result**: Fully automated rotation - no manual intervention needed once properly integrated.

## Key Takeaways

1. **library-go provides the rotation logic** - operators don't implement it themselves
2. **Operators integrate library-go** - they create controllers and call library functions
3. **Rotation is fully automated** - once integrated, no manual steps required
4. **Universal 80% rule** - all certificates rotate at the same threshold (1/5th of validity remaining)
5. **Consistent across OpenShift** - Service-CA, Platform-CA, and all operators use the same library

## Code References

### library-go Rotation Logic
- **Signing CA rotation**: `library-go/pkg/operator/certrotation/signer.go:152-179`
- **Target cert rotation**: `library-go/pkg/operator/certrotation/target.go:157-238`
- **80% rule implementation**: `signer.go:168` and `target.go:222`

### Operator Integration Examples
- **Service-CA**: `openshift/service-ca-operator/pkg/controller/servingcert/controller.go`
- **OCM**: `open-cluster-management/pkg/operator/operators/clustermanager/controllers/certrotationcontroller/certrotation_controller.go`
- **Platform operators**: Various operators in `openshift/origin` use the same pattern

## Conclusion

**Certificate rotation in OpenShift is a shared responsibility**:

- **library-go**: Provides the universal rotation framework and logic
- **Operators**: Integrate library-go and run rotation controllers
- **Result**: Fully automated, consistent certificate rotation across all OpenShift components

The beauty of this architecture is that **operators don't need to understand rotation details** - they just use library-go's functions, and rotation happens automatically.



