#!/usr/bin/env bash
set -euo pipefail

# Removes what workshop modules 20 & 30 created, so they can be run again.
#
# APPS: the applications whose CI/CD and promotion objects are removed (default "rust java").
# Each app <a> may have, from the Backstage cicd-pipeline template and module 30:
#   hub:   Argo CD Applications <a>-cicd, <a>-dev-cd, <a>-prod-cd and <a>-kardinal,
#          AppProject <a>-project, CICDPipeline <a>-cicd-pipeline in team-<a>,
#          Kardinal's namespace <a>-app (Pipeline, PolicyGates, Bundles, Approvals, AuditEvents)
#   spokes: namespace team-<a> on dev and prod
#   AWS / GitLab / Backstage: ECR peeks/<a> (+/cache), GitLab <a>-cicd, catalog <a>-cicd-pipeline
# The steps that know an app's own manifests (spoke AppmodServices, resetting the GitLab app
# repos) cover rust and java when they are in APPS, and module 20's next-js app (team-nextjs
# on the spokes) unless NEXTJS=no.
APPS=${APPS:-rust java}
NEXTJS=${NEXTJS:-yes}
echo "============================================"
echo "  Cleanup: Workshop Modules 20 & 30 Tests"
echo "  Apps: ${APPS}"
echo "============================================"
echo ""

# --- GitLab token ---
# The workshop's GitLab PAT (setup-env writes GIT_TOKEN). GitLab refuses the OAuth password grant
# (unsupported_grant_type), which this used before, so the repos were never deleted.
if [[ "${GIT_TOKEN:-}" == glpat-* ]]; then
  GL_AUTH="PRIVATE-TOKEN: ${GIT_TOKEN}"
else
  GL_AUTH="Authorization: Bearer $(curl -sLk "${GITLAB_URL}/oauth/token" \
    -d "grant_type=password&username=user1&password=${USER1_PASSWORD}" | jq -r '.access_token')"
fi
echo "GitLab token obtained"

# --- Backstage token ---
source ~/environment/platform-on-eks-workshop/scripts/validation/backstage-auth.sh 2>/dev/null
BS_TOKEN=$(backstage_get_token)
echo "Backstage token obtained"

# =============================================
# 1. Delete ArgoCD Applications on hub (cascading)
# =============================================
# <a>-cicd first: it syncs the CICDPipeline and the dev/prod (and, with the template's
# promoter=kardinal, the <a>-kardinal) Applications, and self-heals anything deleted before it.
# Then <a>-kardinal when it was applied by hand (applications/java/kardinal/deploy-kardinal.sh):
# once it is gone, Kardinal no longer promotes the app.
echo ""
echo ">>> Deleting ArgoCD Applications..."
kubectl config use-context peeks-hub
for a in ${APPS}; do
  for app in ${a}-cicd ${a}-kardinal ${a}-dev-cd ${a}-prod-cd; do
    # Not waiting here: the CICDPipeline's ECR repositories still hold images until step 6.
    kubectl delete application ${app} -n argocd --ignore-not-found --wait=false 2>/dev/null || true
  done
  kubectl delete appproject ${a}-project -n argocd --ignore-not-found 2>/dev/null || true
done

# =============================================
# 2. Delete CICDPipelines (Kro instances) left on hub
# =============================================
echo ""
echo ">>> Deleting CICDPipelines on hub cluster..."
for a in ${APPS}; do
  kubectl delete cicdpipeline ${a}-cicd-pipeline -n team-${a} --ignore-not-found --wait=false
done
echo "Waiting 60s for Kro to clean up resources..."
sleep 60

# =============================================
# 3. Delete the Kardinal promotion namespaces on hub
# =============================================
# The Pipeline, its PolicyGates, Bundles (and their kro Graphs and PromotionSteps), Approvals
# and AuditEvents live in <a>-app. Deleting it is what removes the promotion history.
echo ""
echo ">>> Deleting Kardinal namespaces on hub cluster..."
for a in ${APPS}; do
  kubectl delete namespace ${a}-app --ignore-not-found --wait=true --timeout=5m 2>/dev/null || true
done

