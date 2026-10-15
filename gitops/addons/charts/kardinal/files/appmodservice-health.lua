-- Argo CD health of a kro AppmodService instance (the appmodservice RGD in
-- gitops/addons/charts/kro/resource-groups/manifests/appmod-service.yaml).
--
-- kro keeps the instance not Ready while its Rollout is not Healthy (readyWhen, #977). That
-- reads the same for a canary that is still running and for one Argo Rollouts aborted, so
-- without this check Argo CD shows an aborted canary as Progressing. The RGD copies the
-- Rollout's phase into status.rollout.<variant>.phase (Progressing until Argo Rollouts has
-- observed the Rollout's current spec), and this check reads it:
--   1. kro has not reconciled the instance's current spec yet (the Ready condition's
--      observedGeneration is older than metadata.generation): Progressing. Until then the
--      status, the Rollout's phase included, describes the previous spec;
--   2. the Rollout is Degraded (an analysis failed and the canary was aborted, or the
--      rollout failed): Degraded, with the Rollout's message;
--   3. Ready=True: Healthy;
--   4. kro reports the instance FAILED or ERROR: Degraded;
--   5. anything else (kro is still creating resources, the canary runs or is paused):
--      Progressing.
local hs = {}
local status = obj.status or {}
local ready = nil
if type(status.conditions) == "table" then
  for _, c in ipairs(status.conditions) do
    if c.type == "Ready" then
      ready = c
    end
  end
end
local generation = obj.metadata.generation
if ready ~= nil and ready.observedGeneration ~= nil and generation ~= nil and ready.observedGeneration < generation then
  hs.status = "Progressing"
  hs.message = "kro has not reconciled generation " .. generation .. " yet"
  return hs
end
local rolloutPhase, rolloutMessage = nil, ""
if type(status.rollout) == "table" then
  for _, r in pairs(status.rollout) do
    if type(r) == "table" and r.phase ~= nil and r.phase ~= "" then
      rolloutPhase = r.phase
      rolloutMessage = r.message or ""
    end
  end
end
if rolloutPhase == "Degraded" then
  hs.status = "Degraded"
  hs.message = "Rollout is Degraded: " .. rolloutMessage
  return hs
end
if ready ~= nil and ready.status == "True" then
  hs.status = "Healthy"
  hs.message = "Ready"
  return hs
end
if status.state == "FAILED" or status.state == "ERROR" then
  hs.status = "Degraded"
  hs.message = "kro reports the instance " .. status.state
  return hs
end
hs.status = "Progressing"
if rolloutPhase ~= nil then
  hs.message = "Rollout is " .. rolloutPhase
  if rolloutMessage ~= "" then
    hs.message = hs.message .. ": " .. rolloutMessage
  end
else
  hs.message = "Waiting for the instance to be Ready"
end
return hs
