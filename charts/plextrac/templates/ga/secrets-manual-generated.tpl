{{- if and (eq .Values.secrets.mode "manual") .Values.secrets.manual.createKubernetesSecrets }}
{{- $namespace := include "plextrac.namespace" . }}
{{- $appSecretName := default "application-secrets" .Values.secrets.manual.generatedSecrets.application.name }}
{{- $sharedSecretName := default "shared-secrets" .Values.secrets.manual.generatedSecrets.shared.name }}
{{- $appStringData := merge (dict) (default (dict) .Values.secrets.manual.generatedSecrets.application.stringData) }}
{{- $appData := merge (dict) (default (dict) .Values.secrets.manual.generatedSecrets.application.data) }}
{{- $sharedStringData := merge (dict) (default (dict) .Values.secrets.manual.generatedSecrets.shared.stringData) }}
{{- $sharedData := merge (dict) (default (dict) .Values.secrets.manual.generatedSecrets.shared.data) }}
{{- $existingAppSecret := lookup "v1" "Secret" $namespace $appSecretName }}
{{- $existingSharedSecret := lookup "v1" "Secret" $namespace $sharedSecretName }}
{{- $existingAppData := dict }}
{{- $existingSharedData := dict }}
{{- if and $existingAppSecret $existingAppSecret.data }}
{{- $existingAppData = $existingAppSecret.data }}
{{- end }}
{{- if and $existingSharedSecret $existingSharedSecret.data }}
{{- $existingSharedData = $existingSharedSecret.data }}
{{- end }}
{{- range $idx, $key := .Values.secrets.manual.requiredKeys.application }}
{{- if not (or (hasKey $appStringData $key) (hasKey $appData $key)) }}
{{- if hasKey $existingAppData $key }}
{{- $_ := set $appData $key (get $existingAppData $key) }}
{{- else }}
{{- $_ := set $appStringData $key (include "plextrac.manualSecretDefaultValue" (dict "key" $key)) }}
{{- end }}
{{- end }}
{{- end }}
{{- range $idx, $key := .Values.secrets.manual.requiredKeys.shared }}
{{- if not (or (hasKey $sharedStringData $key) (hasKey $sharedData $key)) }}
{{- if hasKey $existingSharedData $key }}
{{- $_ := set $sharedData $key (get $existingSharedData $key) }}
{{- else }}
{{- $_ := set $sharedStringData $key (include "plextrac.manualSecretDefaultValue" (dict "key" $key)) }}
{{- end }}
{{- end }}
{{- end }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ $appSecretName }}
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
  name: {{ $sharedSecretName }}
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
  name: {{ default "internal-registry-creds" .Values.secrets.manual.generatedSecrets.registryCredentials.name }}
  namespace: {{ $namespace }}
type: kubernetes.io/dockerconfigjson
stringData:
  .dockerconfigjson: {{ default "{}" .Values.secrets.manual.generatedSecrets.registryCredentials.dockerconfigjson | quote }}
{{- end }}
{{- if .Values.secrets.manual.generatedSecrets.tls.enabled }}
---
apiVersion: v1
kind: Secret
metadata:
  name: {{ default "internal-tls" .Values.secrets.manual.generatedSecrets.tls.name }}
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
