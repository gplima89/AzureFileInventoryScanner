# Azure File Storage Inventory Scanner

[![Azure](https://img.shields.io/badge/Azure-Automation-0078D4?logo=microsoftazure)](https://azure.microsoft.com/en-us/products/automation/)
[![PowerShell](https://img.shields.io/badge/PowerShell-7.x-5391FE?logo=powershell)](https://docs.microsoft.com/en-us/powershell/)
[![Log Analytics](https://img.shields.io/badge/Log%20Analytics-DCR-orange)](https://docs.microsoft.com/en-us/azure/azure-monitor/logs/data-collector-api)

An Azure Automation runbook that performs comprehensive inventory scanning of Azure File Storage accounts and sends the data to Log Analytics for analysis, reporting, and lifecycle management.

## 📋 Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Step-by-Step Implementation Guide](#step-by-step-implementation-guide)
- [Configuration](#configuration)
- [Usage](#usage)
- [Hybrid Runbook Worker (Large Scale)](#hybrid-runbook-worker-large-scale)
- [Sample Queries](#sample-queries)
- [Troubleshooting](#troubleshooting)
- [Validation Script](#validation-script)
- [Contributing](#contributing)
- [License](#license)

## Overview

The Azure File Storage Inventory Scanner is designed to scan Azure File Shares of any size (optimized for 2TB+ shares) and collect detailed metadata about every file. The data is sent to a Log Analytics workspace where you can:

- **Analyze storage usage** by file type, age, and size
- **Identify duplicate files** using MD5 hash comparison
- **Track file lifecycle** and identify stale data
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
| `FileInventory_LogAnalyticsStreamName` | `Custom-<TableName>_CL` |
| `FileInventory_LogAnalyticsTableName` | `<TableName>_CL` |

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

## Step-by-Step Implementation Guide

This guide walks you through setting up the Azure File Inventory Scanner from scratch.

### Step 1: Create Resource Group

```powershell
# Using Azure CLI
az group create --name rg-file-inventory --location eastus

# Or using PowerShell
New-AzResourceGroup -Name "rg-file-inventory" -Location "eastus"
```

### Step 2: Create Log Analytics Workspace

```powershell
# Using Azure CLI
az monitor log-analytics workspace create \
    --resource-group rg-file-inventory \
    --workspace-name law-file-inventory \
    --retention-time 90

# Or using PowerShell
New-AzOperationalInsightsWorkspace `
    -ResourceGroupName "rg-file-inventory" `
    -Name "law-file-inventory" `
    -Location "eastus" `
    -RetentionInDays 90
```

### Step 3: Create Custom Log Analytics Table

**Option A: Via Azure Portal**
1. Navigate to your Log Analytics workspace
2. Go to **Settings** → **Tables** → **Create** → **New custom log (DCR-based)**
3. Enter table name (e.g., `FileInventory_CL`)
4. Upload or paste the schema from `Templates/file-inventory-table-schema.json`

**Option B: Via Azure CLI**
```bash
# Create the table using REST API
az rest --method PUT \
    --url "https://management.azure.com/subscriptions/<Sub-ID>/resourceGroups/rg-file-inventory/providers/Microsoft.OperationalInsights/workspaces/law-file-inventory/tables/FileInventory_CL?api-version=2022-10-01" \
    --body @Templates/file-inventory-table-schema.json
```

### Step 4: Create Data Collection Endpoint (DCE)

```powershell
# Using Azure CLI
az monitor data-collection endpoint create \
    --name dce-file-inventory \
    --resource-group rg-file-inventory \
    --location eastus \
    --public-network-access Enabled

# Get the DCE logs ingestion endpoint (save this for later)
az monitor data-collection endpoint show \
    --name dce-file-inventory \
    --resource-group rg-file-inventory \
    --query logsIngestion.endpoint -o tsv
```

### Step 5: Create Data Collection Rule (DCR)

> ⚠️ **CRITICAL**: The DCR `transformKql` must explicitly project all columns. Using just `"source"` will result in empty columns!

**Option A: Using the Template (Recommended)**

1. Copy `Templates/dcr-fresh.json` and replace placeholders:
   - `<Subscription-ID>` → Your subscription ID
   - `<Resource-Group>` → Your resource group name
   - `<DCE-Name>` → Your DCE name
   - `<Workspace-Name>` → Your Log Analytics workspace name
   - `<Table-Name>` → Your table name (without `_CL` suffix)

2. Create the DCR:
```bash
az rest --method PUT \
    --url "https://management.azure.com/subscriptions/<Sub-ID>/resourceGroups/rg-file-inventory/providers/Microsoft.Insights/dataCollectionRules/dcr-file-inventory?api-version=2022-06-01" \
    --body @dcr-configured.json
```

3. Get the DCR immutable ID (save this for later):
```bash
az monitor data-collection rule show \
    --name dcr-file-inventory \
    --resource-group rg-file-inventory \
    --query immutableId -o tsv
```

**Option B: Via Azure Portal**
1. Navigate to **Monitor** → **Data Collection Rules** → **Create**
2. Name: `dcr-file-inventory`
3. Platform Type: **Custom**
4. Data Collection Endpoint: Select your DCE
5. Add data source → **Custom**
6. Configure stream with schema from template
7. **Important**: In transform, use explicit column projection

### Step 6: Create Automation Account

```powershell
# Create Automation Account
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

# Get the Principal ID (save for RBAC assignments)
az automation account show \
    --name aa-file-inventory \
    --resource-group rg-file-inventory \
    --query identity.principalId -o tsv
```

### Step 7: Assign RBAC Permissions

```powershell
# Store the Principal ID
$principalId = "<principal-id-from-step-6>"

# 1. Storage Account Key Operator (on storage account to scan)
az role assignment create \
    --assignee $principalId \
    --role "Storage Account Key Operator Service Role" \
    --scope "/subscriptions/<Sub-ID>/resourceGroups/<Storage-RG>/providers/Microsoft.Storage/storageAccounts/<Storage-Account>"

# 2. Monitoring Metrics Publisher (on DCR)
az role assignment create \
    --assignee $principalId \
    --role "Monitoring Metrics Publisher" \
    --scope "/subscriptions/<Sub-ID>/resourceGroups/rg-file-inventory/providers/Microsoft.Insights/dataCollectionRules/dcr-file-inventory"
```

### Step 8: Import PowerShell Modules

In Azure Portal:
1. Navigate to your Automation Account
2. Go to **Shared Resources** → **Modules** → **Browse gallery**
3. Search and import:
   - `Az.Accounts` (v2.x or later)
   - `Az.Storage` (v5.x or later)

Or via PowerShell:
```powershell
# Import Az.Accounts
Import-AzAutomationModule `
    -ResourceGroupName "rg-file-inventory" `
    -AutomationAccountName "aa-file-inventory" `
    -Name "Az.Accounts" `
    -ContentLinkUri "https://www.powershellgallery.com/api/v2/package/Az.Accounts"

# Import Az.Storage
Import-AzAutomationModule `
    -ResourceGroupName "rg-file-inventory" `
    -AutomationAccountName "aa-file-inventory" `
    -Name "Az.Storage" `
    -ContentLinkUri "https://www.powershellgallery.com/api/v2/package/Az.Storage"
```

### Step 9: Create Automation Variables

```powershell
# DCE Endpoint
az automation variable create \
    --name FileInventory_LogAnalyticsDceEndpoint \
    --resource-group rg-file-inventory \
    --automation-account-name aa-file-inventory \
    --value '"https://dce-file-inventory.<region>-1.ingest.monitor.azure.com"'

# DCR Immutable ID
az automation variable create \
    --name FileInventory_LogAnalyticsDcrImmutableId \
    --resource-group rg-file-inventory \
    --automation-account-name aa-file-inventory \
    --value '"dcr-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"'

# Stream Name (MUST use hyphen after Custom-, NOT underscore)
az automation variable create \
    --name FileInventory_LogAnalyticsStreamName \
    --resource-group rg-file-inventory \
    --automation-account-name aa-file-inventory \
    --value '"Custom-FileInventory_CL"'

# Table Name
az automation variable create \
    --name FileInventory_LogAnalyticsTableName \
    --resource-group rg-file-inventory \
    --automation-account-name aa-file-inventory \
    --value '"FileInventory_CL"'
```

> ⚠️ **Important**: Stream name format is `Custom-<TableName>_CL` with a **hyphen** after "Custom", not an underscore!

### Step 10: Import and Publish the Runbook

```powershell
# Create the runbook
az automation runbook create \
    --name AzureFileInventoryScanner \
    --resource-group rg-file-inventory \
    --automation-account-name aa-file-inventory \
    --type PowerShell72

# Upload the script content
az automation runbook replace-content \
    --name AzureFileInventoryScanner \
    --resource-group rg-file-inventory \
    --automation-account-name aa-file-inventory \
    --content @Runbooks/AzureFileInventoryScanner.ps1

# Publish the runbook
az automation runbook publish \
    --name AzureFileInventoryScanner \
    --resource-group rg-file-inventory \
    --automation-account-name aa-file-inventory
```

### Step 11: Validate Your Setup

Run the validation script to verify everything is configured correctly:

```powershell
.\Scripts\Test-FileInventorySetup.ps1 `
    -SubscriptionId "<Subscription-ID>" `
    -ResourceGroupName "rg-file-inventory" `
    -AutomationAccountName "aa-file-inventory" `
    -WorkspaceName "law-file-inventory" `
    -DceName "dce-file-inventory" `
    -DcrName "dcr-file-inventory" `
    -TableName "FileInventory" `
    -RunIngestionTest
```

### Step 12: Run Your First Scan

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

### Common Issues and Solutions

| Issue | Possible Cause | Solution |
|-------|----------------|----------|
| **Authentication failed** | Managed Identity not enabled | Enable System-Assigned Managed Identity on Automation Account |
| **Access denied to storage** | Missing RBAC permissions | Assign `Storage Account Key Operator Service Role` to MI |
| **Data not appearing in Log Analytics** | DCR misconfigured | Run validation script; check DCE endpoint, DCR immutable ID |
| **Data ingests but columns are empty** | DCR transform using just `"source"` | Use explicit column projection in `transformKql` (see below) |
| **Stream name error** | Wrong stream name format | Must be `Custom-<TableName>_CL` with **hyphen** after Custom |
| **Job timeout (3 hours)** | File share too large | Use Hybrid Worker (see section below) |
| **Out of memory** | Batch size too large | Reduce `BatchSize` parameter to 250-500 |

### Critical: DCR Transform Configuration

> ⚠️ **This is the #1 cause of data appearing empty in Log Analytics!**

When you create a DCR separately from the table, you **must** use explicit column projection in the `transformKql`. Simply using `"source"` will NOT work.

**❌ WRONG (columns will be empty):**
```json
"transformKql": "source"
```

**✅ CORRECT (all columns populated):**
```json
"transformKql": "source | project TimeGenerated, StorageAccount, FileShare, FilePath, FileName, FileExtension, FileSizeBytes, FileSizeMB, FileSizeGB, LastModified, Created, AgeInDays, FileHash, IsDuplicate, DuplicateCount, DuplicateGroupId, FileCategory, AgeBucket, SizeBucket, ScanTimestamp, ExecutionId"
```

### Verify Data Ingestion

```kusto
// Check if records are being ingested
<TableName>_CL
| where TimeGenerated > ago(1h)
| take 10

// Check which columns have data
<TableName>_CL
| where TimeGenerated > ago(1h)
| project TimeGenerated, StorageAccount, FileShare, FileName
| take 5

// Verify by ExecutionId
<TableName>_CL
| where ExecutionId == "your-execution-id"
| count
```

### Check Runbook Job Status

```powershell
# Get recent job status
Get-AzAutomationJob -ResourceGroupName "rg-file-inventory" `
    -AutomationAccountName "aa-file-inventory" `
    -RunbookName "AzureFileInventoryScanner" | 
    Select-Object -First 5 | 
    Format-Table Status, StartTime, EndTime
```

### Verify RBAC Assignments

```powershell
# Get Automation Account principal ID
$principalId = (az automation account show `
    --name aa-file-inventory `
    --resource-group rg-file-inventory `
    --query identity.principalId -o tsv)

# List all role assignments
az role assignment list --assignee $principalId --output table
```

### Debug DCR Configuration

```bash
# View DCR details
az monitor data-collection rule show \
    --name dcr-file-inventory \
    --resource-group rg-file-inventory

# Check the immutable ID
az monitor data-collection rule show \
    --name dcr-file-inventory \
    --resource-group rg-file-inventory \
    --query immutableId -o tsv
```

## Validation Script

The repository includes a comprehensive validation script that checks all components of your setup.

### Features

The `Test-FileInventorySetup.ps1` script performs 28 tests across these categories:

| Category | Tests |
|----------|-------|
| **Authentication** | Azure login, subscription access |
| **DCE Validation** | Existence, endpoint accessibility, configuration |
| **DCR Validation** | Existence, immutable ID, stream configuration, transform |
| **Table Validation** | Existence, schema columns, column count |
| **Schema Comparison** | DCR stream vs Table schema alignment |
| **Automation Account** | Existence, managed identity, required variables |
| **RBAC Validation** | Monitoring Metrics Publisher role on DCR |
| **Ingestion Test** | Optional end-to-end data ingestion verification |

### Usage

```powershell
# Basic validation (no ingestion test)
.\Scripts\Test-FileInventorySetup.ps1 `
    -SubscriptionId "<Subscription-ID>" `
    -ResourceGroupName "<Resource-Group>" `
    -AutomationAccountName "<Automation-Account>" `
    -WorkspaceName "<Workspace-Name>" `
    -DceName "<DCE-Name>" `
    -DcrName "<DCR-Name>" `
    -TableName "<Table-Name>"

# Full validation with ingestion test
.\Scripts\Test-FileInventorySetup.ps1 `
    -SubscriptionId "<Subscription-ID>" `
    -ResourceGroupName "<Resource-Group>" `
    -AutomationAccountName "<Automation-Account>" `
    -WorkspaceName "<Workspace-Name>" `
    -DceName "<DCE-Name>" `
    -DcrName "<DCR-Name>" `
    -TableName "<Table-Name>" `
    -RunIngestionTest
```

### Sample Output

```
============================================================
Azure File Inventory Scanner - Setup Validation
============================================================
Subscription: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
Resource Group: rg-file-inventory
Started: 2026-01-27 10:30:00
============================================================

--- Authentication Tests ---
[PASS] Azure Authentication
       Logged in as: user@domain.com
[PASS] Subscription Access
       Subscription: My Subscription

--- DCE Tests ---
[PASS] DCE Exists
       DCE 'dce-file-inventory' found
[PASS] DCE Endpoint Accessible
       Endpoint: https://dce-file-inventory.eastus-1.ingest.monitor.azure.com

--- DCR Tests ---
[PASS] DCR Exists
       DCR 'dcr-file-inventory' found
[PASS] DCR Immutable ID
       ID: dcr-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
[PASS] DCR Transform Configured
       Transform explicitly projects all columns

--- Table Tests ---
[PASS] Table Exists
       Table 'FileInventory_CL' found
[PASS] Table Schema Valid
       Found 21 columns (expected 21)

--- RBAC Tests ---
[PASS] Automation Account Has DCR Role
       'Monitoring Metrics Publisher' role assigned

============================================================
Summary: 27/28 tests passed
============================================================
```

### Interpreting Results

| Result | Meaning | Action |
|--------|---------|--------|
| `[PASS]` | Test succeeded | No action needed |
| `[FAIL]` | Test failed | Review the details and fix the issue |
| `[WARN]` | Warning condition | May work but review recommended |

### Common Validation Failures

| Failure | Fix |
|---------|-----|
| DCR Transform uses 'source' only | Update DCR with explicit column projection |
| Missing RBAC role on DCR | Assign `Monitoring Metrics Publisher` to Automation Account MI |
| Schema mismatch | Recreate table or DCR to align schemas |
| Variable not found | Create missing Automation Account variable |
| Ingestion test failed | Check DCE endpoint URL and authentication |

## Hybrid Runbook Worker (Large Scale)

For file shares larger than 2TB or when scans exceed 3 hours, use a **Hybrid Runbook Worker** to bypass Azure Automation's 3-hour limit.

### When to Use Hybrid Worker

| Scenario | Recommendation |
|----------|----------------|
| File shares < 2TB | Standard Azure Automation (cloud-based) |
| File shares > 2TB | Hybrid Runbook Worker |
| Scans exceeding 3 hours | Hybrid Runbook Worker |
| Need private network access | Hybrid Runbook Worker |

### Key Benefits

| Feature | Description |
|---------|-------------|
| **No Timeout** | Runs until completion (no 3-hour limit) |
| **Same Script** | Uses the exact same PowerShell runbook |
| **Private Access** | Can access storage via private endpoints |
| **Local Compute** | Runs on your VM with dedicated resources |

### Quick Setup

```powershell
# 1. Create a Windows VM (or use existing)
# 2. Run the setup script from the HybridWorker folder
.\HybridWorker\Setup-HybridWorker.ps1 `
    -SubscriptionId "<Sub-ID>" `
    -ResourceGroupName "rg-file-inventory" `
    -AutomationAccountName "aa-file-inventory" `
    -HybridWorkerGroupName "hw-file-inventory" `
    -VmName "vm-hybrid-worker" `
    -VmResourceGroupName "rg-hybrid-worker"
```

### Running on Hybrid Worker

```powershell
# Start runbook on Hybrid Worker
Start-AzAutomationRunbook -Name "AzureFileInventoryScanner" `
    -ResourceGroupName "rg-file-inventory" `
    -AutomationAccountName "aa-file-inventory" `
    -RunOn "hw-file-inventory" `
    -Parameters @{
        StorageAccountName = "mystorageaccount"
        StorageAccountResourceGroup = "my-rg"
        SubscriptionId = "00000000-0000-0000-0000-000000000000"
        SkipHashComputation = $true
    }
```

📖 **Full documentation:** [HybridWorker/SETUP-GUIDE.md](HybridWorker/SETUP-GUIDE.md)

## File Structure

```
AzureFileInventoryScanner/
├── README.md                               # This file
├── LICENSE                                 # MIT License
├── .gitignore                              # Git ignore rules
├── Runbooks/
│   └── AzureFileInventoryScanner.ps1       # Main runbook script (PowerShell 7.x)
├── Templates/
│   ├── file-inventory-table-schema.json    # Log Analytics table schema
│   └── dcr-fresh.json                      # Data Collection Rule template
├── Scripts/
│   ├── Deploy-AzureInfrastructure.ps1      # Automated deployment script
│   ├── Configure-AutomationVariables.ps1   # Variable configuration helper
│   └── Test-FileInventorySetup.ps1         # Comprehensive validation script
├── Queries/
│   └── sample-queries.kql                  # Sample KQL queries for analysis
└── HybridWorker/
    ├── SETUP-GUIDE.md                      # Hybrid Worker setup documentation
    └── Setup-HybridWorker.ps1              # Hybrid Worker deployment script
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
