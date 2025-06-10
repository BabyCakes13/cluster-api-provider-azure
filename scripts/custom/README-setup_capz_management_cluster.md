# CAPZ Management Cluster Setup Script

This script automates the setup of a complete [Cluster API Provider for Azure (CAPZ)](https://github.com/kubernetes-sigs/cluster-api-provider-azure) management cluster and development environment on Azure.

## What It Does
- **Checks prerequisites**: Ensures required tools (`az`, `docker`, `kubectl`, `jq`, `curl`, `make`, `sed`) are installed.
- **Azure authentication**: Verifies Azure CLI login and sets the correct subscription and tenant.
- **VM SKU check**: Confirms required VM SKUs are available in your chosen Azure region.
- **Resource provisioning**:
  - Creates a unique Azure resource group
  - Creates a user-managed identity
  - Creates an Azure Container Registry (ACR)
- **Container registry setup**: Authenticates Docker with ACR and tests image push/pull.
- **Cluster identity and machine type setup**: Sets environment variables for cluster identity and VM sizes.
- **Management cluster creation**: Builds and deploys a new AKS management cluster using CAPZ.
- **Kubernetes configuration**: Sets kubeconfig to the new cluster and verifies context.
- **Development environment**: Starts [Tilt](https://tilt.dev/) for live development workflows.
- **Cleanup on failure**: Optionally deletes all created resources if the script fails.

## Prerequisites
- Azure CLI installed and authenticated
- Docker installed and running
- kubectl installed
- jq, curl, make, sed installed
- CAPZ repository cloned (run this script from the repo root)
- Sufficient Azure permissions to create resource groups, identities, and registries

## Usage
Make the script executable if needed:

```zsh
chmod +x scripts/custom/setup_capz_management_cluster.sh
```

Run the script with your Azure details:

```zsh
./scripts/custom/setup_capz_management_cluster.sh \
  -s <AZURE_SUBSCRIPTION_ID> \
  -t <AZURE_TENANT_ID> \
  -r <RESOURCE_GROUP_NAME_PREFIX> \
  -l <AZURE_LOCATION> \
  --cleanup-on-failure
```

- `-s` or `--subscription-id`: Your Azure Subscription ID
- `-t` or `--tenant-id`: Your Azure Tenant ID
- `-r` or `--rg-prefix`: Prefix for the resource group name (e.g., `mycapz`)
- `-l` or `--location`: (Optional) Azure region (default: `eastus`)
- `--cleanup-on-failure`: (Optional) Delete resources if the script fails

**Example:**
```zsh
./scripts/custom/setup_capz_management_cluster.sh \
  -s <AZURE_SUBSCRIPTION_ID> \
  -t <AZURE_TENANT_ID> \
  -r mariavonica-capz-management \
  -l eastus \
  --cleanup-on-failure
```

## What Gets Created
- Azure resource group (with a unique timestamped name)
- User-managed identity
- Azure Container Registry (ACR)
- AKS management cluster (via CAPZ)
- Tilt development environment

## Cleanup
If `--cleanup-on-failure` is provided, the script will delete the resource group and all resources in it if any step fails. Otherwise, you can manually delete the resource group with:

```zsh
az group delete --name <RESOURCE_GROUP_NAME> --yes
```

## Security Warning
**Do NOT modify this script to include credentials or sensitive values.** Never commit secrets or tokens to version control.

## Troubleshooting
- Ensure all prerequisites are installed and available in your `$PATH`.
- Make sure you have sufficient Azure permissions.
- If you encounter quota or SKU errors, try a different Azure region.