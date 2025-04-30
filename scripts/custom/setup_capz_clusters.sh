#!/bin/bash

#####################################################################
# CAPZ (Cluster API Provider for Azure) Cluster Setup Script
#
# This script sets up a development environment for CAPZ by:
# 1. Configuring Azure identities and resources
# 2. Setting up container registry access
# 3. Creating an AKS management cluster
# 4. Configuring Kubernetes and Tilt for development
#
# Prerequisites:
# - Azure CLI installed and authenticated
# - Docker installed and running
# - kubectl installed
# - CAPZ repository cloned (run this from repo root)
#####################################################################

# Parse command-line arguments
usage() {
    echo "Usage: $0 -s <AZURE_SUBSCRIPTION_ID> -t <AZURE_TENANT_ID> -r <RESOURCE_GROUP_NAME_PREFIX> [-l <AZURE_LOCATION>]"
    echo
    echo "Required arguments:"
    echo "  -s, --subscription-id    Azure Subscription ID"
    echo "  -t, --tenant-id          Azure Tenant ID"
    echo "  -r, --rg-prefix          Resource Group Name Prefix"
    echo
    echo "Optional arguments:"
    echo "  -l, --location           Azure Location (default: polandcentral)"
    echo "  -h, --help               Display this help message"
    exit 1
}

# Default location
AZURE_LOCATION="polandcentral"

# Parse arguments
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -s|--subscription-id)
            AZURE_SUBSCRIPTION_ID="$2"
            shift 2
            ;;
        -t|--tenant-id)
            AZURE_TENANT_ID="$2"
            shift 2
            ;;
        -r|--rg-prefix)
            RESOURCE_GROUP_NAME_PREFIX="$2"
            shift 2
            ;;
        -l|--location)
            AZURE_LOCATION="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate required arguments
if [ -z "$AZURE_SUBSCRIPTION_ID" ] || [ -z "$AZURE_TENANT_ID" ] || [ -z "$RESOURCE_GROUP_NAME_PREFIX" ]; then
    echo "ERROR: Required parameters are missing."
    usage
fi

# Export the variables
export AZURE_SUBSCRIPTION_ID
export AZURE_TENANT_ID

# Display configuration
echo "Using the following configuration:"
echo "  Subscription ID: $AZURE_SUBSCRIPTION_ID"
echo "  Tenant ID:       $AZURE_TENANT_ID"
echo "  RG Prefix:       $RESOURCE_GROUP_NAME_PREFIX"
echo "  Location:        $AZURE_LOCATION"

# Verify Azure CLI login status
echo "Verifying Azure CLI login status..."
ACCOUNT_INFO=$(az account show 2>/dev/null)
if [ $? -ne 0 ]; then
    echo "You are not logged in to Azure CLI. Logging in now..."
    az login --tenant "$AZURE_TENANT_ID"
else
    CURRENT_SUBSCRIPTION=$(echo $ACCOUNT_INFO | jq -r '.id')
    if [ "$CURRENT_SUBSCRIPTION" != "$AZURE_SUBSCRIPTION_ID" ]; then
        echo "Setting Azure subscription to $AZURE_SUBSCRIPTION_ID..."
        az account set --subscription "$AZURE_SUBSCRIPTION_ID"
    else
        echo "Already using correct Azure subscription."
    fi
fi

#####################################################################
# 0. VM SKU AVAILABILITY VERIFICATION
#####################################################################
echo "Checking VM SKU availability in ${AZURE_LOCATION}..."

# Check Standard_B2s availability
echo "Checking availability of Standard_B2s..."
SKU_B2S_OUTPUT=$(az vm list-skus -l ${AZURE_LOCATION} -s Standard_B2s --output table)

# Check if output contains "None" in the Restrictions column for virtualMachines
if ! echo "$SKU_B2S_OUTPUT" | grep -q "virtualMachines.*Standard_B2s"; then
    echo "ERROR: Standard_B2s SKU is not available in ${AZURE_LOCATION}!"
    echo "Please choose a different location with this SKU available."
    exit 1
fi

# Extract zones from the output
ZONES_B2S=$(echo "$SKU_B2S_OUTPUT" | grep "virtualMachines.*Standard_B2s" | awk '{print $4}')
if [ -z "${ZONES_B2S}" ]; then
    echo "WARNING: Standard_B2s is available but not in specific zones in ${AZURE_LOCATION}."
else
    echo "Standard_B2s is available in zones: ${ZONES_B2S}"
fi

# Check Standard_D4s_v3 availability
echo "Checking availability of Standard_D4s_v3..."
SKU_D4SV3_OUTPUT=$(az vm list-skus -l ${AZURE_LOCATION} -s Standard_D4s_v3 --output table)

# Check if output contains "None" in the Restrictions column for virtualMachines
if ! echo "$SKU_D4SV3_OUTPUT" | grep -q "virtualMachines.*Standard_D4s_v3"; then
    echo "ERROR: Standard_D4s_v3 SKU is not available in ${AZURE_LOCATION}!"
    echo "Please choose a different location with this SKU available."
    exit 1
