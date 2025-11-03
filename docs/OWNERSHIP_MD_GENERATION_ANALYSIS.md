# OpenShift Certificate Ownership.md Generation Analysis

This document explains how [ownership.md](https://github.com/openshift/origin/blob/main/tls/ownership/ownership.md) is generated, what requirements certificates must meet, and whether these represent "layered products" or core platform components.

## Overview

The `ownership.md` file is a **TLS registry for OpenShift platform operators and components**. It serves as the authoritative documentation of all TLS certificates and CA bundles managed by core OpenShift platform components, tracking their ownership, lifecycle, and management status. This registry ensures proper certificate governance, rotation compliance, and ownership accountability for the OpenShift platform infrastructure.

## How ownership.md is Generated

### **Generation Process**

1. **E2E Test Collection** (`test/extended/operators/certs.go`):
   - The `[sig-arch][Late] collect certificate data` test runs during OpenShift e2e tests
   - Collects all TLS artifacts (certificates and CA bundles) from the cluster
   - **Only collects from platform namespaces** (see namespace filtering below)

2. **Raw Data Generation**:
   - Test output: `raw-tls-artifacts-<topology>-<arch>-<platform>-<network>.json`
   - Contains all certificate metadata including annotations

3. **Ownership Processing** (`pkg/cmd/update-tls-artifacts/generate-owners/`):
   - Command: `go run -mod vendor ./cmd/update-tls-artifacts generate-ownership`
   - Script: `hack/update-tls-ownership.sh`
   - Processes raw JSON and generates `ownership.md`

### **Key Code Locations**

**Collection Logic** (`vendor/github.com/openshift/library-go/pkg/certs/cert-inspection/certgraphanalysis/collector.go`):

```go
// Lines 50-65: Platform namespace definition
var wellKnownPlatformNamespaces = sets.New(
    "openshift",
    "default",
    "kube-system",
    "kube-public",
    "kubernetes",
)

func isPlatformNamespace(nsName string) bool {
    if strings.HasPrefix(nsName, "openshift-") {
        return true
    }
    if strings.HasPrefix(nsName, "kubernetes-") {
        return true
    }
    return wellKnownPlatformNamespaces.Has(nsName)
}
```

**Annotation Extraction** (lines 124-127):

```go
CABundleInfo: certgraphapi.PKIRegistryCertificateAuthorityInfo{
    SelectedCertMetadataAnnotations: recordedAnnotationsFrom(configMap.ObjectMeta, annotationsToCollect),
    OwningJiraComponent:             configMap.Annotations[annotations.OpenShiftComponent],
    Description:                     configMap.Annotations[annotations.OpenShiftDescription],
},
```

## Requirements to Appear in ownership.md

### **1. Platform Namespace Requirement**

Certificates **MUST** be in platform namespaces to be collected:
- **Namespaces starting with `openshift-`**: All OpenShift operator namespaces
- **Namespaces starting with `kubernetes-`**: Kubernetes system namespaces
- **Well-known namespaces**: `openshift`, `default`, `kube-system`, `kube-public`, `kubernetes`

**Example from code** (`test/extended/operators/certs.go` line 124):

```go
inClusterPKIContent, err := gatherCertsFromPlatformNamespaces(ctx, kubeClient, masters, bootstrapHostname)
```

This means certificates in namespaces like:
- ✅ `openshift-apiserver-operator` - Included
- ✅ `openshift-monitoring` - Included
- ✅ `kube-system` - Included
- ❌ `multicluster-engine` - **NOT included** (not a platform namespace)
- ❌ `open-cluster-management-hub` - **NOT included** (not a platform namespace)
- ❌ `my-app-namespace` - **NOT included** (user namespace)

### **2. Annotation Requirement**

Certificates **MUST** have the `openshift.io/owning-component` annotation:

**Annotation Format**:
```
openshift.io/owning-component: <Jira Component Name>
```

**From code** (`pkg/cmd/update-tls-artifacts/generate-owners/tlsmetadata/ownership/requirement.go` lines 93-98):

```go
owner := certKeyInfo.OwningJiraComponent
if len(owner) == 0 || owner == tlsmetadatainterfaces.UnknownOwner {
    certsWithoutOwners = append(certsWithoutOwners, curr)
    continue  // Goes to "Missing Owners" section
}
certsByOwner[owner] = append(certsByOwner[owner], curr)
```

**Examples of valid annotations**:
- `openshift.io/owning-component: Networking / cluster-network-operator`
- `openshift.io/owning-component: service-ca`
- `openshift.io/owning-component: Machine Config Operator`
- `openshift.io/owning-component: Monitoring`

### **3. Certificate Data Requirement**

The certificate must contain valid TLS data:
- Secrets with `tls.crt`, `ca.crt`, `ca-bundle.crt`, etc.
- ConfigMaps with CA bundle data
- Valid X.509 certificate parsing

## Tests and Enforcement

### **E2E Tests**

**Test 1: "collect certificate data"** (`test/extended/operators/certs.go` line 141):
- Collects all TLS artifacts from platform namespaces
- Generates raw JSON output
- Part of `[sig-arch][Late]` test suite (runs after main tests)

**Test 2: "all tls artifacts must be registered"** (line 169):
- Validates that all collected certificates are in the registry
- Ensures no new certificates are added without ownership
- **Fails if new certificates are found without annotations**

**Test 3: "all registered tls artifacts must have no metadata violation regressions"**:
- Checks that violation list doesn't grow
- Ensures certificates maintain required metadata
- **Prevents adding certificates without proper annotations**

### **Violation Tracking**

Certificates without `openshift.io/owning-component` annotation are tracked in:
- `tls/violations/ownership/ownership-violations.json`
- This file is "remove-only" - new entries indicate test failures
- PRs adding certificates without annotations will fail CI

**From code** (`pkg/cmd/update-tls-artifacts/generate-owners/tlsmetadata/ownership/requirement.go` lines 52-79):

```go
func generateViolationJSON(pkiInfo *certs.PKIRegistryInfo) *certs.PKIRegistryInfo {
    ret := &certs.PKIRegistryInfo{}
    
    for i := range pkiInfo.CertKeyPairs {
        curr := pkiInfo.CertKeyPairs[i]
        certKeyInfo := tlsmetadatainterfaces.GetCertKeyPairInfo(curr)
        if certKeyInfo == nil {
            continue
        }
        owner := certKeyInfo.OwningJiraComponent
        if len(owner) == 0 || owner == tlsmetadatainterfaces.UnknownOwner {
            ret.CertKeyPairs = append(ret.CertKeyPairs, curr)  // ← Violation!
        }
    }
    // Same for CA bundles...
    return ret
}
```

## Components Listed in ownership.md

### **Core Platform Components** (Not Layered Products)

The components in ownership.md are **OpenShift core platform components**:

1. **Networking / cluster-network-operator** (41 certificates)
   - Core OpenShift networking operator
   - Manages CNI, OVN, service mesh certificates

2. **Monitoring** (8 certificates)
   - OpenShift monitoring stack
   - Prometheus, Thanos, Alertmanager certificates

3. **Image Registry** (4 certificates)
   - OpenShift integrated registry

4. **Machine Config Operator** (6 certificates)
   - Core OpenShift node configuration operator

5. **Operator Framework / operator-lifecycle-manager** (2 certificates)
   - OpenShift's OLM for operator management

6. **apiserver-auth** (5 certificates)
   - Kubernetes API server authentication

7. **Etcd** (1 certificate)
   - Core etcd database certificates

8. **Node / Kubelet** (2 certificates)
   - Core Kubernetes kubelet certificates

9. **RHCOS** (2 certificates)
   - Red Hat CoreOS system certificates

10. **Bare Metal Hardware Provisioning / cluster-baremetal-operator** (1 certificate)
    - OpenShift bare metal operator

11. **Cloud Compute / Cloud Controller Manager** (1 certificate)
    - OpenShift cloud integration

12. **End User** (1 certificate)
    - User-provided certificates

### **Why MCE/OCM Certificates Don't Appear**

Certificates from products like:
- MultiCluster Engine (MCE) - `multicluster-engine` namespace
- Open Cluster Management (OCM) - `open-cluster-management-*` namespaces
- MetalLB - `metallb-system` namespace

**Are NOT in ownership.md** because:
1. These namespaces don't match platform namespace patterns (`openshift-*`, `kubernetes-*`)
2. They are considered "layered products" - installed on top of OpenShift
3. They have their own certificate management outside OpenShift's core platform

## Layered Products with owning-component Annotation

### **The Service-CA Case**

**Important Discovery**: Layered products that use Service-CA **DO have** the `openshift.io/owning-component: service-ca` annotation, but they are **still excluded** from ownership.md.

**Example**: MetalLB certificate
```bash
oc get secret -n metallb-system frr-k8s-webhook-server-cert -o go-template='{{index .data "tls.crt"}}' | base64 -d | openssl x509 -noout -text
```

This certificate will have:
- ✅ `openshift.io/owning-component: service-ca` annotation (added by Service-CA operator)
- ✅ Service-CA signed certificate
- ✅ Auto-rotated by Service-CA operator
- ❌ **NOT in ownership.md** (because `metallb-system` is not a platform namespace)

### **Why This Happens**

1. **Service-CA Adds Annotation Automatically**:
   - Service-CA operator automatically adds `openshift.io/owning-component: service-ca` to ALL certificates it creates
   - This happens regardless of namespace

2. **Test Only Collects Platform Namespaces**:
   - The e2e test uses `GatherCertsFromPlatformNamespaces` (line 81 of `test/extended/operators/certs.go`)
   - Only certificates in platform namespaces are collected
   - MetalLB, MCE, OCM are in non-platform namespaces

**From Code** (`test/extended/operators/certs.go` line 81):
```go
return certgraphanalysis.GatherCertsFromPlatformNamespaces(ctx, kubeClient,
    certgraphanalysis.SkipRevisioned,
    certgraphanalysis.SkipHashed,
    certgraphanalysis.ElideProxyCADetails,
    certgraphanalysis.RewritePrimaryCertBundleSecret,
    certgraphanalysis.RewriteNodeNames(masters, bootstrapHostname),
    certgraphanalysis.CollectAnnotations(annotationsToCollect...),
)
```

### **Is There a Separate Test?**

**Answer: No, there is no separate test for layered products.**

Even though:
- Service-CA certificates in layered products have the annotation
- Service-CA properly manages and rotates them
- They follow the same rotation rules as platform certificates

They are **not tested or tracked** in ownership.md because:
1. The test explicitly filters to platform namespaces only
2. There's a `GatherCertsFromAllNamespaces` function available, but it's **not used** in the test
3. Ownership.md is meant to track **core platform certificates only**

### **Implications**

This means:
- ✅ Service-CA certificates in layered products are **still properly managed**
- ✅ They still have the `openshift.io/owning-component: service-ca` annotation
- ✅ They still auto-rotate using the same 80% rule
- ❌ They are **not documented** in ownership.md
- ❌ They are **not validated** by the e2e tests
- ❌ There is **no enforcement** that layered products maintain annotations

**Conclusion**: The annotation requirement is enforced only for platform namespaces. Layered products using Service-CA get the annotation automatically, but are excluded from tracking and validation.

## Summary: Requirements Checklist

For a certificate to appear in `ownership.md`:

✅ **MUST be in a platform namespace**:
- `openshift-*` prefix
- `kubernetes-*` prefix  
- Or well-known: `openshift`, `default`, `kube-system`, `kube-public`, `kubernetes`

✅ **MUST have `openshift.io/owning-component` annotation**:
- Value becomes the Jira component owner
- Format: `openshift.io/owning-component: <Component Name>`

✅ **MUST contain valid TLS data**:
- Parsable X.509 certificate
- In Secret or ConfigMap with recognized data fields

✅ **MUST pass e2e tests**:
- No new violations added
- Matches expected registry entries

❌ **CANNOT be from non-platform namespaces**:
- User namespaces excluded
- Layered product namespaces excluded (MCE, ACM, etc.)

## References

- **Ownership.md Source**: https://github.com/openshift/origin/blob/main/tls/ownership/ownership.md
- **Generation Code**: `pkg/cmd/update-tls-artifacts/generate-owners/`
- **E2E Test**: `test/extended/operators/certs.go`
- **Collection Logic**: `vendor/github.com/openshift/library-go/pkg/certs/cert-inspection/certgraphanalysis/collector.go`
- **Documentation**: `tls/README.md`

