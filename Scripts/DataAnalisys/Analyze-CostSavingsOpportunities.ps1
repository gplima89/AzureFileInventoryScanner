<#
.SYNOPSIS
    Analyzes Azure File Inventory data from Log Analytics Workspace to identify cost savings opportunities.

.DESCRIPTION
    This script queries the FileInventory_CL custom table in Log Analytics Workspace and produces
    a comprehensive cost savings analysis report covering three key areas:

    1. Archive or Delete Cold Files (Over 5 years old)
       - Identifies files not modified in 5+ years that are candidates for archival or deletion
       - Breaks down by storage account, file share, file category, and age bucket
       - Estimates storage cost savings from deletion

    2. Remove Redundant and Duplicate Files
       - Uses MD5 file hashes (FileHash) to identify true duplicates
       - Falls back to FileName + FileSizeBytes matching when hashes are unavailable
       - Calculates wasted storage from redundant copies
       - Lists top duplicate groups with locations

    3. Compress Large PDF Files
       - Identifies PDF files above a configurable size threshold (default 50 MB)
       - Estimates compression savings (typical 30-60% for uncompressed PDFs)
       - Breaks down by storage account and file share

    Outputs a console report with summaries and exports detailed CSV files for each category.

.PARAMETER WorkspaceId
    Required. The Log Analytics Workspace ID containing the inventory table.

.PARAMETER TableName
    Optional. The custom log table name to query. Default: FileInventory_CL.

.PARAMETER StorageAccountFilter
    Optional. Filter analysis to a specific storage account name.

.PARAMETER FileShareFilter
    Optional. Filter analysis to a specific file share name.

.PARAMETER ColdFileAgeDays
    Optional. Age threshold in days for cold file detection. Default: 1825 (5 years).

.PARAMETER PdfSizeThresholdMB
    Optional. Minimum PDF file size in MB to flag for compression. Default: 200.

.PARAMETER PdfCompressionRatio
    Optional. Expected compression ratio for large PDFs (0.0-1.0). Default: 0.40 (60% size reduction).

.PARAMETER LookbackHours
    Optional. How far back to look for the latest scan data. Default: 48.

.PARAMETER LookbackDays
    Optional. Overrides LookbackHours with a value in days. E.g., -LookbackDays 30 = 720 hours.

.PARAMETER StorageCostPerGiBMonth
    Optional. Estimated storage cost per GiB/month in USD for savings calculation.
    Default: 0.0255 (Azure Files Transaction Optimized LRS, East US).

.PARAMETER OutputPath
    Optional. Directory to save CSV reports. Default: script directory.

.PARAMETER TimeoutSeconds
    Optional. Timeout for KQL queries. Default: 600.

.EXAMPLE
    .\Analyze-CostSavingsOpportunities.ps1 -WorkspaceId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    # Analyzes all storage accounts in the workspace with default settings.

.EXAMPLE
    .\Analyze-CostSavingsOpportunities.ps1 -WorkspaceId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -StorageAccountFilter "mystorageaccount" -ColdFileAgeDays 730
    # Analyzes a specific storage account with 2-year cold threshold.

.EXAMPLE
    .\Analyze-CostSavingsOpportunities.ps1 -WorkspaceId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -PdfSizeThresholdMB 100 -PdfCompressionRatio 0.50
    # Uses 100 MB PDF threshold and expects 50% final size after compression.

.NOTES
    Author: Azure File Storage Lifecycle Team
    Requires: Az.Accounts, Az.OperationalInsights modules
    Data Source: FileInventory_CL custom table (populated by AzureFileInventoryScanner runbook)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceId,

    [Parameter(Mandatory = $false)]
    [string]$TableName = 'FileInventory_CL',

    [Parameter(Mandatory = $false)]
    [string]$StorageAccountFilter,

    [Parameter(Mandatory = $false)]
    [string]$FileShareFilter,

    [Parameter(Mandatory = $false)]
    [int]$ColdFileAgeDays = 1825,

    [Parameter(Mandatory = $false)]
    [double]$PdfSizeThresholdMB = 200,

    [Parameter(Mandatory = $false)]
    [double]$PdfCompressionRatio = 0.40,

    [Parameter(Mandatory = $false)]
    [int]$LookbackHours = 48,

    [Parameter(Mandatory = $false)]
    [int]$LookbackDays,

    [Parameter(Mandatory = $false)]
    [double]$StorageCostPerGiBMonth = 0.0255,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [int]$TimeoutSeconds = 600
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

#region Setup
$scriptStartTime = Get-Date

# Override LookbackHours if LookbackDays is specified
if ($PSBoundParameters.ContainsKey('LookbackDays')) {
    $LookbackHours = $LookbackDays * 24
}

# Validate Azure connection
$context = Get-AzContext
if (-not $context) {
    Write-Error "Not connected to Azure. Please run Connect-AzAccount first."
    throw "Azure context not found."
}
Write-Host "`n====================================================================" -ForegroundColor Cyan
Write-Host "  Azure File Inventory - Cost Savings Opportunity Analysis" -ForegroundColor Cyan
Write-Host "====================================================================" -ForegroundColor Cyan
Write-Host "  Workspace ID    : $WorkspaceId" -ForegroundColor Gray
Write-Host "  Azure Account   : $($context.Account.Id)" -ForegroundColor Gray
Write-Host "  Subscription    : $($context.Subscription.Name)" -ForegroundColor Gray
Write-Host "  Cold File Age   : $ColdFileAgeDays days ($([math]::Round($ColdFileAgeDays / 365, 1)) years)" -ForegroundColor Gray
Write-Host "  PDF Threshold   : $PdfSizeThresholdMB MB" -ForegroundColor Gray
Write-Host "  Compression     : $([math]::Round((1 - $PdfCompressionRatio) * 100, 0))% estimated reduction" -ForegroundColor Gray
Write-Host "  Storage Cost    : `$$StorageCostPerGiBMonth /GiB/month" -ForegroundColor Gray
Write-Host "  Table Name      : $TableName" -ForegroundColor Gray
Write-Host "  Lookback        : $LookbackHours hours ($([math]::Round($LookbackHours / 24, 1)) days)" -ForegroundColor Gray
if ($StorageAccountFilter) { Write-Host "  Storage Filter  : $StorageAccountFilter" -ForegroundColor Gray }
if ($FileShareFilter) { Write-Host "  Share Filter    : $FileShareFilter" -ForegroundColor Gray }
Write-Host "====================================================================`n" -ForegroundColor Cyan

# Set output path
if (-not $OutputPath) {
    $OutputPath = $PSScriptRoot
}
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
#endregion

