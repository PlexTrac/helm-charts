# Secrets Setup by Mode

Use this guide to configure secrets for the `plextrac` chart across all supported `secrets.mode` values:

- `manual` (default)
- `externalSecrets`
- `csi`

## Secret types this chart expects

Regardless of mode, workloads expect these Kubernetes Secrets by name:

- `application-secrets` (`Opaque`)
- `shared-secrets` (`Opaque`)
- `internal-tls` (`kubernetes.io/tls`) when ingress TLS is enabled
- A registry pull secret only if using a private image registry (configured via `global.imagePullSecrets`)

Notes:

- All workloads reference `application-secrets` and `shared-secrets` via `secretKeyRef`.
- Image pull secrets are driven by `global.imagePullSecrets`. PlexTrac images require authentication — you must configure a registry credential secret and reference it here before the chart can pull images.
- TLS is represented as an `ExternalSecret` in `externalSecrets` mode, or a pre-created TLS secret in `manual`/CSI-backed setups.
- In `externalSecrets`/`csi` modes the chart does not generate `application-secrets`; your store must supply **every** key in `secrets.manual.requiredKeys.application`. This includes `PG_METRICS_USER` and `PG_METRICS_PASSWORD` (they back the postgres-exporter sidecar): the postgres pod will not start if they are missing.

## Common prerequisites

- Kubernetes cluster access
- Target namespace already exists. `scripts/setup-registry-credentials.sh` creates it (with the Helm ownership labels the chart adopts), so the install commands below omit `--create-namespace`. If you create the namespace another way, set `global.createNamespace: false` so the chart does not also try to claim it.
- Helm 3
- Chart path: `./charts/plextrac`
- Set `global.ingress.host` to a valid DNS host for your environment