fi

# Extract zones from the output
ZONES_D4SV3=$(echo "$SKU_D4SV3_OUTPUT" | grep "virtualMachines.*Standard_D4s_v3" | awk '{print $4}')
if [ -z "${ZONES_D4SV3}" ]; then
    echo "WARNING: Standard_D4s_v3 is available but not in specific zones in ${AZURE_LOCATION}."
else
    echo "Standard_D4s_v3 is available in zones: ${ZONES_D4SV3}"
fi

echo "VM SKU verification completed successfully."

#####################################################################
# 1. AZURE RESOURCE CONFIGURATION
#####################################################################
# Generate a unique resource group name based on timestamp
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
RESOURCE_GROUP_NAME="${RESOURCE_GROUP_NAME_PREFIX}-capz-rg-${TIMESTAMP}"
echo "Using uniquely generated resource group name: ${RESOURCE_GROUP_NAME}"

# Check if resource group exists, create it if it doesn't
echo "Checking if resource group ${RESOURCE_GROUP_NAME} exists..."
if ! az group show --name ${RESOURCE_GROUP_NAME} > /dev/null 2>&1; then
    echo "Resource group ${RESOURCE_GROUP_NAME} doesn't exist. Creating it now in ${AZURE_LOCATION}..."
    az group create --name ${RESOURCE_GROUP_NAME} --location ${AZURE_LOCATION}
    if [ $? -eq 0 ]; then
        echo "Resource group created successfully."
    else
        echo "ERROR: Failed to create resource group!"
        exit 1
    fi
else
    echo "Resource group ${RESOURCE_GROUP_NAME} already exists."
fi

# Generate a name for the user-managed identity
USER_IDENTITY_NAME="${RESOURCE_GROUP_NAME_PREFIX}-user-identity-${TIMESTAMP}"
echo "Creating user-managed identity: ${USER_IDENTITY_NAME}"

# Create a user-managed identity in the resource group
echo "Creating user-managed identity in resource group ${RESOURCE_GROUP_NAME}..."
IDENTITY_JSON=$(az identity create \
  --name ${USER_IDENTITY_NAME} \
  --resource-group ${RESOURCE_GROUP_NAME} \
  --location ${AZURE_LOCATION} \
  --query '{clientId:clientId,principalId:principalId,resourceId:id}' \
  -o json)

if [ $? -eq 0 ]; then
    echo "User-managed identity created successfully."
    
    # Extract identity details
    AZURE_CLIENT_ID_USER_ASSIGNED_IDENTITY=$(echo ${IDENTITY_JSON} | jq -r '.clientId')
    AZURE_OBJECT_ID_USER_ASSIGNED_IDENTITY=$(echo ${IDENTITY_JSON} | jq -r '.principalId')
    AZURE_USER_ASSIGNED_IDENTITY_RESOURCE_ID=$(echo ${IDENTITY_JSON} | jq -r '.resourceId')
    
    echo "Identity Client ID: ${AZURE_CLIENT_ID_USER_ASSIGNED_IDENTITY}"
    echo "Identity Principal ID: ${AZURE_OBJECT_ID_USER_ASSIGNED_IDENTITY}"
    echo "Identity Resource ID: ${AZURE_USER_ASSIGNED_IDENTITY_RESOURCE_ID}"
    
    # Update environment variables with the new identity
    export USER_IDENTITY=${USER_IDENTITY_NAME}
    export AZURE_CLIENT_ID_USER_ASSIGNED_IDENTITY=${AZURE_CLIENT_ID_USER_ASSIGNED_IDENTITY}
    export AZURE_CLIENT_ID="${AZURE_CLIENT_ID_USER_ASSIGNED_IDENTITY}"
    export AZURE_OBJECT_ID_USER_ASSIGNED_IDENTITY=${AZURE_OBJECT_ID_USER_ASSIGNED_IDENTITY}
    export AZURE_USER_ASSIGNED_IDENTITY_RESOURCE_ID=${AZURE_USER_ASSIGNED_IDENTITY_RESOURCE_ID}
else
    echo "ERROR: Failed to create user-managed identity!"
    exit 1
fi