# =============================================
# 4. Clean up dev and prod cluster resources
# =============================================
echo ""
echo ">>> Cleaning up dev and prod clusters..."
for ctx in peeks-spoke-dev peeks-spoke-prod; do
  kubectl config use-context ${ctx}

  # Delete AppModServices (Kro instances) and their services, only for the apps cleaned up
  if [[ " ${APPS} " == *" rust "* ]]; then
    kubectl delete appmodservice rust-microservice -n team-rust --ignore-not-found 2>/dev/null || true
    kubectl delete svc rust-microservice rust-microservice-preview -n team-rust --ignore-not-found 2>/dev/null || true
  fi
  if [[ " ${APPS} " == *" java "* ]]; then
    kubectl delete appmodservice progressive-app java-webservice -n team-java --ignore-not-found 2>/dev/null || true
    kubectl delete svc progressive-app progressive-app-preview -n team-java --ignore-not-found 2>/dev/null || true
  fi
  if [ "${NEXTJS}" = yes ]; then
    kubectl delete appmodservice next-js-app -n team-nextjs --ignore-not-found 2>/dev/null || true
    kubectl delete svc next-js-app next-js-app-preview -n team-nextjs --ignore-not-found 2>/dev/null || true
  fi
done

sleep 30

# Delete namespaces
for ctx in peeks-spoke-dev peeks-spoke-prod; do
  kubectl config use-context ${ctx}
  for a in ${APPS}; do
    kubectl delete namespace team-${a} --ignore-not-found 2>/dev/null || true
  done
  [ "${NEXTJS}" = yes ] && kubectl delete namespace team-nextjs --ignore-not-found 2>/dev/null || true
done

# =============================================
# 5. Clean up hub cluster namespaces
# =============================================
echo ""
echo ">>> Cleaning up hub cluster namespaces..."
kubectl config use-context peeks-hub
for a in ${APPS}; do
  kubectl delete namespace team-${a} --ignore-not-found 2>/dev/null || true
done

# =============================================
# 6. Delete ECR repositories
# =============================================
echo ""
echo ">>> Deleting ECR repositories..."
for a in ${APPS}; do
  for repo in peeks/${a} peeks/${a}/cache; do
    aws ecr delete-repository --repository-name "${repo}" --region ${AWS_REGION} --force 2>/dev/null || true
    echo "  Deleted ECR: ${repo}"
  done
done

# =============================================
# 7. Delete Backstage components
# =============================================
echo ""
echo ">>> Deleting Backstage catalog entities..."
for a in ${APPS}; do
  entity="component:default/${a}-cicd-pipeline"
  KIND=$(echo $entity | cut -d: -f1)
  NS_NAME=$(echo $entity | cut -d: -f2)
  NS=$(echo $NS_NAME | cut -d/ -f1)
  NAME=$(echo $NS_NAME | cut -d/ -f2)

  # Unregister entity
  ENTITY_UID=$(curl -sLk "${BACKSTAGE_URL}/api/catalog/entities/by-name/${KIND}/${NS}/${NAME}" \
    -H "Authorization: Bearer ${BS_TOKEN}" | jq -r '.metadata.uid // empty')

  if [ -n "$ENTITY_UID" ]; then
    # Find the location
    LOC_REF=$(curl -sLk "${BACKSTAGE_URL}/api/catalog/entities/by-name/${KIND}/${NS}/${NAME}" \
      -H "Authorization: Bearer ${BS_TOKEN}" | jq -r '.metadata.annotations["backstage.io/managed-by-origin-location"] // empty')

    if [ -n "$LOC_REF" ]; then
      # Delete by unregistering location
      LOC_ID=$(curl -sLk "${BACKSTAGE_URL}/api/catalog/locations" \
        -H "Authorization: Bearer ${BS_TOKEN}" | jq -r ".[] | select(.data.target == \"${LOC_REF#url:}\") | .data.id // empty" 2>/dev/null)

      if [ -n "$LOC_ID" ]; then
        curl -sLk -X DELETE "${BACKSTAGE_URL}/api/catalog/locations/${LOC_ID}" \
          -H "Authorization: Bearer ${BS_TOKEN}" 2>/dev/null || true
      fi
    fi

    # Force delete entity
    curl -sLk -X DELETE "${BACKSTAGE_URL}/api/catalog/entities/by-uid/${ENTITY_UID}" \
      -H "Authorization: Bearer ${BS_TOKEN}" 2>/dev/null || true
    echo "  Deleted Backstage entity: ${entity}"
  else
    echo "  Entity not found: ${entity}"
  fi
done

