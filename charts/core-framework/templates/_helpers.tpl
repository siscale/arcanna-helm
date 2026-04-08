{{- define "core-framework.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "core-framework.fullname" -}}
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

{{- define "core-framework.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{ include "core-framework.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "core-framework.selectorLabels" -}}
app.kubernetes.io/name: {{ include "core-framework.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app: core-framework
{{- end }}

{{/* ── Secret env vars injected into main container ── */}}
{{- define "core-framework.secretEnvVars" -}}
# Elasticsearch
- name: DATA_WAREHOUSE_USER
  value: "elastic"
- name: DATA_WAREHOUSE_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.esSecretName }}
      key: elastic
- name: DATA_WAREHOUSE_HOSTS
  value: {{ .Values.config.elasticsearch.hosts | quote }}
- name: DATA_WAREHOUSE_PORT
  value: {{ .Values.config.elasticsearch.port | quote }}
- name: DATA_WAREHOUSE_SCHEMA
  value: {{ .Values.config.elasticsearch.schema | quote }}
# Postgres
- name: POSTGRES_USER
  valueFrom:
    secretKeyRef:
      name: {{ .Values.postgresSecretName }}
      key: user
- name: POSTGRES_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.postgresSecretName }}
      key: password
- name: POSTGRES_DB
  valueFrom:
    secretKeyRef:
      name: {{ .Values.postgresSecretName }}
      key: database
# Redis
- name: REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.redisSecretName }}
      key: password
# App secrets
- name: SEAL_TOKEN
  valueFrom:
    secretKeyRef:
      name: {{ .Values.appSecretName }}
      key: seal-token
- name: CORE_SECURITY_TOKEN
  valueFrom:
    secretKeyRef:
      name: {{ .Values.appSecretName }}
      key: api-token
- name: SESSION_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ .Values.appSecretName }}
      key: api-token
- name: MONITORING_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.appSecretName }}
      key: monitoring-api-key
- name: MONITORING_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ .Values.appSecretName }}
      key: monitoring-secret
- name: ARCANNA_RAG_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.appSecretName }}
      key: rag-api-key
{{- end }}
