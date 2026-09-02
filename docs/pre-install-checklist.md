# Pre-Install Checklist

Everything you need to decide **before** running `helm install`, and the exact values
field each decision maps to.

> **Helm does not read `.env`.** The only file `.env.local` feeds is
> `scripts/setup-registry-credentials.sh`, and only its `DOCKER_*` / `CKEDITOR_DOCKER_*`
> variables. Every other setting below goes in your values file. Copy one of
> `charts/plextrac/examples/values-*.yaml` to `my-values.yaml` and edit it.

This reference used to live as commentary in `.env.example`, which invited exactly that
confusion. It was trimmed back to registry credentials in
[#20](https://github.com/PlexTrac/helm-charts/pull/20); this document is the rest of it,
corrected and kept current. See [Provenance](#provenance) at the end.

---

## A. Universal — required regardless of secrets mode

| Decision | Values field | Notes |
|---|---|---|
| Hostname | `global.ingress.host` | Must resolve to the ingress LoadBalancer IP. Required for valid Ingress objects. |
| Namespace | `global.namespace` | **Wins over `helm -n`.** If your namespace is not literally `plextrac`, set this or every resource renders into `plextrac`. |
| Namespace ownership | `global.createNamespace` | `false` when the namespace already exists and something else manages it. Avoids `invalid ownership metadata`. |
| StorageClass | `storage.storageClassName` | K3s `local-path`, GKE `premium-rwo`, AKS `managed-premium`, EKS `gp3`. `""` uses the cluster default class. |
| TLS secret name | `global.ingress.tlsSecretName` | Defaults to `internal-tls`. |
| TLS issuance | `global.ingress.certManager.issuer` | `selfSigned` \| `letsencrypt` \| `letsencrypt-staging` \| `""` (none / bring your own). |
| ACME contact | `global.ingress.certManager.email` | Required when the issuer is `letsencrypt` or `letsencrypt-staging`. |
| Bring-your-own issuer | `global.ingress.certManagerClusterIssuer` | Used **only** when `certManager.issuer` is `""`. |
| Image pull secrets | `global.imagePullSecrets` | List of `{name: ...}`. See section B. |
| Registry re-homing | `global.image.registry` | Prefixes every image except those with their own `registry` (e.g. ckeditor). |
| Secrets mode | `secrets.mode` | `manual` \| `externalSecrets` \| `csi`. See section C. |

Extra non-secret environment variables go in `extraEnv` (a flat map, injected into the
`env-config` ConfigMap and consumed by `plextracapi` via `envFrom`).

---

## B. Registry credentials

PlexTrac images require authentication. This is the one place `.env` is still used:

```bash
cp .env.example .env.local   # fill in DOCKER_* and, if using CKEditor, CKEDITOR_DOCKER_*
./scripts/setup-registry-credentials.sh
```

The script creates the pull secret in the cluster and prints the values snippet to paste
in. `DOCKER_REGISTRY` may be any Docker Registry HTTP API v2 or OCI-compliant registry:
Docker Hub, Harbor, GHCR, ECR/GCR/ACR, a self-hosted registry, or a mirror.

> `.env.local` is shell-sourced, so values are subject to shell expansion. If your
> username or password contains a `$` (common for Harbor robot accounts such as
> `robot$myproject`), wrap it in **single** quotes so it passes through literally.

The resulting secret is referenced by `global.imagePullSecrets`. In `manual` mode you can
alternatively have the chart create it from
`secrets.manual.generatedSecrets.registryCredentials`; in `externalSecrets` mode use
`secrets.externalSecrets.registryCredentials`.

---

## C. Secrets modes

| Mode | What the chart does | You must provide |
|---|---|---|
| `manual` (default) | Generates every password and key on first install and preserves them across upgrades. | Nothing required. Optionally the operator-supplied keys in section C.1. |
| `externalSecrets` | Creates `ExternalSecret` objects; External Secrets Operator syncs them from your store. | The **full key set** below, pre-populated in your store. |
| `csi` | Creates a `SecretProviderClass`; the Secrets Store CSI Driver syncs into Kubernetes Secrets. | The **full key set** below, pre-populated in your provider. |

Reference examples: `values-self-hosted.yaml` (manual), `values-external-secrets.yaml`
(ESO), `values-csi-aws.yaml` / `values-csi-gcp.yaml` (CSI). Full detail in
[runbooks/secrets-modes.md](runbooks/secrets-modes.md).

In `manual` mode, `secrets.manual.createKubernetesSecrets: false` makes the chart skip
Secret creation so you can apply them yourself.

### ESO connection settings

| Values field | Example |
|---|---|
| `secrets.externalSecrets.secretStoreRef.kind` | `ClusterSecretStore` or `SecretStore` |
| `secrets.externalSecrets.secretStoreRef.name` | your store's name |
| `secrets.externalSecrets.refreshInterval` | `1h` |
| `secrets.externalSecrets.application.remoteKey` | `plextrac/application-secrets` |
| `secrets.externalSecrets.shared.remoteKey` | `plextrac/shared-secrets` |
| `secrets.externalSecrets.registryCredentials.remoteKey` | `plextrac/registry-credentials` (when `.enabled`) |
| `secrets.externalSecrets.tls.remoteKey` | `plextrac/tls-cert` (when `.enabled`; must be a PKCS#12 bundle) |

### CSI settings

Set `secrets.csi.secretProviderClass.enabled: true`, `.provider`
(`aws` \| `gcp` \| `azure` \| `vault`), `.parameters.secrets` with your provider's
resource paths, and `.secretObjects` to map them onto the `application-secrets` and
`shared-secrets` names and key structure.

### C.1 The key contract

<!-- BEGIN GENERATED: secret-key-contract -->

### `application-secrets` — 49 keys

In `externalSecrets` and `csi` modes **every key below must exist** in your secret
store before `helm install`, even the ones that may be empty. In `manual` mode the
chart fills all of them in for you and you can ignore this table.

> **Nothing validates this at install time.** In `manual` mode the chart generates
> the keys from `secrets.manual.requiredKeys`, so the contract holds by construction.
> In `externalSecrets` mode the chart uses `dataFrom.extract.key`, which pulls your
> remote secret wholesale without enumerating keys; in `csi` mode you supply the
> whole `parameters.secrets` / `secretObjects` mapping yourself. In both, a missing
> key installs cleanly and fails later at runtime, as a crash-loop or a quietly
> broken feature. This table is the only place the contract is written down, which
> is why it is generated rather than hand-maintained.

#### Auto-generated (27) — random values, `manual` mode creates these for you

In `externalSecrets` / `csi` mode you generate these yourself. Any random value works
on first creation, but **keep them stable afterwards**: nothing rotates them for you,
and changing some of them breaks the deployment (see the rotation notes in
[secrets-modes.md](runbooks/secrets-modes.md)). Lengths below are what the chart
generates, not a hard requirement.

| Key | Chart-generated length |
|---|---|
| `API_INTEGRATION_AUTH_CONFIG_NOTIFICATION_SERVICE` | 32 chars |
| `CB_ADMIN_PASS` | 32 chars |
| `CB_API_PASS` | 32 chars |
| `CB_BACKUP_PASS` | 32 chars |
| `CKEDITOR_ENVIRONMENT_SECRET_KEY` | 32 chars |
| `CLOUD_STORAGE_ACCESS_KEY` | 20 chars |
| `CLOUD_STORAGE_SECRET_KEY` | 32 chars |
| `COOKIE_KEY` | 32 chars |
| `INTERNAL_API_KEY_SHARED` | 32 chars |
| `JWT_KEY` | 32 chars |
| `MFA_KEY` | 32 chars |
| `MINIO_LOCAL_PASSWORD` | 32 chars |
| `MINIO_ROOT_PASSWORD` | 32 chars |
| `PG_CKEDITOR_ADMIN_PASSWORD` | 32 chars |
| `PG_CKEDITOR_RO_PASSWORD` | 32 chars |
| `PG_CKEDITOR_RW_PASSWORD` | 32 chars |
| `PG_CORE_ADMIN_PASSWORD` | 32 chars |
| `PG_CORE_AI_SQL_PASSWORD` | 32 chars |
| `PG_CORE_RO_PASSWORD` | 32 chars |
| `PG_CORE_RW_PASSWORD` | 32 chars |
| `PG_METRICS_PASSWORD` | 32 chars |
| `PG_RUNBOOKS_ADMIN_PASSWORD` | 32 chars |
| `PG_RUNBOOKS_RO_PASSWORD` | 32 chars |
| `PG_RUNBOOKS_RW_PASSWORD` | 32 chars |
| `POSTGRES_PASSWORD` | 32 chars |
| `PROVIDER_CODE_KEY` | 32 chars |
| `REDIS_PASSWORD` | 32 chars |

#### Static defaults (21) — usernames, database and bucket names

These are identities, not secrets. The values match the docker-compose reference
deployment. Override them only if you know why; several are referenced by the
Postgres init scripts.

| Key | Value |
|---|---|
| `CB_ADMIN_USER` | `ptadminuser` |
| `CB_API_USER` | `ptapiuser` |
| `CB_BACKUP_USER` | `ptbackupuser` |
| `CB_BUCKET` | `reportMe` |
| `MINIO_LOCAL_USER` | `localadmin` |
| `MINIO_ROOT_USER` | `admin` |
| `PG_CKEDITOR_ADMIN_USER` | `ckeditor_admin` |
| `PG_CKEDITOR_DB` | `ckeditor` |
| `PG_CKEDITOR_RO_USER` | `ckeditor_ro` |
| `PG_CKEDITOR_RW_USER` | `ckeditor_rw` |
| `PG_CORE_ADMIN_USER` | `core_admin` |
| `PG_CORE_AI_SQL_USER` | `ai_sql` |
| `PG_CORE_DB` | `core` |
| `PG_CORE_RO_USER` | `core_ro` |
| `PG_CORE_RW_USER` | `core_rw` |
| `PG_METRICS_USER` | `metrics` |
| `PG_RUNBOOKS_ADMIN_USER` | `runbooks_admin` |
| `PG_RUNBOOKS_DB` | `runbooks` |
| `PG_RUNBOOKS_RO_USER` | `runbooks_ro` |
| `PG_RUNBOOKS_RW_USER` | `runbooks_rw` |
| `POSTGRES_USER` | `internalonly` |

#### Operator-supplied (1) — may be empty, but the key must exist

| Key |
|---|
| `ADMIN_EMAIL` |

### `shared-secrets` — 4 keys

All optional integrations. Each key must exist in `externalSecrets` / `csi` mode; an
empty value disables that integration.

| Key |
|---|
| `CKEDITOR_SERVER_LICENSE_KEY` |
| `LAUNCH_DARKLY_SDK_KEY` |
| `PENDO_API_KEY` |
| `SENTRY_DSN_BACKEND` |

<!-- END GENERATED: secret-key-contract -->

---

## D. Optional components

All disabled by default. Each has its own reference section in
[user-guide.md](user-guide.md).

| Component | Enable with | Also required |
|---|---|---|
| Synqly (in-cluster integrations) | `synqly.enabled` | `synqly.admin.username` must be an email address. `synqly.database.dedicated` to get its own Postgres. |
| Keycloak (OIDC/SSO broker) | `keycloak.enabled` | `keycloak.host` — browser-facing, needs its own DNS and TLS. `keycloak.database.dedicated` for its own Postgres. |
| MCP server | `mcp.enabled` | **Requires `keycloak.enabled`.** Served at `/mcp` on the app host. |

Replica counts and resources for these come from `replicaCounts.<component>` and
`resources.<component>`, same as the core services.

---

## E. Multi-node clusters

Two claims are mounted by pods that can land on different nodes and must move to
`ReadWriteMany` storage. Single-node clusters need nothing here.

| Values field | Purpose |
|---|---|
| `storage.claims.plextracapi` | `accessMode` / `storageClassName` / `size` override for the shared app volume |
| `storage.claims.whitelabeling` | same, for the white-label locale overrides |
| `podSecurityContext.fsGroup` | Must be `1337`. The app image runs as uid/gid 1337 and cannot write to a root-owned volume. |

Ready-made overlays: `examples/values-eks-efs.yaml` and
`examples/values-gke-filestore.yaml`. Full detail in
[user-guide.md § Storage configuration](user-guide.md#reference-storage-configuration).

---

## Provenance

The key contract in section C.1 is **generated from the chart**, not written by hand:

```bash
scripts/gen-secrets-reference.py           # regenerate after changing requiredKeys
scripts/gen-secrets-reference.py --check   # CI guard: fails if this doc is stale
```

The generator renders the chart twice and classifies each key by whether its value
changes between renders (auto-generated), is empty (operator-supplied), or is stable and
non-empty (static default).

This matters because the hand-maintained version of this list had already drifted before
it was removed: it claimed 47 application keys when the listing held 51 distinct names,
it listed the four `shared-secrets` keys under `application-secrets` as well, and it
predated `PG_METRICS_USER` / `PG_METRICS_PASSWORD`. Regenerate rather than edit
section C.1 by hand.
