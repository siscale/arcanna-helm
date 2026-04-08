{{- define "migration.name" -}}
migration-{{ .Values.phase }}
{{- end }}

{{- define "migration.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: migration
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app: migration
phase: {{ .Values.phase }}
{{- end }}

{{- define "migration.selectorLabels" -}}
app: migration
phase: {{ .Values.phase }}
{{- end }}
