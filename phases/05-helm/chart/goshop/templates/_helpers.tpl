{{/*
Common labels gắn cho mọi resource.
Helm best practice: dùng "app.kubernetes.io/*" labels chuẩn.
*/}}
{{- define "goshop.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end }}

{{/*
Selector labels = subset của common labels.
Phải IMMUTABLE — đổi sau khi deploy là Helm upgrade fail.
*/}}
{{- define "goshop.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Tên đầy đủ resource: <release>-<chart>, gắn ngắn lại nếu vượt 63 ký tự (k8s limit).
*/}}
{{- define "goshop.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end }}
