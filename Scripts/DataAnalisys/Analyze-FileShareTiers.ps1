<#
.SYNOPSIS
    Analyzes Azure File Share access patterns and recommends optimal access tiers for cost savings.

.DESCRIPTION
    This script lists all file shares in a storage account, retrieves performance metrics
    from Log Analytics Workspace (StorageFileLogs) or Azure Monitor, and provides tier 
    recommendations based on Microsoft's guidelines.
    
    Azure Files Access Tier Recommendations:
    - Hot: High storage cost, low transaction cost - best for frequently accessed data
    - Cool: Low storage cost, high transaction cost - best for infrequently accessed data
    - Transaction Optimized: Lowest transaction cost - best for transaction-heavy workloads
    - Premium: SSD-based, lowest latency - best for IO-intensive workloads

.PARAMETER StorageAccountName
    The name of the Azure Storage Account to analyze.

.PARAMETER ResourceGroupName
    The resource group containing the storage account.

.PARAMETER WorkspaceId
    Optional. Log Analytics Workspace ID to query for metrics (recommended for per-file-share accuracy).
    If not provided, falls back to Azure Monitor metrics (storage account level only).

.PARAMETER SubscriptionId
    Optional. The subscription ID. If not provided, uses the current context.

.PARAMETER TimeRangeHours
    Optional. Number of hours to analyze metrics. Default is 24.

.PARAMETER TimeRangeDays
    Optional. Number of days to analyze metrics. Overrides TimeRangeHours if specified.

.PARAMETER FileShareName
    Optional. Name of a specific file share to analyze. If not provided, analyzes all file shares.

.PARAMETER OutputPath
    Optional. Path to save the analysis report. Default is the script directory.

.EXAMPLE
    .\Analyze-FileShareTiers.ps1 -StorageAccountName "mystorageaccount" -ResourceGroupName "my-rg" -WorkspaceId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

.EXAMPLE
    .\Analyze-FileShareTiers.ps1 -StorageAccountName "mystorageaccount" -ResourceGroupName "my-rg" -WorkspaceId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -TimeRangeDays 7

.EXAMPLE
    .\Analyze-FileShareTiers.ps1 -StorageAccountName "mystorageaccount" -ResourceGroupName "my-rg" -FileShareName "myfileshare"

.NOTES
    Author: Azure File Storage Lifecycle Team
    Requires: Az.Accounts, Az.Storage, Az.Monitor, Az.OperationalInsights modules
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$StorageAccountName,
    
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory = $false)]
    [string]$WorkspaceId,
    
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory = $false)]
    [int]$TimeRangeHours = 24,
    
    [Parameter(Mandatory = $false)]
    [int]$TimeRangeDays,
    
    [Parameter(Mandatory = $false)]
    [string]$FileShareName,
    
    [Parameter(Mandatory = $false)]
    [string]$OutputPath
)

#region Module Imports
$ErrorActionPreference = "Stop"

try {
    Import-Module Az.Accounts -ErrorAction Stop
    Import-Module Az.Storage -ErrorAction Stop
    Import-Module Az.Monitor -ErrorAction Stop
    Import-Module Az.OperationalInsights -ErrorAction Stop
}
catch {
    Write-Error "Failed to import required Az modules. Please install: Az.Accounts, Az.Storage, Az.Monitor, Az.OperationalInsights"
    Write-Error "Run: Install-Module Az -Scope CurrentUser"
    throw
}
#endregion

#region Helper Functions

function Get-FileShareMetricsFromLAW {
    <#
    .SYNOPSIS
        Retrieves file share transaction metrics from Log Analytics Workspace.
    #>
    [CmdletBinding()]
    param(
        [string]$WorkspaceId,
        [string]$StorageAccountName,
        [string]$FileShareName,
        [datetime]$StartTime,
        [datetime]$EndTime,
        [int]$TimeoutSeconds = 300
    )
    
    $startStr = $StartTime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $endStr = $EndTime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    
    # Query for transaction metrics per file share from StorageFileLogs
    # Uri format: https://account.file.core.windows.net:443/filesharename/path
    $query = @"
StorageFileLogs
| where TimeGenerated >= datetime($startStr) and TimeGenerated <= datetime($endStr)
| where AccountName =~ '$StorageAccountName'
| extend FileShare = extract("file\\.core\\.windows\\.net(:\\d+)?/([^/?]+)", 2, Uri)
| where isnotempty(FileShare)
$(if ($FileShareName) { "| where FileShare =~ '$FileShareName'" } else { "" })
| summarize 
    TotalTransactions = count(),
    ReadTransactions = countif(Category == 'StorageRead'),
    WriteTransactions = countif(Category == 'StorageWrite'),
    DeleteTransactions = countif(Category == 'StorageDelete'),
    ListTransactions = countif(OperationName contains 'List'),
    TotalBytesRead = sum(ResponseBodySize),
    TotalBytesWritten = sum(RequestBodySize),
    AvgLatencyMs = avg(DurationMs),
    MaxLatencyMs = max(DurationMs),
    UniqueCallerIPs = dcount(CallerIpAddress),
    UniqueOperations = dcount(OperationName)
    by FileShare
| order by TotalTransactions desc
"@
    
    try {
        $result = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $query -Wait $TimeoutSeconds -ErrorAction Stop
        # Convert to array to avoid lazy enumerable issues
        return @($result.Results)
    }
    catch {
        Write-Warning "Failed to query LAW for metrics: $($_.Exception.Message)"
        return $null
    }
}

