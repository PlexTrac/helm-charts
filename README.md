---
# vim: set expandtab ft=markdown ts=4 sw=4 sts=4 tw=100:
title: README
description: README
---

# README

These are the helm charts used to deploy the PlexTrac application.


# QuickStart

## Pre-Requisites

- Kubernetes cluster 1.xx or higher
- ? Access to desired namespace
- Helm 3
- Registry Auth Token
- Optional: desired domain name (requires properly configured Ingress/Cert-Manager)

## Installation

**Configure Helm Repo**

```bash
helm repo add plextrac https://helm.plextrac.com/charts
```

**Customize parameters**


- Customize parameters (optional)
- Install


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

### globals

Place values here that are _shared_ between a chart and it's sub-charts. For example, a password
that should be shared between an application and it's dependency (eg, redis) should be placed in
globals following an appropriate namespacing scheme. This global config is separate from sub-chart
specific configuration.

**Example:**

```yaml
# -- Global customizations (for charts that support it)
globals:
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

In the above example, `.Values.globals.redis.password` will be used by the redis sub-chart & by
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
...
redis:
  enabled: true
  nameOverride: localcache  # would be available at `redis://localcache:6379`
```



### External Dependencies

More complex or higher load environments may merit using a separately managed dependency (eg,
swapping out Redis for Elasticache). This should be configured in the top-level `Values`, not
under the corresponding internal dependency (ie, sub-chart) configuration.

**Wrong:**

```yaml
...
redis:
  enabled: false
  host: redis-01.7abc2d.0001.usw2.cache.amazonaws.com
  port: 6379
```

**Correct:**

```yaml
---
...
redis:
  enabled: false

externalRedisHost: redis-01.7abc2d.0001.usw2.cache.amazonaws.com
externalRedisPort: 6379
```

By making these explicit via the `external` prefix, we avoid confusion and ensure configuration
parameters are obvious. _Simple is better than complex_.