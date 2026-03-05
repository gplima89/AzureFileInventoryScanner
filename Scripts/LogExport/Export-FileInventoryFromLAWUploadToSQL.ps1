<#
.SYNOPSIS
    Exports all file inventory data from Log Analytics Workspace to Azure SQL Managed Instance.

.DESCRIPTION
    This script exports data from a specified table (default: FileInventory_CL) in Log Analytics Workspace
    in batches and uploads each batch to a SQL MI database using SqlBulkCopy. It uses
    cursor-based pagination (advancing by TimeGenerated) to efficiently export all records
    regardless of the total data size, without the 500K row limitation of row_number() approaches.

    The script will:
    1. Query the total record count
    2. Connect to SQL MI and prepare the target table (auto-creates if missing)
    3. Optionally truncate the target table
    4. Export data in configurable batch sizes (default 100,000 rows)
    5. Upload each batch to SQL MI using SqlBulkCopy
    6. Provide progress updates during the export

.PARAMETER WorkspaceId
    The Log Analytics Workspace ID (GUID).

.PARAMETER LAWTableName
    The name of the table in Log Analytics to query. Default is "FileInventory_CL".

.PARAMETER SqlServer
    The SQL Managed Instance server name (e.g., myinstance.public.xxxxx.database.windows.net).

.PARAMETER SqlDatabase
    The target SQL MI database name.

.PARAMETER SqlTable
    The target table name in the SQL database. Default is "FileInventory".

.PARAMETER SqlSchema
    The SQL schema for the target table. Default is "dbo".

.PARAMETER SqlPort
    The SQL MI port. Default is 3342 (public endpoint). Use 1433 for private endpoint.

.PARAMETER UseSqlAuth
    If specified, uses SQL Authentication (username/password) instead of Azure AD token-based auth.

.PARAMETER SqlUsername
    SQL Authentication username. Required when -UseSqlAuth is specified.

.PARAMETER SqlPassword
    SQL Authentication password (SecureString). Required when -UseSqlAuth is specified.
    Use: -SqlPassword (ConvertTo-SecureString "password" -AsPlainText -Force)

.PARAMETER TruncateTable
    If specified, truncates the target SQL table before uploading data.

.PARAMETER BatchSize
    Number of records to export per LAW query batch. Default is 100,000.
    Reduce if you encounter memory issues or timeout errors.

.PARAMETER SqlBulkCopyTimeout
    Timeout in seconds for each SqlBulkCopy operation. Default is 600.

.PARAMETER SqlBulkCopyBatchSize
    Internal batch size for SqlBulkCopy writes. Default is 10,000.

.PARAMETER StartDate
    Optional. Start date for filtering records by TimeGenerated.

.PARAMETER EndDate
    Optional. End date for filtering records by TimeGenerated.

.PARAMETER StorageAccountFilter
    Optional. Filter by specific storage account name.

.PARAMETER FileShareFilter
    Optional. Filter by specific file share name.

.PARAMETER SqlTenantId
    Optional. The Azure AD (Entra ID) Tenant ID where the SQL MI is located.
    Required for cross-tenant scenarios where the LAW and SQL MI are in different tenants.
    When specified, the script will request an Azure AD token scoped to this tenant for SQL MI auth,
    while using the current tenant context for LAW queries.
    Your account must be a guest user in the SQL MI tenant or have cross-tenant access.

.PARAMETER QueryTimeoutSeconds
    Timeout in seconds for each LAW query batch. Default is 600 (10 minutes).

.EXAMPLE
    # Azure AD authentication (default)
    .\Export-FileInventoryFromLAWUploadToSQL.ps1 -WorkspaceId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -SqlServer "myinstance.public.xxxxx.database.windows.net" `
        -SqlDatabase "FileInventoryDB"

.EXAMPLE
    # Azure AD auth with truncate and custom table name
    .\Export-FileInventoryFromLAWUploadToSQL.ps1 -WorkspaceId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -SqlServer "myinstance.public.xxxxx.database.windows.net" `
        -SqlDatabase "FileInventoryDB" -SqlTable "MyTable" -TruncateTable