function Get-FileShareOperationBreakdownFromLAW {
    <#
    .SYNOPSIS
        Gets detailed operation breakdown for a file share from LAW.
    #>
    [CmdletBinding()]
    param(
        [string]$WorkspaceId,
        [string]$StorageAccountName,
        [string]$FileShareName,
        [datetime]$StartTime,
        [datetime]$EndTime,
        [int]$TimeoutSeconds = 300
    )
    
    $startStr = $StartTime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $endStr = $EndTime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    
    $query = @"
StorageFileLogs
| where TimeGenerated >= datetime($startStr) and TimeGenerated <= datetime($endStr)
| where AccountName =~ '$StorageAccountName'
| extend FileShare = extract("file\\.core\\.windows\\.net(:\\d+)?/([^/?]+)", 2, Uri)
| where FileShare =~ '$FileShareName'
| summarize Count = count() by OperationName, Category
| order by Count desc
| take 20
"@
    
    try {
        $result = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $query -Wait $TimeoutSeconds -ErrorAction Stop
        return @($result.Results)
    }
    catch {
        return $null
    }
}

function Get-FileShareHourlyPatternFromLAW {
    <#
    .SYNOPSIS
        Gets hourly access pattern for a file share from LAW.
    #>
    [CmdletBinding()]
    param(
        [string]$WorkspaceId,
        [string]$StorageAccountName,
        [string]$FileShareName,
        [datetime]$StartTime,
        [datetime]$EndTime,
        [int]$TimeoutSeconds = 300
    )
    
    $startStr = $StartTime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $endStr = $EndTime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    
    $query = @"
StorageFileLogs
| where TimeGenerated >= datetime($startStr) and TimeGenerated <= datetime($endStr)
| where AccountName =~ '$StorageAccountName'
| extend FileShare = extract("file\\.core\\.windows\\.net(:\\d+)?/([^/?]+)", 2, Uri)
| where FileShare =~ '$FileShareName'
| summarize Transactions = count() by bin(TimeGenerated, 1h)
| order by TimeGenerated asc
"@
    
    try {
        $result = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $query -Wait $TimeoutSeconds -ErrorAction Stop
        return @($result.Results)
    }
    catch {
        return $null
    }
}