#region Helper Functions

function Invoke-LAWQuery {
    <#
    .SYNOPSIS
        Executes a KQL query against Log Analytics Workspace with error handling.
    #>
    [CmdletBinding()]
    param(
        [string]$WorkspaceId,
        [string]$Query,
        [string]$Description,
        [int]$TimeoutSeconds = 600
    )

    Write-Host "  [QUERY] $Description..." -ForegroundColor Gray
    try {
        $result = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $Query -Wait $TimeoutSeconds -ErrorAction Stop
        $data = @($result.Results)
        Write-Host "  [QUERY] Returned $($data.Count) records." -ForegroundColor Gray
        return $data
    }
    catch {
        Write-Warning "  [QUERY] Failed: $($_.Exception.Message)"
        return @()
    }
}

function Format-SizeGB {
    param([double]$SizeGB)
    if ($SizeGB -ge 1024) {
        return "$([math]::Round($SizeGB / 1024, 2)) TB"
    }
    elseif ($SizeGB -ge 1) {
        return "$([math]::Round($SizeGB, 2)) GB"
    }
    else {
        return "$([math]::Round($SizeGB * 1024, 2)) MB"
    }
}

function Format-Number {
    param([long]$Number)
    return $Number.ToString("N0")
}

function Get-KQLFilter {
    <#
    .SYNOPSIS
        Returns KQL where clauses for storage account and file share filters.
    #>
    param(
        [string]$StorageAccountFilter,
        [string]$FileShareFilter
    )
    $filter = ""
    if ($StorageAccountFilter) {
        $filter += "| where StorageAccount =~ '$StorageAccountFilter'`n"
    }
    if ($FileShareFilter) {
        $filter += "| where FileShare =~ '$FileShareFilter'`n"
    }
    return $filter
}

#endregion

#region Build KQL Filters
$kqlFilter = Get-KQLFilter -StorageAccountFilter $StorageAccountFilter -FileShareFilter $FileShareFilter
#endregion

# ============================================================================
# PHASE 0: Data Validation - Check table availability
# ============================================================================
Write-Host "`n[PHASE 0] Validating $TableName data availability..." -ForegroundColor Yellow

$validationQuery = @"
$TableName
| where TimeGenerated > ago(${LookbackHours}h)
| where isnotempty(FilePath)
$kqlFilter
| summarize
    TotalFiles = count(),
    TotalSizeGB = round(sum(FileSizeGB), 2),
    StorageAccounts = dcount(StorageAccount),
    FileShares = dcount(strcat(StorageAccount, '/', FileShare)),
    LatestScan = max(TimeGenerated),
    OldestScan = min(TimeGenerated),
    HashesAvailable = countif(FileHash !in ('SKIPPED', 'SKIPPED_TOO_LARGE', 'ERROR', 'SKIPPED_PERFORMANCE', '')),
    AvgAgeInDays = round(avg(AgeInDays), 0)
"@

$validation = Invoke-LAWQuery -WorkspaceId $WorkspaceId -Query $validationQuery -Description "Checking data availability" -TimeoutSeconds $TimeoutSeconds

if ($validation.Count -eq 0 -or [long]$validation[0].TotalFiles -eq 0) {
    Write-Error "No $TableName data found in the last $LookbackHours hours. Ensure the inventory scanner runbook has run recently."
    throw "No data available for analysis."
}

$totalFiles = [long]$validation[0].TotalFiles
$totalSizeGB = [double]$validation[0].TotalSizeGB
$storageAccounts = [int]$validation[0].StorageAccounts
$fileShares = [int]$validation[0].FileShares
$hashesAvailable = [long]$validation[0].HashesAvailable
$avgAge = [double]$validation[0].AvgAgeInDays

Write-Host "`n  Data Summary:" -ForegroundColor White
Write-Host "    Total Files       : $(Format-Number $totalFiles)" -ForegroundColor Gray
Write-Host "    Total Size        : $(Format-SizeGB $totalSizeGB)" -ForegroundColor Gray
Write-Host "    Storage Accounts  : $storageAccounts" -ForegroundColor Gray
Write-Host "    File Shares       : $fileShares" -ForegroundColor Gray
Write-Host "    Hashes Available  : $(Format-Number $hashesAvailable) ($([math]::Round($hashesAvailable * 100 / [math]::Max($totalFiles, 1), 1))%)" -ForegroundColor Gray
Write-Host "    Avg File Age      : $avgAge days ($([math]::Round($avgAge / 365, 1)) years)" -ForegroundColor Gray

# ============================================================================
# PHASE 1: Archive or Delete Cold Files (Over N years old)
# ============================================================================
Write-Host "`n[PHASE 1] Analyzing Cold Files (not modified in $ColdFileAgeDays+ days / $([math]::Round($ColdFileAgeDays / 365, 1))+ years)..." -ForegroundColor Yellow

# 1a. Summary by Storage Account and File Share
$coldFilesSummaryQuery = @"
$TableName
| where TimeGenerated > ago(${LookbackHours}h)
| where isnotempty(FilePath)
$kqlFilter
| where AgeInDays >= $ColdFileAgeDays
| summarize
    ColdFileCount = count(),
    ColdSizeGB = round(sum(FileSizeGB), 4),
    ColdSizeTB = round(sum(FileSizeGB) / 1024, 4),
    OldestFileDays = max(AgeInDays),
    AvgAgeDays = round(avg(AgeInDays), 0),
    TopCategories = make_set(FileCategory, 10)
    by StorageAccount, FileShare
| order by ColdSizeGB desc
"@

$coldFilesSummary = Invoke-LAWQuery -WorkspaceId $WorkspaceId -Query $coldFilesSummaryQuery -Description "Cold files by storage account/share" -TimeoutSeconds $TimeoutSeconds

# 1b. Cold files breakdown by File Category
$coldByCategoryQuery = @"
$TableName
| where TimeGenerated > ago(${LookbackHours}h)
| where isnotempty(FilePath)
$kqlFilter
| where AgeInDays >= $ColdFileAgeDays
| summarize
    FileCount = count(),
    TotalSizeGB = round(sum(FileSizeGB), 4),
    AvgSizeMB = round(avg(FileSizeMB), 2),
    AvgAgeDays = round(avg(AgeInDays), 0)
    by FileCategory
| order by TotalSizeGB desc
"@

$coldByCategory = Invoke-LAWQuery -WorkspaceId $WorkspaceId -Query $coldByCategoryQuery -Description "Cold files by category" -TimeoutSeconds $TimeoutSeconds

