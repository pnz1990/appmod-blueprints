# Progressive Delivery and Promotion

How the platform rolls out new versions safely (Argo Rollouts) and promotes them across environments (Kardinal).

## Strategies

| Strategy | What it does | When |
|----------|--------------|------|
| **Canary** (default) | Shift traffic gradually to the new version; gate at checkpoints | Most services — the platform default |
| **Blue/Green** | Two identical environments; instant switch + instant rollback | Need zero in-flight risk / instant rollback |
| **A/B** | Run two versions to compare behavior | Experimentation / measuring effectiveness |

The platform's `appmod-service` OAM component wires Argo Rollouts canary automatically — developers get progressive delivery without writing Rollout specs.

## The default canary

```
new version → 20% traffic   [functional gate]
            → 40% (pause)
            → 60% (pause)
            → 80%           [performance gate / metrics gate]
            → 100%          old version retired
```

Any gate failure (or an image-pull failure, etc.) triggers **automatic rollback** to the last stable version.

## Quality gates (Argo Rollouts Analyses)

Three gate types, all developer-configured, platform-executed:

- **Functional gate** — a smoke/correctness check at ~20% traffic. Example: verify the served page color matches expected.
  ```yaml
  functionalGate: { pause: "20s", image: "httpd:alpine", extraArgs: "red" }   # "red" = expected
  ```
- **Performance gate** — a load/latency check at ~80% traffic (e.g. Artillery image), pass/fail on a threshold.
  ```yaml
  performanceGate: { pause: "10s", image: "httpd:alpine", extraArgs: "160" }  # 160 = max avg ms
  ```
- **Metrics gate** — developer-defined Prometheus queries, the most powerful gate. Each criterion: a function (`sum|avg|max|min|count`) over a metric, a comparison, a threshold, and whether breaching means success or failure.
  ```yaml
  metrics:
    pause: "2s"
    evaluationCriteria:
      - interval: "1s"
        count: 1
        function: "avg"
        successOrFailCondition: "fail"        # breaching this fails the rollout
        metric: "rocket_http_requests_duration_seconds_sum"
        comparisonType: ">"
        threshold: 3                          # avg response time > 3s → rollback
  ```

**Principle — developers own "healthy."** The platform supplies the mechanism (canary + analysis); each team defines the metrics and thresholds that define health for *their* app. Gates are config in the OAM manifest, not platform code.

## Multi-stage promotion — Kardinal

Kardinal ([kardinal-promoter](https://github.com/pnz1990/kardinal-promoter)) orchestrates dev→prod promotion GitOps-natively from the hub: addon `kardinal`, which needs the self-managed upstream kro with its Graph feature (addon `kro-upstream`, `hub.kroMode: upstream`). Resources, in namespace `<app>-app` on the hub:

- **Pipeline** — one per app: the app's GitLab repo, its environments in order (dev, then prod), how to update each one (`update.strategy: yaml` on `deployment/<env>/application.yaml` `spec.image`) and how to check it (`health.type: argocd` on `<app>-<env>-cd`).
- **Bundle** — one version: the image CI built. CI creates it through Kardinal's Bundle API right after the image push (`kardinal.enabled` on the CICDPipeline). A newer Bundle supersedes one still in flight.
- **PolicyGate** — CEL gates, injected per environment; `prod-approval` (scope team, applies to prod) waits for one approval.
- **PromotionStep** — one per environment per Bundle (kro creates it from the Bundle's Graph): clone → update → commit → push → ask Argo CD to sync → wait until the Application is Healthy and Synced at that commit.

The Backstage `cicd-pipeline` template creates all of it (parameter `promoter: kardinal`, the default).

Flow:
```
Argo Workflows builds image → CI creates a Bundle (Bundle API)
   → dev: Kardinal commits the image into deployment/dev/application.yaml → ArgoCD deploys dev → Healthy
   → prod waits at prod-approval: Approve in the Kardinal UI (https://<domain>/ui/, Keycloak SSO)
     or `kardinal approve <app> prod -n <app>-app` on the IDE
   → prod: Kardinal commits the SAME image into deployment/prod/application.yaml → ArgoCD deploys prod
```

Key properties:
- **Same-artifact promotion** — prod runs the exact image that passed dev; no rebuild, no drift.
- **Auto dev / approved prod** — speed in lower environments, an approval gate for production. An approval records who gave it, as the API server authenticated them (`oidc:user1` from the UI, the IAM identity from the CLI).
- **GitOps-native** — every promotion is a Git commit (`[kardinal] Promote <bundle> to <env>`): auditable, reversible.
- **Explainable** — `kardinal explain <app> -n <app>-app` shows each gate's expression and why it blocks.

Verify: `kardinal get pipelines -A`, `kardinal inbox -A`, `kubectl get bundles,promotionsteps -n <app>-app`; confirm the prod manifest's `image:` changed after the promotion.

## Watching a rollout

```bash
kubectl argo rollouts get rollout <name> -n <ns> -w     # live progression + gate status
kubectl argo rollouts retry rollout <name> -n <ns>      # retry after a fix
```
