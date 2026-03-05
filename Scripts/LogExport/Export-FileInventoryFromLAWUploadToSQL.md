# Export File Inventory from Log Analytics Workspace to SQL MI

## Overview

The `Export-FileInventoryFromLAWUploadToSQL.ps1` script exports data from a Log Analytics Workspace table (default: `FileInventory_CL`) and uploads it directly to an Azure SQL Managed Instance database. It overcomes the 64MB export limit in the Azure Portal by using batch-based cursor pagination, allowing you to export and upload millions of records efficiently using `SqlBulkCopy`.

## Features

- **Batch Processing**: Exports data in configurable batches (default: 100,000 records per batch)
- **SQL Bulk Upload**: Uses `System.Data.SqlClient.SqlBulkCopy` for high-performance inserts
- **Auto Table Creation**: Automatically creates the target SQL table if it doesn't exist
- **Dual Authentication**: Supports Azure AD (token-based) and SQL Authentication
- **Truncate Option**: Optionally truncate the target table before uploading
- **Progress Tracking**: Displays real-time progress with ETA
- **Retry Logic**: Automatically retries failed LAW queries with exponential backoff
- **Filtering**: Filter by date range, storage account, or file share

## Prerequisites

### 1. PowerShell 5.1 or later

### 2. Azure PowerShell Modules

- `Az.Accounts`
- `Az.OperationalInsights`

Install with:
```powershell
Install-Module Az -Scope CurrentUser
```

### 3. Azure Authentication

Must be logged into Azure:
```powershell
Connect-AzAccount
```

### 4. Permissions

- **Log Analytics Workspace**: Read access to the workspace (Log Analytics Reader role or higher)
- **SQL MI (Azure AD auth)**: The Azure AD identity must have access to the target database (e.g., `db_datawriter`, `db_ddladmin` if auto-creating tables)
- **SQL MI (SQL auth)**: A SQL login with `INSERT` permission on the target table (and `CREATE TABLE` / `ALTER` on the schema if auto-creating)

### 5. SQL Managed Instance Network Access

The machine running the script must be able to reach the SQL MI endpoint:
- **Public endpoint**: Ensure the SQL MI public endpoint is enabled and the port (default `3342`) is allowed through NSG/firewall rules
- **Private endpoint**: Ensure the machine has connectivity to the private IP (port `1433`) via VPN, ExpressRoute, or same VNet

### 6. .NET Framework / .NET Runtime

The script uses `System.Data.SqlClient` which is included with .NET Framework on Windows. On PowerShell 7+ (cross-platform), ensure the `System.Data.SqlClient` assembly is available.

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `WorkspaceId` | **Yes** | — | Log Analytics Workspace ID (GUID) |
| `LAWTableName` | No | `FileInventory_CL` | Name of the table in Log Analytics to query |
| `SqlServer` | **Yes** | — | SQL MI server FQDN (e.g., `myinstance.public.xxxxx.database.windows.net`) |
| `SqlDatabase` | **Yes** | — | Target database name |
| `SqlTable` | No | `FileInventory` | Target table name |
| `SqlSchema` | No | `dbo` | SQL schema for the target table |
| `SqlPort` | No | `3342` | SQL MI port (`3342` for public endpoint, `1433` for private) |
| `UseSqlAuth` | No | `$false` | Switch: use SQL Authentication instead of Azure AD |
| `SqlUsername` | When `-UseSqlAuth` | — | SQL login username |
| `SqlPassword` | When `-UseSqlAuth` | — | SQL login password (`SecureString`) |
| `TruncateTable` | No | `$false` | Switch: truncate the target table before inserting |
| `BatchSize` | No | `100000` | Records per LAW query batch |
| `SqlBulkCopyTimeout` | No | `600` | SqlBulkCopy timeout in seconds |
| `SqlBulkCopyBatchSize` | No | `10000` | Internal batch size for SqlBulkCopy writes |
| `StartDate` | No | — | Filter by start date (e.g., `"2026-02-01"`) |
| `EndDate` | No | — | Filter by end date (e.g., `"2026-02-12"`) |
| `StorageAccountFilter` | No | — | Filter by storage account name |
| `FileShareFilter` | No | — | Filter by file share name |
| `QueryTimeoutSeconds` | No | `600` | LAW query timeout in seconds |

## Authentication Methods

### Azure AD (Default)

Uses the current `Az` context to obtain an access token for `https://database.windows.net/`. No additional credentials are needed — the script calls `Get-AzAccessToken` automatically.

**Requirements**:
- Run `Connect-AzAccount` before executing the script
- The signed-in Azure AD identity must be configured as a user in the SQL MI database:

```sql
-- Run on the target database (as an admin)
CREATE USER [user@domain.com] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datawriter ADD MEMBER [user@domain.com];
ALTER ROLE db_ddladmin ADD MEMBER [user@domain.com];  -- Only if auto-creating tables
```

