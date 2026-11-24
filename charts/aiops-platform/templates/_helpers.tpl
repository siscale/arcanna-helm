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