# 1c. Cold files breakdown by Age Bucket (5-7y, 7-10y, 10+y)
$coldByAgeQuery = @"
$TableName
| where TimeGenerated > ago(${LookbackHours}h)
| where isnotempty(FilePath)
$kqlFilter
| where AgeInDays >= $ColdFileAgeDays
| extend ColdAgeBucket = case(
    AgeInDays >= 3650, '10+ years',
    AgeInDays >= 2555, '7-10 years',
    AgeInDays >= 1825, '5-7 years',
    'Other')
| summarize
    FileCount = count(),
    TotalSizeGB = round(sum(FileSizeGB), 4)
    by ColdAgeBucket
| order by case(
    ColdAgeBucket, '5-7 years', 1,
    ColdAgeBucket, '7-10 years', 2,
    ColdAgeBucket, '10+ years', 3,
    4) asc
"@

$coldByAge = Invoke-LAWQuery -WorkspaceId $WorkspaceId -Query $coldByAgeQuery -Description "Cold files by age bracket" -TimeoutSeconds $TimeoutSeconds

# 1d. Top 500 largest cold files (detailed list for CSV export)
$coldFilesDetailQuery = @"
$TableName
| where TimeGenerated > ago(${LookbackHours}h)
| where isnotempty(FilePath)
$kqlFilter
| where AgeInDays >= $ColdFileAgeDays
| project
    StorageAccount,
    FileShare,
    FilePath,
    FileName,
    FileExtension,
    FileCategory,
    FileSizeMB = round(FileSizeMB, 2),
    FileSizeGB = round(FileSizeGB, 4),
    LastModified,
    AgeInDays,
    AgeYears = round(AgeInDays / 365.0, 1)
| order by FileSizeGB desc
| take 500
"@

$coldFilesDetail = Invoke-LAWQuery -WorkspaceId $WorkspaceId -Query $coldFilesDetailQuery -Description "Top 500 largest cold files" -TimeoutSeconds $TimeoutSeconds

# Phase 1 Console Report
$totalColdFiles = ($coldFilesSummary | Measure-Object -Property ColdFileCount -Sum).Sum
$totalColdSizeGB = ($coldFilesSummary | Measure-Object -Property ColdSizeGB -Sum).Sum
if ($null -eq $totalColdFiles) { $totalColdFiles = 0 }
if ($null -eq $totalColdSizeGB) { $totalColdSizeGB = 0 }
$coldMonthlySavings = [math]::Round($totalColdSizeGB * $StorageCostPerGiBMonth, 2)
$coldYearlySavings = [math]::Round($coldMonthlySavings * 12, 2)

Write-Host "`n  ┌─────────────────────────────────────────────────────────────────┐" -ForegroundColor White
Write-Host "  │  COLD FILES ANALYSIS - Archive/Delete Candidates               │" -ForegroundColor White
Write-Host "  ├─────────────────────────────────────────────────────────────────┤" -ForegroundColor White
Write-Host "  │  Cold Files Found     : $('{0,-38}' -f (Format-Number ([long]$totalColdFiles)))│" -ForegroundColor Gray
Write-Host "  │  Total Cold Storage   : $('{0,-38}' -f (Format-SizeGB $totalColdSizeGB))│" -ForegroundColor Gray
Write-Host "  │  % of Total Files     : $('{0,-38}' -f "$([math]::Round($totalColdFiles * 100 / [math]::Max($totalFiles, 1), 1))%")│" -ForegroundColor Gray
Write-Host "  │  % of Total Storage   : $('{0,-38}' -f "$([math]::Round($totalColdSizeGB * 100 / [math]::Max($totalSizeGB, 0.001), 1))%")│" -ForegroundColor Gray
Write-Host "  │  Est. Monthly Savings : $('{0,-38}' -f ('$' + $coldMonthlySavings + ' (if deleted)'))│" -ForegroundColor Green
Write-Host "  │  Est. Yearly Savings  : $('{0,-38}' -f ('$' + $coldYearlySavings + ' (if deleted)'))│" -ForegroundColor Green
Write-Host "  └─────────────────────────────────────────────────────────────────┘" -ForegroundColor White

if ($coldFilesSummary.Count -gt 0) {
    Write-Host "`n  Cold Files by Storage Account / File Share:" -ForegroundColor White
    Write-Host "  $('-' * 100)" -ForegroundColor DarkGray
    Write-Host ("  {0,-30} {1,-25} {2,12} {3,14} {4,10}" -f "Storage Account", "File Share", "Files", "Size", "Avg Age") -ForegroundColor DarkCyan
    Write-Host "  $('-' * 100)" -ForegroundColor DarkGray
    foreach ($row in $coldFilesSummary) {
        $acct = if ($row.StorageAccount.Length -gt 28) { $row.StorageAccount.Substring(0, 28) + ".." } else { $row.StorageAccount }
        $share = if ($row.FileShare.Length -gt 23) { $row.FileShare.Substring(0, 23) + ".." } else { $row.FileShare }
        Write-Host ("  {0,-30} {1,-25} {2,12} {3,14} {4,8} d" -f $acct, $share, (Format-Number ([long]$row.ColdFileCount)), (Format-SizeGB ([double]$row.ColdSizeGB)), $row.AvgAgeDays) -ForegroundColor Gray
    }
}

if ($coldByCategory.Count -gt 0) {
    Write-Host "`n  Cold Files by Category:" -ForegroundColor White
    Write-Host "  $('-' * 75)" -ForegroundColor DarkGray
    Write-Host ("  {0,-25} {1,12} {2,14} {3,10} {4,10}" -f "Category", "Files", "Size", "Avg MB", "Avg Age") -ForegroundColor DarkCyan
    Write-Host "  $('-' * 75)" -ForegroundColor DarkGray
    foreach ($row in $coldByCategory) {
        Write-Host ("  {0,-25} {1,12} {2,14} {3,10} {4,8} d" -f $row.FileCategory, (Format-Number ([long]$row.FileCount)), (Format-SizeGB ([double]$row.TotalSizeGB)), $row.AvgSizeMB, $row.AvgAgeDays) -ForegroundColor Gray
    }
}

if ($coldByAge.Count -gt 0) {
    Write-Host "`n  Cold Files by Age Bracket:" -ForegroundColor White
    Write-Host "  $('-' * 55)" -ForegroundColor DarkGray
    Write-Host ("  {0,-15} {1,12} {2,14} {3,12}" -f "Age Bracket", "Files", "Size", "% of Cold") -ForegroundColor DarkCyan
    Write-Host "  $('-' * 55)" -ForegroundColor DarkGray
    foreach ($row in $coldByAge) {
        $pctCold = if ($totalColdSizeGB -gt 0) { [math]::Round([double]$row.TotalSizeGB * 100 / $totalColdSizeGB, 1) } else { 0 }
        Write-Host ("  {0,-15} {1,12} {2,14} {3,11}%" -f $row.ColdAgeBucket, (Format-Number ([long]$row.FileCount)), (Format-SizeGB ([double]$row.TotalSizeGB)), $pctCold) -ForegroundColor Gray
    }
}

