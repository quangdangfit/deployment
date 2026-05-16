{{/* Common labels */}}
{{- define "goshop.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end }}

{{/* Selector labels — IMMUTABLE */}}
{{- define "goshop.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* Full names cho từng component */}}
{{- define "goshop.api.fullname" -}}
{{- printf "%s-api" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{- define "goshop.web.fullname" -}}
{{- printf "%s-web" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{/* Selector cho từng component (label kèm app.kubernetes.io/component) */}}
{{- define "goshop.api.selectorLabels" -}}
{{ include "goshop.selectorLabels" . }}
app.kubernetes.io/component: api
{{- end }}

{{- define "goshop.web.selectorLabels" -}}
{{ include "goshop.selectorLabels" . }}
app.kubernetes.io/component: web
{{- end }}
