# Azure Automation Hybrid Worker Setup Guide

This guide walks you through setting up an Azure Automation Hybrid Runbook Worker to run the File Inventory Scanner without the 3-hour timeout limitation.

## Overview

| Aspect | Sandbox (Default) | Hybrid Worker |
|--------|-------------------|---------------|
| **Max Runtime** | 3 hours | **Unlimited** |
| **Where it runs** | Azure-managed sandbox | Your VM |
| **Network Access** | Public only | VNet/Private endpoints |
| **Cost** | Automation minutes | VM cost |

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Azure Automation Account                          │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                    AzureFileInventoryScanner Runbook                  │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                      │                                      │
│                    ┌─────────────────┴─────────────────┐                    │
│                    ▼                                   ▼                    │
│           ┌─────────────────┐               ┌─────────────────┐            │
│           │  Azure Sandbox  │               │  Hybrid Worker  │            │
│           │   (3h limit)    │               │  (No limit)     │            │
│           └─────────────────┘               └────────┬────────┘            │
└──────────────────────────────────────────────────────┼──────────────────────┘
                                                       │
                                                       ▼
                                         ┌─────────────────────────┐
                                         │    Windows/Linux VM     │
                                         │  ┌───────────────────┐  │
                                         │  │ Hybrid Worker     │  │
                                         │  │ Extension         │  │
                                         │  └───────────────────┘  │
                                         │  ┌───────────────────┐  │
                                         │  │ Az PowerShell     │  │
                                         │  │ Modules           │  │
                                         │  └───────────────────┘  │
                                         └─────────────────────────┘
                                                       │
                                    ┌──────────────────┼──────────────────┐
                                    ▼                  ▼                  ▼
                             ┌───────────┐      ┌───────────┐      ┌───────────┐
                             │  Storage  │      │    Log    │      │   Azure   │
                             │  Account  │      │ Analytics │      │ Services  │
                             └───────────┘      └───────────┘      └───────────┘
```

## Prerequisites

1. **Azure Subscription** with Contributor access
2. **Azure Automation Account** (already created)
3. **Windows or Linux VM** in Azure (or on-premises)
4. **Network connectivity** from VM to:
   - Azure Storage Account
   - Log Analytics endpoint
   - Azure Automation service

## Permissions Required

### User Permissions (to run the setup)

| Permission | Scope | Purpose |
|------------|-------|---------|
| **Contributor** | Resource Group | Create/manage VMs, Automation resources |
| **User Access Administrator** | Resource Group | Assign RBAC roles to Managed Identity |

### VM Managed Identity Permissions

The Hybrid Worker VM uses a **System-Assigned Managed Identity** to authenticate to Azure services. The following RBAC roles must be assigned:

| Role | Scope | Purpose |
|------|-------|---------|
| **Storage Account Key Operator Service Role** | Target Storage Account(s) | Access storage account keys to list and enumerate files in Azure File Shares |
| **Monitoring Metrics Publisher** | Data Collection Rule (DCR) | Send file inventory data to Log Analytics via the DCR ingestion endpoint |

### Automation Account Permissions

If using the Automation Account's Managed Identity (for sandbox runs), it also needs:

| Role | Scope | Purpose |
|------|-------|---------|
| **Storage Account Key Operator Service Role** | Target Storage Account(s) | Access storage account keys for file enumeration |
| **Monitoring Metrics Publisher** | Data Collection Rule (DCR) | Ingest data to Log Analytics |

### Network/Firewall Requirements

The Hybrid Worker VM requires **outbound HTTPS (443)** access to:

| Endpoint | Purpose |
|----------|---------|
| `*.azure-automation.net` | Azure Automation service communication |
| `*.blob.core.windows.net` | Azure Blob Storage (runbook content) |
| `*.file.core.windows.net` | Azure Files (target file shares) |
| `*.ods.opinsights.azure.com` | Log Analytics data ingestion |
| `*.ingest.monitor.azure.com` | DCR ingestion endpoint |
| `login.microsoftonline.com` | Azure AD authentication |
| `management.azure.com` | Azure Resource Manager |

> 💡 **Tip**: For enhanced security, use **Private Endpoints** for Storage Accounts and Log Analytics workspaces in enterprise environments.

## Step-by-Step Setup

### Step 1: Create or Select a VM

#### Option A: Create a new Azure VM

```powershell
# Variables
$resourceGroup = "rg-file-inventory"
$location = "eastus"
$vmName = "vm-hybrid-worker"
$vmSize = "Standard_D2s_v3"  # 2 vCPUs, 8 GB RAM - sufficient for scanning

