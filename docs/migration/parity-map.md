# Kustomize to Helm Parity Map

This map tracks migration parity from `product-deploy-manifests/base` into `charts/plextrac/templates`.

| Kustomize source | Helm target |
| --- | --- |
| `base/namespace.yaml` | `templates/namespace.yaml` |
| `base/configmap-env-config.yaml` | `templates/configmaps.yaml` (`configMaps.envConfig`) |
| `base/configmap-customer-curated-waf-rules.yaml` | `templates/configmaps.yaml` (`configMaps.customerCuratedWafRules`) |
| `base/configmap-postgres-initdb.yaml` | `templates/configmaps.yaml` (`configMaps.postgresInitdb`) |
| `base/pvcs.yaml` | `templates/pvcs.yaml` (`persistentVolumeClaims`) |
| `base/services.yaml` | `templates/services.yaml` (`services.*`) |
| `base/ingress-plextrac.yaml` | `templates/ingresses.yaml` (`ingresses[]`) |
| `base/jobs.yaml` | `templates/jobs.yaml` (`jobs.list[]`) |
| `base/deployment-*.yaml` | `templates/deployments.yaml` (`components.*`) |
| `base/externalsecret-plextrac-*.yaml` | `templates/secrets.yaml` (`secrets.mode=externalSecrets`) |