.EXAMPLE
    # SQL Authentication
    .\Export-FileInventoryFromLAWUploadToSQL.ps1 -WorkspaceId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -SqlServer "myinstance.public.xxxxx.database.windows.net" `
        -SqlDatabase "FileInventoryDB" -UseSqlAuth `
        -SqlUsername "myuser" -SqlPassword (ConvertTo-SecureString "mypassword" -AsPlainText -Force)

.EXAMPLE
    # With date filters and private endpoint
    .\Export-FileInventoryFromLAWUploadToSQL.ps1 -WorkspaceId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -SqlServer "myinstance.xxxxx.database.windows.net" -SqlPort 1433 `
        -SqlDatabase "FileInventoryDB" -TruncateTable `
        -StartDate "2026-02-01" -EndDate "2026-02-12"

.EXAMPLE
    # Cross-tenant: LAW in Tenant A, SQL MI in Tenant B
    # Connect to Tenant A first (Connect-AzAccount -TenantId <TenantA>), then:
    .\Export-FileInventoryFromLAWUploadToSQL.ps1 -WorkspaceId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -SqlServer "myinstance.public.xxxxx.database.windows.net" `
        -SqlDatabase "FileInventoryDB" `
        -SqlTenantId "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy" `
        -TruncateTable

.NOTES
    Author: Azure File Inventory Team
    Requires: Az.Accounts, Az.OperationalInsights modules
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceId,

    [Parameter(Mandatory = $false)]
    [string]$LAWTableName = "FileInventory_CL",

    [Parameter(Mandatory = $true)]
    [string]$SqlServer,

    [Parameter(Mandatory = $true)]
    [string]$SqlDatabase,

    [Parameter(Mandatory = $false)]
    [string]$SqlTable = "FileInventory",

    [Parameter(Mandatory = $false)]
    [string]$SqlSchema = "dbo",

    [Parameter(Mandatory = $false)]
    [int]$SqlPort = 3342,

    [Parameter(Mandatory = $false)]
    [switch]$UseSqlAuth,

    [Parameter(Mandatory = $false)]
    [string]$SqlUsername,

    [Parameter(Mandatory = $false)]
    [securestring]$SqlPassword,

    [Parameter(Mandatory = $false)]
    [switch]$TruncateTable,

    [Parameter(Mandatory = $false)]
    [int]$BatchSize = 100000,

    [Parameter(Mandatory = $false)]
    [int]$SqlBulkCopyTimeout = 600,

    [Parameter(Mandatory = $false)]
    [int]$SqlBulkCopyBatchSize = 10000,

    [Parameter(Mandatory = $false)]
    [string]$StartDate,

    [Parameter(Mandatory = $false)]
    [string]$EndDate,

    [Parameter(Mandatory = $false)]
    [string]$StorageAccountFilter,

    [Parameter(Mandatory = $false)]
    [string]$FileShareFilter,

    [Parameter(Mandatory = $false)]
    [string]$SqlTenantId,

    [Parameter(Mandatory = $false)]
    [int]$QueryTimeoutSeconds = 600
)

#region Module Imports
$ErrorActionPreference = "Stop"

try {
    Import-Module Az.Accounts -ErrorAction Stop
    Import-Module Az.OperationalInsights -ErrorAction Stop
}
catch {
    Write-Error "Failed to import required Az modules. Please install: Az.Accounts, Az.OperationalInsights"
    Write-Error "Run: Install-Module Az -Scope CurrentUser"
    throw
}

# Validate SQL Auth parameters
if ($UseSqlAuth) {
    if ([string]::IsNullOrEmpty($SqlUsername)) {
        throw "SqlUsername is required when using SQL Authentication (-UseSqlAuth)"
    }
    if ($null -eq $SqlPassword) {
        throw "SqlPassword is required when using SQL Authentication (-UseSqlAuth)"
    }
}
#endregion

#region Helper Functions

function Write-ProgressMessage {
    param(
        [string]$Message,
        [string]$Status = "Info"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Status) {
        "Info" { "Cyan" }
        "Success" { "Green" }
        "Warning" { "Yellow" }
        "Error" { "Red" }
        default { "White" }
    }
    
    Write-Host "[$timestamp] " -NoNewline -ForegroundColor Gray
    Write-Host $Message -ForegroundColor $color
}

function Build-WhereClause {
    param(
        [string]$StartDate,
        [string]$EndDate,
        [string]$StorageAccountFilter,
        [string]$FileShareFilter
    )
    
    $conditions = @()
    
    if (-not [string]::IsNullOrEmpty($StartDate)) {
        $parsedDate = [datetime]::Parse($StartDate)
        $startStr = $parsedDate.ToString("yyyy-MM-ddTHH:mm:ssZ")
        $conditions += "TimeGenerated >= datetime($startStr)"
    }
    
    if (-not [string]::IsNullOrEmpty($EndDate)) {
        $parsedDate = [datetime]::Parse($EndDate)
        $endStr = $parsedDate.ToString("yyyy-MM-ddTHH:mm:ssZ")
        $conditions += "TimeGenerated <= datetime($endStr)"
    }
    
    if (-not [string]::IsNullOrEmpty($StorageAccountFilter)) {
        $conditions += "StorageAccount == '$StorageAccountFilter'"
    }
    
    if (-not [string]::IsNullOrEmpty($FileShareFilter)) {
        $conditions += "FileShare == '$FileShareFilter'"
    }
    
    if ($conditions.Count -gt 0) {
        return "| where " + ($conditions -join " and ")
    }
    
    return ""
}

function Invoke-LAWQueryWithRetry {
    param(
        [string]$WorkspaceId,
        [string]$Query,
        [int]$TimeoutSeconds,
        [int]$MaxRetries = 3
    )
    
    $retryCount = 0
    $lastError = $null
    
    while ($retryCount -lt $MaxRetries) {
        try {
            $result = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $Query -Wait $TimeoutSeconds -ErrorAction Stop
            return $result
        }
        catch {
            $lastError = $_
            $retryCount++
            
            if ($retryCount -lt $MaxRetries) {
                $waitTime = [math]::Pow(2, $retryCount) * 5  # Exponential backoff: 10s, 20s, 40s
                Write-ProgressMessage "Query failed, retrying in $waitTime seconds... (Attempt $retryCount of $MaxRetries)" -Status "Warning"
                Start-Sleep -Seconds $waitTime
            }
        }
    }
    
    throw "Query failed after $MaxRetries attempts. Last error: $($lastError.Exception.Message)"
}

function Get-SqlConnection {
    param(
        [string]$Server,
        [int]$Port,
        [string]$Database,
        [bool]$UseSqlAuth,
        [string]$Username,
        [securestring]$Password
    )

    $connectionStringBuilder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $connectionStringBuilder["Data Source"] = "${Server},${Port}"
    $connectionStringBuilder["Initial Catalog"] = $Database
    $connectionStringBuilder["TrustServerCertificate"] = $true
    $connectionStringBuilder["Connect Timeout"] = 30

    $connection = New-Object System.Data.SqlClient.SqlConnection

    if ($UseSqlAuth) {
        $connectionStringBuilder["User ID"] = $Username
        $credential = New-Object System.Net.NetworkCredential("", $Password)
        $connectionStringBuilder["Password"] = $credential.Password
        $connection.ConnectionString = $connectionStringBuilder.ConnectionString
    }
    else {
        # Azure AD token-based authentication
        $connectionStringBuilder["Encrypt"] = $true
        $connection.ConnectionString = $connectionStringBuilder.ConnectionString
        $tokenParams = @{ ResourceUrl = "https://database.windows.net/"; ErrorAction = "Stop"; WarningAction = "SilentlyContinue" }
        if (-not [string]::IsNullOrEmpty($SqlTenantId)) { $tokenParams["TenantId"] = $SqlTenantId }
        $tokenResponse = Get-AzAccessToken @tokenParams
        # Handle both string and SecureString token formats (Az.Accounts 5.x+ returns SecureString)
        if ($tokenResponse.Token -is [securestring]) {
            $connection.AccessToken = (New-Object System.Net.NetworkCredential("", $tokenResponse.Token)).Password
        }
        else {
            $connection.AccessToken = $tokenResponse.Token
        }
    }

    return $connection
}

function ConvertTo-DataTable {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$InputObject
    )

    $dataTable = New-Object System.Data.DataTable

    # Get properties from the first object (exclude PowerShell internal properties)
    $properties = $InputObject[0].PSObject.Properties | Where-Object {
        $_.Name -ne "PSComputerName" -and $_.Name -ne "RunspaceId" -and $_.Name -ne "PSShowComputerName"
    }

    foreach ($prop in $properties) {
        $column = New-Object System.Data.DataColumn
        $column.ColumnName = $prop.Name
        $column.DataType = [string]  # LAW returns string values
        $column.AllowDBNull = $true
        $dataTable.Columns.Add($column) | Out-Null
    }

    # Add rows
    foreach ($item in $InputObject) {
        $row = $dataTable.NewRow()
        foreach ($prop in $properties) {
            $value = $item.PSObject.Properties[$prop.Name].Value
            if ($null -eq $value -or $value -eq "") {
                $row[$prop.Name] = [DBNull]::Value
            }
            else {
                $row[$prop.Name] = [string]$value
            }
        }
        $dataTable.Rows.Add($row) | Out-Null
    }

    return , $dataTable
}

function New-SqlTableFromDataTable {
    param(
        [System.Data.SqlClient.SqlConnection]$Connection,
        [string]$Schema,
        [string]$TableName,
        [System.Data.DataTable]$DataTable
    )

    $fullTableName = "[$Schema].[$TableName]"

    # Build CREATE TABLE statement dynamically from DataTable columns
    $columns = @()
    foreach ($col in $DataTable.Columns) {
        $sqlType = "NVARCHAR(MAX)"
        $columns += "        [$($col.ColumnName)] $sqlType NULL"
    }

    $createTableSql = @"
IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = '$Schema' AND TABLE_NAME = '$TableName')
BEGIN
    CREATE TABLE $fullTableName (
$($columns -join ",`n")
    )
