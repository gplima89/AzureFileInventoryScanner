# Azure File Share Tier Analysis – Implementation & Usage Guide

## Overview

The **Analyze-FileShareTiers.ps1** script analyzes Azure File Share access patterns and recommends optimal access tiers (Hot, Cool, Transaction Optimized, or Premium) to reduce costs. It calculates **actual estimated monthly costs** for each tier using region-specific pricing from the [Azure Retail Prices API](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices), classifies transactions into Microsoft's 5 billing categories (Write, List, Read, Other/Protocol, Delete), and outputs a single consolidated CSV report with dollar-amount cost comparisons and actionable tier-change recommendations.

When only `-WorkspaceId` is provided (without `-StorageAccountName`), the script **auto-discovers all storage accounts** streaming StorageFileLogs to that workspace and analyzes every file share across all of them in a single run.

---

## Prerequisites

| Requirement | Details |
|---|---|
| **PowerShell** | 7.x+ recommended (5.1 works) |
| **Az PowerShell Modules** | `Az.Accounts`, `Az.Storage`, `Az.Monitor`, `Az.OperationalInsights` |
| **Azure Permissions** | Reader (or higher) on the target Storage Account and Resource Group |
| **Log Analytics (optional)** | A Log Analytics Workspace receiving **StorageFileLogs** from the target storage account |

---

## Step 1 – Install Required Modules

Open a PowerShell terminal and install the Azure modules if you haven't already:

```powershell
Install-Module Az -Scope CurrentUser -Force
```

Or install only the specific modules needed:

```powershell
Install-Module Az.Accounts, Az.Storage, Az.Monitor, Az.OperationalInsights -Scope CurrentUser -Force
```

---

## Step 2 – Authenticate to Azure

```powershell
# Interactive login
Connect-AzAccount

# If you need a specific tenant
Connect-AzAccount -TenantId "<your-tenant-id>"
```

Verify the correct subscription is selected:

```powershell
Get-AzContext
```

If you need to switch subscriptions:

```powershell
Set-AzContext -SubscriptionId "<subscription-id>"
```

---

## Step 3 – (Recommended) Enable StorageFileLogs Diagnostic Setting

For the most accurate per-file-share metrics, enable the **StorageFileLogs** diagnostic setting on your storage account and send logs to a Log Analytics Workspace.

### Via Azure Portal

1. Navigate to your **Storage Account** → **Monitoring** → **Diagnostic settings**.
2. Under the **file** sub-resource, click **+ Add diagnostic setting**.
3. Check **StorageFileLogs** (under logs).
4. Select **Send to Log Analytics workspace** and choose your workspace.
5. Save.

### Via Azure CLI

```bash
az monitor diagnostic-settings create \
  --name "FileShareLogs" \
  --resource "<storage-account-resource-id>/fileServices/default" \
  --workspace "<log-analytics-workspace-resource-id>" \
  --logs '[{"category":"StorageFileLogs","enabled":true}]'
```

> **Note:** Allow at least 15–30 minutes for logs to start flowing into the workspace after enabling the diagnostic setting.

---

## Step 4 – Run the Script

Navigate to the script folder and execute it. Below are several usage examples.

### Auto-Discover All Storage Accounts (recommended for multi-account analysis)

Provide only the `-WorkspaceId` to auto-discover and analyze **all** storage accounts streaming logs to the workspace:

```powershell
.\Analyze-FileShareTiers.ps1 `
  -WorkspaceId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
  -TimeRangeDays 7
```

This produces a single consolidated CSV with results for every file share across all discovered storage accounts.

### Single Storage Account (with Log Analytics)

```powershell
.\Analyze-FileShareTiers.ps1 `
  -StorageAccountName "mystorageaccount" `
  -ResourceGroupName "my-resource-group" `
  -WorkspaceId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

### Analyze a Specific File Share

```powershell
.\Analyze-FileShareTiers.ps1 `
  -StorageAccountName "mystorageaccount" `
  -ResourceGroupName "my-resource-group" `
  -WorkspaceId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
  -FileShareName "myfileshare"
```

### Analyze the Last 7 Days (single account)

```powershell
.\Analyze-FileShareTiers.ps1 `
  -StorageAccountName "mystorageaccount" `
  -ResourceGroupName "my-resource-group" `
  -WorkspaceId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
  -TimeRangeDays 7
```

### Without Log Analytics (Azure Monitor fallback)

```powershell
.\Analyze-FileShareTiers.ps1 `
  -StorageAccountName "mystorageaccount" `
  -ResourceGroupName "my-resource-group"
```

### Specify a Custom Output Path

```powershell
.\Analyze-FileShareTiers.ps1 `
  -WorkspaceId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
  -TimeRangeDays 7 `
  -OutputPath "C:\Reports"
