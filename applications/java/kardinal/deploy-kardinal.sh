#!/bin/bash
# Promote the java app with Kardinal (replaces kargo/deploy-kargo.sh).
#
# Applies ONE Argo CD Application, java-kardinal (argocd-application.yaml), which syncs
# ./chart from the GitLab java repo into namespace java-app on the hub: Pipeline java
# (dev automatic, prod after one approval), the prod approval gate and the git Secret.
# From then on the configuration is GitOps: change it in git. Kardinal itself is a
# platform addon (enable_kardinal); it needs no IAM role or Pod Identity here, since it
# only talks to GitLab and to the hub's Argo CD Applications.
#
# Kargo and Kardinal must not both promote java (both write deployment/<env>), so this
# also deletes the java Kargo Project (java-app-kargo, from deploy-kargo.sh) when present.
#
# Not needed when java-cicd came from the Backstage cicd-pipeline template with
# promoter=kardinal (its default): java-cicd then already syncs its own java-kardinal
# Application (from the java-cicd repo) and the script leaves it alone.
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

SRC=$("${KUBECTL[@]}" -n argocd get application java-kardinal -o jsonpath='{.spec.source.repoURL}' 2>/dev/null || true)
if [[ "$SRC" == */java-cicd.git ]]; then
  echo "java-kardinal is already managed by java-cicd (the Backstage template, promoter=kardinal):"
  echo "Kardinal already promotes java. Nothing to do."
  "${KUBECTL[@]}" get pipelines.kardinal.io java -n java-app
  exit 0
fi

echo "Applying the Argo CD Application java-kardinal..."
envsubst '${GITLAB_URL} ${GIT_USERNAME} ${RESOURCE_PREFIX}' < argocd-application.yaml | "${KUBECTL[@]}" apply -f -

if "${KUBECTL[@]}" get projects.kargo.akuity.io java-app-kargo >/dev/null 2>&1; then
  echo "Deleting the java Kargo Project java-app-kargo (its Stages, Warehouse and Freight go with it)..."
  "${KUBECTL[@]}" delete projects.kargo.akuity.io java-app-kargo --wait=true --timeout=5m
fi

echo "Waiting for Pipeline java to be Ready..."
for _ in $(seq 1 60); do
  READY=$("${KUBECTL[@]}" get pipelines.kardinal.io java -n java-app \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  [ "$READY" = "True" ] && break
  sleep 5
done
"${KUBECTL[@]}" get pipelines.kardinal.io java -n java-app
if [ "$READY" != "True" ]; then
  echo "Pipeline java is not Ready yet: kubectl describe pipelines.kardinal.io java -n java-app" >&2
  exit 1
fi
echo "Done. Kardinal now promotes java: each version (Bundle) goes to dev, then waits for an approval for prod."
echo "Watch it with: kardinal get pipelines -n java-app; approve prod with: kardinal approve java prod -n java-app"
