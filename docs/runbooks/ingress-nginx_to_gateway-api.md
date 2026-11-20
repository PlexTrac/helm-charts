# Migrate from ingress-nginx to Gateway API (Istio)

ingress-nginx was [retired upstream](https://www.kubernetes.dev/blog/2025/11/12/ingress-nginx-retirement/) in March 2026 and gets no more security fixes. From chart 2.30.0, PlexTrac can route through the Kubernetes Gateway API instead, served by Istio, the same setup PlexTrac's cloud uses. Hostnames, paths, TLS Secrets and certificates stay the same.

This runbook moves a running install over in three phases. Until the last phase, going back takes seconds. New installs don't need it: the [user guide](../user-guide.md) and the [K3s guide](../PlexTrac_K3s_Installation_Guide.md) set up Gateway API from the start.

| Phase | What changes | Who serves traffic |
|---|---|---|
| 1. Prepare | Istio and the PlexTrac Gateway are installed next to ingress-nginx, unexposed | ingress-nginx |
| 2. Cut over | The gateway takes ports 80/443 from ingress-nginx (under a second of failed requests in testing) | Istio gateway |
| 3. Clean up | The Ingresses and ingress-nginx are removed | Istio gateway |

## Before you start

- Chart 2.30.0 or newer: `git pull` your clone of this repository. Upgrading to it changes nothing by itself; the Ingresses render exactly as before until you turn the gateway on.
- Kubernetes 1.32 or newer (the range Istio 1.31 supports), and cert-manager 1.15 or newer if you use it. Commands use `helm` and `jq`, as in the user guide.
- **A TLS Secret must exist** for `global.ingress.tlsSecretName` (and for Keycloak, `keycloak-tls` unless you set `keycloak.tlsSecretName`). ingress-nginx serves its own self-signed certificate when the Secret is missing; the gateway serves nothing. Check with `kubectl -n plextrac get secret internal-tls`. If it is missing, set `global.ingress.certManager.issuer: selfSigned` or create the Secret ([TLS options](../user-guide.md#reference-tls-configuration)) before Phase 2.
- The commands assume the namespace and release `plextrac` and your values in `my-values.yaml`, run from the root of this repository. They also use the `jetstack` and `ingress-nginx` Helm repos from your original install; check with `helm repo list`.
- On K3s, the node IP stays the same: Phase 2 hands ports 80/443 from one Service to the other. On GKE, AKS or EKS the gateway gets its own load balancer IP, so Phase 2 is a DNS change instead (see the note there).

## Phase 1: Prepare

Nothing here changes what users reach.

1. Install the Gateway API CRDs if they are not there yet. K3s 1.37 and newer installs them itself (v1.6.3).

   ```bash
   kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1 || \
     kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.3/standard-install.yaml
   ```

2. Install Istio. The values file runs istiod as a Gateway API controller only (no sidecars) and stops it from acting on the existing Ingresses.

   ```bash
   helm repo add istio https://blob.istio.io/istio-release/charts && helm repo update istio
   helm upgrade --install istio-base istio/base -n istio-system --create-namespace \
     --version 1.31.4 --set defaultRevision=default --wait
   helm upgrade --install istiod istio/istiod -n istio-system --version 1.31.4 \
     -f charts/plextrac/examples/istiod-values.yaml --wait
   ```

3. If you use cert-manager, let it answer Let's Encrypt challenges through the gateway. This keeps your current cert-manager version. The restart matters: cert-manager only looks for Gateway API when it starts.

   ```bash
   CM_VERSION=$(helm -n cert-manager get metadata cert-manager -o json | jq -r .version)
   helm upgrade cert-manager jetstack/cert-manager -n cert-manager --version "$CM_VERSION" --reuse-values \
     --set config.apiVersion=controller.config.cert-manager.io/v1alpha1 \
     --set config.kind=ControllerConfiguration \
     --set config.enableGatewayAPI=true
   kubectl -n cert-manager rollout restart deployment cert-manager
   ```

4. Add the gateway to `my-values.yaml`, unexposed for now, and upgrade:

   ```yaml
   global:
     gateway:
       enabled: true
       serviceType: ClusterIP   # removed again in Phase 2
   ```

   ```bash
   helm upgrade plextrac ./charts/plextrac -n plextrac -f my-values.yaml --wait --timeout 15m
   ```

5. Check the gateway, then test it through a port-forward while ingress-nginx keeps serving users. Use your hostname:

   ```bash
   kubectl -n plextrac get gateway plextrac    # PROGRAMMED True
   kubectl -n plextrac get httproute           # one route per Ingress
   kubectl -n plextrac port-forward svc/plextrac-istio 8443:443 &
   curl -k --resolve plextrac.mycompany.com:8443:127.0.0.1 https://plextrac.mycompany.com:8443/api/v2/health/full
   kill %1
   ```

## Phase 2: Cut over

1. Delete the `serviceType: ClusterIP` line from `my-values.yaml` and upgrade. The gateway Service becomes a LoadBalancer and shows `EXTERNAL-IP <pending>` while ingress-nginx still holds the ports. The chart also switches the Let's Encrypt HTTP-01 solver to the gateway.

   ```bash
   helm upgrade plextrac ./charts/plextrac -n plextrac -f my-values.yaml --wait --timeout 15m
   ```

2. Release the ports from ingress-nginx (keeping its chart version). The gateway picks them up within a second or two:

   ```bash
   NGINX_VERSION=$(helm -n ingress-nginx get metadata ingress-nginx -o json | jq -r .version)
   helm upgrade ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --version "$NGINX_VERSION" \
     --reuse-values --set controller.service.type=ClusterIP
   kubectl -n plextrac get svc plextrac-istio  # EXTERNAL-IP is now the node IP
   curl -I https://plextrac.mycompany.com/api/v2/health/full
   ```

   Then sign in through the browser. You can stay in this state as long as you like; certificate renewals work through the gateway.

> **GKE, AKS, EKS or MetalLB:** after step 1 the gateway gets its own `EXTERNAL-IP` instead of `<pending>`. Skip step 2 and point the DNS records for the app host (and `keycloak.host`) at that IP. ingress-nginx keeps serving until DNS caches expire.

**Roll back** (any time before Phase 3), in reverse order:

```bash
NGINX_VERSION=$(helm -n ingress-nginx get metadata ingress-nginx -o json | jq -r .version)
helm upgrade ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --version "$NGINX_VERSION" \
  --reuse-values --set controller.service.type=LoadBalancer
# put "serviceType: ClusterIP" back under global.gateway in my-values.yaml, then:
helm upgrade plextrac ./charts/plextrac -n plextrac -f my-values.yaml --wait --timeout 15m
```

## Phase 3: Clean up

1. Turn the Ingresses off in `my-values.yaml` and upgrade:

   ```yaml
   global:
     ingress:
       enabled: false
     gateway:
       enabled: true
   ```

   ```bash
   helm upgrade plextrac ./charts/plextrac -n plextrac -f my-values.yaml --wait --timeout 15m
   ```

   With cert-manager, the chart now creates the Certificates itself (`internal-tls-cert`, `keycloak-tls-cert`) instead of the Ingress annotations. They report `READY False` (`IncorrectCertificate`) for about 3 minutes, then cert-manager issues each certificate once more and they turn `True`. The current certificates keep serving in the meantime.

   ```bash
   kubectl -n plextrac get certificate
   ```

2. Remove ingress-nginx:

   ```bash
   helm uninstall ingress-nginx -n ingress-nginx
   kubectl delete namespace ingress-nginx
   ```

To return to ingress-nginx after this, reinstall it unexposed, set `global.ingress.enabled: true` and upgrade the chart, then roll back as in Phase 2. Reinstall it with a ClusterIP Service: as a LoadBalancer it waits for ports the gateway holds, `--wait` times out before its admission webhook is set up, and the chart upgrade then fails.

```bash
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace \
  --version 4.15.1 --set controller.service.type=ClusterIP --wait
```

## What behaves differently

The routes reproduce the Ingresses, including what ingress-nginx did implicitly (it set `X-Real-IP` and HSTS, and hid the backend's `Server` header). Differences found in testing:

- `/mcp/metrics` is always blocked. On ingress-nginx this needs `mcp.blockMetricsPath` and snippet annotations.
- The gateway does not cap request bodies, so `global.ingress.proxyBodySize` no longer applies. The application enforces its own limits.
- Paths match whole segments and are case-sensitive: `/api` (no trailing slash) reaches the API instead of the web UI, `/graphqlX` and `/API/...` reach the web UI.
- Clients that connect by IP without SNI get the app's certificate instead of ingress-nginx's self-signed default.
- CORS preflights on `/mcp` echo the request's `Origin` instead of `*`, without `Access-Control-Allow-Credentials`.
- Memory: istiod and the gateway proxy idle at about 95 MiB together, against about 70 MiB for ingress-nginx (K3s, `istiod-values.yaml`).

## Troubleshooting

| Symptom | Check |
|---|---|
| `no matches for kind "Gateway"` on upgrade | The Gateway API CRDs are missing (Phase 1, step 1). |
| Gateway `PROGRAMMED False` | `kubectl -n plextrac describe gateway plextrac` and `kubectl -n plextrac get pods -l gateway.networking.k8s.io/gateway-name=plextrac` (the proxy pod pulls `istio/proxyv2`). |
| A path returns 404 or the wrong page | `kubectl -n plextrac describe httproute <name>`: each parent should be `Accepted` and `ResolvedRefs`. |
| HTTPS handshake fails, HTTP works | The TLS Secret is missing (see Before you start). |
| `EXTERNAL-IP` stays `<pending>` after Phase 2 | Another LoadBalancer Service still holds 80/443: `kubectl get svc -A \| grep LoadBalancer`. |
| Let's Encrypt certificate not renewing | `kubectl -n plextrac get challenges`. cert-manager needs Gateway API enabled and a restart (Phase 1, step 3). |

Request logs: `kubectl -n plextrac logs deploy/plextrac-istio`. Control plane: `kubectl -n istio-system logs deploy/istiod`.
