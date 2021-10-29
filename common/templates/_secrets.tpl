{{/*
    Generate a secret if it doesn't exist, otherwise return from existing secret
*/}}
{{- define "common.secret.statefulSecretGenerator" -}}

{{- $existingSecret := (
      lookup "v1" (default "Secret" .kind)
                  (default "" .namespace)
                  .name).data  -}}

{{- if $existingSecret -}}
{{ index $existingSecret .key }}
{{- else -}}

{{- $secretValue := randAlphaNum (default 16 .length) -}}

{{- if (eq (default "Secret" .kind) "Secret") -}}
{{ $secretValue | b64enc }}
{{- else -}}
{{ $secretValue }}
{{- end -}}

{{- end -}}
{{- end -}}

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