# Export File Inventory from Log Analytics Workspace

## Overview

The `Export-FileInventoryFromLAW.ps1` script exports file inventory data from an Azure Log Analytics Workspace to CSV files. It overcomes the 64MB export limit in the Azure Portal by using batch-based pagination, allowing you to export millions of records.

## Features

- **Batch Processing**: Exports data in configurable batches (default: 100,000 records per batch)
- **Progress Tracking**: Displays real-time progress with ETA
- **Retry Logic**: Automatically retries failed queries with exponential backoff
- **Filtering**: Filter by date range, storage account, or file share
- **File Combining**: Optionally combine all batch files into a single CSV

## Prerequisites

1. **PowerShell 5.1 or later**
2. **Azure PowerShell Modules**:
   - Az.Accounts
   - Az.OperationalInsights

   Install with:
   ```powershell
   Install-Module Az -Scope CurrentUser
   ```

3. **Azure Authentication**: Must be logged into Azure
   ```powershell
   Connect-AzAccount
   ```

4. **Permissions**: Read access to the Log Analytics Workspace

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `WorkspaceId` | Yes | - | Log Analytics Workspace ID (GUID) |
| `BatchSize` | No | 100000 | Records per batch |
| `OutputPath` | No | Current directory | Path for output CSV files |
| `OutputFileName` | No | FileInventory_Export | Base name for output files |
| `CombineFiles` | No | False | Combine batches into single CSV |
| `RemoveBatchFiles` | No | False | Auto-remove batch files after successful merge (validates size first) |
| `StartDate` | No | - | Filter by start date (e.g., "2026-02-01") |
| `EndDate` | No | - | Filter by end date (e.g., "2026-02-12") |
| `StorageAccountFilter` | No | - | Filter by storage account name |
| `FileShareFilter` | No | - | Filter by file share name |
| `QueryTimeoutSeconds` | No | 600 | Query timeout in seconds |

## Step-by-Step Execution

### Step 1: Open PowerShell

Open a PowerShell terminal (PowerShell 5.1 or PowerShell 7+).

### Step 2: Navigate to the Scripts Folder

```powershell
cd "<path-to-repo>\Scripts\LogExport"
```

### Step 3: Connect to Azure (if not already connected)

```powershell
Connect-AzAccount
```

Follow the prompts to authenticate with your Azure credentials.

### Step 4: Find Your Workspace ID

You can find the Workspace ID in the Azure Portal:
1. Navigate to your Log Analytics Workspace
2. Go to **Settings** > **Properties**
3. Copy the **Workspace ID** (GUID format)

Or use PowerShell:
```powershell
Get-AzOperationalInsightsWorkspace | Select-Object Name, CustomerId
```

### Step 5: Run the Export Script

#### Basic Export (all records)
```powershell
.\Export-FileInventoryFromLAW.ps1 -WorkspaceId "<your-workspace-id>"
```

#### Export to a Specific Folder
```powershell
.\Export-FileInventoryFromLAW.ps1 -WorkspaceId "<your-workspace-id>" -OutputPath "C:\temp\exports"
```

#### Export with Date Filter
```powershell
.\Export-FileInventoryFromLAW.ps1 -WorkspaceId "<your-workspace-id>" -StartDate "2026-02-01" -EndDate "2026-02-12"
```

#### Export and Combine into Single File
```powershell
.\Export-FileInventoryFromLAW.ps1 -WorkspaceId "<your-workspace-id>" -OutputPath "C:\temp\exports" -CombineFiles
```

#### Export, Combine, and Auto-Remove Batch Files
```powershell
.\Export-FileInventoryFromLAW.ps1 -WorkspaceId "<your-workspace-id>" -OutputPath "C:\temp\exports" -CombineFiles -RemoveBatchFiles
```

#### Export with Smaller Batch Size (for large files or timeout issues)
```powershell
.\Export-FileInventoryFromLAW.ps1 -WorkspaceId "<your-workspace-id>" -BatchSize 50000
```

#### Export Specific Storage Account
```powershell
.\Export-FileInventoryFromLAW.ps1 -WorkspaceId "<your-workspace-id>" -StorageAccountFilter "mystorageaccount"
```

### Step 6: Monitor Progress

The script displays progress information:
```
[2026-02-12 11:30:25] Processing batch 1 of 276 (records 0 to 100,000)...
[2026-02-12 11:30:50]   Exported 100,000 records to: FileInventory_Export_batch1_20260212_113050.csv
[2026-02-12 11:30:50]   Progress: 0.4% | Total exported: 100,000 | ETA: 01:55:31
```

### Step 7: Access Exported Files

After completion, find your CSV files in the output directory:
- Individual batch files: `FileInventory_Export_batch1_*.csv`, `FileInventory_Export_batch2_*.csv`, etc.
- Combined file (if `-CombineFiles` used): `FileInventory_Export_combined_*.csv`

## Output Format

The exported CSV contains the following columns from the `FileInventory_CL` table:

| Column | Description |
|--------|-------------|
| TimeGenerated | Timestamp when record was created |
| StorageAccount | Azure Storage Account name |
| FileShare | File share name |
| FilePath | Full path of the file |
| FileName | File name |
| FileExtension | File extension (e.g., .pdf, .docx) |
| FileSizeBytes | File size in bytes |
| FileSizeMB | File size in megabytes |
| FileSizeGB | File size in gigabytes |
| LastModified | Last modified date/time |
| Created | Creation date/time |
| AgeInDays | Age since last modified |
| FileHash | MD5 hash of file content |
| FileCategory | Category (Documents, Images, etc.) |
| AgeBucket | Age range bucket |
| SizeBucket | Size range bucket |

## Troubleshooting

### "Not connected to Azure" Error
Run `Connect-AzAccount` before executing the script.

### Query Timeout Errors
- Reduce batch size: `-BatchSize 50000`
- Increase timeout: `-QueryTimeoutSeconds 900`

### Out of Memory Errors
- Reduce batch size: `-BatchSize 25000`
- Export to a local drive instead of OneDrive/network paths

### Missing Records
The script uses row-based pagination. If a batch fails, it will continue with the next batch. Check the output for any "Failed to export batch" messages.

## Performance Expectations

| Records | Approximate Time |
|---------|------------------|
| 1 million | ~20-30 minutes |
| 10 million | ~3-4 hours |
| 27 million | ~6-8 hours |

*Times vary based on network speed, LAW region, and query complexity.*

## Example Complete Workflow

```powershell
# 1. Navigate to scripts folder
cd "<path-to-repo>\Scripts\LogExport"

# 2. Connect to Azure
Connect-AzAccount

# 3. Create output directory
New-Item -ItemType Directory -Path "C:\temp\exports" -Force

# 4. Run export
.\Export-FileInventoryFromLAW.ps1 `
    -WorkspaceId "<your-workspace-id>" `
    -OutputPath "C:\temp\exports" `
    -CombineFiles

# 5. Check exported files
Get-ChildItem "C:\temp\exports" | Format-Table Name, Length
```
