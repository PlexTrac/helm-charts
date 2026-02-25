# Overlay to Values Mapping Guide

## Release-stage scope

Current scope is GA-only. Use the baseline `values.yaml` or `charts/plextrac/examples/values-ga.yaml`.

## Image tags

Set chart values per component image tag and promote by updating the GA profile override.

## Secrets provider switching

- `secrets.mode=externalSecrets`: External Secrets Operator
- `secrets.mode=csi`: Secrets Store CSI Driver
- `secrets.mode=manual`: pre-created Kubernetes Secrets
