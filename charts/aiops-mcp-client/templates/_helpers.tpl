{{- define "aiops-mcp-client.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{ include "aiops-mcp-client.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "aiops-mcp-client.selectorLabels" -}}
app.kubernetes.io/name: aiops-mcp-client
app.kubernetes.io/instance: {{ .Release.Name }}
app: aiops-mcp-client
{{- end }}
