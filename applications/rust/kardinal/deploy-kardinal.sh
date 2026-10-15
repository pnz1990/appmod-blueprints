#!/bin/bash
# Promote the rust app with Kardinal (the same pattern as applications/java/kardinal).
#
# Applies ONE Argo CD Application, rust-kardinal (argocd-application.yaml), which syncs
# ./chart from the GitLab rust repo into namespace rust-app on the hub: Pipeline rust (dev
# automatic with a bake and automatic rollback, prod through a GitLab merge request after a
# dev soak gate), the rust PolicyGates and the git Secret. From then on the configuration
# is GitOps: change it in git (chart/values.yaml lists the optional features: gates,
# MetricChecks, a NotificationHook, an ECR Subscription, per-team CI identity). Kardinal
# itself is a platform addon (enable_kardinal); it needs no IAM role or Pod Identity here,
# since it only talks to GitLab and to the hub's Argo CD Applications.
#
# Then turn on kardinal.enabled in the rust CICDPipeline (rust-cicd repo,
# manifests/kro-cicd-pipeline.yaml), so CI hands each build to Kardinal as a Bundle instead
# of writing deployment/dev itself.
#
# Needs GITLAB_URL and GIT_USERNAME (setup-env); RESOURCE_PREFIX defaults to peeks.
set -euo pipefail

if [[ -z "${GITLAB_URL:-}" || -z "${GIT_USERNAME:-}" ]]; then
  echo "Error: GITLAB_URL and GIT_USERNAME must be set (see ~/.bashrc.d/platform.sh)." >&2
  exit 1
fi
export RESOURCE_PREFIX="${RESOURCE_PREFIX:-peeks}"
export GITLAB_URL="${GITLAB_URL%/}" GIT_USERNAME
KUBECTL=(kubectl --context "${KUBE_CONTEXT:-${RESOURCE_PREFIX}-hub}")
cd "$(dirname "$0")"

if ! "${KUBECTL[@]}" get crd pipelines.kardinal.io >/dev/null 2>&1; then
  echo "Error: Kardinal is not installed on the hub (addon kardinal, label enable_kardinal)." >&2
  exit 1
fi

echo "Applying the Argo CD Application rust-kardinal..."
envsubst '${GITLAB_URL} ${GIT_USERNAME} ${RESOURCE_PREFIX}' < argocd-application.yaml | "${KUBECTL[@]}" apply -f -

echo "Waiting for Pipeline rust to be Ready..."
READY=""
for _ in $(seq 1 60); do
  READY=$("${KUBECTL[@]}" get pipelines.kardinal.io rust -n rust-app \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  [ "$READY" = "True" ] && break
  sleep 5
done
"${KUBECTL[@]}" get pipelines.kardinal.io rust -n rust-app
if [ "$READY" != "True" ]; then
  echo "Pipeline rust is not Ready yet: kubectl describe pipelines.kardinal.io rust -n rust-app" >&2
  exit 1
fi
echo "Done. Kardinal now promotes rust: each version (Bundle) goes to dev and must stay healthy there for"
echo "2 minutes (else it is rolled back); then Kardinal opens a GitLab merge request for prod: merge it to promote."
echo "Next: set kardinal.enabled: \"true\" in rust-cicd's manifests/kro-cicd-pipeline.yaml, so CI creates the Bundles."
echo "Watch it with: kardinal get pipelines -n rust-app; what prod waits for: kardinal why rust prod -n rust-app"
