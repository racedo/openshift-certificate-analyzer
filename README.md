# openshift-certificate-analyzer

OpenShift cluster certificate discovery and rotation analysis tools.

- `scripts/get-all-cluster-certificates.sh`: Scans a cluster and writes `all-cluster-certificates.csv` with certificate details (issuer, validity, fingerprints, platform/user management, annotations, and commands to reproduce).
- `docs/CERTIFICATE_ROTATION_CODE_ANALYSIS.md`: Explains rotation policies (80% rule), links to upstream code, and shows exact lines that implement rotation across Service-CA, Platform-CA, Cluster-Proxy CA, HyperShift CSR signer, and OCM webhook signer.

## Usage

1) Ensure `oc`, `jq`, `openssl` are installed and you are logged into a cluster with `oc login`.
2) Run the scanner:

```bash
bash scripts/get-all-cluster-certificates.sh
```

3) Inspect the output CSV (created in the current directory):

```bash
open all-cluster-certificates.csv
```

## License
Apache-2.0
