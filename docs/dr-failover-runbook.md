# Omnix DR Failover Runbook

## Architecture (current)

```
                    ┌──────────────────────────────────────┐
                    │   Azure Front Door (Standard)        │
                    │   ep-omnix-amhff7fwg8azbucj          │
                    │       .b02.azurefd.net               │
                    │                                      │
                    │   Origin Group: og-omnix-mendix      │
                    │   Health probe: HEAD / every 30s     │
                    │   2-of-4 samples to flip             │
                    └────────┬───────────────────┬─────────┘
                             │                   │
                  Priority 1 │                   │ Priority 2
                  weight 1000│                   │ weight 1000
                             ▼                   ▼
                    ┌────────────────┐  ┌────────────────┐
                    │  PROD (westus2)│  │  DR (ncus)     │
                    │  AKS LB        │  │  AKS LB        │
                    │  4.149.147.18  │  │  64.236.173.86 │
                    │  Mendix pod    │  │  Mendix pod    │
                    │  + postgres SC │  │  + postgres SC │
                    └────────────────┘  └────────────────┘
```

Public URL: **https://ep-omnix-amhff7fwg8azbucj.b02.azurefd.net/**

Failover is **automatic** when prod's health probe fails (~30–90 s detection + DNS propagation).

---

## How Front Door routes traffic

- **Normal:** all traffic → `origin-prod` (priority 1).
- **Probe fails on prod:** AFD marks prod unhealthy, drains it from POPs, sends traffic to `origin-dr` (priority 2). Time to switch: ~30–90 s.
- **Prod recovers:** AFD waits `trafficRestorationTimeToHealedOrNewEndpointsInMinutes = 10` after probe success before sending traffic back. Prevents flapping.

---

## Test 1 — Simulated unplanned outage (recommended drill)

```powershell
# 1) Pin a browser tab on https://ep-omnix-amhff7fwg8azbucj.b02.azurefd.net/ to watch
# 2) From the laptop, scale prod to 0 to break it
az aks command invoke -g rg-omnix-prod -n aks-omnix-prod --command "kubectl scale deploy/mendix-app -n mendix --replicas=0"

# 3) Watch the FD endpoint (expect 502 for 30-90s, then 200 from DR)
1..40 | ForEach-Object {
  $r = curl.exe -sIo /dev/null -w "%{http_code}" "https://ep-omnix-amhff7fwg8azbucj.b02.azurefd.net/" 2>$null
  Write-Host "$(Get-Date -f HH:mm:ss) HTTP=$r"
  Start-Sleep 5
}

# 4) Confirm DR is serving
az aks command invoke -g rg-omnix-dr -n aks-omnix-dr --command "kubectl get pod -n mendix -l app=mendix-app -o wide"

# 5) Recover prod
az aks command invoke -g rg-omnix-prod -n aks-omnix-prod --command "kubectl scale deploy/mendix-app -n mendix --replicas=1"
```

---

## Test 2 — Planned failover (admin-controlled)

```powershell
# Disable prod origin → drains immediately to DR
az afd origin update -g rg-omnix-shared --profile-name afd-omnix `
  --origin-group-name og-omnix-mendix --origin-name origin-prod --enabled-state Disabled

curl.exe -sIL "https://ep-omnix-amhff7fwg8azbucj.b02.azurefd.net/"

# Re-enable
az afd origin update -g rg-omnix-shared --profile-name afd-omnix `
  --origin-group-name og-omnix-mendix --origin-name origin-prod --enabled-state Enabled
```

---

## Test 3 — Force failover by NSG block (most realistic)

```powershell
# Block FD probes
az network nsg rule update -g rg-omnix-prod --nsg-name nsg-omnix-prod-snet-aks-nodes `
  -n AllowAfdBackend --access Deny

# Restore
az network nsg rule update -g rg-omnix-prod --nsg-name nsg-omnix-prod-snet-aks-nodes `
  -n AllowAfdBackend --access Allow
```

---

## Quick reference

| Resource | Value |
|---|---|
| Public URL | https://ep-omnix-amhff7fwg8azbucj.b02.azurefd.net/ |
| Mendix admin user | `MxAdmin` |
| Mendix admin password | `Demo!Password1` |
| Prod LB IP | 4.149.147.18 |
| DR LB IP | 64.236.173.86 |
| AFD profile | `afd-omnix` (rg-omnix-shared) |
| AFD endpoint | `ep-omnix` |
| Origin group | `og-omnix-mendix` |
| Origins | `origin-prod` (P1), `origin-dr` (P2) |
| Probe | HEAD `/`, 30s, 2-of-4 |
| Restoration delay | 10 min |
| Expected RTO | 30–90 s (auto) |
| Expected RPO | N/A in this demo (independent postgres in each region) |

---

## What's still needed for true stateful DR

- SQL Failover Group (currently both SQL servers are in centralus, so FG can't be created without relocating DR SQL to eastus2)
- Storage GRS (currently LRS)

These are deferred for the showcase — Front Door layer is fully functional today.
