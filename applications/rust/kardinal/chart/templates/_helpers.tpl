{{- define "rust-kardinal.gitURL" -}}
{{- if not .Values.gitlab.url }}{{ fail "gitlab.url is required (https://<GitLab host>)" }}{{ end -}}
{{ trimSuffix "/" .Values.gitlab.url }}/{{ .Values.gitlab.username }}/{{ .Values.app }}.git
{{- end -}}

{{- /*
The arm-rollback pre-deploy hook of an environment (rollbackPolicy in values.yaml). Before a
version promotes into the environment, it creates that version's RollbackPolicy: Kardinal
rolls the version back after failureThreshold consecutive failed health checks (an aborted
canary is one every 10 seconds). The RollbackPolicy is named after the Bundle and owned by
it, so it goes when Kardinal deletes the Bundle (historyLimit). Rollback versions get none.
The hook fails open: it always exits 0, and says in its log when it armed nothing.
Usage: include "rust-kardinal.armRollbackHook" (dict "env" "dev" "root" $)
*/ -}}
{{- define "rust-kardinal.armRollbackHook" -}}
{{- $rp := .root.Values.rollbackPolicy -}}
- name: arm-rollback
  phase: pre
  timeout: 2m
  job:
    backoffLimit: 1
    template:
      spec:
        serviceAccountName: {{ $rp.serviceAccount }}
        securityContext:
          runAsNonRoot: true
          runAsUser: 65534
          runAsGroup: 65534
          seccompProfile:
            type: RuntimeDefault
        containers:
          - name: arm-rollback
            image: {{ $rp.image }}
            resources:
              requests:
                cpu: 10m
                memory: 32Mi
              limits:
                memory: 128Mi
            securityContext:
              allowPrivilegeEscalation: false
              capabilities:
                drop: ["ALL"]
            env:
              - name: HOME
                value: /tmp
              - name: NAMESPACE
                valueFrom:
                  fieldRef:
                    fieldPath: metadata.namespace
              - name: HOOKRUN
                valueFrom:
                  fieldRef:
                    fieldPath: "metadata.labels['kardinal.io/hookrun']"
              - name: PIPELINE
                value: {{ .root.Values.app | quote }}
              - name: ENVIRONMENT
                value: {{ .env | quote }}
              - name: FAILURE_THRESHOLD
                value: {{ $rp.failureThreshold | quote }}
            command: ["/bin/sh", "-c"]
            args:
              - |
                warn() { echo "WARNING: no RollbackPolicy for this version: $1. A failed health check still rolls it back at health.timeout (onHealthFailure)."; exit 0; }
                BUNDLE=$(kubectl -n "$NAMESPACE" get hookruns.kardinal.io "$HOOKRUN" -o jsonpath='{.spec.bundleName}') || warn "cannot read HookRun $HOOKRUN"
                [ -n "$BUNDLE" ] || warn "HookRun $HOOKRUN names no Bundle"
                BUNDLE_UID=$(kubectl -n "$NAMESPACE" get bundles.kardinal.io "$BUNDLE" -o jsonpath='{.metadata.uid}') || warn "cannot read Bundle $BUNDLE"
                ROLLBACK=$(kubectl -n "$NAMESPACE" get bundles.kardinal.io "$BUNDLE" -o jsonpath='{.metadata.labels.kardinal\.io/rollback}{.spec.provenance.rollbackOf}') || warn "cannot read Bundle $BUNDLE"
                if [ -n "$ROLLBACK" ]; then
                  echo "Bundle $BUNDLE is a rollback: Kardinal never rolls a rollback back, so it gets no RollbackPolicy."
                  exit 0
                fi
                if kubectl -n "$NAMESPACE" get rollbackpolicies.kardinal.io "$BUNDLE" > /dev/null 2>&1; then
                  echo "RollbackPolicy $BUNDLE exists already."
                  exit 0
                fi
                kubectl create -f - <<EOF || warn "cannot create RollbackPolicy $BUNDLE"
                apiVersion: kardinal.io/v1alpha1
                kind: RollbackPolicy
                metadata:
                  name: $BUNDLE
                  namespace: $NAMESPACE
                  labels:
                    app.kubernetes.io/managed-by: arm-rollback-hook
                  ownerReferences:
                    - apiVersion: kardinal.io/v1alpha1
                      kind: Bundle
                      name: $BUNDLE
                      uid: $BUNDLE_UID
                spec:
                  pipelineName: $PIPELINE
                  environment: $ENVIRONMENT
                  bundleRef: $BUNDLE
                  failureThreshold: $FAILURE_THRESHOLD
                EOF
                echo "RollbackPolicy $BUNDLE: $PIPELINE rolls this version back in $ENVIRONMENT after $FAILURE_THRESHOLD consecutive failed health checks."
{{- end -}}
