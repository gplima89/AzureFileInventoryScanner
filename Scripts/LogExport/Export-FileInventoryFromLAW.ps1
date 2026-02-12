<#
.SYNOPSIS
    Exports all file inventory data from Log Analytics Workspace to CSV files.

.DESCRIPTION
    This script exports data from the FileInventory_CL table in Log Analytics Workspace
    in batches to overcome the 64MB export limit. It uses row-based pagination to ensure
    all records can be exported regardless of the total data size.

    The script will:
    1. Query the total record count
    2. Export data in configurable batch sizes (default 100,000 rows)
    3. Save each batch to a separate CSV file or combine into a single file
    4. Provide progress updates during the export

.PARAMETER WorkspaceId
    The Log Analytics Workspace ID (GUID).

.PARAMETER BatchSize
    Number of records to export per batch. Default is 100,000.
    Reduce if you encounter memory issues or timeout errors.

.PARAMETER OutputPath
    Path where CSV files will be saved. Default is the current directory.

.PARAMETER OutputFileName
    Base name for the output file(s). Default is "FileInventory_Export".

.PARAMETER CombineFiles
    If specified, combines all batch files into a single CSV file.

.PARAMETER StartDate
    Optional. Start date for filtering records by TimeGenerated.

.PARAMETER EndDate
    Optional. End date for filtering records by TimeGenerated.

.PARAMETER StorageAccountFilter
    Optional. Filter by specific storage account name.

.PARAMETER FileShareFilter
    Optional. Filter by specific file share name.

.PARAMETER QueryTimeoutSeconds
    Timeout in seconds for each query batch. Default is 600 (10 minutes).

.EXAMPLE
    .\Export-FileInventoryFromLAW.ps1 -WorkspaceId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

.EXAMPLE
    .\Export-FileInventoryFromLAW.ps1 -WorkspaceId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -BatchSize 50000 -CombineFiles

.EXAMPLE
    .\Export-FileInventoryFromLAW.ps1 -WorkspaceId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -StartDate "2026-02-01" -EndDate "2026-02-12"

.NOTES
    Author: Azure File Inventory Team
    Requires: Az.Accounts, Az.OperationalInsights modules
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceId,
    
    [Parameter(Mandatory = $false)]
    [int]$BatchSize = 100000,
    
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".",
    
    [Parameter(Mandatory = $false)]
    [string]$OutputFileName = "FileInventory_Export",
    
    [Parameter(Mandatory = $false)]
    [switch]$CombineFiles,
    
    [Parameter(Mandatory = $false)]
    [string]$StartDate,
    
    [Parameter(Mandatory = $false)]
    [string]$EndDate,
    
    [Parameter(Mandatory = $false)]
    [string]$StorageAccountFilter,
    
    [Parameter(Mandatory = $false)]
    [string]$FileShareFilter,
    
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

#endregion

#region Main Script

Write-ProgressMessage "========================================" -Status "Info"
Write-ProgressMessage "Azure File Inventory Export Tool" -Status "Info"
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

# Create output directory if it doesn't exist
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    Write-ProgressMessage "Created output directory: $OutputPath" -Status "Info"
}

$OutputPath = Resolve-Path $OutputPath

# Build the where clause based on filters
$whereClause = Build-WhereClause -StartDate $StartDate -EndDate $EndDate -StorageAccountFilter $StorageAccountFilter -FileShareFilter $FileShareFilter

# Get total record count
Write-ProgressMessage "Querying total record count..." -Status "Info"
$countQuery = @"
FileInventory_CL
$whereClause
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
    return
}

# Calculate number of batches
$totalBatches = [math]::Ceiling($totalRecords / $BatchSize)
Write-ProgressMessage "Will export in $totalBatches batches of $($BatchSize.ToString('N0')) records each" -Status "Info"
Write-ProgressMessage ""

# Export data in batches
$exportedFiles = [System.Collections.Generic.List[string]]::new()
$totalExported = [long]0
$startTime = Get-Date

