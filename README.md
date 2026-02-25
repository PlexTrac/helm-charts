# PlexTrac Helm Charts

Public-ready Helm chart repository for deploying the PlexTrac platform on Kubernetes.

## Repository layout

- `charts/plextrac`: primary chart
- `charts/plextrac/examples`: GA, CSI, manual, and override template examples
- `docs/migration`: migration and parity mapping from Kustomize manifests
- `docs/runbooks`: release and support runbooks
- `.github/workflows`: CI and release automation

## Versioning

- `charts/plextrac/Chart.yaml` `version` follows SemVer and tracks release cadence (example: `2.27.1`).
- `appVersion` tracks application release signaling and can move independently.

## Deployment profile

This repository currently publishes and supports the **GA profile only**.

Use:

- default `charts/plextrac/values.yaml` (already GA-aligned), or
- `charts/plextrac/examples/values-ga.yaml` for explicit GA installs.

## Secrets model (kept for multi-provider support)

Set `secrets.mode` in values:

- `externalSecrets` (default GA path): creates `ExternalSecret` resources
- `csi`: creates `SecretProviderClass` for CSI-based providers
- `manual`: either references pre-existing Kubernetes Secrets or auto-creates required GA Kubernetes Secrets when `secrets.manual.createKubernetesSecrets=true`

In `manual` auto-create mode, missing GA-required secret keys are generated automatically (or reused from existing in-cluster secret values).

Detailed usage by mode: `docs/runbooks/secrets-modes.md`.

Ingress host and TLS secret are configured via:

- `global.ingress.host`
- `global.ingress.tlsSecretName`
- `global.ingress.certManagerClusterIssuer` (optional)

Starter override template:

- `charts/plextrac/examples/values-override-template.yaml`

## Basic usage (GA)

```bash
helm upgrade --install plextrac ./charts/plextrac --namespace plextrac --create-namespace
```

```bash
helm upgrade --install plextrac ./charts/plextrac \
  -f charts/plextrac/examples/values-ga.yaml \
  --namespace plextrac \
  --create-namespace
```

```bash
cp charts/plextrac/examples/values-override-template.yaml my-values.yaml
```

```bash
helm upgrade --install plextrac ./charts/plextrac \
  -f my-values.yaml \
  --namespace plextrac \
  --create-namespace
```

## CI and release

- PR/main validation: `.github/workflows/chart-ci.yml`
- Release pipeline: `.github/workflows/chart-release.yml`
- Releases publish to both:
  - OCI: `ghcr.io/<org>/charts/plextrac`
  - GitHub Pages chart repo (`gh-pages` branch)
