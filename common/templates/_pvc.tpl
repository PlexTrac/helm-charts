{{/* Generic template for PVC */}}
{{- define "common.storage.pvc" }}

{{- $root := . -}}
{{- with .Values.volumes }}
  {{- range $name, $spec := . }}
    {{- if not $spec.existing }}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ $.Chart.Name }}-{{ $name }}
  labels:
    {{- include "common.labels" $root | nindent 4 }}
spec:
  accessModes:
    {{- default (list "ReadWriteOnce") $spec.accessModes | toYaml | nindent 4 }}
  {{- with $spec.storageClassName }}
  storageClassName: {{ . | default "" | quote}}
  {{- end }}
  resources:
    requests:
      storage: {{ $spec.storage | default "1Gi" }}
    {{- end }}
  {{- end }}
{{- end }}
{{- end }}
