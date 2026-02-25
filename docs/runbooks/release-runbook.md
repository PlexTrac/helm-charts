# Helm Release Runbook

## Pre-release checklist

1. Confirm CI passes.
2. Bump `charts/plextrac/Chart.yaml` `version` using SemVer.
3. Verify GA render output with `helm lint` and `helm template -f charts/plextrac/examples/values-ga.yaml`.

## Release flow

1. Merge to `main`.
2. `chart-release.yml` validates SemVer, packages the GA chart, and publishes to GHCR + GitHub Pages.

## Rollback

Use `helm rollback` for deployment rollback and publish a new chart patch version for release rollback.