```

---

## Step 5 – Review the Output

The script produces:

1. **Console output** – A summary table with current tier, recommended tier, estimated monthly cost per tier, and whether action is needed, followed by detailed cost comparison and implementation commands.
2. **CSV report** – Exported to the script directory (or the path specified by `-OutputPath`). Includes columns for estimated cost per tier (`EstCost_TransOpt`, `EstCost_Hot`, `EstCost_Cool`, `CurrentEstCost`) and all 5 billing transaction categories. The filename follows the pattern:
   ```
   FileShareTierAnalysis_<StorageAccountName>_<yyyyMMdd_HHmmss>.csv
   # or for auto-discover mode:
   FileShareTierAnalysis_AllAccounts_<yyyyMMdd_HHmmss>.csv
   ```

---

## Step 6 – Apply Tier Changes (if recommended)

The script output includes ready-to-use commands for each recommendation. Example:

### PowerShell

```powershell
Update-AzRmStorageShare `
  -ResourceGroupName "my-resource-group" `
  -StorageAccountName "mystorageaccount" `
  -Name "myfileshare" `
  -AccessTier "Cool"
```

### Azure CLI

```bash
az storage share-rm update \
  --resource-group "my-resource-group" \
  --storage-account "mystorageaccount" \
  --name "myfileshare" \
  --access-tier "Cool"
```

> **Important:** Changing a file share's access tier is an online operation with no downtime, but it may take a few minutes to take effect. Review the estimated savings in the report before applying changes.

---

## Parameters Reference

| Parameter | Required | Default | Description |
|---|---|---|---|
| `StorageAccountName` | No | — | Name of a specific Azure Storage Account. If omitted with `-WorkspaceId`, auto-discovers all accounts from LAW |
| `ResourceGroupName` | No | — | Resource group containing the storage account. Required when `-StorageAccountName` is specified |
| `WorkspaceId` | No | — | Log Analytics Workspace ID. When provided alone, auto-discovers all storage accounts streaming logs |
| `SubscriptionId` | No | Current context | Target subscription ID |
| `TimeRangeHours` | No | `24` | Number of hours to analyze |
| `TimeRangeDays` | No | — | Number of days to analyze (overrides `TimeRangeHours`) |
| `FileShareName` | No | All shares | Analyze a specific file share only |
| `OutputPath` | No | Script directory | Path to save the CSV report |

> **Note:** You must provide at least `-WorkspaceId` or both `-StorageAccountName` and `-ResourceGroupName`.

---

## Tier Recommendation Logic

The script calculates the **actual estimated monthly cost** for each tier (Transaction Optimized, Hot, Cool) using real Azure pricing and recommends the cheapest option. This follows [Microsoft's official guidance](https://learn.microsoft.com/en-us/azure/storage/files/understanding-billing) rather than using arbitrary thresholds.

### How It Works

1. **Pricing retrieval** – The script queries the [Azure Retail Prices API](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices) for the storage account's region and redundancy type (LRS, ZRS, GRS, etc.). If the API is unavailable, it falls back to hardcoded East US LRS approximate rates.

2. **Transaction categorization** – Transactions from StorageFileLogs are classified into Microsoft's 5 billing categories:

   | Billing Category | Operations | Pricing |
   |---|---|---|
   | **Write** | Create, Put, Set, Copy, Lease, Flush, Rename | Per 10K operations |
   | **List** | List, QueryDirectory | Per 10K operations |
   | **Read** | Get, Query, Read | Per 10K operations |
   | **Other/Protocol** | Close, Negotiate, SessionSetup, TreeConnect, etc. | Per 10K operations |
   | **Delete** | Delete | **Always free** |

3. **Cost calculation** – For each tier, the monthly cost is computed as:

   ```
   Monthly Cost = (Data GiB × Storage Rate)
                + (Metadata GiB × Metadata Rate)      # Hot/Cool only
                + (Write Ops / 10K × Write Rate)
                + (List Ops / 10K × List Rate)
                + (Read Ops / 10K × Read Rate)
                + (Other Ops / 10K × Other Rate)
                + (Data Read GiB × Retrieval Rate)     # Cool only
   ```

4. **Recommendation** – The tier with the lowest estimated monthly cost is recommended, with actual dollar savings shown.

### Key Pricing Differences Between Tiers

| Cost Component | Transaction Optimized | Hot | Cool |
|---|---|---|---|
| Data at rest (per GiB) | Highest | Medium | Lowest |
| Metadata (per GiB) | Included | Charged separately | Charged separately |
| Write/List transactions | Lowest | Medium | Highest |
| Read transactions | Low | Low | Low |
| Other/Protocol | Low | Low | Medium |
| Data retrieval | Free | Free | Charged per GiB |
| Delete | Free | Free | Free |

> **Note:** If the Azure Retail Prices API is unreachable, the script falls back to a heuristic based on transactions-per-GB ratio (>100 = TransactionOptimized, 10-100 = Hot, <10 = Cool) and flags that pricing data is unavailable.

> Premium file shares are excluded from recommendations since their tier is fixed (SSD-based).

---

## Troubleshooting

| Issue | Solution |
|---|---|
| `Not connected to Azure` | Run `Connect-AzAccount` before executing the script |
| `Storage account not found` | Verify the storage account name, resource group, and subscription |
| `No metrics found in Log Analytics` | Ensure **StorageFileLogs** diagnostic setting is enabled and logs have had time to ingest (15–30 min) |
| `Failed to import Az modules` | Run `Install-Module Az -Scope CurrentUser -Force` |
| `Access denied` | Ensure you have at least **Reader** role on the storage account and resource group |
