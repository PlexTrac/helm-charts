{{- define "plextrac.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "plextrac.selectorLabels" -}}
app.kubernetes.io/name: {{ include "plextrac.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "plextrac.commonLabels" -}}
{{ include "plextrac.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: plextrac
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "plextrac.namespace" -}}
{{- default .Release.Namespace .Values.global.namespace -}}
{{- end -}}

{{- define "plextrac.ingressHost" -}}
{{- default "plextrac.example.com" .Values.global.ingress.host -}}
{{- end -}}

{{- define "plextrac.ingressTlsSecretName" -}}
{{- default "internal-tls" .Values.global.ingress.tlsSecretName -}}
{{- end -}}

{{- define "plextrac.keycloakTlsSecretName" -}}
{{- default "keycloak-tls" .Values.keycloak.tlsSecretName -}}
{{- end -}}

{{/*
Gateway API (Istio) routing, rendered when global.gateway.enabled. It can run next to the
Ingresses (global.ingress.enabled) while a cluster migrates from ingress-nginx.

"plextrac.gatewayServesHTTP" is "true" when the Istio gateway, not ingress-nginx, answers on port
80: the Ingresses are off, or both are rendered and the gateway Service is a LoadBalancer (the
cutover step of a migration). It picks the ACME HTTP-01 solver of the chart-managed Issuers,
because Let's Encrypt only reaches whichever controller holds port 80.
*/}}
{{- define "plextrac.gatewayServesHTTP" -}}
{{- $gw := .Values.global.gateway | default dict -}}
{{- if and $gw.enabled (or (not .Values.global.ingress.enabled) (eq ($gw.serviceType | default "LoadBalancer") "LoadBalancer")) -}}
true
{{- end -}}
{{- end -}}

{{/* ACME HTTP-01 solver for the chart-managed Issuers. Call with the root context. */}}
{{- define "plextrac.acmeHTTP01Solver" -}}
{{- if include "plextrac.gatewayServesHTTP" . -}}
- http01:
    gatewayHTTPRoute:
      parentRefs:
        - kind: Gateway
          name: plextrac
          namespace: {{ include "plextrac.namespace" . }}
          sectionName: http
{{- else -}}
- http01:
    ingress:
      ingressClassName: nginx
{{- end -}}
{{- end -}}

{{/*
HTTPRoute filters for what ingress-nginx did implicitly:
  - X-Real-IP: ingress-nginx sets it on every request and the API logs the client IP from it.
    Envoy has no such header, so it is set from the downstream address (an Envoy command operator;
    Istio passes it through unescaped). A literal "%" in a header value must be written "%%".
  - Strict-Transport-Security: ingress-nginx adds it to responses on TLS hosts. Browsers ignore it
    on plain-HTTP responses, so the same rule can serve both listeners.
  - Server: ingress-nginx drops the backend's Server header; Envoy passes it through
    ("Server: nginx" from plextracnginx, "Server: MinIO" on uploads).
Call as {{ include "plextrac.gatewayEdgeFilters" (dict "hsts" true) | nindent 8 }}.
*/}}
{{- define "plextrac.gatewayEdgeFilters" -}}
- type: RequestHeaderModifier
  requestHeaderModifier:
    set:
      - name: X-Real-IP
        value: "%DOWNSTREAM_REMOTE_ADDRESS_WITHOUT_PORT%"
- type: ResponseHeaderModifier
  responseHeaderModifier:
{{- if .hsts }}
    set:
      - name: Strict-Transport-Security
        value: "max-age=31536000; includeSubDomains"
{{- end }}
    remove:
      - Server
{{- end -}}

{{- define "plextrac.validateSecretMode" -}}
{{- if not (has .Values.secrets.mode (list "externalSecrets" "csi" "manual")) -}}
{{- fail "values.secrets.mode must be one of: externalSecrets, csi, manual" -}}
{{- end -}}
{{- end -}}

{{- define "plextrac.imagePullSecrets" -}}
{{- with .Values.global.imagePullSecrets }}
imagePullSecrets:
{{- toYaml . | nindent 0 }}
{{- end }}
{{- end -}}

{{/* Synqly pull secrets: union of global.imagePullSecrets and synqly.imagePullSecrets (deduped by name). */}}
{{- define "plextrac.synqly.imagePullSecrets" -}}
{{- $names := list -}}
{{- range concat (.Values.global.imagePullSecrets | default list) (.Values.synqly.imagePullSecrets | default list) -}}
{{- $names = append $names .name -}}
{{- end -}}
{{- with ($names | uniq) }}
imagePullSecrets:
{{- range . }}
- name: {{ . }}
{{- end }}
{{- end }}
{{- end -}}

{{/* Keycloak pull secrets: union of global.imagePullSecrets and keycloak.imagePullSecrets (deduped by name). */}}
{{- define "plextrac.keycloak.imagePullSecrets" -}}
{{- $names := list -}}
{{- range concat (.Values.global.imagePullSecrets | default list) (.Values.keycloak.imagePullSecrets | default list) -}}
{{- $names = append $names .name -}}
{{- end -}}
{{- with ($names | uniq) }}
imagePullSecrets:
{{- range . }}
- name: {{ . }}
{{- end }}
{{- end }}
{{- end -}}

{{/* MCP pull secrets: union of global.imagePullSecrets and mcp.imagePullSecrets (deduped by name). */}}
{{- define "plextrac.mcp.imagePullSecrets" -}}
{{- $names := list -}}
{{- range concat (.Values.global.imagePullSecrets | default list) (.Values.mcp.imagePullSecrets | default list) -}}
{{- $names = append $names .name -}}
{{- end -}}
{{- with ($names | uniq) }}
imagePullSecrets:
{{- range . }}
- name: {{ . }}
{{- end }}
{{- end }}
{{- end -}}

{{- define "plextrac.manualSecretDefaultValue" -}}
{{- $key := .key -}}
{{- if eq $key "ADMIN_EMAIL" -}}
{{- "" -}}
{{- else if eq $key "CKEDITOR_SERVER_LICENSE_KEY" -}}
{{- "" -}}
{{- else if eq $key "LAUNCH_DARKLY_SDK_KEY" -}}
{{- "" -}}
{{- else if eq $key "PENDO_API_KEY" -}}
{{- "" -}}
{{- else if eq $key "SENTRY_DSN_BACKEND" -}}
{{- "" -}}
{{- else if eq $key "CLOUD_STORAGE_ACCESS_KEY" -}}
{{- randAlphaNum 20 -}}
{{- else -}}
{{- randAlphaNum 32 -}}
{{- end -}}
{{- end -}}

{{/*
Render a component image reference: "<registry>/<repository>:<tag>".
Resolution order for the registry prefix:
  1. the component's own .registry (e.g. images.ckeditor.registry) — wins if set
  2. else global.image.registry
  3. if neither is set, the repository is used as-is (no prefix)
Call as: {{ include "plextrac.image" (dict "image" .Values.images.<component> "root" $) }}
*/}}
{{- define "plextrac.image" -}}
{{- $globalReg := "" -}}
{{- if .root.Values.global.image -}}
{{- $globalReg = .root.Values.global.image.registry | default "" -}}
{{- end -}}
{{- $reg := .image.registry | default $globalReg -}}
{{- if $reg -}}
{{- printf "%s/%s:%s" $reg .image.repository .image.tag -}}
{{- else -}}
{{- printf "%s:%s" .image.repository .image.tag -}}
{{- end -}}
{{- end -}}

{{/*
Resolve a container's imagePullPolicy.
  1. global.image.pullPolicy, if set, applies to every container (e.g. IfNotPresent for
     air-gapped installs whose images are pre-loaded into the node's container runtime)
  2. else the container's own default (pass "default"); empty means "omit the field" so
     Kubernetes applies its own default
Call as: {{ include "plextrac.imagePullPolicy" (dict "default" "Always" "root" $) }}
*/}}
{{- define "plextrac.imagePullPolicy" -}}
{{- $globalPolicy := "" -}}
{{- if .root.Values.global.image -}}
{{- $globalPolicy = .root.Values.global.image.pullPolicy | default "" -}}
{{- end -}}
{{- $globalPolicy | default .default | default "" -}}
{{- end -}}
