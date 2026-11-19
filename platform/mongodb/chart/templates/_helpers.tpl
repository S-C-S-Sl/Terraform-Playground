{{- define "mongodb.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mongodb.headless" -}}
{{ include "mongodb.fullname" . }}-headless
{{- end -}}

{{/* Fester DNS-Name des (einzigen) Mitglieds, wie er in der Replica-Set-Konfiguration steht */}}
{{- define "mongodb.memberHost" -}}
{{ include "mongodb.fullname" . }}-0.{{ include "mongodb.headless" . }}.{{ .Release.Namespace }}.svc.cluster.local:27017
{{- end -}}

{{- define "mongodb.selectorLabels" -}}
app.kubernetes.io/name: mongodb
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "mongodb.labels" -}}
{{ include "mongodb.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "mongodb.image" -}}
{{ .Values.image.repository }}:{{ .Values.image.tag }}
{{- end -}}
