# ALB Controller (Application Gateway for Containers) — install on the cluster

The ALB Controller runs in the cluster and provisions the AGC frontend on demand from Gateway / HTTPRoute resources.

## One-time prerequisites (per cluster)

1. Connect kubectl from the jump VM:

   ```powershell
   az aks get-credentials --resource-group rg-omnix-dev --name aks-omnix-dev
   kubelogin convert-kubeconfig -l azurecli
   ```

2. Create the alb-system namespace + identity binding (uses the AKS kubelet
   identity by default; the Helm chart manages the RBAC):

   ```powershell
   helm repo add application-gateway-kubernetes-ingress https://raw.githubusercontent.com/Azure/AKS-Application-Gateway-for-Containers/main/charts/
   helm repo update
   helm install alb-controller oci://mcr.microsoft.com/application-lb/charts/alb-controller `
     --namespace alb-system --create-namespace `
     --version 1.7.9 `
     --set albController.namespace=alb-system
   ```

3. Verify:
   ```powershell
   kubectl get pods -n alb-system
   ```

After this, any `Gateway` resource with `gatewayClassName: azure-alb-external`
will provision an AGC frontend automatically.

The `scripts/deploy-sample-app.ps1` wraps all of this.
