# PlexTrac Helm Charts

Helm chart for deploying the PlexTrac platform on Kubernetes. Supports self-hosted and on-premises deployments.

## Before you install

A successful install requires three things to be in place **before** running `helm upgrade --install`:

1. **A running Kubernetes cluster** with NGINX Ingress Controller installed
2. **A DNS record** pointing your hostname to the ingress LoadBalancer IP
3. **Your credentials gathered** — at minimum a domain name

See [docs/user-guide.md](docs/user-guide.md) for the full phased installation guide.

## Quick start (K3s)

```bash
# 1. Install K3s (disable Traefik — PlexTrac uses NGINX)
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik" sh -
mkdir -p ~/.kube && sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config && sudo chown $(id -u):$(id -g) ~/.kube/config

# 2. Install NGINX Ingress Controller
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx && helm repo update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace --wait

# 3. Get the ingress IP and create your DNS record (or /etc/hosts entry)
kubectl -n ingress-nginx get svc ingress-nginx-controller

# 4. Fill in your credentials
cp .env.example .env.local   # edit with your domain, email, and any Docker creds

# 5. Configure your values file
cp charts/plextrac/examples/values-self-hosted.yaml my-values.yaml
# Edit my-values.yaml — set global.ingress.host at minimum

# 6. Install
helm upgrade --install plextrac ./charts/plextrac \
  --namespace plextrac \
  --create-namespace \
  -f my-values.yaml \
  --wait --timeout 10m

# 7. Verify
curl -I https://plextrac.mycompany.com/api/v2/health/full
```

## Uninstalling

```bash
helm uninstall plextrac --namespace plextrac
# PVCs are not deleted automatically — remove manually if you want full cleanup:
kubectl -n plextrac delete pvc --all
```

## Repository layout

| Path | Purpose |
|---|---|
| `charts/plextrac/` | The PlexTrac Helm chart |
| `charts/plextrac/values.yaml` | Default values |
| `charts/plextrac/examples/` | Ready-to-use configuration examples |
| `.env.example` | Pre-install checklist — credentials and settings to gather before installing |
| `docs/user-guide.md` | Full phased installation and configuration guide |
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
