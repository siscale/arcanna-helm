{{- define "modular-service.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{ include "modular-service.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "modular-service.selectorLabels" -}}
app.kubernetes.io/name: {{ .Values.serviceName }}
app.kubernetes.io/instance: {{ .Release.Name }}
app: {{ .Values.serviceName }}
{{- end }}

{{/* Standard env vars */}}
{{- define "modular-service.envVars" -}}
- name: MONITORING_PORT
  value: {{ .Values.port | quote }}
- name: COMPONENT_TYPE
  value: {{ .Values.componentType | quote }}
- name: DEPLOYMENT_TYPE
  value: {{ ternary "k8s-statefulset" "k8s-deployment" (eq .Values.workloadType "StatefulSet") | quote }}
- name: IMAGE_TAG
  value: {{ .Values.image.tag | quote }}
- name: POD_UID
  valueFrom:
    fieldRef:
      fieldPath: metadata.uid
{{- end }}

{{/* Secret env vars — 3 fixed secrets + 1 per-env (ES) */}}
{{- define "modular-service.secretEnvVars" -}}
- name: DATA_WAREHOUSE_USER
  value: "elastic"
- name: DATA_WAREHOUSE_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.esSecretName }}
      key: elastic
- name: DATA_WAREHOUSE_HOSTS
  value: {{ .Values.elasticsearch.hosts | quote }}
- name: DATA_WAREHOUSE_PORT
  value: {{ .Values.elasticsearch.port | quote }}
- name: DATA_WAREHOUSE_SCHEMA
  value: {{ .Values.elasticsearch.schema | quote }}
- name: POSTGRES_USER
  valueFrom:
    secretKeyRef:
      name: postgres-credentials
      key: user
- name: POSTGRES_PASSWORD
  valueFrom:
    secretKeyRef:
      name: postgres-credentials
      key: password
- name: POSTGRES_DB
  valueFrom:
    secretKeyRef:
      name: postgres-credentials
      key: database
- name: REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: redis-credentials
      key: password
- name: SEAL_TOKEN
  valueFrom:
    secretKeyRef:
      name: arcanna-app-credentials
      key: seal-token
- name: CORE_SECURITY_TOKEN
  valueFrom:
    secretKeyRef:
      name: arcanna-app-credentials
      key: api-token
- name: SESSION_SECRET
  valueFrom:
    secretKeyRef:
      name: arcanna-app-credentials
      key: api-token
- name: MONITORING_API_KEY
  valueFrom:
    secretKeyRef:
      name: arcanna-app-credentials
      key: monitoring-api-key
- name: MONITORING_SECRET
  valueFrom:
    secretKeyRef:
      name: arcanna-app-credentials
      key: monitoring-secret
- name: ARCANNA_RAG_API_KEY
  valueFrom:
    secretKeyRef:
      name: arcanna-app-credentials
      key: rag-api-key
{{- end }}