END
"@

    $command = $Connection.CreateCommand()
    $command.CommandText = $createTableSql
    $command.CommandTimeout = 60
    $command.ExecuteNonQuery() | Out-Null
    Write-ProgressMessage "  Table $fullTableName verified/created" -Status "Success"
}

#endregion

#region Main Script

Write-ProgressMessage "========================================" -Status "Info"
Write-ProgressMessage "Azure File Inventory Export to SQL MI" -Status "Info"
Write-ProgressMessage "========================================" -Status "Info"
Write-ProgressMessage ""

# Verify Azure connection
Write-ProgressMessage "Verifying Azure connection..." -Status "Info"
$context = Get-AzContext
if (-not $context) {
    Write-ProgressMessage "Not connected to Azure. Please run Connect-AzAccount first." -Status "Error"
    throw "Not connected to Azure"
}
Write-ProgressMessage "Connected as: $($context.Account.Id)" -Status "Success"
Write-ProgressMessage "Current tenant: $($context.Tenant.Id)" -Status "Info"
if (-not [string]::IsNullOrEmpty($SqlTenantId)) {
    Write-ProgressMessage "Cross-tenant mode: SQL MI token will be requested for tenant $SqlTenantId" -Status "Warning"
}

# Connect to SQL MI
$authMethod = if ($UseSqlAuth) { "SQL Authentication" } else { "Azure AD (token-based)" }
Write-ProgressMessage "Connecting to SQL MI: ${SqlServer},${SqlPort} / $SqlDatabase (auth: $authMethod)..." -Status "Info"
try {
    $connectionStringBuilder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $connectionStringBuilder["Data Source"] = "${SqlServer},${SqlPort}"
    $connectionStringBuilder["Initial Catalog"] = $SqlDatabase
    $connectionStringBuilder["TrustServerCertificate"] = $true
    $connectionStringBuilder["Connect Timeout"] = 30

    $sqlConnection = New-Object System.Data.SqlClient.SqlConnection

    if ($UseSqlAuth) {
        $connectionStringBuilder["User ID"] = $SqlUsername
        $credential = New-Object System.Net.NetworkCredential("", $SqlPassword)
        $connectionStringBuilder["Password"] = $credential.Password
        $sqlConnection.ConnectionString = $connectionStringBuilder.ConnectionString
    }
    else {
        $connectionStringBuilder["Encrypt"] = $true
        $sqlConnection.ConnectionString = $connectionStringBuilder.ConnectionString
        $sqlTokenParams = @{ ResourceUrl = "https://database.windows.net/"; ErrorAction = "Stop"; WarningAction = "SilentlyContinue" }
        if (-not [string]::IsNullOrEmpty($SqlTenantId)) { $sqlTokenParams["TenantId"] = $SqlTenantId }
        $tokenResponse = Get-AzAccessToken @sqlTokenParams
        if ($tokenResponse.Token -is [securestring]) {
            $sqlConnection.AccessToken = (New-Object System.Net.NetworkCredential("", $tokenResponse.Token)).Password
        }
        else {
            $sqlConnection.AccessToken = $tokenResponse.Token
        }
    }

    $sqlConnection.Open()
    Write-ProgressMessage "SQL MI connection established" -Status "Success"
}
catch {
    Write-ProgressMessage "Failed to connect to SQL MI: $($_.Exception.Message)" -Status "Error"
    Write-ProgressMessage "" -Status "Info"
    Write-ProgressMessage "Troubleshooting tips:" -Status "Warning"
    Write-ProgressMessage "  1. Verify the server FQDN includes '.public.' for public endpoint (e.g., myinstance.public.xxxxx.database.windows.net)" -Status "Warning"
    Write-ProgressMessage "  2. Ensure port $SqlPort is correct (3342 for public endpoint, 1433 for private)" -Status "Warning"
    Write-ProgressMessage "  3. Check that the database '$SqlDatabase' exists on the SQL MI" -Status "Warning"
    if (-not $UseSqlAuth) {
        Write-ProgressMessage "  4. Confirm your Azure AD account ($($context.Account.Id)) has access to the SQL MI" -Status "Warning"
        Write-ProgressMessage "  5. If SQL MI has 'Azure AD only' auth enabled, do not use -UseSqlAuth" -Status "Warning"
    }
    else {
        Write-ProgressMessage "  4. Verify SQL username and password are correct" -Status "Warning"
        Write-ProgressMessage "  5. If SQL MI has 'Azure AD only' auth enabled, remove -UseSqlAuth and use Azure AD auth instead" -Status "Warning"
    }
    Write-ProgressMessage "  6. Test connectivity: Test-NetConnection -ComputerName $SqlServer -Port $SqlPort" -Status "Warning"
    throw
}

