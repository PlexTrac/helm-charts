{{/*
    Common definition for labels
*/}}
{{- define "common.labels" -}}
{{- include "common.labels.selectorLabels" . }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/managed-by: {{ .Release.Service | quote }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- include "common.labels.extraLabels" . }}
{{- end -}}


{{- define "common.labels.selectorLabels" -}}
app.kubernetes.io/name: {{ include "common.names.name" . }}
app.kubernetes.io/instance: {{ include "common.names.fullname" . }}
{{- end -}}


{{- define "common.labels.extraLabels" }}
{{- $extraLabels := merge dict .Values.global.extraLabels (default dict .Values.extraLabels) -}}
{{- range $key, $value := $extraLabels }}
{{ $key }}: {{ $value }}
{{- end -}}
{{- end -}}
