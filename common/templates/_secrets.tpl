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