# Create VM (Windows Server 2022)
az vm create `
    --resource-group $resourceGroup `
    --name $vmName `
    --image Win2022Datacenter `
    --size $vmSize `
    --admin-username azureuser `
    --admin-password '<YourSecurePassword123!>' `
    --public-ip-sku Standard
```

#### Option B: Use an existing VM
- Windows Server 2016+ or Windows 10/11
- Linux (Ubuntu 18.04+, RHEL 7+, SUSE 12+)
- Minimum 2 vCPUs, 4 GB RAM recommended

### Step 2: Enable System-Assigned Managed Identity on VM

```powershell
# Enable Managed Identity
az vm identity assign `
    --resource-group "rg-file-inventory" `
    --name "vm-hybrid-worker"
```

### Step 3: Install the Hybrid Worker Extension

#### Via Azure Portal:
1. Go to your **Automation Account**
2. Navigate to **Hybrid Worker Groups** (under Process Automation)
3. Click **+ Create hybrid worker group**
4. Enter a name (e.g., `file-inventory-workers`)
5. Click **Add machines** → Select your VM
6. Azure will automatically install the extension

#### Via Azure CLI:

```powershell
# Variables
$automationAccount = "aa-file-inventory"
$resourceGroup = "rg-file-inventory"
$vmName = "vm-hybrid-worker"
$workerGroupName = "file-inventory-workers"

# Get Automation Account details
$aaInfo = az automation account show `
    --name $automationAccount `
    --resource-group $resourceGroup `
    --query "{id:id, location:location}" `
    -o json | ConvertFrom-Json

# Create Hybrid Worker Group
az automation hrwg create `
    --automation-account-name $automationAccount `
    --resource-group $resourceGroup `
    --name $workerGroupName

# Add VM to the Hybrid Worker Group (installs extension automatically)
az automation hrwg hrw create `
    --automation-account-name $automationAccount `
    --resource-group $resourceGroup `
    --hybrid-runbook-worker-group-name $workerGroupName `
    --name $vmName `
    --vm-resource-id "/subscriptions/<subscription-id>/resourceGroups/$resourceGroup/providers/Microsoft.Compute/virtualMachines/$vmName"
```

### Step 4: Install PowerShell Modules on the VM

Connect to the VM (RDP for Windows) and run:

```powershell
# Run as Administrator
# Install required Az modules
Install-Module -Name Az.Accounts -Force -AllowClobber
Install-Module -Name Az.Storage -Force -AllowClobber

# Verify installation
Get-Module -Name Az.Accounts -ListAvailable
Get-Module -Name Az.Storage -ListAvailable
```

### Step 5: Grant RBAC Permissions to VM's Managed Identity

```powershell
# Get VM's Managed Identity Principal ID
$vmPrincipalId = az vm show `
    --resource-group "rg-file-inventory" `
    --name "vm-hybrid-worker" `
    --query identity.principalId `
    -o tsv

# Grant Storage Account Key Operator on target storage account
az role assignment create `
    --assignee $vmPrincipalId `
    --role "Storage Account Key Operator Service Role" `
    --scope "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<storage-account>"

# Grant Monitoring Metrics Publisher on DCR
az role assignment create `
    --assignee $vmPrincipalId `
    --role "Monitoring Metrics Publisher" `
    --scope "/subscriptions/<sub-id>/resourceGroups/rg-file-inventory/providers/Microsoft.Insights/dataCollectionRules/<dcr-name>"
```

### Step 6: Run the Runbook on Hybrid Worker

#### Via Azure Portal:
1. Go to **Automation Account** → **Runbooks**
2. Select **AzureFileInventoryScanner**
3. Click **Start**
4. In **Run Settings**, select **Run on: Hybrid Worker**
5. Choose your worker group: `file-inventory-workers`
6. Enter parameters and click **OK**

