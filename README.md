---
# vim: set expandtab ft=markdown ts=4 sw=4 sts=4 tw=100:
title: README
description: README
---

# README

These are the helm charts used to deploy the PlexTrac application.

## Development

### Tips & Tricks

**Templating**

If you're want to see the output of a single template, just do

```bash
helm template -n NAMESPACE RELEASE_NAME -s templates/TEMPLATE.yaml CHART_DIR | yq e
```
# QuickStart

## Pre-Requisites

-   Kubernetes cluster 1.xx or higher
-   ? Access to desired namespace
-   Helm 3
-   Registry Auth Token
-   Optional: desired domain name (requires properly configured Ingress/Cert-Manager)

## Installation

**Configure Helm Repo**

```bash
helm repo add plextrac https://helm.plextrac.com/charts
```

**Customize parameters**

-   Customize parameters (optional)
-   Install

# Charts

## `plextrac`

This helm chart manages the core components of the PlexTrac application (eg, `core-backend` and
`core-frontend`). _subcharts_ (aka, dependencies) are used to configure additional dependencies such
as databases, cache, microservices.

### Notes

The `plextracapi` container is considered the main app. Pending a better deployment method for the
frontend bundle, `plextracnginx` is also deployed by default. Services are named to minimize issues
with our current implementation details.

If not using Ingress, please port-forward to the `RELEASE-ui` service

### Use Cases

This Chart should work in all the following configurations.

#### Dev/Evaluation

Refer to Single Tenancy, below.

#### CI/CD

Low resource usage, should be able to trigger an upgrade or image update frequently. May need to run
migrations via job, etc. Shared resources are an option for cache, database, etc.

#### Single Tenancy

May be deployed in single node (aka, not HA) or shared clusters where HA is possible. Resource usage
is low enough that data stores may operate in single instance configurations. Medium resource usage.
Zero downtime deploys are desirable, with option to run migrations at deploy time or as a scheduled
job.

#### Multi Tenancy

May need to configure a proper _cluster_ for database, cache, etc. High resource usage. Zero
downtime deploys _required_. Migrations must run decoupled from deploys. May opt to configure one or
more dependencies separately.

### Sub-Charts

**couchbase**

Core database implementation. If not enabled, `CB_API_USER` & `CB_API_PASS`

**cockroachdb**

Intended to replace couchbase, deploys `cockroachdb`. Currently used for audit log.

**redis**

Used for cache & inter-pod communication for multi-pod configurations

# Values

## Structure

### global

Place values here that are _shared_ between a chart and it's sub-charts. For example, a password
that should be shared between an application and it's dependency (eg, redis) should be placed in
global following an appropriate namespacing scheme. This global config is separate from sub-chart
specific configuration.

**Example:**

```yaml
# -- Global customizations (for charts that support it)
global:
  # -- Customize the registry used for pulling images
  imageRegistry: k3d-registry.localhost:5000
  redis:
    # -- Specify the redis password
    password: ********************************

image:
  # -- Docker image repository
  repository: plextrac/foo
  # -- Docker image tag
  tag: "stable"

# -- configuration for the redis sub-chart
redis:
  # -- Enables installation of the redis sub-chart
  enabled: true
```

In the above example, `.Values.global.redis.password` will be used by the redis sub-chart & by
the parent chart for redis authentication. The `image` parameter in the main deployment will be set
as `k3d-registry.localhost:5000/plextrac/foo:stable`.

### sub-charts

Configuration specific to sub-charts must go under a top level key of the sub-charts name. If the
chart is optional, the dependency should be included dependent on a `subchart.enabled == true`
flag.

> it should be fine to override the name of a dependency (eg, to deploy redis as `localcache`)
> this should be supported

**Example**

```yaml

---
redis:
    enabled: true
    nameOverride: localcache # would be available at `redis://localcache:6379`
```

### External Dependencies

More complex or higher load environments may merit using a separately managed dependency (eg,
swapping out Redis for Elasticache). This should be configured in the top-level `Values`, not
under the corresponding internal dependency (ie, sub-chart) configuration.

**Wrong:**

```yaml