function Get-TierRecommendation {
    <#
    .SYNOPSIS
        Recommends an access tier based on transaction patterns and storage size.
    #>
    [CmdletBinding()]
    param(
        [long]$TotalTransactions,
        [long]$ReadTransactions,
        [long]$WriteTransactions,
        [double]$StorageUsedGB,
        [string]$CurrentTier,
        [bool]$IsPremium
    )
    
    # Premium file shares cannot change tiers
    if ($IsPremium) {
        return @{
            RecommendedTier = "Premium"
            Reason = "Premium file shares have fixed tier (SSD-based)"
            PotentialSavings = "N/A"
        }
    }
    
    # Calculate transactions per GB per day
    $transactionsPerGB = if ($StorageUsedGB -gt 0) { $TotalTransactions / $StorageUsedGB } else { 0 }
    
    # Calculate read/write ratio
    $readRatio = if ($TotalTransactions -gt 0) { $ReadTransactions / $TotalTransactions } else { 0 }
    
    # Microsoft's tier recommendation logic:
    # - Transaction Optimized: > 100 transactions per GB per day (transaction-heavy)
    # - Hot: 10-100 transactions per GB per day (general purpose)
    # - Cool: < 10 transactions per GB per day (infrequent access)
    
    $recommendation = @{
        RecommendedTier = $CurrentTier
        Reason = ""
        PotentialSavings = "None - already optimal"
    }
    
    if ($transactionsPerGB -gt 100) {
        # Transaction-heavy workload
        $recommendation.RecommendedTier = "TransactionOptimized"
        $recommendation.Reason = "High transaction rate ($([math]::Round($transactionsPerGB, 1)) transactions/GB/day) - Transaction Optimized tier minimizes transaction costs"
        
        if ($CurrentTier -eq "Hot") {
            $recommendation.PotentialSavings = "~10-20% savings on transaction costs"
        }
        elseif ($CurrentTier -eq "Cool") {
            $recommendation.PotentialSavings = "~40-60% savings on transaction costs"
        }
    }
    elseif ($transactionsPerGB -ge 10 -and $transactionsPerGB -le 100) {
        # General purpose workload
        $recommendation.RecommendedTier = "Hot"
        $recommendation.Reason = "Moderate transaction rate ($([math]::Round($transactionsPerGB, 1)) transactions/GB/day) - Hot tier provides balanced cost"
        
        if ($CurrentTier -eq "TransactionOptimized") {
            $recommendation.PotentialSavings = "~10-15% savings on storage costs"
        }
        elseif ($CurrentTier -eq "Cool") {
            $recommendation.PotentialSavings = "~20-40% savings on transaction costs"
        }
    }
    elseif ($transactionsPerGB -lt 10) {
        # Infrequent access
        $recommendation.RecommendedTier = "Cool"
        $recommendation.Reason = "Low transaction rate ($([math]::Round($transactionsPerGB, 1)) transactions/GB/day) - Cool tier minimizes storage costs"
        
        if ($CurrentTier -eq "Hot") {
            $recommendation.PotentialSavings = "~20-30% savings on storage costs"
        }
        elseif ($CurrentTier -eq "TransactionOptimized") {
            $recommendation.PotentialSavings = "~30-50% savings on storage costs"
        }
    }
    
    # If no transactions at all, definitely recommend Cool
    if ($TotalTransactions -eq 0) {
        $recommendation.RecommendedTier = "Cool"
        $recommendation.Reason = "No transactions detected - Cool tier recommended for dormant shares"
        if ($CurrentTier -ne "Cool") {
            $recommendation.PotentialSavings = "~20-50% savings on storage costs"
        }
    }
    
    # Check if already optimal
    if ($recommendation.RecommendedTier -eq $CurrentTier) {
        $recommendation.PotentialSavings = "None - already optimal"
        $recommendation.Reason = "Current tier is optimal for the access pattern"
    }
    
    return $recommendation
}

function Format-BytesToGB {
    param([long]$Bytes)
    return [math]::Round($Bytes / 1GB, 2)
}

function Format-Number {
    param([long]$Number)
    return $Number.ToString("N0")
}

#endregion

#region Main Execution

Write-Host ""
Write-Host "=============================================================================" -ForegroundColor Cyan
Write-Host "  Azure File Share Tier Analysis and Cost Optimization Tool" -ForegroundColor Cyan
Write-Host "=============================================================================" -ForegroundColor Cyan
Write-Host ""

# Step 1: Validate Azure connection
Write-Host "[VALIDATION] Checking Azure connection..." -ForegroundColor Yellow
$context = Get-AzContext -ErrorAction SilentlyContinue

if (-not $context) {
    Write-Host "[ERROR] Not connected to Azure. Please run 'Connect-AzAccount' first." -ForegroundColor Red
    Write-Host ""
    Write-Host "To connect, run one of the following:" -ForegroundColor Yellow
    Write-Host "  Connect-AzAccount                                    # Interactive login" -ForegroundColor Gray
    Write-Host "  Connect-AzAccount -TenantId <tenant-id>              # Specific tenant" -ForegroundColor Gray
    Write-Host "  Connect-AzAccount -Identity                          # Managed Identity" -ForegroundColor Gray
    Write-Host ""
    exit 1
}

Write-Host "[VALIDATION] Connected to Azure as: $($context.Account.Id)" -ForegroundColor Green

# Step 2: Set subscription context if provided
if ($SubscriptionId) {
    Write-Host "[VALIDATION] Setting subscription context to: $SubscriptionId" -ForegroundColor Yellow
    try {
        Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
        $context = Get-AzContext
    }
    catch {
        Write-Host "[ERROR] Failed to set subscription context to: $SubscriptionId" -ForegroundColor Red
        Write-Host "[ERROR] $_" -ForegroundColor Red
        Write-Host ""
        Write-Host "Please verify:" -ForegroundColor Yellow
        Write-Host "  1. The subscription ID is correct" -ForegroundColor Gray
        Write-Host "  2. You have access to this subscription" -ForegroundColor Gray
        Write-Host ""
        Write-Host "To list available subscriptions, run: Get-AzSubscription" -ForegroundColor Yellow
        exit 1
    }
}

