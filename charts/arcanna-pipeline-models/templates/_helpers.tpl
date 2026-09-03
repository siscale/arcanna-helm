{{- define "arcanna-pipeline-models.name" -}}
arcanna-pipeline-models-{{ required "installerServer.version must be set" .Values.installerServer.version }}-{{ .Release.Revision | default 1 }}
{{- end }}

{{- define "arcanna-pipeline-models.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: arcanna-pipeline-models
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{ include "arcanna-pipeline-models.selectorLabels" . }}
{{- end }}

{{- define "arcanna-pipeline-models.selectorLabels" -}}
app: arcanna-pipeline-models
{{- end }}
