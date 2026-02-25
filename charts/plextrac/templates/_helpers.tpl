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
{{- default "plextrac-com-tls" .Values.global.ingress.tlsSecretName -}}
{{- end -}}

{{- define "plextrac.validateSecretMode" -}}
{{- if not (has .Values.secrets.mode (list "externalSecrets" "csi" "manual")) -}}
{{- fail "values.secrets.mode must be one of: externalSecrets, csi, manual" -}}
{{- end -}}
{{- end -}}

{{- define "plextrac.manualSecretDefaultValue" -}}
{{- $key := .key -}}
{{- if eq $key "ADMIN_EMAIL" -}}
{{- "" -}}
{{- else if eq $key "API_INTEGRATION_AUTH_CONFIG_NOTIFICATION_SERVICE" -}}
{{- "{}" -}}
{{- else if eq $key "pt-load-bq-sa-svc-acct-creds.json" -}}
{{- "{}" -}}
{{- else -}}
{{- randAlphaNum 40 -}}
{{- end -}}
{{- end -}}
