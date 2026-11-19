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

{{/* Passwort eines Dienstes: aus values, sonst aus dem Verwaltungs-Secret, sonst neu.
     Achtung: randAlphaNum liefert bei jedem Aufruf einen neuen Wert. Beim allerersten Install
     erzeugt der Helper deshalb in secret.yaml und client-secrets.yaml verschiedene Werte -
     verhindert durch das Zwischenspeichern in .Values (siehe unten). */}}
{{- define "mongodb.clientPassword" -}}
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

{{/* Dienste als JSON für den Init-Job (ohne Passwörter) */}}
{{- define "mongodb.clientsJson" -}}
{{- $list := list -}}
{{- range .Values.clients }}{{ $list = append $list (dict "name" .name "database" .database) }}{{ end -}}
{{- toJson $list -}}
{{- end -}}
