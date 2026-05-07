# Omnix Mendix on Azure — Terraform

Production-style Azure infrastructure for hosting a Mendix application across four environments (DEV / SIT / PROD / DR), built from the AX Advisory Omnix proposal. Single subscription, four resource groups, parameterised region (default `westus2`, easy swap to `uaenorth`).

## Layout

```
bootstrap/                  one-shot — creates remote state storage account
modules/                    reusable building blocks
envs/
  shared/                   ACR, Bastion, jump host, Private DNS zones
  dev/  sit/  prod/  dr/    one composition per environment
k8s/
  helm/mendix-app/          sample app Helm chart (Mendix Company Expenses)
  bootstrap/                ALB Controller + Workload Identity bindings
scripts/                    bootstrap, deploy-app, stop-env, start-env
```

## Order of operations

1. `bootstrap/` — creates the storage account that holds Terraform state. Run **once** with local state, then commit nothing (state self-references after).
2. `envs/shared/` — ACR Premium (geo-replicated), Bastion + Windows jump VM, all `privatelink.*` DNS zones.
3. `envs/dev/` → `sit/` → `prod/` → `dr/` — each env is independent; share the shared layer.
4. `k8s/bootstrap/` — install ALB Controller (AGC) + bind Workload Identity into the cluster.
5. `k8s/helm/mendix-app/` — `helm install` the sample Mendix Company Expenses app.

Each step uses `terraform plan` first, then `apply` only after review.

## Region swap

Set `var.location_primary` and `var.location_dr` in each env's tfvars.

| Pair | Primary | DR |
|------|---------|-----|
| US (default) | `westus2` | `northcentralus` |
| UAE | `uaenorth` | `uaecentral` |

## Cost control between demos

`scripts/stop-env.ps1 -Env dev` will:
- `az aks stop` the cluster (no compute charge; control plane free for 12 mo, ~$0.10/hr after)
- scale Azure SQL DB → `Basic` (~$5/mo)
- deallocate the jump VM
- (optional) `terraform destroy` the bastion module (~$140/mo savings)

`scripts/start-env.ps1 -Env dev` reverses everything and is idempotent.

ACR Premium and NAT GW have small idle costs (~$2.70/day combined) — leave running.

## Substitutions vs the original proposal

| Proposal | This build | Reason |
|----------|-----------|--------|
| 4 subscriptions | 4 resource groups in 1 sub | Per user direction |
| Azure SQL Managed Instance | Azure SQL Database (private endpoint) | ~$1,500/mo cheaper, 4 hr faster deploy, Mendix supports it |
| Azure Files Premium | Azure Files Standard (DEV/SIT) / Premium (PROD) | DEV/SIT cost containment |
| ACR Premium per env | Single shared Premium ACR (geo-replicated) | Cheaper, valid pattern, per user direction |
| Bastion + jump host per env | Single shared Bastion + jump VM | Cheaper, per user direction |
| UAE North | westus2 (variable) | Per user direction |
