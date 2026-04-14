# PlexTrac Helm Charts

Helm chart for deploying the PlexTrac platform on Kubernetes. Supports self-hosted and on-premises deployments.

## Quick start

```bash
# 1. Copy the starter values file
cp charts/plextrac/examples/values-self-hosted.yaml my-values.yaml

# 2. Set your domain and admin email
#    Edit my-values.yaml:
#      global.ingress.host: plextrac.mycompany.com
#      secrets.manual.generatedSecrets.application.stringData.ADMIN_EMAIL: admin@mycompany.com

# 3. Install
helm upgrade --install plextrac ./charts/plextrac \
  -f my-values.yaml \
  --namespace plextrac \
  --create-namespace
```

See **[docs/user-guide.md](docs/user-guide.md)** for the complete installation and configuration guide.

## Repository layout

| Path | Purpose |
|---|---|
| `charts/plextrac/` | The PlexTrac Helm chart |
| `charts/plextrac/values.yaml` | Default values |
| `charts/plextrac/examples/` | Ready-to-use configuration examples |
| `docs/user-guide.md` | Full usage guide (start here) |
| `docs/runbooks/secrets-modes.md` | Detailed secrets configuration reference |
| `docs/migration/` | Kustomize → Helm migration guides |
| `.github/workflows/` | CI and release automation |

## Examples at a glance

| File | Use case |
|---|---|
| `examples/values-self-hosted.yaml` | Manual secrets, DockerHub images — recommended default |
| `examples/values-external-secrets.yaml` | External Secrets Operator |
| `examples/values-csi-aws.yaml` | CSI driver with AWS Secrets Manager |
| `examples/values-csi-gcp.yaml` | CSI driver with GCP Secret Manager |
| `examples/values-override-template.yaml` | Blank template — copy and uncomment what you need |

## Versioning

`Chart.yaml` `version` follows SemVer. `appVersion` tracks the PlexTrac application release.

## CI and release

- PR/main validation: `.github/workflows/chart-ci.yml`
- Release pipeline: `.github/workflows/chart-release.yml`
- Releases publish to OCI (`ghcr.io/<org>/charts/plextrac`) and GitHub Pages (`gh-pages` branch)