# ============================================================================
# PHASE 2: Remove Redundant and Duplicate Files
# ============================================================================
Write-Host "`n[PHASE 2] Analyzing Duplicate and Redundant Files..." -ForegroundColor Yellow

# 2a. Hash-based duplicate summary
$dupHashSummaryQuery = @"
$TableName
| where TimeGenerated > ago(${LookbackHours}h)
| where isnotempty(FilePath)
$kqlFilter
| where FileHash !in ('SKIPPED', 'SKIPPED_TOO_LARGE', 'ERROR', 'SKIPPED_PERFORMANCE', '')
| summarize
    FileCount = count(),
    TotalSizeGB = round(sum(FileSizeGB), 4),
    Locations = make_list(strcat(StorageAccount, '/', FileShare, '/', FilePath), 10)
    by FileHash, FileName, FileSizeBytes
| where FileCount > 1
| extend
    RedundantCopies = FileCount - 1,
    WastedSizeGB = round((FileCount - 1) * TotalSizeGB / FileCount, 4)
| summarize
    TotalDuplicateGroups = count(),
    TotalDuplicateFiles = sum(FileCount),
    TotalRedundantFiles = sum(RedundantCopies),
    TotalWastedGB = round(sum(WastedSizeGB), 4)
"@

$dupHashSummary = Invoke-LAWQuery -WorkspaceId $WorkspaceId -Query $dupHashSummaryQuery -Description "Hash-based duplicate summary" -TimeoutSeconds $TimeoutSeconds

# 2b. Top 200 duplicate groups by wasted space (hash-based)
$dupHashDetailQuery = @"
$TableName
| where TimeGenerated > ago(${LookbackHours}h)
| where isnotempty(FilePath)
$kqlFilter
| where FileHash !in ('SKIPPED', 'SKIPPED_TOO_LARGE', 'ERROR', 'SKIPPED_PERFORMANCE', '')
| summarize
    DuplicateCount = count(),
    TotalSizeGB = round(sum(FileSizeGB), 4),
    WastedSizeGB = round(sum(FileSizeGB) - min(FileSizeGB), 4),
    FileSizeMB = round(max(FileSizeMB), 2),
    Locations = make_list(strcat(StorageAccount, '/', FileShare, '/', FilePath), 15)
    by FileHash, FileName, FileSizeBytes
| where DuplicateCount > 1
| order by WastedSizeGB desc
| take 200
"@

$dupHashDetail = Invoke-LAWQuery -WorkspaceId $WorkspaceId -Query $dupHashDetailQuery -Description "Top duplicate groups (hash-based)" -TimeoutSeconds $TimeoutSeconds

# 2c. Name+Size based duplicates (when hash is unavailable)
$dupNameSizeQuery = @"
$TableName
| where TimeGenerated > ago(${LookbackHours}h)
| where isnotempty(FilePath)
$kqlFilter
| where FileHash in ('SKIPPED', 'SKIPPED_TOO_LARGE', 'SKIPPED_PERFORMANCE', '') or isempty(FileHash)
| summarize
    DuplicateCount = count(),
    TotalSizeGB = round(sum(FileSizeGB), 4),
    WastedSizeGB = round(sum(FileSizeGB) - min(FileSizeGB), 4),
    FileSizeMB = round(max(FileSizeMB), 2),
    Locations = make_list(strcat(StorageAccount, '/', FileShare, '/', FilePath), 10)
    by FileName, FileSizeBytes
| where DuplicateCount > 1
| order by WastedSizeGB desc
| take 200
"@

$dupNameSize = Invoke-LAWQuery -WorkspaceId $WorkspaceId -Query $dupNameSizeQuery -Description "Potential duplicates by name+size (no hash)" -TimeoutSeconds $TimeoutSeconds

# 2d. Duplicates by storage account and file share
$dupByShareQuery = @"
$TableName
| where TimeGenerated > ago(${LookbackHours}h)
| where isnotempty(FilePath)
$kqlFilter
| where FileHash !in ('SKIPPED', 'SKIPPED_TOO_LARGE', 'ERROR', 'SKIPPED_PERFORMANCE', '')
| summarize FileCount = count() by FileHash, FileSizeBytes
| where FileCount > 1
| join kind=inner (
    $TableName
    | where TimeGenerated > ago(${LookbackHours}h)
    | where isnotempty(FilePath)
    $kqlFilter
    | where FileHash !in ('SKIPPED', 'SKIPPED_TOO_LARGE', 'ERROR', 'SKIPPED_PERFORMANCE', '')
) on FileHash, FileSizeBytes
| summarize
    DuplicateFiles = count(),
    WastedSizeGB = round(sum(FileSizeGB) - dcount(FileHash) * avg(FileSizeGB), 4)
    by StorageAccount, FileShare
| where DuplicateFiles > 0
| order by WastedSizeGB desc
"@

$dupByShare = Invoke-LAWQuery -WorkspaceId $WorkspaceId -Query $dupByShareQuery -Description "Duplicates by storage account/share" -TimeoutSeconds $TimeoutSeconds

# Phase 2 Console Report
$hashDupGroups = if ($dupHashSummary.Count -gt 0 -and $dupHashSummary[0].TotalDuplicateGroups) { [long]$dupHashSummary[0].TotalDuplicateGroups } else { 0 }
$hashDupFiles = if ($dupHashSummary.Count -gt 0 -and $dupHashSummary[0].TotalRedundantFiles) { [long]$dupHashSummary[0].TotalRedundantFiles } else { 0 }
$hashWastedGB = if ($dupHashSummary.Count -gt 0 -and $dupHashSummary[0].TotalWastedGB) { [double]$dupHashSummary[0].TotalWastedGB } else { 0 }
$nameSizeDups = ($dupNameSize | Measure-Object -Property DuplicateCount -Sum).Sum
$nameSizeWastedGB = ($dupNameSize | Measure-Object -Property WastedSizeGB -Sum).Sum
if ($null -eq $nameSizeDups) { $nameSizeDups = 0 }
if ($null -eq $nameSizeWastedGB) { $nameSizeWastedGB = 0 }
$totalDupWastedGB = $hashWastedGB + $nameSizeWastedGB
$dupMonthlySavings = [math]::Round($totalDupWastedGB * $StorageCostPerGiBMonth, 2)
$dupYearlySavings = [math]::Round($dupMonthlySavings * 12, 2)

