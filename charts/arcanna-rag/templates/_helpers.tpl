{{- define "arcanna-rag.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{ include "arcanna-rag.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "arcanna-rag.selectorLabels" -}}
app.kubernetes.io/name: arcanna-rag
app.kubernetes.io/instance: {{ .Release.Name }}
app: arcanna-rag
{{- end }}
