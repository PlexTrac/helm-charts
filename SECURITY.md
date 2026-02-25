# Security Policy

## Secret handling

- Do not commit plaintext secrets in any values file.
- Use `secrets.mode=externalSecrets` or `secrets.mode=csi` for production where possible.
- If using `secrets.mode=manual`, reference existing Kubernetes Secrets by name.

## Reporting security issues

Please report security concerns through your normal PlexTrac security contact channels and avoid posting sensitive details in public issues.
