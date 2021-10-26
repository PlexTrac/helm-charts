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