Write-Host "[VALIDATION] Using subscription: $($context.Subscription.Name) ($($context.Subscription.Id))" -ForegroundColor Green
Write-Host ""

# Step 3: Validate storage account exists and is accessible
Write-Host "[VALIDATION] Checking access to storage account: $StorageAccountName" -ForegroundColor Yellow
$storageAccount = $null
try {
    $storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -ErrorAction Stop
}
catch {
    $errorMessage = $_.Exception.Message
    
    if ($errorMessage -match "ResourceGroupNotFound|ResourceNotFound|not found") {
        Write-Host "[ERROR] Storage account '$StorageAccountName' not found in resource group '$ResourceGroupName'" -ForegroundColor Red
        Write-Host ""
        Write-Host "Please verify:" -ForegroundColor Yellow
        Write-Host "  1. Storage account name is correct" -ForegroundColor Gray
        Write-Host "  2. Resource group name is correct" -ForegroundColor Gray
        Write-Host "  3. The resource exists in subscription: $($context.Subscription.Name)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "To find your storage account, run:" -ForegroundColor Yellow
        Write-Host "  Get-AzStorageAccount | Select-Object StorageAccountName, ResourceGroupName, Location" -ForegroundColor Gray
    }
    elseif ($errorMessage -match "AuthorizationFailed|Forbidden|does not have authorization") {
        Write-Host "[ERROR] Access denied to storage account '$StorageAccountName'" -ForegroundColor Red
        Write-Host ""
        Write-Host "Please verify:" -ForegroundColor Yellow
        Write-Host "  1. You have Reader or Contributor role on the resource group" -ForegroundColor Gray
        Write-Host "  2. The subscription context is correct" -ForegroundColor Gray
        Write-Host ""
        Write-Host "Current subscription: $($context.Subscription.Name) ($($context.Subscription.Id))" -ForegroundColor Gray
    }
    else {
        Write-Host "[ERROR] Failed to access storage account: $errorMessage" -ForegroundColor Red
    }
    
    Write-Host ""
    exit 1
}

Write-Host "[VALIDATION] Storage account found and accessible" -ForegroundColor Green

$isPremiumAccount = $storageAccount.Sku.Name -like "*Premium*"
Write-Host "[INFO] Storage Account SKU: $($storageAccount.Sku.Name)" -ForegroundColor Green
Write-Host "[INFO] Storage Account Kind: $($storageAccount.Kind)" -ForegroundColor Green
Write-Host "[INFO] Location: $($storageAccount.Location)" -ForegroundColor Green
Write-Host ""

# Get storage context
$storageContext = $storageAccount.Context

# List all file shares
Write-Host "[INFO] Listing file shares..." -ForegroundColor Yellow
$fileShares = $null
try {
    $fileShares = Get-AzStorageShare -Context $storageContext -ErrorAction Stop | Where-Object { -not $_.IsSnapshot }
}
catch {
    Write-Host "[ERROR] Failed to list file shares: $_" -ForegroundColor Red
    Write-Host ""
    Write-Host "Please verify:" -ForegroundColor Yellow
    Write-Host "  1. The storage account has file shares enabled" -ForegroundColor Gray
    Write-Host "  2. Network access is allowed (check firewall settings)" -ForegroundColor Gray
    Write-Host "  3. You have 'Storage File Data' or 'Storage Account Key Operator' permissions" -ForegroundColor Gray
    Write-Host ""
    exit 1
}

# Filter to specific file share if provided
if ($FileShareName) {
    $fileShares = $fileShares | Where-Object { $_.Name -eq $FileShareName }
    if ($fileShares.Count -eq 0) {
        Write-Host "[ERROR] File share '$FileShareName' not found in storage account: $StorageAccountName" -ForegroundColor Red
        Write-Host ""
        Write-Host "Available file shares:" -ForegroundColor Yellow
        $allShares = Get-AzStorageShare -Context $storageContext -ErrorAction SilentlyContinue | Where-Object { -not $_.IsSnapshot }
        $allShares | ForEach-Object { Write-Host "  - $($_.Name)" -ForegroundColor Gray }
        Write-Host ""
        exit 1
    }
    Write-Host "[INFO] Analyzing specific file share: $FileShareName" -ForegroundColor Green
}

if ($fileShares.Count -eq 0) {
    Write-Host "[WARNING] No file shares found in storage account: $StorageAccountName" -ForegroundColor Yellow
    exit 0
}

