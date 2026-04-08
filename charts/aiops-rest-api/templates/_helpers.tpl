{{- define "aiops-rest-api.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "aiops-rest-api.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "aiops-rest-api.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{ include "aiops-rest-api.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "aiops-rest-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "aiops-rest-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app: aiops-rest-api
{{- end }}

{{/* ── Elasticsearch env vars (init container + main container) ── */}}
{{- define "aiops-rest-api.esEnvVars" -}}
- name: DATA_WAREHOUSE_USER
  value: "elastic"
- name: DATA_WAREHOUSE_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.esSecretName }}
      key: elastic
- name: DATA_WAREHOUSE_SCHEMA
  value: {{ .Values.config.elasticsearch.schema | quote }}
- name: DATA_WAREHOUSE_HOSTS
  value: {{ .Values.config.elasticsearch.hosts | quote }}
- name: DATA_WAREHOUSE_PORT
  value: {{ .Values.config.elasticsearch.port | quote }}
{{- end }}

{{/* ── App secret env vars (init container + main container) ── */}}
{{- define "aiops-rest-api.appSecretEnvVars" -}}
- name: SEAL_TOKEN
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.name }}
      key: seal-token
- name: CORE_SECURITY_TOKEN
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.name }}
      key: api-token
- name: MONITORING_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.name }}
      key: monitoring-api-key
- name: MONITORING_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.name }}
      key: monitoring-secret
- name: ARCANNA_RAG_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.name }}
      key: rag-api-key
{{- end }}