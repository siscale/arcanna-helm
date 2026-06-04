{{/* Common labels */}}
{{- define "admin-user.labels" -}}
app.kubernetes.io/name: admin-user
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/* Selector labels */}}
{{- define "admin-user.selectorLabels" -}}
app.kubernetes.io/name: admin-user
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
   Cluster name derived from esSecretName.
   ECK names the secret "<clusterName>-es-elastic-user" and the http service
   "<clusterName>-es-http", so we strip the suffix to recover clusterName.
*/}}
{{- define "admin-user.esClusterName" -}}
{{- $sec := required "esSecretName is required" .Values.esSecretName -}}
{{- trimSuffix "-es-elastic-user" $sec -}}
{{- end -}}

{{/* ES http service name */}}
{{- define "admin-user.esHosts" -}}
{{ include "admin-user.esClusterName" . }}-es-http
{{- end -}}

{{/*
   Elasticsearch env vars — same shape as the aiops-rest-api chart's esEnvVars
   helper. DATA_WAREHOUSE_HOSTS derived from esSecretName (no per-env duplication).
*/}}
{{- define "admin-user.esEnvVars" -}}
- name: DATA_WAREHOUSE_USER
  value: "elastic"
- name: DATA_WAREHOUSE_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.esSecretName }}
      key: elastic
- name: DATA_WAREHOUSE_SCHEMA
  value: {{ .Values.esSchema | quote }}
- name: DATA_WAREHOUSE_HOSTS
  value: {{ include "admin-user.esHosts" . | quote }}
- name: DATA_WAREHOUSE_PORT
  value: {{ .Values.esPort | quote }}
{{- end }}