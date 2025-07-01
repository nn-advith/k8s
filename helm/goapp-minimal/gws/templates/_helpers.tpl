{{- define "go-webserver.name" -}}
gows
{{- end}}

{{- define "go-webserver.fullname" -}}
{{ .Release.Name }}
{{- end}}