Write-Host "[INFO] Found $($fileShares.Count) file share(s)" -ForegroundColor Green
Write-Host ""

# Calculate time range
$endTime = Get-Date
if ($TimeRangeDays -gt 0) {
    $TimeRangeHours = $TimeRangeDays * 24
}
$startTime = $endTime.AddHours(-$TimeRangeHours)

$timeRangeDisplay = if ($TimeRangeHours -ge 24) { "$([math]::Floor($TimeRangeHours / 24)) day(s)" } else { "$TimeRangeHours hour(s)" }
Write-Host "[INFO] Analyzing metrics from $($startTime.ToString('yyyy-MM-dd HH:mm')) to $($endTime.ToString('yyyy-MM-dd HH:mm')) ($timeRangeDisplay)" -ForegroundColor Yellow

# Determine data source
$useLAW = -not [string]::IsNullOrEmpty($WorkspaceId)
if ($useLAW) {
    Write-Host "[INFO] Data Source: Log Analytics Workspace (per-file-share metrics)" -ForegroundColor Green
    
    # Pre-fetch all file share metrics from LAW
    Write-Host "[INFO] Querying Log Analytics for file share metrics..." -ForegroundColor Yellow
    $lawMetrics = Get-FileShareMetricsFromLAW -WorkspaceId $WorkspaceId -StorageAccountName $StorageAccountName -FileShareName $FileShareName -StartTime $startTime -EndTime $endTime
    
    if ($null -eq $lawMetrics -or $lawMetrics.Count -eq 0) {
        Write-Host "[WARNING] No metrics found in Log Analytics. Make sure StorageFileLogs is enabled for this storage account." -ForegroundColor Yellow
        Write-Host "[INFO] To enable, go to Storage Account > Diagnostic settings > Add diagnostic setting > Select 'StorageFileLogs' and send to Log Analytics Workspace" -ForegroundColor Gray
        $useLAW = $false
    }
    else {
        Write-Host "[INFO] Found metrics for $($lawMetrics.Count) file share(s) in LAW" -ForegroundColor Green
    }
}
else {
    Write-Host "[INFO] Data Source: Azure Monitor Metrics (Note: per-file-share filtering may be limited)" -ForegroundColor Yellow
    Write-Host "[TIP] For accurate per-file-share metrics, enable StorageFileLogs diagnostic setting and provide -WorkspaceId parameter" -ForegroundColor Gray
}
Write-Host ""

