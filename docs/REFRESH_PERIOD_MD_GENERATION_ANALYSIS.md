# Refresh Period MD Generation Analysis

This document explains how the `refresh-period.md` file is generated in OpenShift and the requirements certificates must meet to be included in the registry.

**Source**: [refresh-period.md](https://github.com/openshift/origin/blob/main/tls/refresh-period/refresh-period.md)

## Overview

The `refresh-period.md` file is a TLS registry for OpenShift platform operators and components that tracks which certificates have the `certificates.openshift.io/refresh-period` annotation, indicating that the certificate is automatically refreshed before expiration without human intervention.

## Generation Process

### 1. **Entry Point**

The refresh-period.md file is generated as part of the TLS artifact update process:

**Script**: `hack/update-tls-ownership.sh`

```bash
#!/usr/bin/env bash
STARTTIME=$(date +%s)
source "$(dirname "${BASH_SOURCE}")/lib/init.sh"

# Update TLS artifacts
go run -mod vendor ./cmd/update-tls-artifacts generate-ownership

ret=$?; ENDTIME=$(date +%s); echo "$0 took $(($ENDTIME - $STARTTIME)) seconds"; exit "$ret"
```

### 2. **Command Structure**

The `generate-ownership` command processes multiple TLS metadata requirements, including refresh-period:

**Code**: `pkg/cmd/update-tls-artifacts/generate-owners/generate_owners_flags.go`

```go
func NewGenerateOwnershipCommand(streams genericclioptions.IOStreams) *cobra.Command {
    // ... command setup ...
    cmd := &cobra.Command{
        Use:           "generate-ownership",
        Short:         "Generate ownership json and markdown files.",
        // ...
    }
    // ...
}
```

### 3. **Requirement Registration**

The refresh-period requirement is registered alongside other TLS requirements:

**Code**: `pkg/cmd/update-tls-artifacts/generate-owners/tlsmetadatadefaults/defaults.go` lines 12-19:

```go
func GetDefaultTLSRequirements() []tlsmetadatainterfaces.Requirement {
	return []tlsmetadatainterfaces.Requirement{
		ownership.NewOwnerRequirement(),
		testcase.NewTestNameRequirement(),
		autoregenerate_after_expiry.NewAutoRegenerateAfterOfflineExpiryRequirement(),
		refresh_period.NewRefreshPeriodRequirement(),  // ← Refresh period requirement
		descriptions.NewDescriptionRequirement(),
	}
}
```

### 4. **Refresh Period Requirement Definition**

The refresh-period requirement is defined as an annotation requirement:

**Code**: `pkg/cmd/update-tls-artifacts/generate-owners/tlsmetadata/refresh_period/requirement.go`:

```go
package refresh_period

const annotationName string = "certificates.openshift.io/refresh-period"

type RefreshPeriodRequirement struct{}

func NewRefreshPeriodRequirement() tlsmetadatainterfaces.Requirement {
	md := markdown.NewMarkdown("")
	md.Text("Acknowledging that a cert/key pair or CA bundle can be refreshed means")
	md.Text("that certificate is being updated before its expiration date as required without human")
	md.Text("intervention.")
	md.Text("")
	md.Text("To assert that a particular cert/key pair or CA bundle can be refreshed, add the annotation to the secret or configmap.")
	md.Text("```yaml")
	md.Text("  annotations:")
	md.Textf("    %v: <refresh period, e.g. 15d or 2y>", annotationName)
	md.Text("```")
	md.Text("")
	md.Text("This assertion means that you have")
	md.OrderedListStart()
	md.NewOrderedListItem()
	md.Text("Manually tested that this works or seen someone else manually test that this works.  AND")
	md.NewOrderedListItem()
	md.Text("Written an automated e2e test to ensure this PKI artifact is function that is a blocking GA criteria, and/or")
	md.Text("QE has required test every release that ensures the functionality works every release.")
	md.NewOrderedListItem()
	md.Textf("This TLS artifact has associated test name annotation (%q).", testcase.AnnotationName)
	md.OrderedListEnd()
	md.Text("If you have not done this, you should not merge the annotation.")

	return tlsmetadatainterfaces.NewAnnotationRequirement(
		// requirement name
		"refresh-period",
		// cert or configmap annotation
		annotationName,
		"Refresh Period",
		string(md.ExactBytes()),
	)
}
```

### 5. **Annotation Processing**

The refresh-period requirement uses the generic annotation requirement infrastructure:

**Code**: `pkg/cmd/update-tls-artifacts/generate-owners/tlsmetadatainterfaces/annotation_requirement.go` lines 190-218:

```go
func generateViolationJSONForAnnotationRequirement(annotationName string, pkiInfo *certs.PKIRegistryInfo) *certs.PKIRegistryInfo {
	ret := &certs.PKIRegistryInfo{}

	for i := range pkiInfo.CertKeyPairs {
		curr := pkiInfo.CertKeyPairs[i]
		certKeyInfo := GetCertKeyPairInfo(curr)
		if certKeyInfo == nil {
			continue
		}

		regenerates, _ := AnnotationValue(certKeyInfo.SelectedCertMetadataAnnotations, annotationName)
		if len(regenerates) == 0 {
			ret.CertKeyPairs = append(ret.CertKeyPairs, curr)  // ← Violation!
		}
	}
	for i := range pkiInfo.CertificateAuthorityBundles {
		curr := pkiInfo.CertificateAuthorityBundles[i]
		caBundleInfo := GetCABundleInfo(curr)
		if caBundleInfo == nil {
			continue
		}
		regenerates, _ := AnnotationValue(caBundleInfo.SelectedCertMetadataAnnotations, annotationName)
		if len(regenerates) == 0 {
			ret.CertificateAuthorityBundles = append(ret.CertificateAuthorityBundles, curr)  // ← Violation!
		}
	}

	return ret
}
```

### 6. **Output Files**

The generation process creates three files:

1. **`tls/refresh-period/refresh-period.md`**: Human-readable markdown report
2. **`tls/refresh-period/refresh-period.json`**: Machine-readable JSON registry
3. **`tls/violations/refresh-period/refresh-period-violations.json`**: List of certificates that don't meet the requirement

## Data Collection Process

### 1. **E2E Test Collection**

The certificate data is collected during e2e tests:

**Code**: `test/extended/operators/certs.go` lines 72-89:

```go
func gatherCertsFromPlatformNamespaces(ctx context.Context, kubeClient kubernetes.Interface, masters []*corev1.Node, bootstrapHostname string) (*certgraphapi.PKIList, error) {
	annotationsToCollect := []string{annotations.OpenShiftComponent}
	for _, currRequirement := range tlsmetadatadefaults.GetDefaultTLSRequirements() {
		annotationRequirement, ok := currRequirement.(tlsmetadatainterfaces.AnnotationRequirement)
		if ok {
			annotationsToCollect = append(annotationsToCollect, annotationRequirement.GetAnnotationName())
		}
	}

	return certgraphanalysis.GatherCertsFromPlatformNamespaces(ctx, kubeClient,
		certgraphanalysis.SkipRevisioned,
		certgraphanalysis.SkipHashed,
		certgraphanalysis.ElideProxyCADetails,
		certgraphanalysis.RewritePrimaryCertBundleSecret,
		certgraphanalysis.RewriteNodeNames(masters, bootstrapHostname),
		certgraphanalysis.CollectAnnotations(annotationsToCollect...),  // ← Includes refresh-period annotation
	)
}
```

### 2. **Platform Namespace Filtering**

Similar to ownership.md, refresh-period.md only tracks certificates from platform namespaces:

**Code**: `test/extended/operators/certs.go` (uses `GatherCertsFromPlatformNamespaces`)

The platform namespace definition is:
- Namespaces starting with `openshift-`
- Namespaces starting with `kubernetes-`
- `kube-system`
- `kube-public`
- `openshift`
- `default`
- `kubernetes`

### 3. **Raw Data Storage**

The collected certificate data is stored in `tls/raw-data/` directory as JSON files during e2e test runs.

### 4. **Processing**

The `generate-ownership` command:
1. Reads raw data from `tls/raw-data/`
2. Processes each requirement (including refresh-period)
3. Generates markdown and JSON files
4. Creates violation files for certificates missing the annotation

## Requirements for Inclusion

For a certificate to be listed as **meeting the requirement** in refresh-period.md, it must:

1. **Be in a Platform Namespace**: The certificate must be in one of the platform namespaces listed above.

2. **Have the Refresh Period Annotation**: The certificate Secret or ConfigMap must have the annotation:
   ```yaml
   annotations:
     certificates.openshift.io/refresh-period: <period, e.g. 15d or 2y>
   ```

3. **Have Manual/Automated Testing**: The requirement states that adding this annotation means you have:
   - Manually tested that refresh works, OR
   - Written an automated e2e test that is blocking GA criteria, OR
   - QE has required a test that runs every release

4. **Have Test Name Annotation**: The certificate should also have the `certificates.openshift.io/test-name` annotation linking it to the e2e test that verifies the refresh functionality.

## Violation Tracking

### **Violation Detection**

Certificates that **do not** have the `certificates.openshift.io/refresh-period` annotation are tracked as violations:

**File**: `tls/violations/refresh-period/refresh-period-violations.json`

This file is "remove-only" - new entries indicate that certificates are missing the annotation.

### **Test Enforcement**

The e2e test `[sig-arch][Late][Jira:"kube-apiserver"]` validates that:

1. No new certificates are added to the violations file without corresponding annotations
2. Registered certificates maintain their metadata annotations

**Code**: `test/extended/operators/certs.go` line 281:

```go
g.It("all registered tls artifacts must have no metadata violation regressions", func() {
	violationRegressionOptions := ensure_no_violation_regression.NewEnsureNoViolationRegressionOptions(ownership.AllViolations, genericclioptions.NewTestIOStreamsDiscard())
	messages, _, err := violationRegressionOptions.HaveViolationsRegressed([]*certgraphapi.PKIList{actualPKIContent})
	o.Expect(err).NotTo(o.HaveOccurred())

	if len(messages) > 0 {
		testresult.Flakef("%s", strings.Join(messages, "\n"))
	}
})
```

## Current Status

Based on the latest refresh-period.md file:

- **Items That DO Meet the Requirement**: 41 certificates
  - `etcd` component: 25 certificates
  - `kube-apiserver` component: 16 certificates

- **Items That Do NOT Meet the Requirement**: 234 certificates
  - Spread across various components including:
    - `service-ca`: 101 certificates (most violations)
    - `kube-apiserver`: 30 certificates
    - `Networking / cluster-network-operator`: 41 certificates
    - And others...

## Relationship to Other TLS Requirements

The refresh-period requirement is part of a suite of TLS metadata requirements:

1. **Ownership** (`openshift.io/owning-component`): Identifies the Jira component responsible
2. **Test Case** (`certificates.openshift.io/test-name`): Links to the e2e test
3. **Auto-Regenerate After Expiry**: Tracks offline regeneration capability
4. **Refresh Period** (`certificates.openshift.io/refresh-period`): Indicates automatic refresh capability
5. **Description**: Provides human-readable description

All these requirements are processed together during the `generate-ownership` command execution.

## Key Takeaways

1. **Refresh Period Annotation**: The `certificates.openshift.io/refresh-period` annotation is a commitment that the certificate is automatically refreshed before expiration.

2. **Platform Namespaces Only**: Like ownership.md, refresh-period.md only tracks certificates from platform namespaces, excluding layered products.

3. **Test Requirement**: Adding the annotation requires corresponding e2e tests that verify the refresh functionality.

4. **Violation Tracking**: The violations file tracks certificates missing the annotation, and PRs adding new certificates without annotations will fail CI.

5. **Low Compliance**: Only 41 out of 275+ certificates currently have the refresh-period annotation, indicating this is a newer requirement or work in progress for the OpenShift platform.

