# Contributing

## Development workflow

1. Update chart templates and values in `charts/plextrac`.
2. Run validation locally:
   - `helm lint charts/plextrac`
   - `helm template plextrac charts/plextrac > /tmp/plextrac-render.yaml`
3. Ensure no plaintext secrets are introduced.
4. Open a PR with a SemVer chart `version` bump when changes are release-worthy.