#region Pre-flight Validation: Connection Test & Table Check

$fullTableName = "[$SqlSchema].[$SqlTable]"

# Step 1: Test SQL connection with a simple query
Write-ProgressMessage "Running pre-flight connection test..." -Status "Info"
try {
    $testCmd = $sqlConnection.CreateCommand()
    $testCmd.CommandText = "SELECT 1 AS ConnectionTest"
    $testCmd.CommandTimeout = 15
    $testResult = $testCmd.ExecuteScalar()
    $testCmd.Dispose()
    if ($testResult -eq 1) {
        Write-ProgressMessage "  Connection test passed (SELECT 1 = OK)" -Status "Success"
    }
    else {
        Write-ProgressMessage "  Connection test returned unexpected result: $testResult" -Status "Warning"
    }
}
catch {
    Write-ProgressMessage "  Connection test FAILED: $($_.Exception.Message)" -Status "Error"
    Write-ProgressMessage "  The connection was opened but cannot execute queries. Check permissions." -Status "Error"
    if ($sqlConnection.State -eq 'Open') { $sqlConnection.Close() }
    $sqlConnection.Dispose()
    throw "Pre-flight connection test failed: $($_.Exception.Message)"
}

# Step 2: Verify connected to the correct database
try {
    $dbCmd = $sqlConnection.CreateCommand()
    $dbCmd.CommandText = "SELECT DB_NAME() AS CurrentDatabase"
    $dbCmd.CommandTimeout = 15
    $currentDb = $dbCmd.ExecuteScalar()
    $dbCmd.Dispose()
    if ($currentDb -eq $SqlDatabase) {
        Write-ProgressMessage "  Database verified: $currentDb" -Status "Success"
    }
    else {
        Write-ProgressMessage "  WARNING: Connected to '$currentDb' instead of '$SqlDatabase'" -Status "Warning"
    }
}
catch {
    Write-ProgressMessage "  Could not verify database name: $($_.Exception.Message)" -Status "Warning"
}