Write-Host "`n  ┌─────────────────────────────────────────────────────────────────┐" -ForegroundColor White
Write-Host "  │  DUPLICATE FILES ANALYSIS - Redundancy Removal                 │" -ForegroundColor White
Write-Host "  ├─────────────────────────────────────────────────────────────────┤" -ForegroundColor White
Write-Host "  │  Hash-Based Duplicates:                                        │" -ForegroundColor White
Write-Host "  │    Duplicate Groups   : $('{0,-38}' -f (Format-Number $hashDupGroups))│" -ForegroundColor Gray
Write-Host "  │    Redundant Files    : $('{0,-38}' -f (Format-Number $hashDupFiles))│" -ForegroundColor Gray
Write-Host "  │    Wasted Storage     : $('{0,-38}' -f (Format-SizeGB $hashWastedGB))│" -ForegroundColor Gray
Write-Host "  │  Name+Size Matches (no hash):                                  │" -ForegroundColor White
Write-Host "  │    Potential Dupes    : $('{0,-38}' -f (Format-Number ([long]$nameSizeDups)))│" -ForegroundColor Gray
Write-Host "  │    Est. Wasted Storage: $('{0,-38}' -f (Format-SizeGB $nameSizeWastedGB))│" -ForegroundColor Gray
Write-Host "  │  Combined Savings:                                             │" -ForegroundColor White
Write-Host "  │    Total Wasted       : $('{0,-38}' -f (Format-SizeGB $totalDupWastedGB))│" -ForegroundColor Gray
Write-Host "  │    Est. Monthly Savings: $('{0,-37}' -f ('$' + $dupMonthlySavings))│" -ForegroundColor Green
Write-Host "  │    Est. Yearly Savings : $('{0,-37}' -f ('$' + $dupYearlySavings))│" -ForegroundColor Green
Write-Host "  └─────────────────────────────────────────────────────────────────┘" -ForegroundColor White

if ($dupHashDetail.Count -gt 0) {
    $topDups = $dupHashDetail | Select-Object -First 10
    Write-Host "`n  Top 10 Duplicate Groups (by wasted space):" -ForegroundColor White
    Write-Host "  $('-' * 100)" -ForegroundColor DarkGray
    Write-Host ("  {0,-35} {1,10} {2,12} {3,12} {4,-25}" -f "File Name", "Size (MB)", "Copies", "Wasted", "Sample Location") -ForegroundColor DarkCyan
    Write-Host "  $('-' * 100)" -ForegroundColor DarkGray
    foreach ($row in $topDups) {
        $fname = if ($row.FileName.Length -gt 33) { $row.FileName.Substring(0, 33) + ".." } else { $row.FileName }
        $locations = $row.Locations | ConvertFrom-Json -ErrorAction SilentlyContinue
        $sampleLoc = if ($locations -and $locations.Count -gt 0) {
            $loc = $locations[0]
            if ($loc.Length -gt 23) { $loc.Substring(0, 23) + ".." } else { $loc }
        }
        else { "N/A" }
        Write-Host ("  {0,-35} {1,10} {2,12} {3,12} {4,-25}" -f $fname, $row.FileSizeMB, $row.DuplicateCount, (Format-SizeGB ([double]$row.WastedSizeGB)), $sampleLoc) -ForegroundColor Gray
    }
}

if ($dupByShare.Count -gt 0) {
    Write-Host "`n  Duplicate Files by Storage Account / File Share:" -ForegroundColor White
    Write-Host "  $('-' * 80)" -ForegroundColor DarkGray
    Write-Host ("  {0,-30} {1,-25} {2,12} {3,12}" -f "Storage Account", "File Share", "Dup Files", "Wasted") -ForegroundColor DarkCyan
    Write-Host "  $('-' * 80)" -ForegroundColor DarkGray
    foreach ($row in $dupByShare) {
        $acct = if ($row.StorageAccount.Length -gt 28) { $row.StorageAccount.Substring(0, 28) + ".." } else { $row.StorageAccount }
        $share = if ($row.FileShare.Length -gt 23) { $row.FileShare.Substring(0, 23) + ".." } else { $row.FileShare }
        Write-Host ("  {0,-30} {1,-25} {2,12} {3,12}" -f $acct, $share, (Format-Number ([long]$row.DuplicateFiles)), (Format-SizeGB ([double]$row.WastedSizeGB))) -ForegroundColor Gray
    }
}

# ============================================================================
# PHASE 3: Compress Large PDF Files
# ============================================================================
Write-Host "`n[PHASE 3] Analyzing Large PDF Files for Compression Opportunities..." -ForegroundColor Yellow

# 3a. PDF summary by storage account and file share
$pdfSummaryQuery = @"
$TableName
| where TimeGenerated > ago(${LookbackHours}h)
| where isnotempty(FilePath)
$kqlFilter
| where FileExtension =~ '.pdf'
| where FileSizeMB >= $PdfSizeThresholdMB
| summarize
    PdfCount = count(),
    TotalSizeGB = round(sum(FileSizeGB), 4),
    AvgSizeMB = round(avg(FileSizeMB), 2),
    MaxSizeMB = round(max(FileSizeMB), 2),
    AvgAgeDays = round(avg(AgeInDays), 0)
    by StorageAccount, FileShare
| order by TotalSizeGB desc
"@

$pdfSummary = Invoke-LAWQuery -WorkspaceId $WorkspaceId -Query $pdfSummaryQuery -Description "Large PDFs by storage account/share" -TimeoutSeconds $TimeoutSeconds

# 3b. PDF size distribution
$pdfSizeDistQuery = @"
$TableName
| where TimeGenerated > ago(${LookbackHours}h)
| where isnotempty(FilePath)
$kqlFilter
| where FileExtension =~ '.pdf'
| where FileSizeMB >= $PdfSizeThresholdMB
| extend PdfSizeBucket = case(
    FileSizeMB >= 1000, '1 GB+',
    FileSizeMB >= 500,  '500 MB - 1 GB',
    FileSizeMB >= 200,  '200 - 500 MB',
    'Under 200 MB')
| summarize
    FileCount = count(),
    TotalSizeGB = round(sum(FileSizeGB), 4),
    AvgAgeDays = round(avg(AgeInDays), 0)
    by PdfSizeBucket
| order by case(
    PdfSizeBucket, '200 - 500 MB', 1,
    PdfSizeBucket, '500 MB - 1 GB', 2,
    PdfSizeBucket, '1 GB+', 3,
    4) asc
"@