for ($batch = 0; $batch -lt $totalBatches; $batch++) {
    $skip = $batch * $BatchSize
    $batchNumber = $batch + 1
    
    Write-ProgressMessage "Processing batch $batchNumber of $totalBatches (records $($skip.ToString('N0')) to $(([math]::Min($skip + $BatchSize, $totalRecords)).ToString('N0')))..." -Status "Info"
    
    # Build the query with pagination
    # Using serialize with row_number() for reliable pagination
    $query = @"
FileInventory_CL
$whereClause
| order by TimeGenerated asc, FilePath asc
| serialize
| extend RowNum = row_number()
| where RowNum > $skip and RowNum <= $($skip + $BatchSize)
| project-away RowNum
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
        
        if ($recordCount -gt 0) {
            $totalExported = $totalExported + $recordCount
            
            # Generate filename for this batch
            $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $batchFileName = "${OutputFileName}_batch${batchNumber}_${timestamp}.csv"
            $batchFilePath = Join-Path $OutputPath $batchFileName
            
            # Export to CSV
            $resultsArray | Export-Csv -Path $batchFilePath -NoTypeInformation -Encoding UTF8
            $exportedFiles.Add($batchFilePath)
            
            # Calculate progress and ETA
            $percentComplete = [math]::Round(($totalExported / $totalRecords) * 100, 1)
            $elapsedTime = (Get-Date) - $startTime
            $recordsPerSecond = if ($elapsedTime.TotalSeconds -gt 0) { $totalExported / $elapsedTime.TotalSeconds } else { 0 }
            $remainingRecords = $totalRecords - $totalExported
            $etaSeconds = if ($recordsPerSecond -gt 0) { $remainingRecords / $recordsPerSecond } else { 0 }
            $eta = [TimeSpan]::FromSeconds($etaSeconds)
            
            Write-ProgressMessage "  Exported $($recordCount.ToString('N0')) records to: $batchFileName" -Status "Success"
            Write-ProgressMessage "  Progress: $percentComplete% | Total exported: $($totalExported.ToString('N0')) | ETA: $($eta.ToString('hh\:mm\:ss'))" -Status "Info"
        }
        else {
            Write-ProgressMessage "  No records returned in this batch (may have reached end of data)" -Status "Warning"
        }
    }
    catch {
        Write-ProgressMessage "  Failed to export batch $batchNumber : $($_.Exception.Message)" -Status "Error"
        Write-ProgressMessage "  Continuing with next batch..." -Status "Warning"
    }
    
    # Small delay between batches to avoid throttling
    if ($batch -lt ($totalBatches - 1)) {
        Start-Sleep -Milliseconds 500
    }
}

Write-ProgressMessage "" -Status "Info"
Write-ProgressMessage "========================================" -Status "Info"
Write-ProgressMessage "Export Summary" -Status "Info"
Write-ProgressMessage "========================================" -Status "Info"
Write-ProgressMessage "Total records exported: $($totalExported.ToString('N0')) of $($totalRecords.ToString('N0'))" -Status "Success"
Write-ProgressMessage "Files created: $($exportedFiles.Count)" -Status "Info"

# Combine files if requested
if ($CombineFiles -and $exportedFiles.Count -gt 1) {
    Write-ProgressMessage "" -Status "Info"
    Write-ProgressMessage "Combining files into single CSV..." -Status "Info"
    
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $combinedFileName = "${OutputFileName}_combined_${timestamp}.csv"
    $combinedFilePath = Join-Path $OutputPath $combinedFileName
    
    $firstFile = $true
    $combinedCount = 0
    
    foreach ($file in $exportedFiles) {
        Write-ProgressMessage "  Processing: $(Split-Path $file -Leaf)..." -Status "Info"
        
        if ($firstFile) {
            # Include header from first file
            Get-Content $file | Set-Content $combinedFilePath -Encoding UTF8
            $firstFile = $false
        }
        else {
            # Skip header row for subsequent files
            Get-Content $file | Select-Object -Skip 1 | Add-Content $combinedFilePath -Encoding UTF8
        }
        
        $combinedCount++
    }
    
    # Get combined file size
    $combinedFileInfo = Get-Item $combinedFilePath
    $combinedFileSizeGB = [math]::Round($combinedFileInfo.Length / 1GB, 2)
    $combinedFileSizeMB = [math]::Round($combinedFileInfo.Length / 1MB, 2)
    
    Write-ProgressMessage "Combined file created: $combinedFileName" -Status "Success"
    Write-ProgressMessage "Combined file size: $combinedFileSizeMB MB ($combinedFileSizeGB GB)" -Status "Info"
    
    # Optionally remove individual batch files
    $removePrompt = Read-Host "Do you want to remove the individual batch files? (y/n)"
    if ($removePrompt -eq 'y') {
        foreach ($file in $exportedFiles) {
            Remove-Item $file -Force
        }
        Write-ProgressMessage "Removed $($exportedFiles.Count) batch files" -Status "Success"
    }
}

# List all exported files with their sizes
Write-ProgressMessage "" -Status "Info"
Write-ProgressMessage "Exported files:" -Status "Info"
foreach ($file in $exportedFiles) {
    if (Test-Path $file) {
        $fileInfo = Get-Item $file
        $fileSizeMB = [math]::Round($fileInfo.Length / 1MB, 2)
        Write-ProgressMessage "  - $(Split-Path $file -Leaf) ($fileSizeMB MB)" -Status "Info"
    }
}

$totalTime = (Get-Date) - $startTime
Write-ProgressMessage "" -Status "Info"
Write-ProgressMessage "Total export time: $($totalTime.ToString('hh\:mm\:ss'))" -Status "Success"
Write-ProgressMessage "Export completed successfully!" -Status "Success"

#endregion
