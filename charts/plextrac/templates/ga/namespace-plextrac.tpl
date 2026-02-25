{{- include "plextrac.validateSecretMode" . }}
{{- if .Values.global.createNamespace }}
apiVersion: v1
kind: Namespace
metadata:
  annotations:
    argocd.argoproj.io/sync-options: Delete=false
  labels:
    app.kubernetes.io/version: 2.23.4
  name: {{ include "plextrac.namespace" . }}
{{- end }}