---
redis:
    enabled: false
    host: redis-01.7abc2d.0001.usw2.cache.amazonaws.com
    port: 6379
```

**Correct:**

```yaml
---
---
redis:
    enabled: false

externalRedisHost: redis-01.7abc2d.0001.usw2.cache.amazonaws.com
externalRedisPort: 6379
```

By making these explicit via the `external` prefix, we avoid confusion and ensure configuration
parameters are obvious. _Simple is better than complex_.

### Credentials

Credentials should, where possible, be loaded from existing secrets. The secrets may be created by
a Helm apply, by a K8s secrets operator, or some other method. The `values.yaml` configuration is
much simpler and there's no confusion about where to set a password (eg, global vs chart values).

Sub-charts should auto-generate credentials if un-specified in values. Credentials should be stored
in predictably named Secrets.

#### Credential Lookup Order:

1. `global.DEPENDENCY.SECRETNAME`
1. `DEPENDENCYSecretName`/`DEPENDENCYSecretKey`
1. (default) Kubernetes Secret, named `{{ DEPENDENCY }}-secret`. Keys are dependency-specific,
    usually `{{ DEPENDENCY }}-username` and `{{ DEPENDENCY }}-password`.

#### Generating Credentials

_Don't be clever_

I started out trying a clever method of storing off credentials and looking them up when generating
the manifests. This probably works fine for folks manually installing via Helm, but for most use
cases the process will be handed off to another tool (eg, ArgoCD). It was a headache.

The tactic I have chosen is instead to put any credential generation behind a flag that is default
false (eg, `createCouchbaseSecret`). On initial installation, simply pass
`--set couchbase.createCouchbaseSecret` so the credentials are configured. These secrets are
annotated `helm.sh/resource-policy: keep`. This ensures that Helm will _create_ but not _delete_
the secret. This does orphan the resource, but _that's showbiz_ I guess.

# Labels & Annotations

Ok, first: what's the difference? These are both key:value maps in the `metadata` section.

> **Labels** are used to query resources. These provide _identity_ to Kubernetes resources.
>
> **Annotations** YOLO <-- it's basically free-form do-what-you-need. Often used for providing
> configuration to tools that may operate on the resource (like create DNS for an Ingress).


## Required

At _minimum_, include the `common.labels` template into _each_ resource. These are standard labels
that most tools expect to have available. Read
[this](https://blog.kubecost.com/blog/kubernetes-labels/) to get an in-depth look at the reasoning
behind this.

## Common Labels

- `helm.sh/chart`: Chart name & Version
- `app.kubernetes.io/managed-by`: Service submitting resources to K8s API (eg, Helm, ArgoCD)
- `app.kubernetes.io/version`: The _application_ version deployed (eg, `stable`,
  `edge-1.xx.x-rc1`)
- `app.kubernetes.io/name`: Application _name_ (eg, `plextrac`, `redis`)
- `app.kubernetes.io/instance`: Unique instance name (eg, `plextrac-dev`, `qa-edge-plextrac`,
  `customer-$NAME-plextrac`)

## Extra Labels

These might be incorporated into the chart, especially if we add an operator to manage the
installation. For now these are examples that can be passed in under `global.extraLabels` or
`.extraLabels` as appropriate. Duplicate keys will be merged with local values taking precedence
over global.

- `app.plextrac.com/`
    - `upgrade-strategy`: `edge`/`stable`/`manual`/tag prefix?
        - This could be used by an update controller to auto-update, similar to the `argo-image-updater`
        project. Useful for self-hosted environments.
    - `environment`: `staging`, `production`, etc
    - `region`: `nyc3`, `us-west-1`, etc
    - `owner`: who maintains this instance?
    - `audience`: who uses this instance?
    - `instance-type`: trial/demo/private/shared


Resources
: https://blog.kubecost.com/blog/kubernetes-labels/