{{/*
    Generate an image name from parameters
    Usage:

        {{ include "common.images.image" (dict "local" .Values.image "global" $)}}
*/}}
{{- define "common.images.image" -}}
  {{/* Set local variables that we update later if necessary */}}
  {{- $registryName := .local.registry -}}
  {{- $repositoryName := .local.repository -}}
  {{- $tag := .local.tag | default .global.Chart.AppVersion | toString -}}

  {{- with .global.Values -}}
    {{- if .global -}}
      {{- $registryName = .global.imageRegistry -}}
    {{- end -}}
  {{- end -}}

  {{- if $registryName -}}
    {{- printf "%s/%s:%s" $registryName $repositoryName $tag -}}
  {{- else -}}
    {{- printf "%s:%s" $repositoryName $tag -}}
  {{- end -}}
{{- end -}}

{{/*
    Parses imagePullSecrets for manually specified credentials
    Provides 2 templates:
      - common.images.pullSecrets
      - common.images.registryCredentials
*/}}

{{- define "common.images.pullSecrets" }}
{{- $managedSecrets := concat .Values.registryCredentials .Values.global.registryCredentials | uniq }}
{{- $pullSecrets := concat .Values.imagePullSecrets .Values.global.imagePullSecrets | uniq }}
  {{- with $pullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
  {{- end -}}
  {{- range $managedSecrets }}
  - name: {{ printf "%s-%s-secret" (.registry | replace "." "-") .username }}
  {{- end }}

{{- end }}


{{- define "common.images.registryCredentials" }}
{{- $managedSecrets := concat .Values.registryCredentials .Values.global.registryCredentials | uniq }}
{{- $rootContext := $ }}
{{- range $managedSecrets }}
---
apiVersion: v1
kind: Secret
metadata:
  name: {{ printf "%s-%s-secret" (.registry | replace "." "-") .username }}
  labels:
    {{- include "common.labels" $rootContext | nindent 4 }}
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: {{ printf "{\"auths\":{\"%s\":{\"username\":\"%s\",\"password\":\"%s\",\"email\":\"%s\",\"auth\":\"%s\"}}}" .registry .username .password .email (printf "%s:%s" .username .password | b64enc) | b64enc }}
{{- end }}
{{- end }}
