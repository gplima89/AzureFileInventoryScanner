# Azure File Storage Inventory Scanner

[![Azure](https://img.shields.io/badge/Azure-Automation-0078D4?logo=microsoftazure)](https://azure.microsoft.com/en-us/products/automation/)
[![PowerShell](https://img.shields.io/badge/PowerShell-7.x-5391FE?logo=powershell)](https://docs.microsoft.com/en-us/powershell/)
[![Log Analytics](https://img.shields.io/badge/Log%20Analytics-DCR-orange)](https://docs.microsoft.com/en-us/azure/azure-monitor/logs/data-collector-api)

An Azure Automation runbook that performs comprehensive inventory scanning of Azure File Storage accounts and sends the data to Log Analytics for analysis, reporting, and lifecycle management.

## 📋 Table of Contents

- [Overview](#overview)
- [Implementation Options](#implementation-options)
- [Features](#features)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Detailed Setup Guide](#detailed-setup-guide)
- [Configuration](#configuration)
- [Usage](#usage)
- [Durable Functions (Large Scale)](#durable-functions-large-scale)
- [Sample Queries](#sample-queries)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [License](#license)

## Overview

The Azure File Storage Inventory Scanner is designed to scan Azure File Shares of any size (optimized for 2TB+ shares) and collect detailed metadata about every file. The data is sent to a Log Analytics workspace where you can:

- **Analyze storage usage** by file type, age, and size
- **Identify duplicate files** using MD5 hash comparison
- **Track file lifecycle** and identify stale data
- **Generate reports** for compliance and governance
- **Optimize storage costs** by identifying opportunities to archive or delete old files

## Implementation Options

This repository provides **two implementation options** depending on your scale and requirements:

| Option | Best For | Max Runtime | Complexity |
|--------|----------|-------------|------------|
| **[Azure Automation Runbook](Runbooks/)** | Small-medium shares (< 2TB) | 3 hours | Low |
| **[Azure Durable Functions](DurableFunctions/)** | Large shares (2TB+) | Unlimited | Medium |

### When to Use Each Option

**Use Azure Automation Runbook when:**
- File shares are under 2TB
- You want simple setup and management
- Scans complete within 3 hours
- You prefer PowerShell

**Use Azure Durable Functions when:**
- File shares exceed 2TB
- You need parallel processing for faster scans
- Scans may exceed 3 hours
- You need automatic checkpointing and resume capability
- **Generate reports** for compliance and governance
- **Optimize storage costs** by identifying opportunities to archive or delete old files

## Features

| Feature | Description |
|---------|-------------|
| 🔄 **Streaming Processing** | Files are processed during traversal—no full in-memory collection |
| 📦 **Automatic Batching** | Configurable batch sizes with automatic flush to Log Analytics |
| 📄 **Pagination Support** | Handles large directories (5000+ items) efficiently |
| 🔐 **MD5 Hash Computation** | Optional duplicate detection via content hashing |
| 🔁 **Retry Logic** | Exponential backoff for transient errors |
| 🧠 **Memory Management** | Automatic garbage collection to prevent memory exhaustion |
| 🗜️ **Gzip Compression** | Compressed payloads for efficient data transfer |
| ❤️ **Progress Heartbeat** | Regular status updates during long-running scans |
| 🔒 **Managed Identity** | Secure authentication using Azure Managed Identity |

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Azure Automation Account                          │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                    AzureFileInventoryScanner Runbook                  │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │  │
│  │  │   Connect   │→ │    Scan     │→ │   Batch     │→ │    Send     │  │  │
│  │  │   Azure     │  │   Files     │  │  Records    │  │   to LA     │  │  │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘  │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                           │                                    │            │
│                     Managed Identity                    Automation          │
│                           │                            Variables            │
└───────────────────────────┼────────────────────────────────────┼────────────┘
                            │                                    │
                            ▼                                    │
         ┌─────────────────────────────────┐                     │
         │     Azure Storage Account       │                     │
         │  ┌───────────────────────────┐  │                     │
         │  │      File Share 1         │  │                     │
         │  │  ├── folder1/             │  │                     │
         │  │  │   ├── file1.pdf        │  │                     │
         │  │  │   └── file2.docx       │  │                     │
         │  │  └── folder2/             │  │                     │
         │  └───────────────────────────┘  │                     │
         │  ┌───────────────────────────┐  │                     │
         │  │      File Share 2         │  │                     │
         │  └───────────────────────────┘  │                     │
         └─────────────────────────────────┘                     │
                                                                 │
                            ┌────────────────────────────────────┘
                            ▼
         ┌─────────────────────────────────────────────────────────────────┐
         │                    Log Analytics Workspace                      │
         │  ┌───────────────────────────────────────────────────────────┐  │
         │  │              Data Collection Endpoint (DCE)               │  │
         │  └─────────────────────────┬─────────────────────────────────┘  │
         │                            │                                    │
         │  ┌─────────────────────────▼─────────────────────────────────┐  │
         │  │             Data Collection Rule (DCR)                    │  │
         │  │  Stream: Custom-FileInventory_CL                          │  │
         │  └─────────────────────────┬─────────────────────────────────┘  │
         │                            │                                    │
         │  ┌─────────────────────────▼─────────────────────────────────┐  │
         │  │              FileInventory_CL Table                       │  │
         │  │  - StorageAccount, FileShare, FilePath, FileName          │  │
         │  │  - FileSizeBytes, LastModified, Created, AgeInDays        │  │
         │  │  - FileHash, FileCategory, AgeBucket, SizeBucket          │  │
         │  └───────────────────────────────────────────────────────────┘  │
         └─────────────────────────────────────────────────────────────────┘
```

## Prerequisites

### Azure Resources Required

1. **Azure Automation Account** (with System-Assigned Managed Identity enabled)
2. **Azure Storage Account** with File Shares to scan
3. **Log Analytics Workspace**
4. **Data Collection Endpoint (DCE)**
5. **Data Collection Rule (DCR)**

### PowerShell Modules (in Automation Account)

- `Az.Accounts` (v2.x or later)
- `Az.Storage` (v5.x or later)

### Required Permissions

| Resource | Role Assignment | Purpose |
|----------|-----------------|---------|
| Storage Account | `Storage Account Key Operator Service Role` | Read storage account keys |
| Storage Account | `Storage File Data SMB Share Reader` | Read file share contents |
| DCR | `Monitoring Metrics Publisher` | Send data to Log Analytics |

## Quick Start

### 1. Deploy Infrastructure (Automated)

```powershell
# Clone the repository
git clone https://github.com/gplima89/AzureFileInventoryScanner.git
cd AzureFileInventoryScanner

# Run the deployment script
.\Scripts\Deploy-AzureInfrastructure.ps1 `
    -ResourceGroupName "rg-file-inventory" `
    -Location "eastus" `
    -AutomationAccountName "aa-file-inventory" `
    -LogAnalyticsWorkspaceName "law-file-inventory" `
    -StorageAccountName "stfileinventory"
```

### 2. Configure Automation Variables

After deployment, set these variables in your Automation Account:

| Variable Name | Value |
|---------------|-------|
| `FileInventory_LogAnalyticsDceEndpoint` | `https://<dce-name>.<region>.ingest.monitor.azure.com` |
| `FileInventory_LogAnalyticsDcrImmutableId` | `dcr-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| `FileInventory_LogAnalyticsStreamName` | `Custom-FileInventory_CL` |
| `FileInventory_LogAnalyticsTableName` | `FileInventory_CL` |

### 3. Run the Runbook

```powershell
Start-AzAutomationRunbook -Name "AzureFileInventoryScanner" `
    -ResourceGroupName "rg-file-inventory" `
    -AutomationAccountName "aa-file-inventory" `
    -Parameters @{
        StorageAccountName = "mystorageaccount"
        StorageAccountResourceGroup = "my-storage-rg"
        SubscriptionId = "00000000-0000-0000-0000-000000000000"
        SkipHashComputation = $true
    }
```

## Detailed Setup Guide

### Step 1: Create Log Analytics Workspace

```powershell
# Create resource group
az group create --name rg-file-inventory --location eastus

# Create Log Analytics workspace
az monitor log-analytics workspace create \
    --resource-group rg-file-inventory \
    --workspace-name law-file-inventory \
    --retention-time 90
```

### Step 2: Create Custom Table

Use the schema from `Templates/file-inventory-table-schema.json` to create the custom table via Azure Portal or ARM template.

**Via Azure Portal:**
1. Navigate to your Log Analytics workspace
2. Go to **Tables** → **Create** → **New custom log (DCR-based)**
3. Follow the wizard and use the schema from the template

### Step 3: Create Data Collection Endpoint & Rule

```powershell
# Create DCE
az monitor data-collection endpoint create \
    --name dce-file-inventory \
    --resource-group rg-file-inventory \
    --location eastus \
    --public-network-access Enabled

# Create DCR (use the ARM template in Templates folder)
az deployment group create \
    --resource-group rg-file-inventory \
    --template-file Templates/dcr-template.json \
    --parameters dcrName=dcr-file-inventory \
                 workspaceResourceId=/subscriptions/{sub}/resourceGroups/rg-file-inventory/providers/Microsoft.OperationalInsights/workspaces/law-file-inventory
```

### Step 4: Create Automation Account

```powershell
# Create Automation Account with System Managed Identity
az automation account create \
    --name aa-file-inventory \
    --resource-group rg-file-inventory \
    --location eastus \
    --sku Basic

# Enable System Managed Identity
az automation account identity assign \
    --name aa-file-inventory \
    --resource-group rg-file-inventory \
    --identity-type SystemAssigned
```

### Step 5: Assign RBAC Permissions

```powershell
# Get the Managed Identity Principal ID
$principalId = (az automation account show --name aa-file-inventory --resource-group rg-file-inventory --query identity.principalId -o tsv)

# Assign Storage Account Key Operator role
az role assignment create \
    --assignee $principalId \
    --role "Storage Account Key Operator Service Role" \
    --scope /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Storage/storageAccounts/{storage}

# Assign Monitoring Metrics Publisher role on DCR
az role assignment create \
    --assignee $principalId \
    --role "Monitoring Metrics Publisher" \
    --scope /subscriptions/{sub}/resourceGroups/rg-file-inventory/providers/Microsoft.Insights/dataCollectionRules/dcr-file-inventory
```

### Step 6: Import Required Modules

In your Automation Account, import these modules from the gallery:
- `Az.Accounts`
- `Az.Storage`

### Step 7: Import the Runbook

```powershell
# Import runbook
az automation runbook create \
    --name AzureFileInventoryScanner \
    --resource-group rg-file-inventory \
    --automation-account-name aa-file-inventory \
    --type PowerShell \
    --runbook-type PowerShell72

# Upload content
az automation runbook replace-content \
    --name AzureFileInventoryScanner \
    --resource-group rg-file-inventory \
    --automation-account-name aa-file-inventory \
    --content @Runbooks/AzureFileInventoryScanner.ps1

# Publish
az automation runbook publish \
    --name AzureFileInventoryScanner \
    --resource-group rg-file-inventory \
    --automation-account-name aa-file-inventory
```

### Step 8: Create Automation Variables

```powershell
# Create variables (replace with your values)
az automation variable create --name FileInventory_LogAnalyticsDceEndpoint \
    --resource-group rg-file-inventory \
    --automation-account-name aa-file-inventory \
    --value '"https://dce-file-inventory.eastus-1.ingest.monitor.azure.com"'

az automation variable create --name FileInventory_LogAnalyticsDcrImmutableId \
    --resource-group rg-file-inventory \
    --automation-account-name aa-file-inventory \
    --value '"dcr-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"'

az automation variable create --name FileInventory_LogAnalyticsStreamName \
    --resource-group rg-file-inventory \
    --automation-account-name aa-file-inventory \
    --value '"Custom-FileInventory_CL"'

az automation variable create --name FileInventory_LogAnalyticsTableName \
    --resource-group rg-file-inventory \
    --automation-account-name aa-file-inventory \
    --value '"FileInventory_CL"'
```

## Configuration

### Runbook Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `StorageAccountName` | string | Yes | - | Name of the storage account to scan |
| `StorageAccountResourceGroup` | string | Yes | - | Resource group of the storage account |
| `SubscriptionId` | string | Yes | - | Subscription ID |
| `FileShareNames` | string | No | "" | Comma-separated list of shares (empty = all) |
| `MaxFileSizeForHashMB` | int | No | 100 | Max file size for hash computation |
| `SkipHashComputation` | bool | No | false | Skip MD5 hashing for faster scans |
| `BatchSize` | int | No | 500 | Records per batch |
| `ThrottleLimit` | int | No | 4 | Concurrent operations (future use) |
| `DryRun` | bool | No | false | Simulation mode |

### Automation Variables

| Variable | Description |
|----------|-------------|
| `FileInventory_LogAnalyticsDceEndpoint` | Data Collection Endpoint URI |
| `FileInventory_LogAnalyticsDcrImmutableId` | DCR immutable ID |
| `FileInventory_LogAnalyticsStreamName` | Stream name (e.g., `Custom-FileInventory_CL`) |
| `FileInventory_LogAnalyticsTableName` | Table name (e.g., `FileInventory_CL`) |
| `FileInventory_ExcludePatterns` | Comma-separated file patterns to exclude |

## Usage

### Scan All File Shares (Fast Mode - No Hashing)

```powershell
Start-AzAutomationRunbook -Name "AzureFileInventoryScanner" `
    -ResourceGroupName "rg-file-inventory" `
    -AutomationAccountName "aa-file-inventory" `
    -Parameters @{
        StorageAccountName = "mystorageaccount"
        StorageAccountResourceGroup = "my-rg"
        SubscriptionId = "00000000-0000-0000-0000-000000000000"
        SkipHashComputation = $true
    }
```

### Scan Specific File Shares with Duplicate Detection

```powershell
Start-AzAutomationRunbook -Name "AzureFileInventoryScanner" `
    -ResourceGroupName "rg-file-inventory" `
    -AutomationAccountName "aa-file-inventory" `
    -Parameters @{
        StorageAccountName = "mystorageaccount"
        StorageAccountResourceGroup = "my-rg"
        SubscriptionId = "00000000-0000-0000-0000-000000000000"
        FileShareNames = "share1,share2"
        SkipHashComputation = $false
        MaxFileSizeForHashMB = 50
    }
```

### Schedule Regular Scans

```powershell
# Create a schedule for weekly scans
$schedule = New-AzAutomationSchedule `
    -Name "WeeklyInventoryScan" `
    -ResourceGroupName "rg-file-inventory" `
    -AutomationAccountName "aa-file-inventory" `
    -StartTime (Get-Date).AddDays(1).Date.AddHours(2) `
    -WeekInterval 1 `
    -DaysOfWeek Sunday

# Link runbook to schedule
Register-AzAutomationScheduledRunbook `
    -Name "AzureFileInventoryScanner" `
    -ResourceGroupName "rg-file-inventory" `
    -AutomationAccountName "aa-file-inventory" `
    -ScheduleName "WeeklyInventoryScan" `
    -Parameters @{
        StorageAccountName = "mystorageaccount"
        StorageAccountResourceGroup = "my-rg"
        SubscriptionId = "00000000-0000-0000-0000-000000000000"
        SkipHashComputation = $true
    }
```

## Sample Queries

See [`Queries/sample-queries.kql`](Queries/sample-queries.kql) for a comprehensive list of KQL queries. Here are some highlights:

### Storage Overview Dashboard

```kusto
FileInventory_CL
| where TimeGenerated > ago(24h)
| summarize 
    TotalFiles = count(),
    TotalSizeGB = sum(FileSizeGB),
    AvgFileSizeMB = avg(FileSizeMB)
    by StorageAccount, FileShare
| order by TotalSizeGB desc
```

### Find Large Files (> 1GB)

```kusto
FileInventory_CL
| where FileSizeGB > 1
| project StorageAccount, FileShare, FilePath, FileSizeGB, LastModified, AgeInDays
| order by FileSizeGB desc
| take 100
```

### Identify Duplicate Files

```kusto
FileInventory_CL
| where FileHash !in ("SKIPPED", "SKIPPED_TOO_LARGE", "ERROR", "SKIPPED_PERFORMANCE")
| summarize 
    Count = count(), 
    TotalSizeMB = sum(FileSizeMB),
    Files = make_list(FilePath, 10)
    by FileHash
| where Count > 1
| order by TotalSizeMB desc
```

### Files Not Modified in 2+ Years

```kusto
FileInventory_CL
| where AgeInDays > 730
| summarize 
    FileCount = count(), 
    TotalSizeGB = sum(FileSizeGB)
    by StorageAccount, FileShare, FileCategory
| order by TotalSizeGB desc
```

### Storage Distribution by File Type

```kusto
FileInventory_CL
| summarize 
    FileCount = count(), 
    TotalSizeGB = sum(FileSizeGB)
    by FileCategory
| order by TotalSizeGB desc
| render piechart
```

## Troubleshooting

### Common Issues

| Issue | Possible Cause | Solution |
|-------|----------------|----------|
| **Authentication failed** | Managed Identity not enabled | Enable System-Assigned Managed Identity on Automation Account |
| **Access denied to storage** | Missing RBAC permissions | Assign `Storage Account Key Operator Service Role` |
| **Data not appearing in Log Analytics** | DCR misconfigured | Verify DCE endpoint, DCR immutable ID, and stream name |
| **Job timeout** | Very large file shares | Increase job timeout or split into multiple shares |
| **Out of memory** | Batch size too large | Reduce `BatchSize` parameter |

### Checking Logs

```kusto
// Check for scan execution records
FileInventory_CL
| where TimeGenerated > ago(1h)
| summarize count() by ExecutionId, bin(TimeGenerated, 5m)

// Check ingestion latency
FileInventory_CL
| where TimeGenerated > ago(1h)
| extend IngestionDelay = ingestion_time() - TimeGenerated
| summarize avg(IngestionDelay), max(IngestionDelay)
```

### Verifying RBAC Assignments

```powershell
# Check role assignments for Managed Identity
az role assignment list --assignee <principal-id> --output table
```

## Durable Functions (Large Scale)

For file shares larger than 2TB or when scans exceed 3 hours, use the **Azure Durable Functions** implementation.

### Key Benefits

| Feature | Description |
|---------|-------------|
| **No Timeout** | Can run for days if needed |
| **Parallel Processing** | Scan 10+ directories simultaneously |
| **Auto-Checkpointing** | Resumes from last checkpoint on failure |
| **Real-time Status** | API endpoints for progress monitoring |
| **Cost Effective** | Pay only for actual execution time |

### Quick Start

```bash
cd DurableFunctions

# Install dependencies
pip install -r requirements.txt

# Configure (copy template and edit)
cp local.settings.template.json local.settings.json

# Run locally
func start

# Start a scan
curl -X POST http://localhost:7071/api/start-scan \
  -H "Content-Type: application/json" \
  -d '{"storageAccountName": "mystorageaccount", "skipHashComputation": true}'
```

### Deploy to Azure

```powershell
.\DurableFunctions\Deploy-DurableFunctions.ps1 `
    -ResourceGroupName "rg-file-inventory" `
    -Location "eastus" `
    -FunctionAppName "func-file-inventory" `
    -StorageAccountName "stfuncinventory"
```

📖 **Full documentation:** [DurableFunctions/README.md](DurableFunctions/README.md)

## File Structure

```
AzureFileInventoryScanner/
├── README.md                           # This file
├── Runbooks/
│   └── AzureFileInventoryScanner.ps1   # Main runbook script (PowerShell)
├── DurableFunctions/                   # Python Durable Functions (for large shares)
│   ├── README.md                       # Durable Functions documentation
│   ├── function_app.py                 # HTTP triggers
│   ├── requirements.txt                # Python dependencies
│   ├── host.json                       # Function app configuration
│   ├── Deploy-DurableFunctions.ps1     # Deployment script
│   ├── orchestrator_main/              # Main orchestrator
│   ├── orchestrator_file_share/        # Sub-orchestrator per share
│   ├── activity_list_file_shares/      # List shares activity
│   ├── activity_scan_directory/        # Scan directory activity
│   └── activity_send_to_log_analytics/ # Send to LA activity
├── Templates/
│   ├── file-inventory-table-schema.json    # Log Analytics table schema
│   └── dcr-template.json               # Data Collection Rule ARM template
├── Scripts/
│   ├── Deploy-AzureInfrastructure.ps1  # Automated deployment script
│   └── Configure-AutomationVariables.ps1   # Variable configuration helper
├── Queries/
│   └── sample-queries.kql              # Sample KQL queries
└── .gitignore
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Azure File Storage documentation
- Azure Monitor Data Collection API documentation
- Azure Automation best practices

---

**Questions or Issues?** Please open an issue on GitHub.
