{{/* Name aller Ressourcen = Release-Name (z. B. "rabbitmq") */}}
{{- define "rabbitmq.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "rabbitmq.selectorLabels" -}}
app.kubernetes.io/name: rabbitmq
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "rabbitmq.labels" -}}
{{ include "rabbitmq.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}