Base install command (use the same flags as the [user-guide Phase 4](../user-guide.md#phase-4--install); `--timeout 15m` because the first install runs DB migrations inline):

```bash
helm upgrade --install plextrac ./charts/plextrac \
  --namespace plextrac \
  -f <your-values-file> \
  --wait --timeout 15m
```

> The per-mode install snippets below are abbreviated — use the same `--wait --timeout 15m` flags shown here.

## Mode 1: `externalSecrets`

Use when External Secrets Operator is installed and connected to a `SecretStore`/`ClusterSecretStore`.

Reference values file:

- `charts/plextrac/examples/values-external-secrets.yaml`

Required values:

- `secrets.mode=externalSecrets`
- `secrets.externalSecrets.secretStoreRef.kind`
- `secrets.externalSecrets.secretStoreRef.name`
- `secrets.externalSecrets.application.remoteKey`
- `secrets.externalSecrets.shared.remoteKey`

Optional generated secret types:

- Registry secret:
  - enable with `secrets.externalSecrets.registryCredentials.enabled=true`
  - set `targetSecretName` to match the pull secret referenced in `global.imagePullSecrets` (for example `internal-registry-creds`)
  - set `remoteKey` containing Docker config JSON payload
- TLS secret:
  - enable with `secrets.externalSecrets.tls.enabled=true`
  - set `targetSecretName` (default `internal-tls`)
  - set `remoteKey` containing a PKCS#12 bundle (template converts to `tls.crt`/`tls.key`)

Install example:

```bash
helm upgrade --install plextrac ./charts/plextrac \
  --namespace plextrac \
  -f charts/plextrac/examples/values-external-secrets.yaml
```

## Mode 2: `csi`

Use when Secrets Store CSI Driver is installed and your provider can sync to Kubernetes Secrets.

Reference values file:

- `charts/plextrac/examples/values-csi-gcp.yaml`

Required values:

- `secrets.mode=csi`
- `secrets.csi.secretProviderClass.enabled=true`
- `secrets.csi.secretProviderClass.provider`
- `secrets.csi.secretProviderClass.parameters`
- `secrets.csi.secretProviderClass.secretObjects`

Important behavior:

- In CSI mode, this chart renders `SecretProviderClass` only.
- Workloads still read Kubernetes Secrets by name (`application-secrets`, `shared-secrets`, your image pull secret such as `internal-registry-creds`, `internal-tls`).
- Configure `secretObjects` so synced Kubernetes Secrets match expected names and key structure.

Install example:

```bash
helm upgrade --install plextrac ./charts/plextrac \
  --namespace plextrac \
  -f charts/plextrac/examples/values-csi-gcp.yaml
```

## Mode 3: `manual`

Use when secrets are managed directly in Kubernetes instead of External Secrets.

Manual mode now supports two patterns:

1. pre-create secrets outside Helm, or
2. have Helm create them from values (`manual.createKubernetesSecrets=true`).

Reference values file:

- `charts/plextrac/examples/values-manual-secrets.yaml`

### Option A: pre-create secrets (outside Helm)

Required setup:

1. Create `application-secrets` and `shared-secrets` with all keys required by GA workloads.
2. Create the image pull secret (this guide uses `internal-registry-creds`; the name must match `global.imagePullSecrets`).
3. Create TLS secret `internal-tls` if ingress TLS is used.

Example creation commands:

```bash
kubectl -n plextrac create secret generic application-secrets --from-env-file=app.env
kubectl -n plextrac create secret generic shared-secrets --from-env-file=shared.env
kubectl -n plextrac create secret docker-registry internal-registry-creds \
  --docker-server=registry.example.com \
  --docker-username="$DOCKER_USER" \
  --docker-password="$DOCKER_PASS"
kubectl -n plextrac create secret tls internal-tls \
  --cert=./tls.crt \
  --key=./tls.key
```

Install example:

```bash
helm upgrade --install plextrac ./charts/plextrac \
  --namespace plextrac \
  -f charts/plextrac/examples/values-manual-secrets.yaml
```

### Option B: Helm creates Kubernetes Secret objects

Set:

- `secrets.mode=manual`
- `secrets.manual.createKubernetesSecrets=true`
- `global.createNamespace=false` if the namespace already exists (or let the chart create it when true)
- `secrets.manual.generatedSecrets.application.stringData` (or `.data`)
- `secrets.manual.generatedSecrets.shared.stringData` (or `.data`)

Optional:

- `secrets.manual.generatedSecrets.registryCredentials.enabled=true` and `dockerconfigjson` (recommended for GA)
- `secrets.manual.generatedSecrets.tls.enabled=true` and `crt`/`key`
- `secrets.manual.generatedSecrets.additional[]` for deployment-specific extra secrets
- `secrets.manual.requiredKeys.application` and `secrets.manual.requiredKeys.shared` can be overridden if your workload key contract changes

Reference example:

- `charts/plextrac/examples/values-manual-secrets.yaml`

Security note:

- Values files contain sensitive material in this mode. Prefer encrypted values tooling (for example SOPS) in GitOps workflows.
- You can create any extra secret object per deployment with `generatedSecrets.additional` (custom `name`, `type`, `stringData`, and/or base64 `data`).
- In manual auto-create mode, this chart auto-populates missing GA required keys (or reuses existing secret values when present).
- Registry credentials are only needed if pulling from a private registry. Set `global.imagePullSecrets` to reference a pre-existing pull secret, or use `generatedSecrets.registryCredentials.enabled=true` to have the chart create it.

## Verify after install

```bash
kubectl -n plextrac get externalsecret
kubectl -n plextrac get secretproviderclass
kubectl -n plextrac get secret
kubectl -n plextrac get pods
```

Expected results by mode:

- `externalSecrets`: `ExternalSecret` objects exist and populate target `Secret` objects.
- `csi`: `SecretProviderClass` exists; synced `Secret` objects are present.
- `manual`: either pre-created `Secret` objects are present, or Helm-generated secret resources are created when `createKubernetesSecrets=true`.
