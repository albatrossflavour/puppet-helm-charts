{{/*
Expand the name of the chart.
*/}}
{{- define "scm.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name. Component names are appended to
this, so it is cut shorter than the usual 63 characters.
*/}}
{{- define "scm.fullname" -}}
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
{{- define "scm.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "scm.labels" -}}
helm.sh/chart: {{ include "scm.chart" . }}
{{ include "scm.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels shared by every component.
*/}}
{{- define "scm.selectorLabels" -}}
app.kubernetes.io/name: {{ include "scm.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Labels for one component.
Usage: include "scm.componentLabels" (dict "root" . "component" "ui")
*/}}
{{- define "scm.componentLabels" -}}
{{ include "scm.labels" .root }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Selector labels for one component.
Usage: include "scm.componentSelectorLabels" (dict "root" . "component" "ui")
*/}}
{{- define "scm.componentSelectorLabels" -}}
{{ include "scm.selectorLabels" .root }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Name of the service account to use.
*/}}
{{- define "scm.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "scm.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Name of the Secret holding the passwords and keys.
*/}}
{{- define "scm.secretName" -}}
{{- default (include "scm.fullname" .) .Values.auth.existingSecret }}
{{- end }}

{{/*
Image reference for one component. A digest wins over the tag, and product
tags are "v" plus the chart appVersion unless image.tag is set.
Usage: include "scm.image" (dict "root" . "image" .Values.ui.image)
*/}}
{{- define "scm.image" -}}
{{- $repo := printf "%s/%s" .root.Values.image.registry .image.repository }}
{{- if .image.digest }}
{{- printf "%s@%s" $repo .image.digest }}
{{- else }}
{{- printf "%s:%s" $repo (default (printf "v%s" .root.Chart.AppVersion) .root.Values.image.tag) }}
{{- end }}
{{- end }}

{{/*
The comply-assessor image, tagged with the assessor version.
*/}}
{{- define "scm.assessorImage" -}}
{{- $repo := printf "%s/%s" .Values.image.registry .Values.assessor.image.repository }}
{{- if .Values.assessor.image.digest }}
{{- printf "%s@%s" $repo .Values.assessor.image.digest }}
{{- else }}
{{- printf "%s:%s" $repo .Values.assessor.version }}
{{- end }}
{{- end }}

{{/*
Pod spec fields every pod shares.

Nothing in SCM calls the Kubernetes API, so no service account token is
mounted. enableServiceLinks is false to keep the kubelet's <SERVICE>_PORT
variables out of containers that read their configuration from the environment.
*/}}
{{- define "scm.podCommon" -}}
serviceAccountName: {{ include "scm.serviceAccountName" . }}
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
Usage: include "scm.scheduling" .Values.ui
*/}}
{{- define "scm.scheduling" -}}
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
{{- define "scm.keepAnnotations" -}}
{{- if .Values.keepOnUninstall }}
helm.sh/resource-policy: keep
{{- end }}
{{- end }}

{{/*
One environment variable read from the Secret.
Usage: include "scm.secretEnv" (dict "root" . "name" "DB_PASSWORD" "key" "comply-db-password")
*/}}
{{- define "scm.secretEnv" -}}
- name: {{ .name }}
  valueFrom:
    secretKeyRef:
      name: {{ include "scm.secretName" .root }}
      key: {{ .key }}
{{- end }}

{{/*
The environment complyadm gives a container, from files/module-env.yaml. That
file is generated from the module by port/generate_files.py, so a variable a
module release adds, drops or changes arrives here with no edit. It leaves out
the variables a template sets itself.
Usage: include "scm.moduleEnv" (dict "root" . "container" "comply_scarpy")
*/}}
{{- define "scm.moduleEnv" -}}
{{- $all := .root.Files.Get "files/module-env.yaml" | fromYaml -}}
{{- range $name, $value := (index $all .container) }}
- name: {{ $name }}
  value: {{ $value | toString | replace "@@FULLNAME@@" (include "scm.fullname" $.root) | replace "@@HOSTNAME@@" $.root.Values.hostname | replace "@@VERSION@@" $.root.Chart.AppVersion | quote }}
{{- end }}
{{- end }}

{{/*
The variables scarpy and scarpy-init both take from chart values or the Secret.
*/}}
{{- define "scm.scarpEnv" -}}
- name: SCARP_DEBUG_LEVEL
  value: {{ .Values.logLevel | quote }}
- name: ASSESSOR_VERSION
  value: {{ .Values.assessor.version | quote }}
{{ include "scm.secretEnv" (dict "root" . "name" "DB_PASSWORD" "key" "comply-db-password") }}
{{ include "scm.secretEnv" (dict "root" . "name" "DB_ENCRYPTION_KEY" "key" "db-encryption-key") }}
{{- end }}

{{/*
Volume holding the PE certificate and CA: the user's Secret, or the empty
placeholder files complyadm ships for an install with no PE mTLS configured.
*/}}
{{- define "scm.peCertsVolume" -}}
- name: pe-certs
  {{- if .Values.pe.existingSecret }}
  secret:
    secretName: {{ .Values.pe.existingSecret }}
  {{- else }}
  configMap:
    name: {{ include "scm.fullname" . }}-pe-certs-placeholder
  {{- end }}
{{- end }}

{{/*
Security context and resources for the small init containers.
*/}}
{{- define "scm.initContainerDefaults" -}}
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
{{- end }}
