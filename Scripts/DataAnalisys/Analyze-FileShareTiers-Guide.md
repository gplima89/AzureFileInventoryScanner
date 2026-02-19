# Azure File Share Tier Analysis – Implementation & Usage Guide

## Overview

The **Analyze-FileShareTiers.ps1** script analyzes Azure File Share access patterns and recommends optimal access tiers (Hot, Cool, Transaction Optimized, or Premium) to reduce costs. It pulls transaction metrics from either a **Log Analytics Workspace** (recommended, per-file-share granularity) or **Azure Monitor** (storage-account level fallback) and outputs a CSV report with actionable tier-change recommendations.

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

### Basic Usage (with Log Analytics – recommended)

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

### Analyze the Last 7 Days

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
  -StorageAccountName "mystorageaccount" `
  -ResourceGroupName "my-resource-group" `
  -WorkspaceId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
  -OutputPath "C:\Reports"
```

---

## Step 5 – Review the Output

The script produces:

1. **Console output** – A summary table with current tier, recommended tier, transactions/day, and whether action is needed, followed by detailed recommendations with implementation commands.
2. **CSV report** – Exported to the script directory (or the path specified by `-OutputPath`). The filename follows the pattern:
   ```
   FileShareTierAnalysis_<StorageAccountName>_<yyyyMMdd_HHmmss>.csv
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
| `StorageAccountName` | Yes | — | Name of the Azure Storage Account to analyze |
| `ResourceGroupName` | Yes | — | Resource group containing the storage account |
| `WorkspaceId` | No | — | Log Analytics Workspace ID (recommended for per-file-share accuracy) |
| `SubscriptionId` | No | Current context | Target subscription ID |
| `TimeRangeHours` | No | `24` | Number of hours to analyze |
| `TimeRangeDays` | No | — | Number of days to analyze (overrides `TimeRangeHours`) |
| `FileShareName` | No | All shares | Analyze a specific file share only |
| `OutputPath` | No | Script directory | Path to save the CSV report |

---

## Tier Recommendation Logic

The script uses transactions per GB per day to recommend tiers:

| Transactions/GB/Day | Recommended Tier | Rationale |
|---|---|---|
| > 100 | Transaction Optimized | High transaction volume — minimize per-transaction cost |
| 10 – 100 | Hot | Balanced workload — moderate storage and transaction costs |
| < 10 | Cool | Infrequent access — minimize storage cost |
| 0 (no transactions) | Cool | Dormant share — lowest storage cost |

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
