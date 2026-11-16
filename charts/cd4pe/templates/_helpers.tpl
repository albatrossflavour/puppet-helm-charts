{{/*
Expand the name of the chart.
*/}}
{{- define "cd4pe.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name. Component names are appended to
this, so it is cut shorter than the usual 63 characters.
*/}}
{{- define "cd4pe.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 40 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 40 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 40 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Chart name and version as used by the chart label.
*/}}
{{- define "cd4pe.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "cd4pe.labels" -}}
helm.sh/chart: {{ include "cd4pe.chart" . }}
{{ include "cd4pe.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels shared by every component.
*/}}
{{- define "cd4pe.selectorLabels" -}}
app.kubernetes.io/name: {{ include "cd4pe.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Labels for one component.
Usage: include "cd4pe.componentLabels" (dict "root" . "component" "ui")
*/}}
{{- define "cd4pe.componentLabels" -}}
{{ include "cd4pe.labels" .root }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Selector labels for one component.
Usage: include "cd4pe.componentSelectorLabels" (dict "root" . "component" "ui")
*/}}
{{- define "cd4pe.componentSelectorLabels" -}}
{{ include "cd4pe.selectorLabels" .root }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Name of the service account to use.
*/}}
{{- define "cd4pe.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "cd4pe.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Name of the Secret holding the passwords and keys.
*/}}
{{- define "cd4pe.secretName" -}}
{{- default (include "cd4pe.fullname" .) .Values.auth.existingSecret }}
{{- end }}

{{/*
Image reference for one component. A digest wins over the tag.
Usage: include "cd4pe.image" (dict "root" . "image" .Values.ui.image)
*/}}
{{- define "cd4pe.image" -}}
{{- $repo := printf "%s/%s" .root.Values.image.registry .image.repository }}
{{- if .image.digest }}
{{- printf "%s@%s" $repo .image.digest }}
{{- else }}
{{- printf "%s:%s" $repo (default .root.Chart.AppVersion .root.Values.image.tag) }}
{{- end }}
{{- end }}

{{/*
Pod spec fields every pod shares.

automountServiceAccountToken is false on purpose and is not a value. If
/var/run/secrets/kubernetes.io/serviceaccount exists, the 5.18.0 backend takes
its old 4.x path and tries to keep the query service token in a Kubernetes
Secret named by CD4PE_QUERY_SERVICE_TOKEN_SECRET_NAME, instead of writing the
file that cd4peadm installs use. The query service then never starts.

enableServiceLinks is false because a Service called <release>-postgres makes
the kubelet inject CD4PE_POSTGRES_PORT and similar into every pod, and the
backend reads CD4PE_* for its own configuration.
*/}}
{{- define "cd4pe.podCommon" -}}
serviceAccountName: {{ include "cd4pe.serviceAccountName" . }}
automountServiceAccountToken: false
enableServiceLinks: false
{{- with .Values.global.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.podSecurityContext }}
securityContext:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/*
Scheduling fields for one component.
Usage: include "cd4pe.scheduling" .Values.ui
*/}}
{{- define "cd4pe.scheduling" -}}
{{- with .nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/*
Annotation that keeps a resource when the release is uninstalled.
*/}}
{{- define "cd4pe.keepAnnotations" -}}
{{- if .Values.keepOnUninstall }}
helm.sh/resource-policy: keep
{{- end }}
{{- end }}

{{/*
Environment shared by pipelinesinfra and the root credentials job.
From cd4peadm 5.18.0 templates/cd4pe_env.epp.
*/}}
{{- define "cd4pe.backendEnv" -}}
- name: CD4PE_BACKEND_SERVICE_ENDPOINT
  value: {{ printf "https://%s" (required "backendHostname is required" .Values.backendHostname) | quote }}
- name: CD4PE_WEBHOOK_URL
  value: {{ printf "https://%s" .Values.backendHostname | quote }}
- name: CD4PE_WEB_UI_ENDPOINT
  value: {{ printf "https://%s" (required "hostname is required" .Values.hostname) | quote }}
- name: LOG4J_PATH
  value: /opt/pfi/log4j2.properties
- name: CD4PE_VERSION
  value: {{ .Chart.AppVersion | quote }}
- name: ENABLE_SSL_WEBHOOKS
  value: "false"
- name: CD4PE_STAGE
  value: beta
- name: CD4PE_STORAGE_PROVIDER
  value: DISK
- name: CD4PE_STORAGE_BUCKET
  value: cd4pe
- name: CD4PE_ROUTE_PREFIX
  value: /cd4pe
- name: CD4PE_SECURE_COOKIE
  value: "false"
- name: CD4PE_EULA_ACCEPTED
  value: "true"
- name: OTEL_TRACES_EXPORTER
  value: none
- name: OTEL_METRICS_EXPORTER
  value: none
# Not in cd4peadm. Without it the agent retries a log export to
# localhost:4318 for ever and fills the pod log.
- name: OTEL_LOGS_EXPORTER
  value: none
- name: OTEL_EXPORTER_JAEGER_ENDPOINT
  value: http://jaeger-aio:14250
- name: OTEL_EXPORTER_JAEGER_SERVICE_NAME
  value: cd4pe
- name: OTEL_RESOURCE_ATTRIBUTES
  value: service.name=cd4pe,service.version=dev
- name: CD4PE_QUERY_SERVICE_TOKEN_PATH
  value: /etc/puppetlabs/cd4pe/query-service/cd4pe-query-service-token
{{- end }}

{{/*
Init container that writes pfi-config.json from the Secret into a memory
volume. cd4peadm writes the same file to /etc/puppetlabs/cd4pe on the host.
The passwords must not contain a double quote or a backslash.
*/}}
{{- define "cd4pe.pfiConfigInit" -}}
- name: render-pfi-config
  image: {{ printf "%s:%s" .Values.initImage.repository .Values.initImage.tag | quote }}
  imagePullPolicy: {{ .Values.image.pullPolicy }}
  command:
    - sh
    - -c
    - |
      set -eu
      umask 077
      cat > /config/pfi-config.json <<JSON
      {
        "dbEndpoint": "postgres://{{ include "cd4pe.fullname" . }}-postgres:5432/cd4pe",
        "dbUser": "cd4pe",
        "dbPass": "${CD4PE_DB_PASSWORD}",
        "dbMaxPoolSize": "2",
        "backendPort": 8000,
        "secretKey": "${CD4PE_SECRET_KEY}"
      }
      JSON
  env:
    - name: CD4PE_DB_PASSWORD
      valueFrom:
        secretKeyRef:
          name: {{ include "cd4pe.secretName" . }}
          key: cd4pe-db-password
    - name: CD4PE_SECRET_KEY
      valueFrom:
        secretKeyRef:
          name: {{ include "cd4pe.secretName" . }}
          key: secret-key
  securityContext:
    allowPrivilegeEscalation: false
    capabilities:
      drop: ["ALL"]
  resources:
    requests:
      cpu: 10m
      memory: 16Mi
    limits:
      memory: 64Mi
  volumeMounts:
    - name: pfi-config
      mountPath: /config
{{- end }}
