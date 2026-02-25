# Secrets Modes Usage Guide

This chart supports three secret wiring modes through `secrets.mode`:

- `externalSecrets` (GA default)
- `csi`
- `manual`

Use this guide to choose and apply the correct mode.

## Common prerequisites

- Kubernetes cluster with namespace access.
- Helm 3 installed.
- Chart path: `./charts/plextrac`.

For all modes, install with:

```bash
helm upgrade --install plextrac ./charts/plextrac \
  --namespace plextrac \
  --create-namespace \
  -f <your-values-file>
```

## Mode 1: externalSecrets (default GA path)

Use when External Secrets Operator is installed and a secret store is configured.

Example values file:

- `charts/plextrac/examples/values-ga.yaml`

Key fields:

- `secrets.externalSecrets.secretStoreRef.kind`
- `secrets.externalSecrets.secretStoreRef.name`
- `secrets.externalSecrets.application.remoteKey`
- `secrets.externalSecrets.shared.remoteKey`
- `secrets.externalSecrets.shared.stageProperty` (set to `ga` for GA)
- `secrets.externalSecrets.registryCredentials.*`
- `secrets.externalSecrets.tls.*`

Example command:

```bash
helm upgrade --install plextrac ./charts/plextrac \
  --namespace plextrac \
  --create-namespace \
  -f charts/plextrac/examples/values-ga.yaml
```

## Mode 2: csi

Use when Secrets Store CSI Driver is installed and you want provider-native CSI mounts/sync.

Example values file:

- `charts/plextrac/examples/values-csi-gcp.yaml`

Key fields:

- `secrets.csi.secretProviderClass.enabled=true`
- `secrets.csi.secretProviderClass.provider`
- `secrets.csi.secretProviderClass.parameters`
- `secrets.csi.secretProviderClass.secretObjects`

Example command:

```bash
helm upgrade --install plextrac ./charts/plextrac \
  --namespace plextrac \
  --create-namespace \
  -f charts/plextrac/examples/values-csi-gcp.yaml
```

Notes:

- In CSI mode, the chart renders `SecretProviderClass`.
- Ensure your CSI configuration syncs/creates Kubernetes Secrets expected by GA workloads.

## Mode 3: manual

Use when you want to create Kubernetes Secrets yourself and have workloads consume them directly.

Example values file:

- `charts/plextrac/examples/values-manual-secrets.yaml`

GA parity manifests reference these secret names:

- `application-secrets`
- `shared-secrets`
- `regcred-dorf` (image pull secret where required)
- `plextrac-com-tls` (for ingress TLS)

Create required secrets before Helm install. Example:

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

Then install:

```bash
helm upgrade --install plextrac ./charts/plextrac \
  --namespace plextrac \
  --create-namespace \
  -f charts/plextrac/examples/values-manual-secrets.yaml
```

## Quick verification

After install, verify secret wiring:

```bash
kubectl -n plextrac get externalsecret
kubectl -n plextrac get secretproviderclass
kubectl -n plextrac get secret
kubectl -n plextrac get pods
```

Interpretation:

- `externalSecrets` mode: expect `ExternalSecret` resources.
- `csi` mode: expect `SecretProviderClass`.
- `manual` mode: expect pre-created `Secret` objects and no generated external secret resources.