#### Via PowerShell:

```powershell
# Start runbook on Hybrid Worker
Start-AzAutomationRunbook `
    -ResourceGroupName "rg-file-inventory" `
    -AutomationAccountName "aa-file-inventory" `
    -Name "AzureFileInventoryScanner" `
    -RunOn "file-inventory-workers" `
    -Parameters @{
        StorageAccountName = "mystorageaccount"
        StorageAccountResourceGroup = "my-storage-rg"
        SubscriptionId = "00000000-0000-0000-0000-000000000000"
        SkipHashComputation = $true
    }
```

### Step 7: Create a Schedule (Optional)

```powershell
# Create weekly schedule
$schedule = New-AzAutomationSchedule `
    -ResourceGroupName "rg-file-inventory" `
    -AutomationAccountName "aa-file-inventory" `
    -Name "WeeklyInventoryScan-HybridWorker" `
    -StartTime (Get-Date).AddDays(1).Date.AddHours(2) `
    -WeekInterval 1 `
    -DaysOfWeek Sunday

# Link runbook to schedule with Hybrid Worker
Register-AzAutomationScheduledRunbook `
    -ResourceGroupName "rg-file-inventory" `
    -AutomationAccountName "aa-file-inventory" `
    -RunbookName "AzureFileInventoryScanner" `
    -ScheduleName "WeeklyInventoryScan-HybridWorker" `
    -RunOn "file-inventory-workers" `
    -Parameters @{
        StorageAccountName = "mystorageaccount"
        StorageAccountResourceGroup = "my-storage-rg"
        SubscriptionId = "00000000-0000-0000-0000-000000000000"
        SkipHashComputation = $true
    }
```

## Troubleshooting

### Check Hybrid Worker Status

```powershell
# List hybrid workers
az automation hrwg hrw list `
    --automation-account-name "aa-file-inventory" `
    --resource-group "rg-file-inventory" `
    --hybrid-runbook-worker-group-name "file-inventory-workers"
```

### Common Issues

| Issue | Solution |
|-------|----------|
| **Worker offline** | Check VM is running and has network connectivity |
| **Module not found** | Install Az modules on the VM |
| **Authentication failed** | Verify Managed Identity is enabled and has RBAC roles |
| **Job stuck in queue** | Check hybrid worker service is running on VM |

### View Logs on the VM

- **Windows**: Event Viewer → Applications and Services Logs → Microsoft → Automation
- **Linux**: `/var/opt/microsoft/omsagent/log/`

## VM Sizing Recommendations

| File Share Size | Recommended VM Size | Est. Cost/month |
|-----------------|---------------------|-----------------|
| < 1 TB | Standard_B2s (2 vCPU, 4 GB) | ~$30 |
| 1-5 TB | Standard_D2s_v3 (2 vCPU, 8 GB) | ~$70 |
| 5-10 TB | Standard_D4s_v3 (4 vCPU, 16 GB) | ~$140 |
| > 10 TB | Standard_D8s_v3 (8 vCPU, 32 GB) | ~$280 |

💡 **Tip**: Use a **Spot VM** for significant cost savings (up to 90%) if your scan can tolerate interruptions.

## Cost Optimization

1. **Auto-shutdown**: Configure VM to shut down after scans complete
2. **Spot Instances**: Use for non-time-critical scans
3. **Right-sizing**: Start small and scale up if needed
4. **Reserved Instances**: If running continuously

## Next Steps

After setup, verify with a small test:

```powershell
# Test with a small share first
Start-AzAutomationRunbook `
    -ResourceGroupName "rg-file-inventory" `
    -AutomationAccountName "aa-file-inventory" `
    -Name "AzureFileInventoryScanner" `
    -RunOn "file-inventory-workers" `
    -Parameters @{
        StorageAccountName = "mystorageaccount"
        StorageAccountResourceGroup = "my-storage-rg"
        SubscriptionId = "00000000-0000-0000-0000-000000000000"
        FileShareNames = "small-test-share"
        SkipHashComputation = $true
    }
```