### SQL Authentication (`-UseSqlAuth`)

Uses traditional SQL login credentials. Pass the username as a string and the password as a `SecureString`.

```powershell
-UseSqlAuth -SqlUsername "myuser" -SqlPassword (ConvertTo-SecureString "mypassword" -AsPlainText -Force)
```

## Step-by-Step Execution

### Step 1: Open PowerShell

Open a PowerShell terminal (PowerShell 5.1 or PowerShell 7+).

### Step 2: Navigate to the Scripts Folder

```powershell
cd "<path-to-repo>\Scripts\LogExport"
```

### Step 3: Connect to Azure

```powershell
Connect-AzAccount
```

Follow the prompts to authenticate with your Azure credentials.

### Step 4: Find Your Workspace ID

You can find the Workspace ID in the Azure Portal:
1. Navigate to your **Log Analytics Workspace**
2. Go to **Settings** > **Properties**
3. Copy the **Workspace ID** (GUID format)

Or use PowerShell:
```powershell
Get-AzOperationalInsightsWorkspace | Select-Object Name, CustomerId
```

### Step 5: Find Your SQL MI Connection Details

In the Azure Portal:
1. Navigate to your **SQL Managed Instance**
2. Go to **Overview**
3. Note the **Host** name (e.g., `myinstance.public.xxxxx.database.windows.net`)
4. Check if **Public endpoint** is enabled under **Networking** (port `3342`) or use the private endpoint (port `1433`)

### Step 6: Run the Script

#### Basic Upload with Azure AD Auth (all records)
```powershell
.\Export-FileInventoryFromLAWUploadToSQL.ps1 `
    -WorkspaceId "<your-workspace-id>" `
    -SqlServer "myinstance.public.xxxxx.database.windows.net" `
    -SqlDatabase "FileInventoryDB"
```

#### Upload with Truncate (clear table first)
```powershell
.\Export-FileInventoryFromLAWUploadToSQL.ps1 `
    -WorkspaceId "<your-workspace-id>" `
    -SqlServer "myinstance.public.xxxxx.database.windows.net" `
    -SqlDatabase "FileInventoryDB" `
    -TruncateTable
```

#### Upload from a Custom LAW Table
```powershell
.\Export-FileInventoryFromLAWUploadToSQL.ps1 `
    -WorkspaceId "<your-workspace-id>" `
    -LAWTableName "MyCustomTable_CL" `
    -SqlServer "myinstance.public.xxxxx.database.windows.net" `
    -SqlDatabase "FileInventoryDB"
```

#### Upload with Custom Table Name and Schema
```powershell
.\Export-FileInventoryFromLAWUploadToSQL.ps1 `
    -WorkspaceId "<your-workspace-id>" `
    -SqlServer "myinstance.public.xxxxx.database.windows.net" `
    -SqlDatabase "FileInventoryDB" `
    -SqlTable "MyCustomTable" `
    -SqlSchema "inventory" `
    -TruncateTable
```

#### Upload with SQL Authentication
```powershell
.\Export-FileInventoryFromLAWUploadToSQL.ps1 `
    -WorkspaceId "<your-workspace-id>" `
    -SqlServer "myinstance.public.xxxxx.database.windows.net" `
    -SqlDatabase "FileInventoryDB" `
    -UseSqlAuth `
    -SqlUsername "myuser" `
    -SqlPassword (ConvertTo-SecureString "mypassword" -AsPlainText -Force)
```

#### Upload with Private Endpoint
```powershell
.\Export-FileInventoryFromLAWUploadToSQL.ps1 `
    -WorkspaceId "<your-workspace-id>" `
    -SqlServer "myinstance.xxxxx.database.windows.net" `
    -SqlPort 1433 `
    -SqlDatabase "FileInventoryDB"
```

#### Upload with Date Filter
```powershell
.\Export-FileInventoryFromLAWUploadToSQL.ps1 `
    -WorkspaceId "<your-workspace-id>" `
    -SqlServer "myinstance.public.xxxxx.database.windows.net" `
    -SqlDatabase "FileInventoryDB" `
    -StartDate "2026-02-01" -EndDate "2026-02-12" `
    -TruncateTable
```

#### Upload a Specific Storage Account with Smaller Batches
```powershell
.\Export-FileInventoryFromLAWUploadToSQL.ps1 `
    -WorkspaceId "<your-workspace-id>" `
    -SqlServer "myinstance.public.xxxxx.database.windows.net" `
    -SqlDatabase "FileInventoryDB" `
    -StorageAccountFilter "mystorageaccount" `
    -BatchSize 50000
