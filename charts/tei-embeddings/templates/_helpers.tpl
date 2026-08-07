{{- define "tei-embeddings.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{ include "tei-embeddings.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "tei-embeddings.selectorLabels" -}}
app.kubernetes.io/name: tei-embeddings
app.kubernetes.io/instance: {{ .Release.Name }}
app: tei-embeddings
{{- end }}
