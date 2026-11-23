{{- define "shop.labels" -}}
app.kubernetes.io/part-of: {{ .root.Chart.Name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .root.Chart.Name .root.Chart.Version }}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/version: {{ .svc.tag | quote }}
{{- end -}}

{{- define "shop.selectorLabels" -}}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/name: {{ .name }}
{{- end -}}

{{/* Probe-Ziel: HTTP-Pfad, wenn angegeben, sonst nur TCP auf den Port. Aufruf mit (dict "path" <pfad oder leer>) */}}
{{- define "shop.probe" -}}
{{- if .path -}}
httpGet:
  path: {{ .path }}
  port: http
{{- else -}}
tcpSocket:
  port: http
{{- end -}}
{{- end -}}