# Step 3: Check if target table already exists
Write-ProgressMessage "Checking if target table $fullTableName exists..." -Status "Info"
try {
    $tableCheckCmd = $sqlConnection.CreateCommand()
    $tableCheckCmd.CommandText = @"
SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES 
WHERE TABLE_SCHEMA = '$SqlSchema' AND TABLE_NAME = '$SqlTable'
"@
    $tableCheckCmd.CommandTimeout = 15
    $tableExists = [int]$tableCheckCmd.ExecuteScalar() -gt 0
    $tableCheckCmd.Dispose()

    if ($tableExists) {
        Write-ProgressMessage "  Table $fullTableName exists" -Status "Success"

        # Get current row count for reference
        $countCmd = $sqlConnection.CreateCommand()
        $countCmd.CommandText = "SELECT COUNT(*) FROM $fullTableName"
        $countCmd.CommandTimeout = 30
        $existingRows = [long]$countCmd.ExecuteScalar()
        $countCmd.Dispose()
        Write-ProgressMessage "  Current row count: $($existingRows.ToString('N0'))" -Status "Info"

        if ($TruncateTable) {
            Write-ProgressMessage "  Table will be truncated before upload (-TruncateTable specified)" -Status "Warning"
        }
        else {
            Write-ProgressMessage "  New data will be appended to existing rows (use -TruncateTable to clear first)" -Status "Info"
        }
    }
    else {
        Write-ProgressMessage "  Table $fullTableName does not exist - it will be auto-created from the first batch" -Status "Info"
    }
}
catch {
    Write-ProgressMessage "  Could not check table existence: $($_.Exception.Message)" -Status "Warning"
    Write-ProgressMessage "  The script will attempt to create the table if needed during export" -Status "Info"
}