# Build the results table
$results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($share in $fileShares) {
    $shareName = $share.Name
    Write-Host "[ANALYZING] File share: $shareName" -ForegroundColor Cyan
    
    # Get share properties using Get-AzRmStorageShare for accurate usage stats
    $shareProperties = $null
    $usageBytes = 0
    $quotaGB = 0
    $currentTier = "TransactionOptimized"
    
    try {
        # Use Get-AzRmStorageShare with -GetShareUsage to get actual usage statistics
        $shareProperties = Get-AzRmStorageShare -ResourceGroupName $ResourceGroupName -StorageAccountName $StorageAccountName -Name $shareName -GetShareUsage -ErrorAction Stop
        
        $quotaGB = $shareProperties.QuotaGiB
        $currentTier = if ($shareProperties.AccessTier) { $shareProperties.AccessTier } else { "TransactionOptimized" }
        $usageBytes = if ($shareProperties.ShareUsageBytes) { $shareProperties.ShareUsageBytes } else { 0 }
    }
    catch {
        Write-Host "  - [WARNING] Could not get share properties via ARM, trying data plane..." -ForegroundColor Yellow
        
        # Fallback to data plane API
        try {
            $sharePropertiesDP = Get-AzStorageShare -Context $storageContext -Name $shareName -ErrorAction Stop
            $quotaGB = $sharePropertiesDP.ShareProperties.QuotaInGB
            $currentTier = if ($sharePropertiesDP.ShareProperties.AccessTier) { $sharePropertiesDP.ShareProperties.AccessTier } else { "TransactionOptimized" }
            
            # Try to get usage from file share statistics
            $shareStats = $sharePropertiesDP.ShareClient.GetStatistics().Value
            if ($shareStats -and $shareStats.ShareUsageInBytes) {
                $usageBytes = $shareStats.ShareUsageInBytes
            }
        }
        catch {
            Write-Host "  - [WARNING] Could not retrieve usage statistics" -ForegroundColor Yellow
        }
    }
    
    $usageGB = Format-BytesToGB -Bytes $usageBytes
    
    Write-Host "  - Current Tier: $currentTier" -ForegroundColor Gray
    Write-Host "  - Quota: ${quotaGB}GB, Used: ${usageGB}GB" -ForegroundColor Gray
    
    # Initialize metrics
    $totalTransactions = 0
    $readTransactions = 0
    $writeTransactions = 0
    $deleteTransactions = 0
    $listTransactions = 0
    $avgLatencyMs = 0
    $uniqueCallerIPs = 0
    $bytesRead = 0
    $bytesWritten = 0
    
    # Get metrics based on data source
    if ($useLAW) {
        # Get metrics from pre-fetched LAW data
        $shareMetrics = $lawMetrics | Where-Object { $_.FileShare -eq $shareName }
        
        if ($shareMetrics) {
            $totalTransactions = [long]$shareMetrics.TotalTransactions
            $readTransactions = [long]$shareMetrics.ReadTransactions
            $writeTransactions = [long]$shareMetrics.WriteTransactions
            $deleteTransactions = [long]$shareMetrics.DeleteTransactions
            $listTransactions = [long]$shareMetrics.ListTransactions
            $avgLatencyMs = [double]$shareMetrics.AvgLatencyMs
            $uniqueCallerIPs = [int]$shareMetrics.UniqueCallerIPs
            $bytesRead = [long]$shareMetrics.TotalBytesRead
            $bytesWritten = [long]$shareMetrics.TotalBytesWritten
            
            Write-Host "  - Total Transactions ($timeRangeDisplay): $(Format-Number $totalTransactions)" -ForegroundColor Gray
            Write-Host "  - Read/Write/Delete/List: $(Format-Number $readTransactions)/$(Format-Number $writeTransactions)/$(Format-Number $deleteTransactions)/$(Format-Number $listTransactions)" -ForegroundColor Gray
            Write-Host "  - Avg Latency: $([math]::Round($avgLatencyMs, 2))ms | Unique IPs: $uniqueCallerIPs" -ForegroundColor Gray
        }
        else {
            Write-Host "  - [INFO] No transactions found in LAW for this file share" -ForegroundColor Gray
        }
    }
    else {
        # Fallback to Azure Monitor metrics
        $resourceId = "$($storageAccount.Id)/fileServices/default"
        
        # Get transaction metrics
        $transactionMetrics = $null
        try {
            $transactionMetrics = Get-AzMetric -ResourceId $resourceId `
                -MetricName "Transactions" `
                -StartTime $startTime `
                -EndTime $endTime `
                -TimeGrain 01:00:00 `
                -AggregationType Total `
                -MetricFilter "FileShare eq '$shareName'" `
                -ErrorAction SilentlyContinue
        }
        catch {
            Write-Host "  - [WARNING] Could not retrieve transaction metrics" -ForegroundColor Yellow
        }
        
        if ($transactionMetrics -and $transactionMetrics.Data) {
            foreach ($dataPoint in $transactionMetrics.Data) {
                if ($dataPoint.Total) {
                    $totalTransactions += $dataPoint.Total
                }
            }
        }
        
        # Try to get read/write breakdown
        try {
            $readMetrics = Get-AzMetric -ResourceId $resourceId `
                -MetricName "Transactions" `
                -StartTime $startTime `
                -EndTime $endTime `
                -TimeGrain 01:00:00 `
                -AggregationType Total `
                -MetricFilter "FileShare eq '$shareName' and ApiName eq 'GetFile'" `
                -ErrorAction SilentlyContinue
            
            if ($readMetrics -and $readMetrics.Data) {
                foreach ($dataPoint in $readMetrics.Data) {
                    if ($dataPoint.Total) { $readTransactions += $dataPoint.Total }
                }
            }
            
            $writeMetrics = Get-AzMetric -ResourceId $resourceId `
                -MetricName "Transactions" `
                -StartTime $startTime `
                -EndTime $endTime `
                -TimeGrain 01:00:00 `
                -AggregationType Total `
                -MetricFilter "FileShare eq '$shareName' and ApiName eq 'PutRange'" `
                -ErrorAction SilentlyContinue
            
            if ($writeMetrics -and $writeMetrics.Data) {
                foreach ($dataPoint in $writeMetrics.Data) {
                    if ($dataPoint.Total) { $writeTransactions += $dataPoint.Total }
                }
            }
        }
        catch {
            # Silently continue if breakdown metrics fail
        }
        
        Write-Host "  - Total Transactions ($timeRangeDisplay): $(Format-Number $totalTransactions)" -ForegroundColor Gray
    }
    
    # Normalize transactions to per-day for recommendation (if analyzing multiple days)
    $daysAnalyzed = [math]::Max(1, $TimeRangeHours / 24)
    $transactionsPerDay = [math]::Ceiling($totalTransactions / $daysAnalyzed)
    
    # Get tier recommendation
    $recommendation = Get-TierRecommendation `
        -TotalTransactions $transactionsPerDay `
        -ReadTransactions ([math]::Ceiling($readTransactions / $daysAnalyzed)) `
        -WriteTransactions ([math]::Ceiling($writeTransactions / $daysAnalyzed)) `
        -StorageUsedGB $usageGB `
        -CurrentTier $currentTier `
        -IsPremium $isPremiumAccount
    
    # Determine if action is needed
    $actionNeeded = $recommendation.RecommendedTier -ne $currentTier
    
    Write-Host "  - Recommended Tier: $($recommendation.RecommendedTier)" -ForegroundColor $(if ($actionNeeded) { "Yellow" } else { "Green" })
    
    # Add to results with enhanced metrics
    $transPerGBPerDay = if ($usageGB -gt 0) { [math]::Round($transactionsPerDay / $usageGB, 1) } else { 0 }
    
    $results.Add([PSCustomObject]@{
        FileShareName       = $shareName
        CurrentTier         = $currentTier
        RecommendedTier     = $recommendation.RecommendedTier
        UsedStorageGB       = $usageGB
        QuotaGB             = $quotaGB
        TotalTransactions   = $totalTransactions
        TransactionsPerDay  = $transactionsPerDay
        TransPerGBPerDay    = $transPerGBPerDay
        ReadTransactions    = $readTransactions
        WriteTransactions   = $writeTransactions
        DeleteTransactions  = $deleteTransactions
        ListTransactions    = $listTransactions
        AvgLatencyMs        = [math]::Round($avgLatencyMs, 2)
        UniqueCallerIPs     = $uniqueCallerIPs
        DataReadGB          = [math]::Round($bytesRead / 1GB, 2)
        DataWrittenGB       = [math]::Round($bytesWritten / 1GB, 2)
        ActionNeeded        = if ($actionNeeded) { "Yes" } else { "No" }
        Reason              = $recommendation.Reason
        PotentialSavings    = $recommendation.PotentialSavings
        AnalysisPeriod      = $timeRangeDisplay
        DataSource          = if ($useLAW) { "LogAnalytics" } else { "AzureMonitor" }
    })
    
    Write-Host ""
}

# Display results table
Write-Host ""
Write-Host "=============================================================================" -ForegroundColor Cyan
Write-Host "  ANALYSIS RESULTS (Data from $timeRangeDisplay)" -ForegroundColor Cyan
Write-Host "=============================================================================" -ForegroundColor Cyan
Write-Host ""

# Summary table
$results | Format-Table -Property @(
    @{Label="File Share"; Expression={$_.FileShareName}; Width=25},
    @{Label="Current"; Expression={$_.CurrentTier}; Width=18},
    @{Label="Recommended"; Expression={$_.RecommendedTier}; Width=18},
    @{Label="Used (GB)"; Expression={$_.UsedStorageGB}; Width=10},
    @{Label="Trans/Day"; Expression={Format-Number $_.TransactionsPerDay}; Width=12},
    @{Label="Trans/GB/Day"; Expression={$_.TransPerGBPerDay}; Width=12},
    @{Label="Action"; Expression={$_.ActionNeeded}; Width=8}
) -AutoSize

# Detailed recommendations
$actionableItems = $results | Where-Object { $_.ActionNeeded -eq "Yes" }

if ($actionableItems.Count -gt 0) {
    Write-Host ""
    Write-Host "=============================================================================" -ForegroundColor Yellow
    Write-Host "  COST OPTIMIZATION RECOMMENDATIONS" -ForegroundColor Yellow
    Write-Host "=============================================================================" -ForegroundColor Yellow
    Write-Host ""
    
    $totalPotentialSavings = 0
    
    foreach ($item in $actionableItems) {
        Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
        Write-Host "📁 FILE SHARE: $($item.FileShareName)" -ForegroundColor Cyan
        Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
        Write-Host ""
        
        # Current State
        Write-Host "   CURRENT STATE:" -ForegroundColor White
        Write-Host "   ├─ Access Tier:        $($item.CurrentTier)" -ForegroundColor Gray
        Write-Host "   ├─ Storage Used:       $($item.UsedStorageGB) GB / $($item.QuotaGB) GB quota" -ForegroundColor Gray
        Write-Host "   ├─ Transactions/Day:   $(Format-Number $item.TransactionsPerDay)" -ForegroundColor Gray
        Write-Host "   ├─ Trans/GB/Day:       $($item.TransPerGBPerDay)" -ForegroundColor Gray
        if ($item.DataSource -eq "LogAnalytics") {
            Write-Host "   ├─ Read Operations:    $(Format-Number $item.ReadTransactions)" -ForegroundColor Gray
            Write-Host "   ├─ Write Operations:   $(Format-Number $item.WriteTransactions)" -ForegroundColor Gray
            Write-Host "   ├─ Data Read:          $($item.DataReadGB) GB" -ForegroundColor Gray
            Write-Host "   ├─ Data Written:       $($item.DataWrittenGB) GB" -ForegroundColor Gray
            Write-Host "   ├─ Avg Latency:        $($item.AvgLatencyMs) ms" -ForegroundColor Gray
            Write-Host "   └─ Unique Clients:     $($item.UniqueCallerIPs) IPs" -ForegroundColor Gray
        }
        else {
            Write-Host "   └─ Read/Write:         $(Format-Number $item.ReadTransactions) / $(Format-Number $item.WriteTransactions)" -ForegroundColor Gray
        }
        Write-Host ""
        
        # Recommendation
        Write-Host "   RECOMMENDATION:" -ForegroundColor Green
        Write-Host "   ├─ Change to:          $($item.RecommendedTier)" -ForegroundColor Green
        Write-Host "   ├─ Reason:             $($item.Reason)" -ForegroundColor White
        Write-Host "   └─ Estimated Savings:  $($item.PotentialSavings)" -ForegroundColor Yellow
        Write-Host ""
        
        # Azure CLI/PowerShell commands
        Write-Host "   IMPLEMENTATION:" -ForegroundColor Magenta
        Write-Host "   PowerShell:" -ForegroundColor Gray
        Write-Host "   Update-AzRmStorageShare -ResourceGroupName '$ResourceGroupName' -StorageAccountName '$StorageAccountName' -Name '$($item.FileShareName)' -AccessTier '$($item.RecommendedTier)'" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "   Azure CLI:" -ForegroundColor Gray
        Write-Host "   az storage share-rm update --resource-group '$ResourceGroupName' --storage-account '$StorageAccountName' --name '$($item.FileShareName)' --access-tier '$($item.RecommendedTier)'" -ForegroundColor DarkGray
        Write-Host ""
    }
    
    # Summary
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow
    Write-Host "   SUMMARY: $($actionableItems.Count) file share(s) can be optimized for cost savings" -ForegroundColor Yellow
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow
    Write-Host ""
    
    # Batch command for all changes
    if ($actionableItems.Count -gt 1) {
        Write-Host "   BATCH UPDATE (all shares at once):" -ForegroundColor Magenta
        Write-Host "   # PowerShell script to update all recommended tiers:" -ForegroundColor Gray
        foreach ($item in $actionableItems) {
            Write-Host "   Update-AzRmStorageShare -ResourceGroupName '$ResourceGroupName' -StorageAccountName '$StorageAccountName' -Name '$($item.FileShareName)' -AccessTier '$($item.RecommendedTier)'" -ForegroundColor DarkGray
        }
        Write-Host ""
    }
}
else {
    Write-Host ""
    Write-Host "=============================================================================" -ForegroundColor Green
    Write-Host "  ✅ ALL FILE SHARES OPTIMALLY CONFIGURED" -ForegroundColor Green
    Write-Host "=============================================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "   All file shares are using optimal access tiers based on the analyzed" -ForegroundColor White
    Write-Host "   usage patterns from the last $timeRangeDisplay." -ForegroundColor White
    Write-Host ""
    Write-Host "   No tier changes recommended at this time." -ForegroundColor Gray
    Write-Host ""
}

# Export results
$exportDir = if ([string]::IsNullOrEmpty($OutputPath)) { $PSScriptRoot } else { $OutputPath }
if (-not (Test-Path $exportDir)) {
    New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
}

$exportFileName = "FileShareTierAnalysis_$($StorageAccountName)_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$exportPath = Join-Path $exportDir $exportFileName
$results | Export-Csv -Path $exportPath -NoTypeInformation

Write-Host "[INFO] Analysis complete!" -ForegroundColor Green
Write-Host "[INFO] Results exported to: $exportPath" -ForegroundColor Green
Write-Host "[INFO] Data source: $(if ($useLAW) { 'Log Analytics Workspace' } else { 'Azure Monitor Metrics' })" -ForegroundColor Gray
Write-Host "[INFO] Analysis period: $timeRangeDisplay" -ForegroundColor Gray
Write-Host ""

# Return results object for pipeline usage
return $results

#endregion
