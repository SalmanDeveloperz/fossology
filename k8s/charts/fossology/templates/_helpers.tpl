{{/*
SPDX-FileCopyrightText: © 2026 Muhammad Salman
SPDX-License-Identifier: FSFAP
*/}}

{{- define "fossology.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "fossology.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "fossology.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Usage: include "fossology.selectorLabels" (dict "ctx" . "component" "web") */}}
{{- define "fossology.selectorLabels" -}}
app.kubernetes.io/name: {{ include "fossology.name" .ctx }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{- define "fossology.labels" -}}
helm.sh/chart: {{ include "fossology.chart" .ctx }}
{{ include "fossology.selectorLabels" . }}
app.kubernetes.io/version: {{ .ctx.Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .ctx.Release.Service }}
app.kubernetes.io/part-of: fossology
{{- end }}

{{- define "fossology.image" -}}
{{- printf "%s:%s" .Values.image.repository (.Values.image.tag | default .Chart.AppVersion) }}
{{- end }}

{{- define "fossology.dbHost" -}}
{{- if .Values.postgresql.enabled }}
{{- printf "%s-db" (include "fossology.fullname" .) }}
{{- else }}
{{- required "database.host is required when postgresql.enabled is false" .Values.database.host }}
{{- end }}
{{- end }}

{{- define "fossology.dbSecretName" -}}
{{- .Values.database.existingSecret | default (printf "%s-db" (include "fossology.fullname" .)) }}
{{- end }}

{{- define "fossology.repositoryClaim" -}}
{{- .Values.repository.persistence.existingClaim | default (printf "%s-repository" (include "fossology.fullname" .)) }}
{{- end }}

{{- define "fossology.sshSecretName" -}}
{{- .Values.ssh.existingSecret | default (printf "%s-ssh" (include "fossology.fullname" .)) }}
{{- end }}

{{- define "fossology.workerName" -}}
{{- printf "%s-worker" (include "fossology.fullname" .) }}
{{- end }}

{{/* Body of [HOSTS]: one stable StatefulSet DNS name per worker, or localhost. */}}
{{- define "fossology.hosts" -}}
{{- if .Values.workers.enabled }}
{{- $worker := include "fossology.workerName" . }}
{{- range $i := until (int .Values.workers.replicas) }}
{{ printf "%s-%d = %s-%d.%s.%s.svc /usr/local/etc/fossology %d" $worker $i $worker $i $worker $.Release.Namespace (int $.Values.workers.maxAgents) }}
{{- end }}
{{- else }}
{{ printf "localhost = localhost /usr/local/etc/fossology %d" (int .Values.scheduler.localMaxAgents) }}
{{- end }}
{{- end }}

{{- define "fossology.dbEnv" -}}
- name: FOSSOLOGY_DB_HOST
  value: {{ include "fossology.dbHost" . | quote }}
- name: FOSSOLOGY_DB_NAME
  value: {{ .Values.database.name | quote }}
- name: FOSSOLOGY_DB_USER
  value: {{ .Values.database.user | quote }}
- name: FOSSOLOGY_DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "fossology.dbSecretName" . }}
      key: password
{{- end }}

{{- define "fossology.repositoryVolume" -}}
- name: repository
  persistentVolumeClaim:
    claimName: {{ include "fossology.repositoryClaim" . }}
{{- end }}

{{- define "fossology.podScheduling" -}}
{{- with .Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.podSecurityContext }}
securityContext:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/* Pod template of the migration Job. Its hash names the Job. */}}
{{- define "fossology.migrationPodSpec" -}}
metadata:
  labels:
    {{- include "fossology.labels" (dict "ctx" . "component" "migration") | nindent 4 }}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  {{- include "fossology.podScheduling" . | nindent 2 }}
  containers:
    - name: migrate
      image: {{ include "fossology.image" . }}
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      args: ["migrate"]
      env:
        {{- include "fossology.dbEnv" . | nindent 8 }}
      {{- with .Values.migration.resources }}
      resources:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      volumeMounts:
        - name: repository
          mountPath: /srv/fossology/repository
  volumes:
    {{- include "fossology.repositoryVolume" . | nindent 4 }}
{{- end }}

{{- define "fossology.migrationJob" -}}
{{- $content := printf "%s|%d" (include "fossology.migrationPodSpec" .) (int .Values.migration.backoffLimit) }}
{{- printf "%s-migrate-%s" (include "fossology.fullname" .) ($content | sha256sum | trunc 10) }}
{{- end }}

{{- define "fossology.migrationReader" -}}
{{- printf "%s-migration-reader" (include "fossology.fullname" .) }}
{{- end }}

{{/* Init container that blocks until the migration Job has succeeded. */}}
{{- define "fossology.waitMigrationInit" -}}
- name: wait-migration
  image: {{ include "fossology.image" . }}
  imagePullPolicy: {{ .Values.image.pullPolicy }}
  args: ["wait-migration"]
  env:
    - name: FOSSOLOGY_MIGRATION_JOB
      value: {{ include "fossology.migrationJob" . }}
  volumeMounts:
    - name: migration-reader
      mountPath: /var/run/secrets/fossology-k8s
      readOnly: true
{{- end }}

{{/* Token for the init container only; the main container gets none. */}}
{{- define "fossology.waitMigrationVolume" -}}
- name: migration-reader
  projected:
    sources:
      - serviceAccountToken:
          path: token
          expirationSeconds: 3600
      - configMap:
          name: kube-root-ca.crt
          items:
            - key: ca.crt
              path: ca.crt
      - downwardAPI:
          items:
            - path: namespace
              fieldRef:
                fieldPath: metadata.namespace
{{- end }}
