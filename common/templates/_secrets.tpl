{{/*
    Set the desired environment variable in a container from
    possible Values or Secrets.

    Usage: {{ include "common.secret.fromValueOrSecret" dict(
                "name" "DEST_NAME"
                "rootContext" .

    )}}
*/}}
{{- define "common.secret.fromValueOrSecret" -}}

{{- $secretValue := (
  pluck .key .rootContext.Values.global .rootContext.Values | first
) -}}

{{- if not $secretValue -}}
valueFrom:
  secretKeyRef:
    name: {{ .secret }}
    key: {{ .secretKey }}
{{- else -}}
value: {{ $secretValue }}
{{- end -}}
{{- end -}}