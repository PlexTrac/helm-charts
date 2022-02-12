{{- define "legacy.CLIENT_DOMAIN_NAME" }}
  {{- if .Values.ingress.enabled -}}
    {{/* If Ingress is configured, use the host param for CLIENT_DOMAIN_NAME */}}
    {{- .Values.ingress.host }}
  {{- else if (eq .Values.service.type "LoadBalancer") -}}
    {{/* If Loadbalancer Service is configured, use the configured ipaddress:port for CLIENT_DOMAIN_NAME */}}
    {{- print (default (.Values.service).LoadBalancerIP) ":" .Values.service.port }}
  {{- else -}}
    {{/* Fall back to assuming user will port-forward to access the service */}}
    {{- print "127.0.0.1:8080" }}
  {{- end }}
{{- end }}
