{{- define "rust-kardinal.gitURL" -}}
{{- if not .Values.gitlab.url }}{{ fail "gitlab.url is required (https://<GitLab host>)" }}{{ end -}}
{{ trimSuffix "/" .Values.gitlab.url }}/{{ .Values.gitlab.username }}/{{ .Values.app }}.git
{{- end -}}
