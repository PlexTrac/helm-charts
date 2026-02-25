# PlexTrac Helm Charts

Public-ready Helm chart repository for deploying the PlexTrac platform on Kubernetes.

## Repository layout

- `charts/plextrac`: primary chart
- `charts/plextrac/examples`: GA, CSI, and manual secret mode examples
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
- `manual`: references pre-existing Kubernetes Secrets

Detailed usage by mode: `docs/runbooks/secrets-modes.md`.

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

## CI and release

- PR/main validation: `.github/workflows/chart-ci.yml`
- Release pipeline: `.github/workflows/chart-release.yml`
- Releases publish to both:
  - OCI: `ghcr.io/<org>/charts/plextrac`
  - GitHub Pages chart repo (`gh-pages` branch)