# Generate a name for the Azure Container Registry
# ACR names must be globally unique, between 5-50 characters, and contain only letters and numbers
ACR_NAME="${RESOURCE_GROUP_NAME_PREFIX}acr${TIMESTAMP}"
# Ensure name is lowercase and without special characters
ACR_NAME=$(echo $ACR_NAME | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')
# Ensure name isn't longer than 50 characters
ACR_NAME=$(echo $ACR_NAME | cut -c 1-50)

echo "Creating Azure Container Registry: ${ACR_NAME}"

# Create an Azure Container Registry in the same resource group
echo "Creating Azure Container Registry in resource group ${RESOURCE_GROUP_NAME}..."
ACR_JSON=$(az acr create \
  --name ${ACR_NAME} \
  --resource-group ${RESOURCE_GROUP_NAME} \
  --location ${AZURE_LOCATION} \
  --sku Standard \
  --query '{loginServer:loginServer,id:id}' \
  -o json)

if [ $? -eq 0 ]; then
    echo "Azure Container Registry created successfully."
    
    # Extract registry details
    ACR_LOGIN_SERVER=$(echo ${ACR_JSON} | jq -r '.loginServer')
    ACR_ID=$(echo ${ACR_JSON} | jq -r '.id')
    
    echo "ACR Login Server: ${ACR_LOGIN_SERVER}"
    echo "ACR ID: ${ACR_ID}"
    
    # Update environment variables with the new ACR
    export REGISTRY="${ACR_LOGIN_SERVER}"
    
    # Log in to ACR using token authentication and capture the token
    echo "Logging into Azure Container Registry with token authentication..."
    TOKEN_RESPONSE=$(az acr login -n ${ACR_NAME} --expose-token)
    
    if [ $? -eq 0 ]; then
        # Extract username and access token from response
        ACR_USERNAME="00000000-0000-0000-0000-000000000000"
        ACCESS_TOKEN=$(echo ${TOKEN_RESPONSE} | jq -r '.accessToken')
        
        echo "ACR authentication successful."
        
        # Login to Docker with the obtained access token
        echo "Logging into Docker with the access token..."
        echo ${ACCESS_TOKEN} | docker login ${ACR_LOGIN_SERVER} -u ${ACR_USERNAME} --password-stdin
        
        if [ $? -eq 0 ]; then
            echo "Docker login successful."
            echo "You can now push images to ${ACR_LOGIN_SERVER}"
        else
            echo "ERROR: Failed to Docker login!"
            exit 1
        fi
    else
        echo "ERROR: Failed to login to Azure Container Registry!"
        exit 1
    fi
else
    echo "ERROR: Failed to create Azure Container Registry!"
    exit 1
fi

#####################################################################
# 2. AZURE IDENTITY CONFIGURATION
#####################################################################
# VM sizes for control plane and worker nodes
export AZURE_CONTROL_PLANE_MACHINE_TYPE="Standard_D4s_v3"
export AZURE_NODE_MACHINE_TYPE="Standard_D4s_v3"
export AKS_NODE_VM_SIZE="Standard_D4s_v3"

# Cluster identity settings
export AZURE_CLUSTER_IDENTITY_SECRET_NAME="cluster-identity-secret"
export CLUSTER_IDENTITY_NAME="cluster-identity"
export AZURE_CLUSTER_IDENTITY_SECRET_NAMESPACE="default"

#####################################################################
# 3. CONTAINER REGISTRY SETUP AND VALIDATION
#####################################################################
# Test ACR access by explicitly logging in and retrieving token
echo "Verifying ACR access with token-based authentication..."
TOKEN_RESPONSE=$(az acr login -n ${REGISTRY} --expose-token)
ACR_USERNAME="00000000-0000-0000-0000-000000000000"
ACCESS_TOKEN=$(echo ${TOKEN_RESPONSE} | jq -r '.accessToken')

# Login to Docker with the obtained access token
echo "Logging into Docker with the access token..."
echo ${ACCESS_TOKEN} | docker login ${REGISTRY} -u ${ACR_USERNAME} --password-stdin

# Testing image push capability
echo "Testing image push capability..."
docker tag hello-world ${REGISTRY}/hello-world:1
docker push ${REGISTRY}/hello-world:1
if [ $? -eq 0 ]; then
    echo "Image push successful."
else
    echo "ERROR: Image push failed!"
    exit 1
fi
# Clean up the pushed image
docker rmi ${REGISTRY}/hello-world:1
if [ $? -eq 0 ]; then
    echo "Image removed successfully."
else
    echo "ERROR: Failed to remove the image!"
    exit 1
fi

#####################################################################
# 4. MANAGEMENT CLUSTER CREATION
#####################################################################
# Log in to Azure Container Registry
echo "Logging into Azure Container Registry..."
# Using token-based authentication for ACR login via make
make acr-login
# Build required modules
echo "Building modules..."
make modules

# Create AKS management cluster
echo "Creating AKS management cluster..."
make clean generate aks-create

#####################################################################
# 5. KUBERNETES CONFIGURATION
#####################################################################
# Verify current kubectl context
echo "Current kubectl context:"
kubectl config current-context

# Set kubeconfig to the newly created cluster
echo "Setting kubeconfig to the AKS management cluster..."
export KUBECONFIG=$PWD/aks-mgmt.config

# Verify the context switched correctly
echo "Verifying kubectl context after configuration:"
kubectl config current-context

#####################################################################
# 6. DEVELOPMENT ENVIRONMENT SETUP
#####################################################################
# Start Tilt for development workflow
echo "Starting Tilt development environment..."
make tilt-up