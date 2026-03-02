# Secrets Setup by Mode

Use this guide to configure secrets for the `plextrac` chart across all supported `secrets.mode` values:

- `externalSecrets` (default)
- `csi`
- `manual`

## Secret types this chart expects

Regardless of mode, workloads expect these Kubernetes Secrets by name:

- `application-secrets` (`Opaque`)
- `shared-secrets` (`Opaque`)
- `plextrac-com-tls` (`kubernetes.io/tls`) when ingress TLS is enabled
- A registry pull secret only if using a private image registry (configured via `global.imagePullSecrets`)

Notes:

- All workloads reference `application-secrets` and `shared-secrets` via `secretKeyRef`.
- Image pull secrets are driven by `global.imagePullSecrets` and default to empty (DockerHub public images require no credentials).
- TLS is represented as an `ExternalSecret` in `externalSecrets` mode, or a pre-created TLS secret in `manual`/CSI-backed setups.

## Common prerequisites

- Kubernetes cluster access for target namespace
- Helm 3
- Chart path: `./charts/plextrac`
- Set `global.ingress.host` to a valid DNS host for your environment

Base install command:

```bash
helm upgrade --install plextrac ./charts/plextrac \
  --namespace plextrac \
  --create-namespace \
  -f <your-values-file>
```

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
  - set `targetSecretName` (default `regcred-dorf`)
  - set `remoteKey` containing Docker config JSON payload
- TLS secret:
  - enable with `secrets.externalSecrets.tls.enabled=true`
  - set `targetSecretName` (default `plextrac-com-tls`)
  - set `remoteKey` containing a PKCS#12 bundle (template converts to `tls.crt`/`tls.key`)

Install example:

```bash
helm upgrade --install plextrac ./charts/plextrac \
  --namespace plextrac \
  --create-namespace \
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
- Workloads still read Kubernetes Secrets by name (`application-secrets`, `shared-secrets`, `regcred-dorf`, `plextrac-com-tls`).
- Configure `secretObjects` so synced Kubernetes Secrets match expected names and key structure.

Install example:

```bash
helm upgrade --install plextrac ./charts/plextrac \
  --namespace plextrac \
  --create-namespace \
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
2. Create image pull secret `regcred-dorf`.
3. Create TLS secret `plextrac-com-tls` if ingress TLS is used.

Example creation commands:

```bash
kubectl -n plextrac create secret generic application-secrets --from-env-file=app.env
kubectl -n plextrac create secret generic shared-secrets --from-env-file=shared.env
kubectl -n plextrac create secret docker-registry regcred-dorf \
  --docker-server=registry.example.com \
  --docker-username="$DOCKER_USER" \
  --docker-password="$DOCKER_PASS"
kubectl -n plextrac create secret tls plextrac-com-tls \
  --cert=./tls.crt \
  --key=./tls.key
```

Install example:

```bash
helm upgrade --install plextrac ./charts/plextrac \
  --namespace plextrac \
  --create-namespace \
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
