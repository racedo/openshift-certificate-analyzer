# OpenShift Certificate Discovery

Cluster-wide TLS inventory: secrets and configmaps, platform vs user-managed, auto-rotate vs will-not-rotate.

| Component | Path | Purpose |
|-----------|------|---------|
| Bash script | `Bash Script/get-all-cluster-certificates.sh` | CLI scan → `all-cluster-certificates.csv` |
| Container app | `Container/app.py` | Flask UI + `/api/certificates` |
| Deployment | `Container/deploy.yaml` | Namespace **`cert-discovery-app`**, RBAC, Route |

This repo must not deploy `cert-missing-owners` or `cert-roadmap-console`. Those are separate projects:

- https://github.com/racedo/openshift-missing-owners
- https://github.com/racedo/openshift-cert-roadmap-console

## Common tasks

```bash
cd "Bash Script" && bash get-all-cluster-certificates.sh

./update-deployment.sh
oc get route cert-discovery-route -n cert-discovery-app -o jsonpath='http://{.spec.host}'
```

`./update-deployment.sh` refreshes **cert-discovery-app** only.

After `Container/app.py` or deploy changes, roll out to management, vm-hosted, and bm-hosted (`KUBECONFIG=~/work/hcp-cluster/configs/kubeconfig-<cluster>.yaml ./update-deployment.sh`).

Do not mention OCPSTRAT-1826 in this app’s UI. License: Apache-2.0.
