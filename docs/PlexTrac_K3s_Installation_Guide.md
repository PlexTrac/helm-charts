# PlexTrac K3s Installation Guide

> For a server without internet access, use the [K3s air-gapped installation guide](PlexTrac_K3s_AirGapped_Installation_Guide.md) instead.

> Already running PlexTrac with ingress-nginx? Move it to Gateway API with the [migration runbook](runbooks/ingress-nginx_to_gateway-api.md).

## Prerequisites

Update your system packages:

```shell
sudo apt update
```

## 1. Install K3s

Install K3s with Traefik disabled (PlexTrac's routing runs on Istio, and Traefik would hold ports 80/443) and make kubeconfig readable without sudo:

```shell
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik --write-kubeconfig-mode 644" sh -
```

Configure kubectl to use the kubeconfig without sudo:

```shell
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> ~/.bashrc
```

## 2. Install Helm

Install Helm from the official script:

```shell
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

Verify the installation:

```shell
helm version
```

## 3. Clone PlexTrac Helm Charts

```shell
git clone https://github.com/PlexTrac/helm-charts.git
cd helm-charts
```

## 4. Install Gateway API, Istio and cert-manager

PlexTrac's routing uses the Kubernetes Gateway API, served by Istio. Install the Gateway API CRDs (K3s 1.37 and newer already has them):

```shell
kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1 || \
  kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.3/standard-install.yaml
```

Install Istio as the Gateway API controller only (no service mesh):

```shell
helm repo add istio https://blob.istio.io/istio-release/charts
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm upgrade --install istio-base istio/base -n istio-system --create-namespace \
  --version 1.31.4 --set defaultRevision=default --wait
helm upgrade --install istiod istio/istiod -n istio-system --version 1.31.4 \
  -f charts/plextrac/examples/istiod-values.yaml --wait
```

Install cert-manager, which issues the TLS certificate. Gateway API support lets it answer Let's Encrypt challenges through the gateway:

```shell
helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager --create-namespace \
  --version v1.21.3 --set crds.enabled=true --set config.gatewayAPI.enabled=true --wait
```

PlexTrac answers on the server's IP once installed: the gateway's Service uses K3s's built-in load balancer. Create a DNS record or `/etc/hosts` entry for your domain pointing at the server's IP (its public IP on a cloud VM).

## 5. Configure Registry Credentials

Copy the example environment file:

```shell
cp .env.example .env.local
```

Edit `.env.local` and set the following required variables: 

- `DOCKER_REGISTRY`: (Default value will be pulled from .env.example file)
- `DOCKER_USERNAME`: ptcustomers (#DOCKER_HUB_USER)
- `DOCKER_PASSWORD`: (#DOCKER_HUB_KEY)
- `CKEDITOR_DOCKER_SERVER`: docker.cke-cs.com (#IMAGE_REGISTRY)
- `CKEDITOR_DOCKER_USERNAME`: cs (#IMAGE_REGISTRY_USER)
- `CKEDITOR_DOCKER_PASSWORD`: (#IMAGE_REGISTRY_PASS)

Create Kubernetes registry secrets:

```shell
./scripts/setup-registry-credentials.sh
```

This will output a `my-values.yaml` snippet that you'll use in the next step.

## 6. Configure Values File

Copy the example values file:

```shell
cp charts/plextrac/examples/values-self-hosted.yaml my-values.yaml
```

Edit `my-values.yaml` and set:

- `global.imagePullSecrets`: the snippet printed in step 5 (uncomment `ckeditor-registry-creds` if you set CKEditor credentials).
- `global.ingress.host`: your domain.
- `global.ingress.certManager.issuer`: `selfSigned` works without DNS or a public IP (browsers warn); `letsencrypt` gives a trusted certificate for a public domain (also set `email`, and open port 80). Or set `""` and create the `internal-tls` Secret yourself with `kubectl -n plextrac create secret tls internal-tls --cert=fullchain.pem --key=privkey.pem`.
- `CKEDITOR_SERVER_LICENSE_KEY`: your CKEditor license key.

The example already turns on Gateway API routing (`global.gateway.enabled: true`) and turns off the ingress-nginx Ingresses (`global.ingress.enabled: false`). The relevant part of the file:

```yaml
global:
  imagePullSecrets:
    - name: internal-registry-creds
    - name: ckeditor-registry-creds   # if CKEditor credentials were provided
  ingress:
    enabled: false
    host: plextrac.mycompany.com      # your domain
    tlsSecretName: internal-tls
    certManager:
      issuer: selfSigned              # or letsencrypt (+ email), or "" with your own Secret
      email: ""
  gateway:
    enabled: true

secrets:
  manual:
    generatedSecrets:
      shared:
        stringData:
          CKEDITOR_SERVER_LICENSE_KEY: "your-license-key"
```

Optional components (Synqly, Keycloak, MCP) are commented out at the end of the file; see the [user guide](user-guide.md).

## 7. Install PlexTrac

Install the PlexTrac Helm chart:

```shell
helm upgrade --install plextrac ./charts/plextrac \
  --namespace plextrac \
  --create-namespace \
  -f my-values.yaml \
  --wait --timeout 15m
```

Note:

First installation runs database migrations inline; allow time for completion. Depending on the hardware, the install may seem like it times out, but watching the pods come online with `kubectl -n plextrac get pods -w` will allow you to see when complete. 

## 8. Verify Installation

Check that the gateway is programmed and has the server's IP, then call the API health endpoint (add `-k` with a `selfSigned` certificate):

```shell
kubectl -n plextrac get gateway plextrac   # PROGRAMMED True
kubectl -n plextrac get httproute
curl -I https://[your_plextrac_domain]/api/v2/health/full
```

Note:

If migrating from a Docker Compose environment, you can proceed to do that from here, there is no need to complete Step 9 or 10 as the credentials will come from your backup.

## 9. Retrieve Global Admin Credentials

Get the global admin token from logs:

```shell
kubectl logs deployment/plextracapi -n plextrac | grep 'password'
```

If the above does not work (link in the log has expired or the token itself has expired), please contact support for assistance in setting the password directly.

---

**Key Points:**

- Traefik is disabled; routing runs through the Gateway API, served by Istio
- Kubeconfig is readable without sudo (`--write-kubeconfig-mode 644`)
- First Helm installation requires extra time for database migrations (`--timeout 15m`)
- All registry credentials must be set before installation