Write-ProgressMessage "Pre-flight validation completed" -Status "Success"
Write-ProgressMessage "" -Status "Info"

#endregion

# Build the where clause based on filters
$whereClause = Build-WhereClause -StartDate $StartDate -EndDate $EndDate -StorageAccountFilter $StorageAccountFilter -FileShareFilter $FileShareFilter

# Get total record count (excluding empty rows)
Write-ProgressMessage "Querying total record count..." -Status "Info"
$countQuery = @"
$LAWTableName
$whereClause
| where isnotempty(FilePath)
| count
"@

try {
    $countResult = Invoke-LAWQueryWithRetry -WorkspaceId $WorkspaceId -Query $countQuery -TimeoutSeconds $QueryTimeoutSeconds
    $totalRecords = [long]$countResult.Results[0].Count
}
catch {
    Write-ProgressMessage "Failed to get record count: $($_.Exception.Message)" -Status "Error"
    throw
}

Write-ProgressMessage "Total records to export: $($totalRecords.ToString('N0'))" -Status "Success"

if ($totalRecords -eq 0) {
    Write-ProgressMessage "No records found matching the criteria. Exiting." -Status "Warning"
    if ($sqlConnection.State -eq 'Open') { $sqlConnection.Close() }
    $sqlConnection.Dispose()
    return
}

