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

## 
