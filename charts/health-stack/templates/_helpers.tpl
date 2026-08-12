{{/*
============================================================================
health-stack — template helpers
============================================================================
*/}}

{{/* Chart name+version string for the standard helm.sh/chart label. */}}
{{- define "health-stack.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels applied to every object. Mirrors the Kustomize commonLabels
(app.kubernetes.io/part-of) and adds the standard Helm set.
*/}}
{{- define "health-stack.labels" -}}
helm.sh/chart: {{ include "health-stack.chart" . }}
app.kubernetes.io/part-of: {{ .Values.global.partOf }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Per-component labels. Call with a dict: (dict "ctx" . "name" "hapi").
Produces the common labels plus app.kubernetes.io/name: <name>, so selectors
stay identical to the original manifests (which keyed on app.kubernetes.io/name).
*/}}
{{- define "health-stack.componentLabels" -}}
{{- $ctx := .ctx -}}
{{ include "health-stack.labels" $ctx }}
app.kubernetes.io/name: {{ .name }}
{{- end -}}

{{/*
Selector labels for a component — MUST be stable across upgrades. We deliberately
use ONLY app.kubernetes.io/name here (matching the original selectors) so an
existing Deployment/StatefulSet's immutable selector keeps matching.
Call with (dict "name" "hapi").
*/}}
{{- define "health-stack.selectorLabels" -}}
app.kubernetes.io/name: {{ .name }}
{{- end -}}

{{/*
Resolve an image reference. Call with a dict:
  (dict "image" .Values.ehrbase.image "fallback" .Values.images.hapi)
"image" wins when it sets .repository; otherwise "fallback" is used. Emits
"repository:tag". pullPolicy is emitted separately by the caller.
*/}}
{{- define "health-stack.image" -}}
{{- $img := .image | default dict -}}
{{- $fb := .fallback | default dict -}}
{{- $repo := $img.repository | default $fb.repository -}}
{{- $tag := $img.tag | default $fb.tag | default "latest" -}}
{{- printf "%s:%s" $repo $tag -}}
{{- end -}}

{{/*
Resolve a pullPolicy the same way (image block wins, else fallback, else IfNotPresent).
*/}}
{{- define "health-stack.pullPolicy" -}}
{{- $img := .image | default dict -}}
{{- $fb := .fallback | default dict -}}
{{- $img.pullPolicy | default $fb.pullPolicy | default "IfNotPresent" -}}
{{- end -}}

{{/*
A wait-for-postgres initContainer. Call with:
  (dict "ctx" . "host" "postgres" "user" "postgres" "userFromEnv" false "secretName" "")
When userFromEnv=true the container also sources `secretName` via envFrom so it
can reference $DB_USER_ADMIN etc. (as the original ehrbase init did).
*/}}
{{- define "health-stack.waitForPostgres" -}}
{{- $ctx := .ctx -}}
{{- /* Build the -U argument. When userFromEnv, reference the shell env var as
       $NAME (unbraced — avoids colliding with Go template {{ }} delimiters and
       is safe here since the var is followed by whitespace). */ -}}
{{- $userArg := .user -}}
{{- if .userFromEnv }}{{- $userArg = printf "$%s" .user -}}{{- end -}}
- name: wait-for-postgres
  image: {{ $ctx.Values.initPostgresImage | quote }}
  command:
    - sh
    - -c
    - |
      until pg_isready -h {{ .host }} -p 5432 -U {{ $userArg }}; do
        echo "waiting for {{ .host }}..."; sleep 3;
      done
{{- if .userFromEnv }}
  envFrom:
    - secretRef:
        name: {{ .secretName }}
{{- end }}
{{- end -}}

{{/*
Config checksum annotation block — rolls pods when the mounted config changes.
This replaces Kustomize's ConfigMap name-hash behavior. Call with (dict "ctx" .).
It hashes the rendered configmaps template so ANY config-file change triggers a roll.
*/}}
{{- define "health-stack.configChecksum" -}}
checksum/config: {{ include (print .ctx.Template.BasePath "/configmaps.yaml") .ctx | sha256sum }}
{{- end -}}

{{/* Common pod scheduling block (nodeSelector/tolerations/affinity). */}}
{{- define "health-stack.scheduling" -}}
{{- with .Values.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}