$pdfSizeDist = Invoke-LAWQuery -WorkspaceId $WorkspaceId -Query $pdfSizeDistQuery -Description "Large PDF size distribution" -TimeoutSeconds $TimeoutSeconds

# 3c. Top 500 largest PDFs (detailed list for CSV)
$pdfDetailQuery = @"
$TableName
| where TimeGenerated > ago(${LookbackHours}h)
| where isnotempty(FilePath)
$kqlFilter
| where FileExtension =~ '.pdf'
| where FileSizeMB >= $PdfSizeThresholdMB
| project
    StorageAccount,
    FileShare,
    FilePath,
    FileName,
    FileSizeMB = round(FileSizeMB, 2),
    FileSizeGB = round(FileSizeGB, 4),
    LastModified,
    AgeInDays,
    EstCompressedSizeMB = round(FileSizeMB * $PdfCompressionRatio, 2),
    EstSavingsMB = round(FileSizeMB * (1 - $PdfCompressionRatio), 2)
| order by FileSizeMB desc
| take 500
"@

$pdfDetail = Invoke-LAWQuery -WorkspaceId $WorkspaceId -Query $pdfDetailQuery -Description "Top 500 largest PDFs" -TimeoutSeconds $TimeoutSeconds

# 3d. Overall PDF statistics (including small PDFs for context)
$pdfOverallQuery = @"
$TableName
| where TimeGenerated > ago(${LookbackHours}h)
| where isnotempty(FilePath)
$kqlFilter
| where FileExtension =~ '.pdf'
| summarize
    TotalPdfs = count(),
    TotalPdfSizeGB = round(sum(FileSizeGB), 4),
    LargePdfs = countif(FileSizeMB >= $PdfSizeThresholdMB),
    LargePdfSizeGB = round(sumif(FileSizeGB, FileSizeMB >= $PdfSizeThresholdMB), 4),
    AvgPdfSizeMB = round(avg(FileSizeMB), 2),
    MaxPdfSizeMB = round(max(FileSizeMB), 2)
"@

$pdfOverall = Invoke-LAWQuery -WorkspaceId $WorkspaceId -Query $pdfOverallQuery -Description "Overall PDF statistics" -TimeoutSeconds $TimeoutSeconds

# Phase 3 Console Report
$totalLargePdfs = if ($pdfOverall.Count -gt 0 -and $pdfOverall[0].LargePdfs) { [long]$pdfOverall[0].LargePdfs } else { 0 }
$totalLargePdfSizeGB = if ($pdfOverall.Count -gt 0 -and $pdfOverall[0].LargePdfSizeGB) { [double]$pdfOverall[0].LargePdfSizeGB } else { 0 }
$totalPdfs = if ($pdfOverall.Count -gt 0 -and $pdfOverall[0].TotalPdfs) { [long]$pdfOverall[0].TotalPdfs } else { 0 }
$totalPdfSizeGB = if ($pdfOverall.Count -gt 0 -and $pdfOverall[0].TotalPdfSizeGB) { [double]$pdfOverall[0].TotalPdfSizeGB } else { 0 }
$pdfSavingsGB = [math]::Round($totalLargePdfSizeGB * (1 - $PdfCompressionRatio), 4)
$pdfMonthlySavings = [math]::Round($pdfSavingsGB * $StorageCostPerGiBMonth, 2)
$pdfYearlySavings = [math]::Round($pdfMonthlySavings * 12, 2)

Write-Host "`n  ┌─────────────────────────────────────────────────────────────────┐" -ForegroundColor White
Write-Host "  │  PDF COMPRESSION ANALYSIS - Large File Optimization            │" -ForegroundColor White
Write-Host "  ├─────────────────────────────────────────────────────────────────┤" -ForegroundColor White
Write-Host "  │  Total PDF Files      : $('{0,-38}' -f (Format-Number $totalPdfs))│" -ForegroundColor Gray
Write-Host "  │  Total PDF Storage    : $('{0,-38}' -f (Format-SizeGB $totalPdfSizeGB))│" -ForegroundColor Gray
Write-Host "  │  Large PDFs (>=$($PdfSizeThresholdMB)MB) : $('{0,-38}' -f (Format-Number $totalLargePdfs))│" -ForegroundColor Gray
Write-Host "  │  Large PDF Storage    : $('{0,-38}' -f (Format-SizeGB $totalLargePdfSizeGB))│" -ForegroundColor Gray
Write-Host "  │  Est. Post-Compression: $('{0,-38}' -f (Format-SizeGB ($totalLargePdfSizeGB * $PdfCompressionRatio)))│" -ForegroundColor Gray
Write-Host "  │  Est. Space Savings   : $('{0,-38}' -f (Format-SizeGB $pdfSavingsGB))│" -ForegroundColor Gray
Write-Host "  │  Est. Monthly Savings : $('{0,-38}' -f ('$' + $pdfMonthlySavings))│" -ForegroundColor Green
Write-Host "  │  Est. Yearly Savings  : $('{0,-38}' -f ('$' + $pdfYearlySavings))│" -ForegroundColor Green
Write-Host "  └─────────────────────────────────────────────────────────────────┘" -ForegroundColor White

if ($pdfSizeDist.Count -gt 0) {
    Write-Host "`n  Large PDF Size Distribution:" -ForegroundColor White
    Write-Host "  $('-' * 65)" -ForegroundColor DarkGray
    Write-Host ("  {0,-18} {1,12} {2,14} {3,14}" -f "Size Bracket", "Files", "Total Size", "Avg Age") -ForegroundColor DarkCyan
    Write-Host "  $('-' * 65)" -ForegroundColor DarkGray
    foreach ($row in $pdfSizeDist) {
        Write-Host ("  {0,-18} {1,12} {2,14} {3,12} d" -f $row.PdfSizeBucket, (Format-Number ([long]$row.FileCount)), (Format-SizeGB ([double]$row.TotalSizeGB)), $row.AvgAgeDays) -ForegroundColor Gray
    }
}

if ($pdfSummary.Count -gt 0) {
    Write-Host "`n  Large PDFs by Storage Account / File Share:" -ForegroundColor White
    Write-Host "  $('-' * 100)" -ForegroundColor DarkGray
    Write-Host ("  {0,-30} {1,-25} {2,10} {3,12} {4,10} {5,10}" -f "Storage Account", "File Share", "PDFs", "Size", "Avg MB", "Avg Age") -ForegroundColor DarkCyan
    Write-Host "  $('-' * 100)" -ForegroundColor DarkGray
    foreach ($row in $pdfSummary) {
        $acct = if ($row.StorageAccount.Length -gt 28) { $row.StorageAccount.Substring(0, 28) + ".." } else { $row.StorageAccount }
        $share = if ($row.FileShare.Length -gt 23) { $row.FileShare.Substring(0, 23) + ".." } else { $row.FileShare }
        Write-Host ("  {0,-30} {1,-25} {2,10} {3,12} {4,10} {5,8} d" -f $acct, $share, (Format-Number ([long]$row.PdfCount)), (Format-SizeGB ([double]$row.TotalSizeGB)), $row.AvgSizeMB, $row.AvgAgeDays) -ForegroundColor Gray
    }
}

