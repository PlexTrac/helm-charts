# PlexTrac K3s Network Requirements

Every external endpoint the Helm/K3s deployment reaches, what it is reached for, and whether it is
actually required.

This replaces the docker-compose allowlist, which no longer applies. See
[What changed from the docker-compose list](#what-changed-from-the-docker-compose-list) if you are
migrating.

All outbound entries are TCP 443 unless noted.

---

## Table of contents

1. [The minimum allowlist](#the-minimum-allowlist)
2. [Outbound: container registries](#outbound-container-registries)
3. [Outbound: cluster bootstrap](#outbound-cluster-bootstrap)
4. [Outbound: steady state](#outbound-steady-state)
5. [Inbound](#inbound)
6. [What changed from the docker-compose list](#what-changed-from-the-docker-compose-list)
7. [Running fully disconnected](#running-fully-disconnected)
8. [Open questions](#open-questions)

---

## The minimum allowlist

A default install on Docker Hub, with no optional components and no cluster bootstrap over the
internet, needs exactly these. Everything in later sections is either bootstrap tooling or
conditional on a feature being switched on.

```text
# Container images: PlexTrac, Redis, Redis exporter
registry-1.docker.io
auth.docker.io
index.docker.io
production.cloudflare.docker.com

# Container images: CKEditor collaboration server
docker.cke-cs.com
```

> **If you mirror images into your own registry, this list drops to zero.** Setting
> `global.image.registry` re-homes every PlexTrac image, plus `redis` and `redis_exporter`, to your
> registry in one line. CKEditor and Synqly pin their own registries and need
> `images.ckeditor.registry` / `images.synqly.registry` set separately. See
> [Running fully disconnected](#running-fully-disconnected).

---

## Outbound: container registries

Hit on every `helm install` and `helm upgrade` that changes an image tag, and again whenever a pod
is rescheduled onto a node that has not cached the layer.

| Endpoint | What it serves | Status |
|---|---|---|
| `registry-1.docker.io` | Registry v2 API. Manifests and layer requests for all `plextrac/*` images, plus `redis` and `oliver006/redis_exporter`. | Required |
| `auth.docker.io` | Token service. Issues the bearer token every pull needs. Blocking this fails the pull with a 401, not a DNS error. | Required |
| `index.docker.io` | Login endpoint, used by `docker login` and `scripts/setup-registry-credentials.sh`. This is the default `DOCKER_REGISTRY` in `.env.example`. | Required |
| `production.cloudflare.docker.com` | Layer CDN. Blob downloads redirect here. Allowing only the registry host produces pulls that authenticate and then stall. | Required |
| `docker.cke-cs.com` | CKEditor collaboration server image. Requires CKEditor-issued credentials, held in the `ckeditor-registry-creds` pull secret. | Required |
| `quay.io` (plus `cdn.quay.io`, `cdn0-3.quay.io`) | Synqly embedded integration server (`quay.io/synqly/embedded`). Also where cert-manager images live. | If `synqly.enabled` or cert-manager |
| `registry.k8s.io` (plus its `*.pkg.dev` backing store) | ingress-nginx controller and its webhook-certgen job. | If installing ingress-nginx |
| `ghcr.io` | Only if you consume the chart from OCI (`oci://ghcr.io/PlexTrac/charts/plextrac`) instead of cloning the repo. | Optional path |

### Image inventory pulled by the chart

| Image | Purpose |
|---|---|
| `plextrac/plextracapi:stable` | Core API, workers, migrations job |
| `plextrac/plextracnginx:stable` | Frontend / static edge |
| `plextrac/plextracdb:7.2.0` | Couchbase |
| `plextrac/plextracpostgres:stable` | Postgres |
| `plextrac/minio:latest` | Object storage |
| `plextrac/plextrac-minio-bootstrap:stable` | Post-install bucket setup |
| `redis:8.4.0-alpine` | Docker official image |
| `oliver006/redis_exporter:latest` | Redis metrics sidecar |
| `docker.cke-cs.com/cs:latest` | CKEditor collaboration server |
| `plextrac/plextrac-keycloak:stable` | Only when `keycloak.enabled` |
| `plextrac/mcp:stable` | Only when `mcp.enabled` |
| `quay.io/synqly/embedded` | Only when `synqly.enabled` |

The authoritative list is `images.*` in [`charts/plextrac/values.yaml`](../charts/plextrac/values.yaml).

---

## Outbound: cluster bootstrap

Needed only if you follow the documented K3s path in
[`PlexTrac_K3s_Installation_Guide.md`](PlexTrac_K3s_Installation_Guide.md) on a fresh host. If you
already have a Kubernetes cluster, an internal K3s mirror, or air-gapped tarballs, none of this
applies. It is not needed again once the cluster exists.

| Endpoint | Step | Status |
|---|---|---|
| `get.k3s.io` | The K3s install script itself. | K3s install |
| `update.k3s.io` | Release-channel lookup that resolves which K3s version to fetch. | K3s install |
| `api.github.com` (`/repos/k3s-io/*`, `/repos/helm/helm`) | Version resolution for K3s, k3s-selinux, and the Helm installer. | K3s + Helm install |
| `github.com` (`/k3s-io/k3s/releases/download`, `/helm/helm/releases`) | Binary downloads for K3s and Helm. | K3s + Helm install |
| `get.helm.sh` | The Helm 3 tarball. Blocking it is the usual cause of a Helm install that resolves a version then fails. | Helm install |
| `raw.githubusercontent.com` | Fetches `get-helm-3` and its signing keys. | Helm install |
| `kubernetes.github.io` (redirects to `github.com` releases) | The ingress-nginx Helm repository index and chart tarball. | ingress-nginx |
| `charts.jetstack.io` | The cert-manager Helm repository. | cert-manager |
| `github.com/PlexTrac/helm-charts` | Cloning the chart repo. Skip if you consume the chart from OCI or ship it as a tarball. | Chart delivery |

> **K3s also pulls its own system images.** CoreDNS, the pause container, local-path-provisioner,
> metrics-server and klipper-lb come from `docker.io/rancher/*`, so they ride on the same Docker Hub
> entries above. The [air-gap image tarball](https://docs.k3s.io/installation/airgap) from the K3s
> releases page removes this.

---

## Outbound: steady state

Every entry here is conditional. The chart ships each of these keys empty, so a deployment that
leaves them empty makes none of these calls. Certificate issuance is the only one wired up by a
chart setting rather than a secret.

| Endpoint | Triggered by | Status |
|---|---|---|
| `acme-v02.api.letsencrypt.org`, `acme-staging-v02.api.letsencrypt.org` | cert-manager ACME issuance, when `certManager.issuer` is `letsencrypt` or `letsencrypt-staging`. Also used for the separate Keycloak certificate. | If Let's Encrypt |
| `stream.launchdarkly.com`, `sdk.launchdarkly.com`, `events.launchdarkly.com`, `app.launchdarkly.com` | Server-side feature flags. Consumed by `plextracapi`, `datalake-maintainer` and `mcp` when `LAUNCH_DARKLY_SDK_KEY` is set. | If LD key set |
| `clientstream.launchdarkly.com`, `clientsdk.launchdarkly.com`, `events.launchdarkly.com` | Browser-side flags. Egress from the **user's workstation**, not the cluster. | If LD key set |
| `*.pendo.io` and `*.storage.googleapis.com` | Product analytics, loaded in the browser when `PENDO_API_KEY` is set. Cluster egress is not involved. Pendo recommends the two wildcards over enumerating `app`/`cdn`/`data`/`portal` subdomains. | If Pendo key set |
| `<org>.ingest.sentry.io` | Backend error reporting when `SENTRY_DSN_BACKEND` is set. The exact host is embedded in your DSN; read it from there rather than allowlisting all of Sentry. | If Sentry DSN set |
| Your SMTP relay | The chart has no mail relay pod and sets only `MAILER_SECURE`. You point PlexTrac at your own relay, so the host and port are yours to allow. | Customer-supplied |
| Your integration targets | With `synqly.enabled`, the in-cluster Synqly server reaches whatever SIEM, ticketing or scanner APIs you connect. Those destinations depend entirely on which integrations you configure. | If `synqly.enabled` |

Vendor references: [LaunchDarkly domain list](https://launchdarkly.com/docs/sdk/concepts/domain-list),
[Pendo host names for restricted networks](https://support.pendo.io/hc/en-us/articles/16101373319707-Host-name-list-for-visitors-in-restricted-network-environments).

---

## Inbound

| Port | Source | Purpose |
|---|---|---|
| 443/tcp | End users | The application, its API (`/api/`, `/graphql`), object downloads (`/cloud/uploads/`), and the MCP endpoint (`/mcp`) if enabled. |
| 443/tcp | End users | **WebSocket upgrade on `/ws-v2`** for CKEditor real-time collaboration. Any proxy or load balancer in front of the ingress must permit the upgrade and hold idle sockets for 60s or more. |
| 80/tcp | Let's Encrypt validation servers | HTTP-01 challenge. Required at issuance and at every renewal, so it must stay open, not be opened once. Not needed for `selfSigned`, bring-your-own certs, or a DNS-01 issuer. |
| 443/tcp | End users | Keycloak, on its own hostname, when `keycloak.enabled`. This is a second DNS record and a second certificate. |

---

## What changed from the docker-compose list

| Endpoint | Then and now | Status |
|---|---|---|
| `api.github.com/repos/PlexTrac/plextrac-manager-util/releases` | The `plextrac` manager utility does not exist in the K3s deployment. Install and upgrade are `helm upgrade --install`. | **No longer needed** |
| `mxa.mailgun.org`, `mxb.mailgun.org` | There is no bundled mail relay in the chart. Mail goes through a relay you supply and allow yourself. | **No longer needed** |
| `docker.io/plextrac/*`, `docker.io/library`, `registry-1.docker.io/v2` | Unchanged in substance. Add `auth.docker.io` and `production.cloudflare.docker.com` if the old rules only covered the registry host. | Carried over |
| `docker.cke-cs.com` | Unchanged. | Carried over |
| Let's Encrypt, ports 80/443 | Same requirement, now driven by cert-manager inside the cluster instead of the host. | Carried over |
| WebSocket, 60s idle timeout | Same requirement, now on the `/ws-v2` ingress path. | Carried over |
| `quay.io`, `registry.k8s.io`, `get.k3s.io`, `get.helm.sh`, `charts.jetstack.io` | New. Kubernetes platform components and optional in-cluster services that had no compose equivalent. | **New** |

---

## Running fully disconnected

For a deployment that cannot open egress at all, the chart is built for this. It is a better answer
than a long allowlist if your policy is strict.

- **Mirror the images.** Set `global.image.registry` to your registry and every PlexTrac image plus
  `redis` and `redis_exporter` re-homes. Override `images.ckeditor.registry` and
  `images.synqly.registry` separately, since both pin their own.
- **Bootstrap K3s from the air-gap tarball** rather than `get.k3s.io`, and install the Helm binary
  from an internal artifact store.
- **Ship the chart as a tarball** or push it to your internal OCI registry instead of cloning from
  GitHub.
- **Leave the SaaS keys empty.** `LAUNCH_DARKLY_SDK_KEY`, `PENDO_API_KEY` and `SENTRY_DSN_BACKEND`
  are all blank by default. Empty keys mean no calls.
- **Use an internal CA** for TLS. Pre-create the secret named by `global.ingress.tlsSecretName`, or
  point `certManagerClusterIssuer` at your own issuer, and Let's Encrypt drops off the list along
  with the inbound port 80 requirement.

See [Reference: Image overrides](user-guide.md#reference-image-overrides) and
[Reference: TLS configuration](user-guide.md#reference-tls-configuration).

---

## Open questions

Two items could not be resolved from the chart alone. Confirm both before sending this to a
customer.

1. **CKEditor at runtime.** The image pull from `docker.cke-cs.com` is certain. Whether the running
   collaboration server also validates its license key over the network depends on the license type.
   CKEditor documents an offline license for fully air-gapped use, which implies the standard key may
   not be offline. Confirm which one PlexTrac ships against.
2. **Three secrets imply outbound calls the chart cannot resolve.** `PROVIDER_CODE_KEY`,
   `API_INTEGRATION_AUTH_CONFIG_NOTIFICATION_SERVICE`, and any AI/LLM feature reachable from
   `plextracapi` are configured inside the application, not the chart. Have the app team confirm
   whether any of them egress.
