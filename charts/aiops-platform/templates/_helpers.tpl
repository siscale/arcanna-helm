{{- define "aiops-platform.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{ include "aiops-platform.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "aiops-platform.selectorLabels" -}}
app.kubernetes.io/name: aiops-platform
app.kubernetes.io/instance: {{ .Release.Name }}
app: aiops-platform
{{- end }}

{{- define "aiops-platform.proxyHeaders" -}}
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Host $http_host;
proxy_buffer_size 256k;
proxy_buffers 8 512k;
proxy_busy_buffers_size 512k;
{{- end }}