# ============================================================================
# PHASE 4: Combined Summary & CSV Export
# ============================================================================
Write-Host "`n[PHASE 4] Generating Summary and Exporting Reports..." -ForegroundColor Yellow

# Combined savings summary
$grandTotalSavingsGB = $totalColdSizeGB + $totalDupWastedGB + $pdfSavingsGB
$grandMonthlySavings = [math]::Round($grandTotalSavingsGB * $StorageCostPerGiBMonth, 2)
$grandYearlySavings = [math]::Round($grandMonthlySavings * 12, 2)

Write-Host "`n  ╔═════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║        COMBINED COST SAVINGS OPPORTUNITY SUMMARY               ║" -ForegroundColor Cyan
Write-Host "  ╠═════════════════════════════════════════════════════════════════╣" -ForegroundColor Cyan
Write-Host "  ║                                                                 ║" -ForegroundColor Cyan
Write-Host "  ║  1. Cold Files (Archive/Delete)                                 ║" -ForegroundColor White
Write-Host "  ║     Files: $('{0,-15}' -f (Format-Number ([long]$totalColdFiles)))  Storage: $('{0,-22}' -f (Format-SizeGB $totalColdSizeGB))║" -ForegroundColor Gray
Write-Host "  ║     Savings: $('{0,-14}' -f ('$' + $coldMonthlySavings + '/mo'))  ($('{0,-24}' -f ('$' + $coldYearlySavings + '/yr')))║" -ForegroundColor Green
Write-Host "  ║                                                                 ║" -ForegroundColor Cyan
Write-Host "  ║  2. Duplicate Files (Remove Redundancy)                         ║" -ForegroundColor White
Write-Host "  ║     Files: $('{0,-15}' -f (Format-Number ([long]($hashDupFiles + $nameSizeDups))))  Wasted:  $('{0,-22}' -f (Format-SizeGB $totalDupWastedGB))║" -ForegroundColor Gray
Write-Host "  ║     Savings: $('{0,-14}' -f ('$' + $dupMonthlySavings + '/mo'))  ($('{0,-24}' -f ('$' + $dupYearlySavings + '/yr')))║" -ForegroundColor Green
Write-Host "  ║                                                                 ║" -ForegroundColor Cyan
Write-Host "  ║  3. PDF Compression                                             ║" -ForegroundColor White
Write-Host "  ║     Files: $('{0,-15}' -f (Format-Number $totalLargePdfs))  Reducible: $('{0,-20}' -f (Format-SizeGB $pdfSavingsGB))║" -ForegroundColor Gray
Write-Host "  ║     Savings: $('{0,-14}' -f ('$' + $pdfMonthlySavings + '/mo'))  ($('{0,-24}' -f ('$' + $pdfYearlySavings + '/yr')))║" -ForegroundColor Green
Write-Host "  ║                                                                 ║" -ForegroundColor Cyan
Write-Host "  ╠═════════════════════════════════════════════════════════════════╣" -ForegroundColor Cyan
Write-Host "  ║  TOTAL POTENTIAL SAVINGS                                        ║" -ForegroundColor Cyan
Write-Host "  ║     Recoverable Storage : $('{0,-38}' -f (Format-SizeGB $grandTotalSavingsGB))║" -ForegroundColor White
Write-Host "  ║     Monthly Savings     : $('{0,-38}' -f ('$' + $grandMonthlySavings))║" -ForegroundColor Green
Write-Host "  ║     Yearly Savings      : $('{0,-38}' -f ('$' + $grandYearlySavings))║" -ForegroundColor Green
Write-Host "  ║                                                                 ║" -ForegroundColor Cyan
Write-Host "  ║  Note: Savings based on `$$StorageCostPerGiBMonth/GiB/month storage cost.       ║" -ForegroundColor DarkGray
Write-Host "  ║  Actual savings depend on tier, redundancy, and region.         ║" -ForegroundColor DarkGray
Write-Host "  ╚═════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# ============================================================================
# CSV EXPORT
# ============================================================================

# Export 1: Cold Files Detail
if ($coldFilesDetail.Count -gt 0) {
    $coldCsvPath = Join-Path $OutputPath "CostSavings_ColdFiles_$timestamp.csv"
    $coldFilesDetail | ForEach-Object {
        [PSCustomObject]@{
            StorageAccount = $_.StorageAccount
            FileShare      = $_.FileShare
            FilePath       = $_.FilePath
            FileName       = $_.FileName
            FileExtension  = $_.FileExtension
            FileCategory   = $_.FileCategory
            FileSizeMB     = $_.FileSizeMB
            FileSizeGB     = $_.FileSizeGB
            LastModified   = $_.LastModified
            AgeInDays      = $_.AgeInDays
            AgeYears       = $_.AgeYears
            Action         = "Archive or Delete"
            EstMonthlyCost = [math]::Round([double]$_.FileSizeGB * $StorageCostPerGiBMonth, 4)
        }
    } | Export-Csv -Path $coldCsvPath -NoTypeInformation -Encoding UTF8
    Write-Host "  [EXPORT] Cold files report  : $coldCsvPath ($($coldFilesDetail.Count) records)" -ForegroundColor Gray
}
else {
    Write-Host "  [EXPORT] No cold files to export." -ForegroundColor DarkGray
}

