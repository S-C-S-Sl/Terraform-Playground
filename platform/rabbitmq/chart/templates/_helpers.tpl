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

{{/* Fester DNS-Name des Service, auch aus anderen Namespaces erreichbar */}}
{{- define "rabbitmq.host" -}}
{{ include "rabbitmq.fullname" . }}.{{ .Release.Namespace }}.svc.cluster.local
{{- end -}}

{{/* Passwort eines Dienstes: aus values, sonst aus dem Verwaltungs-Secret, sonst einmal pro
     Render erzeugt und am Eintrag zwischengespeichert (gleicher Wert in allen Templates). */}}
{{- define "rabbitmq.clientPassword" -}}
{{- $key := printf "client-%s-password" .client.name -}}
{{- if .client.password -}}
{{- .client.password -}}
{{- else if (get .old $key) -}}
{{- get .old $key | b64dec -}}
{{- else -}}
{{- if not (hasKey .client "_generated") -}}
{{- $_ := set .client "_generated" (randAlphaNum 24) -}}
{{- end -}}
{{- .client._generated -}}
{{- end -}}
{{- end -}}

{{/* Bestehendes Verwaltungs-Secret (Daten) oder leeres dict */}}
{{- define "rabbitmq.oldSecretData" -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace (include "rabbitmq.fullname" .) -}}
{{- if $existing }}{{ toJson $existing.data }}{{ else }}{}{{ end -}}
{{- end -}}

{{/* Dienste als "name:vhost name:vhost" für das postStart-Skript */}}
{{- define "rabbitmq.clientsList" -}}
{{- $list := list -}}
{{- range .Values.clients }}{{ $list = append $list (printf "%s:%s" .name .vhost) }}{{ end -}}
{{- join " " $list -}}
{{- end -}}