# Estimate number of batches for progress display
$estimatedBatches = [math]::Ceiling($totalRecords / $BatchSize)
Write-ProgressMessage "Estimated batches: ~$estimatedBatches (batch size: $($BatchSize.ToString('N0')) records)" -Status "Info"
Write-ProgressMessage ""

# Export data using cursor-based pagination and upload to SQL MI
$totalExported = [long]0
$totalInserted = [long]0
$startTime = Get-Date
$batchNumber = 0
$cursorTimestamp = $null
$consecutiveErrors = 0
$tableCreated = $false

while ($true) {
    $batchNumber++
    
    # Build cursor clause to advance past the last exported timestamp
    $cursorClause = ""
    if ($null -ne $cursorTimestamp) {
        $cursorClause = "| where TimeGenerated > datetime($cursorTimestamp)"
    }
    
    Write-ProgressMessage "Processing batch $batchNumber (exported $($totalExported.ToString('N0')) of ~$($totalRecords.ToString('N0')) so far)..." -Status "Info"
    
    # Cursor-based query: filter empty rows, order by time, take batch
    $query = @"
$LAWTableName
$whereClause
| where isnotempty(FilePath)
$cursorClause
| order by TimeGenerated asc
| take $BatchSize
"@
    
    try {
        $result = Invoke-LAWQueryWithRetry -WorkspaceId $WorkspaceId -Query $query -TimeoutSeconds $QueryTimeoutSeconds
        
        # Get results - handle different result structures
        $resultData = $result.Results
        if ($null -eq $resultData) {
            $resultData = @()
        }
        
        # Ensure we have a proper array and get count
        $resultsArray = @($resultData)
        $recordCount = $resultsArray.Length
        
        if ($recordCount -eq 0) {
            Write-ProgressMessage "  No more records to export - done" -Status "Success"
            break
        }
        
        $consecutiveErrors = 0
        $totalExported = $totalExported + $recordCount
        
        # Update cursor to the timestamp of the last row in this batch
        $cursorTimestamp = $resultsArray[-1].TimeGenerated
        
        # Convert results to DataTable for SqlBulkCopy
        Write-ProgressMessage "  Converting $($recordCount.ToString('N0')) records to DataTable..." -Status "Info"
        $dataTable = ConvertTo-DataTable -InputObject $resultsArray
        
        # Create table on first batch if it doesn't exist
        if (-not $tableCreated) {
            New-SqlTableFromDataTable -Connection $sqlConnection -Schema $SqlSchema -TableName $SqlTable -DataTable $dataTable
            $tableCreated = $true
            
            # Truncate after table is verified/created
            if ($TruncateTable) {
                Write-ProgressMessage "  Truncating table $fullTableName..." -Status "Info"
                $truncateCmd = $sqlConnection.CreateCommand()
                $truncateCmd.CommandText = "IF EXISTS (SELECT * FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = '$SqlSchema' AND TABLE_NAME = '$SqlTable') TRUNCATE TABLE $fullTableName"
                $truncateCmd.CommandTimeout = 60
                $truncateCmd.ExecuteNonQuery() | Out-Null
                $truncateCmd.Dispose()
                Write-ProgressMessage "  Table truncated" -Status "Success"
            }
        }
        
        # Bulk copy to SQL MI
        Write-ProgressMessage "  Uploading batch to SQL MI..." -Status "Info"
        $bulkCopy = New-Object System.Data.SqlClient.SqlBulkCopy($sqlConnection)
        $bulkCopy.DestinationTableName = $fullTableName
        $bulkCopy.BulkCopyTimeout = $SqlBulkCopyTimeout
        $bulkCopy.BatchSize = $SqlBulkCopyBatchSize
        
        # Map columns explicitly
        foreach ($col in $dataTable.Columns) {
            $bulkCopy.ColumnMappings.Add($col.ColumnName, $col.ColumnName) | Out-Null
        }
        
        try {
            $bulkCopy.WriteToServer($dataTable)
            $totalInserted += $recordCount
        }
        finally {
            $bulkCopy.Close()
            $dataTable.Dispose()
        }
        
        # Calculate progress and ETA
        $percentComplete = [math]::Round(($totalExported / [math]::Max($totalRecords, $totalExported)) * 100, 1)
        $elapsedTime = (Get-Date) - $startTime
        $recordsPerSecond = if ($elapsedTime.TotalSeconds -gt 0) { $totalExported / $elapsedTime.TotalSeconds } else { 0 }
        $remainingRecords = [math]::Max(0, $totalRecords - $totalExported)
        $etaSeconds = if ($recordsPerSecond -gt 0) { $remainingRecords / $recordsPerSecond } else { 0 }
        $eta = [TimeSpan]::FromSeconds($etaSeconds)
        
        Write-ProgressMessage "  Uploaded $($recordCount.ToString('N0')) records to SQL MI" -Status "Success"
        Write-ProgressMessage "  Progress: $percentComplete% | Total uploaded: $($totalInserted.ToString('N0')) | ETA: $($eta.ToString('hh\:mm\:ss'))" -Status "Info"
        
        # Warn if API returned fewer rows than requested (response size limit truncation)
        if ($recordCount -lt $BatchSize) {
            if ($totalExported -lt $totalRecords) {
                Write-ProgressMessage "  Note: API returned $($recordCount.ToString('N0')) of $($BatchSize.ToString('N0')) requested (response size limit). Continuing from cursor..." -Status "Warning"
            }
        }
    }
    catch {
        $consecutiveErrors++
        Write-ProgressMessage "  Failed to process batch $batchNumber : $($_.Exception.Message)" -Status "Error"
        
        if ($consecutiveErrors -ge 3) {
            Write-ProgressMessage "  3 consecutive failures - stopping export" -Status "Error"
            break
        }
        Write-ProgressMessage "  Will retry next batch..." -Status "Warning"
    }
    
    # Small delay between batches to avoid throttling
    Start-Sleep -Milliseconds 500
}

# Close SQL connection
if ($sqlConnection.State -eq 'Open') {
    $sqlConnection.Close()
}
$sqlConnection.Dispose()

Write-ProgressMessage "" -Status "Info"
Write-ProgressMessage "========================================" -Status "Info"
Write-ProgressMessage "Upload Summary" -Status "Info"
Write-ProgressMessage "========================================" -Status "Info"
Write-ProgressMessage "Total records exported from LAW: $($totalExported.ToString('N0')) of $($totalRecords.ToString('N0'))" -Status "Success"
Write-ProgressMessage "Total records inserted to SQL MI: $($totalInserted.ToString('N0'))" -Status "Success"
Write-ProgressMessage "Target: ${SqlServer},${SqlPort} / $SqlDatabase / $fullTableName" -Status "Info"

$totalTime = (Get-Date) - $startTime
Write-ProgressMessage "" -Status "Info"
Write-ProgressMessage "Total time: $($totalTime.ToString('hh\:mm\:ss'))" -Status "Success"
Write-ProgressMessage "Upload to SQL MI completed successfully!" -Status "Success"

#endregion