# Export 2: Duplicate Files Detail
if ($dupHashDetail.Count -gt 0 -or $dupNameSize.Count -gt 0) {
    $dupCsvPath = Join-Path $OutputPath "CostSavings_Duplicates_$timestamp.csv"
    $dupExport = @()

    if ($dupHashDetail.Count -gt 0) {
        $dupExport += $dupHashDetail | ForEach-Object {
            [PSCustomObject]@{
                DetectionMethod = "MD5 Hash"
                FileName        = $_.FileName
                FileHash        = $_.FileHash
                FileSizeMB      = $_.FileSizeMB
                DuplicateCount  = $_.DuplicateCount
                TotalSizeGB     = $_.TotalSizeGB
                WastedSizeGB    = $_.WastedSizeGB
                Locations       = $_.Locations
                EstMonthlyCost  = [math]::Round([double]$_.WastedSizeGB * $StorageCostPerGiBMonth, 4)
                Action          = "Remove redundant copies"
            }
        }
    }

    if ($dupNameSize.Count -gt 0) {
        $dupExport += $dupNameSize | ForEach-Object {
            [PSCustomObject]@{
                DetectionMethod = "Name+Size Match"
                FileName        = $_.FileName
                FileHash        = "N/A"
                FileSizeMB      = $_.FileSizeMB
                DuplicateCount  = $_.DuplicateCount
                TotalSizeGB     = $_.TotalSizeGB
                WastedSizeGB    = $_.WastedSizeGB
                Locations       = $_.Locations
                EstMonthlyCost  = [math]::Round([double]$_.WastedSizeGB * $StorageCostPerGiBMonth, 4)
                Action          = "Verify and remove redundant copies"
            }
        }
    }

    $dupExport | Export-Csv -Path $dupCsvPath -NoTypeInformation -Encoding UTF8
    Write-Host "  [EXPORT] Duplicates report  : $dupCsvPath ($($dupExport.Count) records)" -ForegroundColor Gray
}
else {
    Write-Host "  [EXPORT] No duplicate files to export." -ForegroundColor DarkGray
}

# Export 3: Large PDF Files Detail
if ($pdfDetail.Count -gt 0) {
    $pdfCsvPath = Join-Path $OutputPath "CostSavings_LargePDFs_$timestamp.csv"
    $pdfDetail | ForEach-Object {
        [PSCustomObject]@{
            StorageAccount      = $_.StorageAccount
            FileShare           = $_.FileShare
            FilePath            = $_.FilePath
            FileName            = $_.FileName
            FileSizeMB          = $_.FileSizeMB
            FileSizeGB          = $_.FileSizeGB
            LastModified        = $_.LastModified
            AgeInDays           = $_.AgeInDays
            EstCompressedSizeMB = $_.EstCompressedSizeMB
            EstSavingsMB        = $_.EstSavingsMB
            EstSavingsGB        = [math]::Round([double]$_.EstSavingsMB / 1024, 4)
            EstMonthlyCost      = [math]::Round(([double]$_.EstSavingsMB / 1024) * $StorageCostPerGiBMonth, 4)
            Action              = "Compress PDF"
        }
    } | Export-Csv -Path $pdfCsvPath -NoTypeInformation -Encoding UTF8
    Write-Host "  [EXPORT] Large PDFs report  : $pdfCsvPath ($($pdfDetail.Count) records)" -ForegroundColor Gray
}
else {
    Write-Host "  [EXPORT] No large PDFs to export." -ForegroundColor DarkGray
}

# Export 4: Executive Summary CSV
$summaryCsvPath = Join-Path $OutputPath "CostSavings_Summary_$timestamp.csv"
@(
    [PSCustomObject]@{
        Category               = "Cold Files (Archive/Delete)"
        Description            = "Files not modified in $ColdFileAgeDays+ days ($([math]::Round($ColdFileAgeDays / 365, 1))+ years)"
        AffectedFiles          = [long]$totalColdFiles
        RecoverableStorageGB   = [math]::Round($totalColdSizeGB, 2)
        EstMonthlySavingsUSD   = $coldMonthlySavings
        EstYearlySavingsUSD    = $coldYearlySavings
        PercentOfTotalFiles    = [math]::Round($totalColdFiles * 100 / [math]::Max($totalFiles, 1), 1)
        PercentOfTotalStorage  = [math]::Round($totalColdSizeGB * 100 / [math]::Max($totalSizeGB, 0.001), 1)
    }
    [PSCustomObject]@{
        Category               = "Duplicate Files (Remove Redundancy)"
        Description            = "Redundant file copies detected via MD5 hash and name+size matching"
        AffectedFiles          = [long]($hashDupFiles + $nameSizeDups)
        RecoverableStorageGB   = [math]::Round($totalDupWastedGB, 2)
        EstMonthlySavingsUSD   = $dupMonthlySavings
        EstYearlySavingsUSD    = $dupYearlySavings
        PercentOfTotalFiles    = [math]::Round(($hashDupFiles + $nameSizeDups) * 100 / [math]::Max($totalFiles, 1), 1)
        PercentOfTotalStorage  = [math]::Round($totalDupWastedGB * 100 / [math]::Max($totalSizeGB, 0.001), 1)
    }
    [PSCustomObject]@{
        Category               = "PDF Compression"
        Description            = "PDFs >= $($PdfSizeThresholdMB) MB, est. $([math]::Round((1 - $PdfCompressionRatio) * 100, 0))% size reduction"
        AffectedFiles          = [long]$totalLargePdfs
        RecoverableStorageGB   = [math]::Round($pdfSavingsGB, 2)
        EstMonthlySavingsUSD   = $pdfMonthlySavings
        EstYearlySavingsUSD    = $pdfYearlySavings
        PercentOfTotalFiles    = [math]::Round($totalLargePdfs * 100 / [math]::Max($totalFiles, 1), 1)
        PercentOfTotalStorage  = [math]::Round($pdfSavingsGB * 100 / [math]::Max($totalSizeGB, 0.001), 1)
    }
    [PSCustomObject]@{
        Category               = "TOTAL"
        Description            = "Combined savings from all categories"
        AffectedFiles          = [long]($totalColdFiles + $hashDupFiles + $nameSizeDups + $totalLargePdfs)
        RecoverableStorageGB   = [math]::Round($grandTotalSavingsGB, 2)
        EstMonthlySavingsUSD   = $grandMonthlySavings
        EstYearlySavingsUSD    = $grandYearlySavings
        PercentOfTotalFiles    = [math]::Round(($totalColdFiles + $hashDupFiles + $nameSizeDups + $totalLargePdfs) * 100 / [math]::Max($totalFiles, 1), 1)
        PercentOfTotalStorage  = [math]::Round($grandTotalSavingsGB * 100 / [math]::Max($totalSizeGB, 0.001), 1)
    }
) | Export-Csv -Path $summaryCsvPath -NoTypeInformation -Encoding UTF8
Write-Host "  [EXPORT] Summary report     : $summaryCsvPath" -ForegroundColor Gray

# Final timing
$elapsed = (Get-Date) - $scriptStartTime
Write-Host "`n====================================================================" -ForegroundColor Cyan
Write-Host "  Analysis completed in $([math]::Round($elapsed.TotalSeconds, 1)) seconds." -ForegroundColor Cyan
Write-Host "  Output directory: $OutputPath" -ForegroundColor Cyan
Write-Host "====================================================================" -ForegroundColor Cyan
