{{- if and (eq .Values.secrets.mode "manual") .Values.secrets.manual.createKubernetesSecrets }}
{{- $namespace := include "plextrac.namespace" . }}
{{- $appStringData := default (dict) .Values.secrets.manual.generatedSecrets.application.stringData }}
{{- $appData := default (dict) .Values.secrets.manual.generatedSecrets.application.data }}
{{- $sharedStringData := default (dict) .Values.secrets.manual.generatedSecrets.shared.stringData }}
{{- $sharedData := default (dict) .Values.secrets.manual.generatedSecrets.shared.data }}
{{- range $idx, $key := .Values.secrets.manual.requiredKeys.application }}
{{- if not (or (hasKey $appStringData $key) (hasKey $appData $key)) }}
{{- fail (printf "Missing required application secret key for manual mode: %s (set secrets.manual.generatedSecrets.application.stringData.%s or .data.%s)" $key $key $key) }}
{{- end }}
{{- end }}
{{- range $idx, $key := .Values.secrets.manual.requiredKeys.shared }}
{{- if not (or (hasKey $sharedStringData $key) (hasKey $sharedData $key)) }}
{{- fail (printf "Missing required shared secret key for manual mode: %s (set secrets.manual.generatedSecrets.shared.stringData.%s or .data.%s)" $key $key $key) }}
{{- end }}
{{- end }}
{{- if not .Values.secrets.manual.generatedSecrets.registryCredentials.enabled }}
{{- fail "secrets.manual.generatedSecrets.registryCredentials.enabled must be true when manual auto-create is enabled; GA workloads require regcred-dorf" }}
{{- end }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ default "application-secrets" .Values.secrets.manual.generatedSecrets.application.name }}
  namespace: {{ $namespace }}
type: Opaque
{{- with $appData }}
data:
{{- toYaml . | nindent 2 }}
{{- end }}
{{- with $appStringData }}
stringData:
{{- toYaml . | nindent 2 }}
{{- end }}
---
apiVersion: v1
kind: Secret
metadata:
  name: {{ default "shared-secrets" .Values.secrets.manual.generatedSecrets.shared.name }}
  namespace: {{ $namespace }}
type: Opaque
{{- with $sharedData }}
data:
{{- toYaml . | nindent 2 }}
{{- end }}
{{- with $sharedStringData }}
stringData:
{{- toYaml . | nindent 2 }}
{{- end }}
{{- if .Values.secrets.manual.generatedSecrets.registryCredentials.enabled }}
---
apiVersion: v1
kind: Secret
metadata:
  name: {{ default "regcred-dorf" .Values.secrets.manual.generatedSecrets.registryCredentials.name }}
  namespace: {{ $namespace }}
type: kubernetes.io/dockerconfigjson
stringData:
  .dockerconfigjson: {{ required "secrets.manual.generatedSecrets.registryCredentials.dockerconfigjson is required when registryCredentials.enabled=true" .Values.secrets.manual.generatedSecrets.registryCredentials.dockerconfigjson | quote }}
{{- end }}
{{- if .Values.secrets.manual.generatedSecrets.tls.enabled }}
---
apiVersion: v1
kind: Secret
metadata:
  name: {{ default "plextrac-com-tls" .Values.secrets.manual.generatedSecrets.tls.name }}
  namespace: {{ $namespace }}
type: kubernetes.io/tls
stringData:
  tls.crt: {{ required "secrets.manual.generatedSecrets.tls.crt is required when tls.enabled=true" .Values.secrets.manual.generatedSecrets.tls.crt | quote }}
  tls.key: {{ required "secrets.manual.generatedSecrets.tls.key is required when tls.enabled=true" .Values.secrets.manual.generatedSecrets.tls.key | quote }}
{{- end }}
{{- range $i, $secret := .Values.secrets.manual.generatedSecrets.additional }}
---
apiVersion: v1
kind: Secret
metadata:
  name: {{ required (printf "secrets.manual.generatedSecrets.additional[%d].name is required" $i) $secret.name }}
  namespace: {{ $namespace }}
type: {{ default "Opaque" $secret.type }}
{{- with $secret.stringData }}
stringData:
{{- toYaml . | nindent 2 }}
{{- end }}
{{- with $secret.data }}
data:
{{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}
{{- end }}
