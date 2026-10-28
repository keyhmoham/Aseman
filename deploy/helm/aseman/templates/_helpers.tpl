{{- define "aseman.name" -}}{{ default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}{{- end -}}
{{- define "aseman.fullname" -}}
{{- if .Values.fullnameOverride -}}{{ .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else -}}{{ printf "%s-%s" .Release.Name (include "aseman.name" .) | trunc 63 | trimSuffix "-" }}{{- end -}}
{{- end -}}
{{- define "aseman.labels" -}}
app.kubernetes.io/name: {{ include "aseman.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}
{{- define "aseman.selector" -}}
app.kubernetes.io/name: {{ include "aseman.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}
{{- define "aseman.secretName" -}}{{ default (printf "%s-secrets" (include "aseman.fullname" .)) .Values.secrets.existingSecret }}{{- end -}}
{{- define "aseman.image" -}}{{ .repository }}:{{ .tag }}{{- end -}}
{{- define "aseman.dsn" -}}
{{- if .Values.postgres.enabled -}}
postgres://{{ .Values.postgres.user }}:$(POSTGRES_PASSWORD)@{{ include "aseman.fullname" . }}-postgres:5432/{{ .Values.postgres.database }}?sslmode=disable
{{- else -}}{{ required "postgres.externalDSN is required when postgres.enabled is false" .Values.postgres.externalDSN }}{{- end -}}
{{- end -}}
{{/* A secret value: the given one, the one already installed, or a new one. */}}
{{- define "aseman.secretValue" -}}
{{- $existing := lookup "v1" "Secret" .root.Release.Namespace (printf "%s-secrets" (include "aseman.fullname" .root)) -}}
{{- if .value -}}{{ .value | b64enc }}
{{- else if and $existing (index $existing.data .key) -}}{{ index $existing.data .key }}
{{- else -}}{{ randAlphaNum 32 | b64enc }}{{- end -}}
{{- end -}}