# =============================================
# 8. Delete GitLab CI/CD repos
# =============================================
# By exact path. GitLab only schedules a deletion (the project is renamed
# <name>-deletion_scheduled-<id> and keeps the path), so the template could not publish
# <a>-cicd again; the scheduled project is then removed for good (permanently_remove).
echo ""
echo ">>> Deleting GitLab CI/CD repositories..."
for a in ${APPS}; do
  repo_name=${a}-cicd
  PROJECT_ID=$(curl -sLk "${GITLAB_URL}/api/v4/projects/user1%2F${repo_name}" \
    -H "${GL_AUTH}" | jq -r ".id // empty")

  if [ -n "$PROJECT_ID" ] && [ "$PROJECT_ID" != "null" ]; then
    curl -sLk -o /dev/null -X DELETE "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}" \
      -H "${GL_AUTH}" 2>/dev/null || true
    sleep 3
    SCHEDULED=$(curl -sLk "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}" \
      -H "${GL_AUTH}" | jq -r '.path_with_namespace // empty')
    if [ -n "$SCHEDULED" ]; then
      curl -sLk -o /dev/null -X DELETE -G "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}" \
        --data-urlencode "permanently_remove=true" --data-urlencode "full_path=${SCHEDULED}" \
        -H "${GL_AUTH}" 2>/dev/null || true
    fi
    echo "  Deleted GitLab project: ${repo_name} (ID: ${PROJECT_ID})"
  else
    echo "  GitLab project not found: ${repo_name}"
  fi
done

# =============================================
# 9. Reset application repos
# =============================================
# deployment/dev and deployment/prod both: module 30 promotes (Kardinal) into prod too.
echo ""
echo ">>> Resetting application repositories..."

# Reset Rust repo
if [[ " ${APPS} " == *" rust "* ]]; then
cd ~/environment/applications/rust
rm -f deployment/dev/application.yaml deployment/dev/services.yaml
rm -f deployment/prod/application.yaml deployment/prod/services.yaml
git checkout -- src/api/services/ui.rs 2>/dev/null || true
git add -A
git diff --cached --quiet || git commit -m "Cleanup: reset to pre-test state"
git push origin main 2>/dev/null || true
fi

# Reset Java repo
if [[ " ${APPS} " == *" java "* ]]; then
cd ~/environment/applications/java
rm -f deployment/dev/application.yaml deployment/dev/services.yaml
rm -f deployment/prod/application.yaml deployment/prod/services.yaml
sed -i 's|argoproj/rollouts-demo:yellow|argoproj/rollouts-demo:blue|' progressive-app.yaml 2>/dev/null || true
git checkout -- src/src/main/webapp/index.jsp 2>/dev/null || true
git checkout -- README.md 2>/dev/null || true
git add -A
git diff --cached --quiet || git commit -m "Cleanup: reset to pre-test state"
git push origin main 2>/dev/null || true
fi

kubectl config use-context peeks-hub

# =============================================
# 10. Wait for the cascading deletes of step 1
# =============================================
echo ""
echo ">>> Waiting for the Applications to finish deleting..."
for i in $(seq 1 60); do
  LEFT=""
  for a in ${APPS}; do
    for app in ${a}-cicd ${a}-kardinal ${a}-dev-cd ${a}-prod-cd; do
      kubectl get application ${app} -n argocd >/dev/null 2>&1 && LEFT="${LEFT} ${app}"
    done
  done
  [ -z "${LEFT}" ] && break
  sleep 10
done
[ -n "${LEFT}" ] && echo "  Still deleting after 10 min:${LEFT}" || echo "  All Applications deleted"

echo ""
echo "============================================"
echo "  Cleanup Complete!"
echo "============================================"
echo ""
APPS_RE=$(echo ${APPS} | tr ' ' '|')
echo "Remaining manual checks:"
echo "  - Verify ArgoCD apps are removed: kubectl get applications -n argocd | grep -E '${APPS_RE}|next'"
echo "  - Verify namespaces are deleted: kubectl get ns | grep -E 'team-(${APPS_RE})|team-nextjs|(${APPS_RE})-app'"
echo "  - Verify Kardinal no longer lists them: kardinal get pipelines -A"
echo "  - Verify ECR repos are deleted: aws ecr describe-repositories --region ${AWS_REGION} --query 'repositories[].repositoryName' | grep peeks"