```

### Step 7: Monitor Progress

The script displays progress information:
```
[2026-02-12 11:30:25] Processing batch 1 (exported 0 of ~27,600,000 so far)...
[2026-02-12 11:30:30]   Converting 100,000 records to DataTable...
[2026-02-12 11:30:32]   Table [dbo].[FileInventory] verified/created
[2026-02-12 11:30:33]   Uploading batch to SQL MI...
[2026-02-12 11:30:50]   Uploaded 100,000 records to SQL MI
[2026-02-12 11:30:50]   Progress: 0.4% | Total uploaded: 100,000 | ETA: 01:55:31
```

## SQL Table Schema

When the script auto-creates the table, all columns are created as `NVARCHAR(MAX)` to accommodate any data returned by the LAW query. The columns are derived dynamically from the first batch of results.

Typical columns from the `FileInventory_CL` table:

| Column | Description |
|--------|-------------|
| `TimeGenerated` | Timestamp when the record was ingested |
| `StorageAccount` | Azure Storage Account name |
| `FileShare` | File share name |
| `FilePath` | Full path of the file |
| `FileName` | File name |
| `FileExtension` | File extension (e.g., `.pdf`, `.docx`) |
| `FileSizeBytes` | File size in bytes |
| `FileSizeMB` | File size in megabytes |
| `FileSizeGB` | File size in gigabytes |
| `LastModified` | Last modified date/time |
| `Created` | Creation date/time |
| `AgeInDays` | Age since last modified |
| `FileHash` | MD5 hash of file content |
| `FileCategory` | Category (Documents, Images, etc.) |
| `AgeBucket` | Age range bucket |
| `SizeBucket` | Size range bucket |

> **Tip**: After the initial load, you can alter column types in SQL to optimize storage and query performance (e.g., convert `FileSizeBytes` to `BIGINT`, `TimeGenerated` to `DATETIME2`, etc.).

## Troubleshooting

### "Not connected to Azure" Error
Run `Connect-AzAccount` before executing the script.

### "SqlUsername is required when using SQL Authentication" Error
When using `-UseSqlAuth`, both `-SqlUsername` and `-SqlPassword` must be provided.

### SQL MI Connection Failures
- **Public endpoint**: Verify the public endpoint is enabled on the SQL MI and port `3342` is allowed in the NSG/firewall
- **Private endpoint**: Ensure network connectivity (VPN/ExpressRoute/VNet peering) and use `-SqlPort 1433`
- **Azure AD auth**: Verify the signed-in identity has been added as a user in the SQL MI database
- **SQL auth**: Verify the login credentials and that the SQL login is mapped to the target database

### LAW Query Timeout Errors
- Reduce batch size: `-BatchSize 50000`
- Increase timeout: `-QueryTimeoutSeconds 900`

### Out of Memory Errors
- Reduce batch size: `-BatchSize 25000`
- Reduce `SqlBulkCopyBatchSize`: `-SqlBulkCopyBatchSize 5000`

### SqlBulkCopy Timeout
- Increase bulk copy timeout: `-SqlBulkCopyTimeout 1200`
- Reduce batch size to send less data per operation: `-BatchSize 50000`

### 3 Consecutive Failures
The script stops after 3 consecutive batch failures. Check the error messages, resolve the issue (network, permissions, timeout), and re-run. If `-TruncateTable` is used, existing data will be cleared — consider running without it and deduplicating afterwards if resuming a partial upload.

### Table Already Exists with Different Schema
The auto-create logic uses `IF NOT EXISTS` — it will not alter an existing table. If the existing table has different columns than the LAW query output, the `SqlBulkCopy` column mapping will fail. Either:
- Drop and re-create the table manually, or
- Ensure the existing table columns match the LAW query output

## Performance Expectations

| Records | Approximate Time |
|---------|------------------|
| 1 million | ~25-40 minutes |
| 10 million | ~4-6 hours |
| 27 million | ~8-12 hours |

*Times vary based on network speed, LAW region, SQL MI tier, and batch size. SQL MI General Purpose tier may be slower than Business Critical for bulk inserts.*

## Example Complete Workflow

```powershell
# 1. Navigate to scripts folder
cd "<path-to-repo>\Scripts\LogExport"

# 2. Connect to Azure
Connect-AzAccount

# 3. Run upload (Azure AD auth, truncate first)
.\Export-FileInventoryFromLAWUploadToSQL.ps1 `
    -WorkspaceId "<your-workspace-id>" `
    -SqlServer "myinstance.public.xxxxx.database.windows.net" `
    -SqlDatabase "FileInventoryDB" `
    -SqlTable "FileInventory" `
    -TruncateTable

# 4. Verify data in SQL MI
# Connect to the SQL MI database and run:
#   SELECT COUNT(*) FROM [dbo].[FileInventory]
#   SELECT TOP 10 * FROM [dbo].[FileInventory]
```
