<#
.SYNOPSIS
    Analyzes Azure File Share access patterns and recommends optimal access tiers for cost savings.

.DESCRIPTION
    This script lists all file shares in one or more storage accounts, retrieves performance metrics
    from Log Analytics Workspace (StorageFileLogs) or Azure Monitor, and provides tier 
    recommendations based on Microsoft's guidelines.
    
    When only -WorkspaceId is provided (without -StorageAccountName), the script auto-discovers
    all storage accounts streaming StorageFileLogs to that workspace and analyzes them all,
    producing a single consolidated CSV report.
    
    Azure Files Access Tier Recommendations:
    - Hot: High storage cost, low transaction cost - best for frequently accessed data
    - Cool: Low storage cost, high transaction cost - best for infrequently accessed data
    - Transaction Optimized: Lowest transaction cost - best for transaction-heavy workloads
    - Premium: SSD-based, lowest latency - best for IO-intensive workloads

.PARAMETER StorageAccountName
    Optional. The name of a specific Azure Storage Account to analyze.
    If omitted and -WorkspaceId is provided, auto-discovers all storage accounts from LAW.

.PARAMETER ResourceGroupName
    Optional. The resource group containing the storage account.
    Required when -StorageAccountName is specified.

.PARAMETER WorkspaceId
    Log Analytics Workspace ID to query for metrics (recommended for per-file-share accuracy).
    When provided alone, auto-discovers all storage accounts streaming logs to this workspace.
    If not provided, -StorageAccountName and -ResourceGroupName are required and Azure Monitor is used.

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
    .\Analyze-FileShareTiers.ps1 -WorkspaceId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -TimeRangeDays 7
    # Auto-discovers all storage accounts streaming to the LAW and analyzes all file shares.

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
    [Parameter(Mandatory = $false)]
    [string]$StorageAccountName,
    
    [Parameter(Mandatory = $false)]
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
| extend BillingCategory = case(
    Category == "StorageDelete", "Delete",
    OperationName has_any ("List", "QueryDirectory", "ListFilesAndDirectories", "ListHandles"), "List",
    Category == "StorageWrite", "Write",
    Category == "StorageRead", "Read",
    "Other")
| summarize 
    TotalTransactions = count(),
    WriteTransactions = countif(BillingCategory == "Write"),
    ListTransactions = countif(BillingCategory == "List"),
    ReadTransactions = countif(BillingCategory == "Read"),
    OtherTransactions = countif(BillingCategory == "Other"),
    DeleteTransactions = countif(BillingCategory == "Delete"),
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
        Recommends an access tier by calculating estimated monthly cost for each tier
        using actual Azure pricing and the observed transaction/storage pattern.
        
        Follows Microsoft's guidance: calculate actual cost per tier using the 5 billing
        transaction categories (Write, List, Read, Other/Protocol, Delete) plus storage,
        metadata, and data retrieval charges. Recommends the cheapest tier.
        
        Reference: https://learn.microsoft.com/en-us/azure/storage/files/understanding-billing
    #>
    [CmdletBinding()]
    param(
        [hashtable]$Pricing,
        [double]$StorageUsedGiB,
        [long]$WriteTransactionsPerMonth,
        [long]$ListTransactionsPerMonth,
        [long]$ReadTransactionsPerMonth,
        [long]$OtherTransactionsPerMonth,
        [long]$DeleteTransactionsPerMonth,
        [double]$DataReadGiBPerMonth,
        [string]$CurrentTier,
        [bool]$IsPremium
    )
    
    # Default return structure
    $defaultResult = @{
        RecommendedTier              = $CurrentTier
        Reason                       = ""
        PotentialSavings             = "None - already optimal"
        EstCost_TransactionOptimized = 0.0
        EstCost_Hot                  = 0.0
        EstCost_Cool                 = 0.0
        CheapestCost                 = 0.0
        CurrentCost                  = 0.0
    }
    
    # Premium file shares cannot change tiers
    if ($IsPremium) {
        $defaultResult.RecommendedTier = "Premium"
        $defaultResult.Reason = "Premium file shares have fixed tier (SSD-based)"
        $defaultResult.PotentialSavings = "N/A"
        return $defaultResult
    }
    
    # If no pricing available, fall back to heuristic
    if ($null -eq $Pricing -or $Pricing.Count -eq 0) {
        $totalTrans = $WriteTransactionsPerMonth + $ListTransactionsPerMonth + $ReadTransactionsPerMonth + $OtherTransactionsPerMonth + $DeleteTransactionsPerMonth
        return Get-TierRecommendationHeuristic -TotalTransactions $totalTrans -StorageUsedGB $StorageUsedGiB -CurrentTier $CurrentTier
    }
    
    # Calculate estimated monthly cost for each tier using actual pricing
    # Cost = StorageAtRest + Metadata + WriteOps + ListOps + ReadOps + OtherOps + DataRetrieval
    # Note: Delete operations are always free across all tiers
    # Note: Metadata is estimated at ~3% of data volume (typical for file shares per Microsoft docs)
    $metadataGiB = $StorageUsedGiB * 0.03
    
    $costs = @{}
    foreach ($tierKey in @("TransactionOptimized", "Hot", "Cool")) {
        $tp = $Pricing[$tierKey]
        
        $storageCost    = $StorageUsedGiB * $tp.DataStoredPerGiBMonth
        $metadataCost   = $metadataGiB * $tp.MetadataPerGiBMonth
        $writeCost      = ($WriteTransactionsPerMonth / 10000) * $tp.WriteOpsPerTenK
        $listCost       = ($ListTransactionsPerMonth / 10000) * $tp.ListOpsPerTenK
        $readCost       = ($ReadTransactionsPerMonth / 10000) * $tp.ReadOpsPerTenK
        $otherCost      = ($OtherTransactionsPerMonth / 10000) * $tp.OtherOpsPerTenK
        # Delete transactions are always free - no charge
        $retrievalCost  = $DataReadGiBPerMonth * $tp.DataRetrievalPerGiB
        
        $totalCost = $storageCost + $metadataCost + $writeCost + $listCost + $readCost + $otherCost + $retrievalCost
        $costs[$tierKey] = [math]::Round($totalCost, 2)
    }
    
    # Find cheapest tier
    $cheapestTier = ($costs.GetEnumerator() | Sort-Object Value | Select-Object -First 1).Key
    $cheapestCost = $costs[$cheapestTier]
    
    # Get current tier cost
    $currentTierKey = $CurrentTier.Replace(" ", "")
    if (-not $costs.ContainsKey($currentTierKey)) {
        $currentTierKey = "TransactionOptimized"  # Default fallback
    }
    $currentCost = $costs[$currentTierKey]
    
    # Calculate savings
    $monthlySavings = [math]::Round($currentCost - $cheapestCost, 2)
    $yearlySavings = [math]::Round($monthlySavings * 12, 2)
    $savingsPercent = if ($currentCost -gt 0) { [math]::Round(($monthlySavings / $currentCost) * 100, 1) } else { 0 }
    
    # Build reason
    $reason = if ($cheapestTier -eq $currentTierKey) {
        "Current tier ($CurrentTier) is already the most cost-effective at `$$currentCost/month"
    }
    else {
        "$cheapestTier estimated at `$$cheapestCost/month vs current $CurrentTier at `$$currentCost/month"
    }
    
    # Build savings string
    $savingsStr = if ($monthlySavings -gt 0) {
        "~`$$monthlySavings/month (`$$yearlySavings/year, $savingsPercent% reduction)"
    }
    else {
        "None - already optimal"
    }
    
    return @{
        RecommendedTier              = $cheapestTier
        Reason                       = $reason
        PotentialSavings             = $savingsStr
        EstCost_TransactionOptimized = $costs["TransactionOptimized"]
        EstCost_Hot                  = $costs["Hot"]
        EstCost_Cool                 = $costs["Cool"]
        CheapestCost                 = $cheapestCost
        CurrentCost                  = $currentCost
    }
}

function Get-TierRecommendationHeuristic {
    <#
    .SYNOPSIS
        Fallback heuristic-based recommendation when pricing data is unavailable.
        Uses transactions-per-GB ratio as a rough proxy.
    #>
    [CmdletBinding()]
    param(
        [long]$TotalTransactions,
        [double]$StorageUsedGB,
        [string]$CurrentTier
    )
    
    $transactionsPerGB = if ($StorageUsedGB -gt 0) { $TotalTransactions / $StorageUsedGB } else { 0 }
    
    $recommendedTier = if ($TotalTransactions -eq 0) { "Cool" }
    elseif ($transactionsPerGB -gt 100) { "TransactionOptimized" }
    elseif ($transactionsPerGB -ge 10) { "Hot" }
    else { "Cool" }
    
    $reason = if ($TotalTransactions -eq 0) {
        "No transactions detected - Cool recommended (pricing unavailable for cost estimate)"
    }
    else {
        "$([math]::Round($transactionsPerGB, 1)) trans/GB/month heuristic suggests $recommendedTier (pricing unavailable for cost estimate)"
    }
    
    return @{
        RecommendedTier              = $recommendedTier
        Reason                       = $reason
        PotentialSavings             = "Pricing data required for cost estimate"
        EstCost_TransactionOptimized = 0.0
        EstCost_Hot                  = 0.0
        EstCost_Cool                 = 0.0
        CheapestCost                 = 0.0
        CurrentCost                  = 0.0
    }
}

function Format-BytesToGB {
    param([long]$Bytes)
    return [math]::Round($Bytes / 1GB, 2)
}

function Format-Number {
    param([long]$Number)
    return $Number.ToString("N0")
}

function Get-StorageAccountsFromLAW {
    <#
    .SYNOPSIS
        Discovers all storage accounts streaming StorageFileLogs to a Log Analytics Workspace.
    #>
    [CmdletBinding()]
    param(
        [string]$WorkspaceId,
        [datetime]$StartTime,
        [datetime]$EndTime,
        [int]$TimeoutSeconds = 300
    )
    
    $startStr = $StartTime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $endStr = $EndTime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    
    $query = @"
StorageFileLogs
| where TimeGenerated >= datetime($startStr) and TimeGenerated <= datetime($endStr)
| distinct AccountName
| order by AccountName asc
"@
    
    try {
        $result = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $query -Wait $TimeoutSeconds -ErrorAction Stop
        return @($result.Results)
    }
    catch {
        Write-Warning "Failed to discover storage accounts from LAW: $($_.Exception.Message)"
        return $null
    }
}

function Get-AzureFilesPricing {
    <#
    .SYNOPSIS
        Retrieves Azure Files pay-as-you-go pricing for cost comparison across tiers.
        Queries the public Azure Retail Prices API (no auth required) with hardcoded fallback.
        
        Reference: https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Region,
        
        [Parameter(Mandatory)]
        [string]$Redundancy  # LRS, ZRS, GRS, GZRS, RA-GRS, RA-GZRS
    )
    
    $redundancyUpper = $Redundancy.ToUpper()
    $tiers = @("Transaction Optimized", "Hot", "Cool")
    $pricing = @{}
    
    try {
        Write-Host "  [PRICING] Fetching Azure Files pricing for region '$Region' ($redundancyUpper)..." -ForegroundColor Gray
        
        $allItems = [System.Collections.Generic.List[PSCustomObject]]::new()
        $apiFilter = "serviceName eq 'Azure Files' and armRegionName eq '$Region' and priceType eq 'Consumption'"
        $url = "https://prices.azure.com/api/retail/prices?" + "`$filter=" + $apiFilter
        
        $pageCount = 0
        do {
            $response = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 30 -ErrorAction Stop
            foreach ($item in $response.Items) {
                $allItems.Add($item)
            }
            $url = $response.NextPageLink
            $pageCount++
            if ($pageCount -gt 20) { break }  # Safety limit
        } while ($url)
        
        foreach ($tier in $tiers) {
            $tierKey = $tier.Replace(" ", "")  # "TransactionOptimized", "Hot", "Cool"
            
            # Match items by skuName containing both tier and redundancy
            $tierItems = $allItems | Where-Object { 
                $_.skuName -like "*$tier*" -and $_.skuName -like "*$redundancyUpper*" -and $_.type -eq "Consumption"
            }
            
            if ($tierItems.Count -eq 0) {
                Write-Host "  [PRICING] No pricing found for tier '$tier' in region '$Region' - using fallback" -ForegroundColor Yellow
                $pricing = $null
                break
            }
            
            $dataStored = ($tierItems | Where-Object { $_.meterName -like "*Data Stored" } | Select-Object -First 1).retailPrice
            $metadata   = ($tierItems | Where-Object { $_.meterName -like "*Metadata*" } | Select-Object -First 1).retailPrice
            $writeOps   = ($tierItems | Where-Object { $_.meterName -like "*Write*" -and $_.meterName -like "*Operations*" } | Select-Object -First 1).retailPrice
            $listOps    = ($tierItems | Where-Object { $_.meterName -like "*List*" -and $_.meterName -like "*Operations*" } | Select-Object -First 1).retailPrice
            $readOps    = ($tierItems | Where-Object { $_.meterName -like "*Read*" -and $_.meterName -like "*Operations*" } | Select-Object -First 1).retailPrice
            $otherOps   = ($tierItems | Where-Object { $_.meterName -like "*Other*" -and $_.meterName -like "*Operations*" } | Select-Object -First 1).retailPrice
            $retrieval  = ($tierItems | Where-Object { $_.meterName -like "*Data Retrieval*" } | Select-Object -First 1).retailPrice
            
            # Validate that we got the critical meters
            if ($null -eq $dataStored -or $null -eq $writeOps) {
                Write-Host "  [PRICING] Incomplete pricing for tier '$tier' - using fallback" -ForegroundColor Yellow
                $pricing = $null
                break
            }
            
            $pricing[$tierKey] = @{
                DataStoredPerGiBMonth   = [double]$dataStored
                MetadataPerGiBMonth     = if ($null -ne $metadata) { [double]$metadata } else { 0.0 }
                WriteOpsPerTenK         = [double]$writeOps
                ListOpsPerTenK          = if ($null -ne $listOps) { [double]$listOps } else { [double]$writeOps }
                ReadOpsPerTenK          = if ($null -ne $readOps) { [double]$readOps } else { 0.0 }
                OtherOpsPerTenK         = if ($null -ne $otherOps) { [double]$otherOps } else { 0.0 }
                DataRetrievalPerGiB     = if ($null -ne $retrieval) { [double]$retrieval } else { 0.0 }
            }
        }
        
        if ($null -ne $pricing -and $pricing.Count -eq 3) {
            Write-Host "  [PRICING] Successfully retrieved pricing from Azure Retail Prices API" -ForegroundColor Green
            return $pricing
        }
    }
    catch {
        Write-Host "  [PRICING] Could not fetch pricing from API: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    
    # Fallback: Hardcoded approximate pricing (East US, LRS, USD)
    Write-Host "  [PRICING] Using fallback pricing (East US LRS approximate rates)" -ForegroundColor Yellow
    Write-Host "  [PRICING] For accurate results, verify at https://azure.microsoft.com/pricing/details/storage/files/" -ForegroundColor Gray
    
    $pricing = @{
        TransactionOptimized = @{
            DataStoredPerGiBMonth   = 0.0600
            MetadataPerGiBMonth     = 0.0
            WriteOpsPerTenK         = 0.0500
            ListOpsPerTenK          = 0.0500
            ReadOpsPerTenK          = 0.0200
            OtherOpsPerTenK         = 0.0040
            DataRetrievalPerGiB     = 0.0
        }
        Hot = @{
            DataStoredPerGiBMonth   = 0.0300
            MetadataPerGiBMonth     = 0.0200
            WriteOpsPerTenK         = 0.1000
            ListOpsPerTenK          = 0.1000
            ReadOpsPerTenK          = 0.0200
            OtherOpsPerTenK         = 0.0040
            DataRetrievalPerGiB     = 0.0
        }
        Cool = @{
            DataStoredPerGiBMonth   = 0.0160
            MetadataPerGiBMonth     = 0.0260
            WriteOpsPerTenK         = 0.1300
            ListOpsPerTenK          = 0.1300
            ReadOpsPerTenK          = 0.0200
            OtherOpsPerTenK         = 0.0065
            DataRetrievalPerGiB     = 0.0100
        }
    }
    
    return $pricing
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

# Step 3: Validate parameters and determine mode
$autoDiscoverMode = $false

if ([string]::IsNullOrEmpty($StorageAccountName) -and [string]::IsNullOrEmpty($WorkspaceId)) {
    Write-Host "[ERROR] You must provide either -WorkspaceId (to auto-discover all storage accounts) or both -StorageAccountName and -ResourceGroupName." -ForegroundColor Red
    Write-Host ""
    Write-Host "Usage examples:" -ForegroundColor Yellow
    Write-Host "  .\Analyze-FileShareTiers.ps1 -WorkspaceId 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' -TimeRangeDays 7" -ForegroundColor Gray
    Write-Host "  .\Analyze-FileShareTiers.ps1 -StorageAccountName 'mysa' -ResourceGroupName 'my-rg' -WorkspaceId 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'" -ForegroundColor Gray
    Write-Host ""
    exit 1
}

if (-not [string]::IsNullOrEmpty($StorageAccountName) -and [string]::IsNullOrEmpty($ResourceGroupName)) {
    Write-Host "[ERROR] -ResourceGroupName is required when -StorageAccountName is specified." -ForegroundColor Red
    exit 1
}

if ([string]::IsNullOrEmpty($StorageAccountName) -and -not [string]::IsNullOrEmpty($WorkspaceId)) {
    $autoDiscoverMode = $true
}

# Calculate time range (needed before discovery)
$endTime = Get-Date
if ($TimeRangeDays -gt 0) {
    $TimeRangeHours = $TimeRangeDays * 24
}
$startTime = $endTime.AddHours(-$TimeRangeHours)
$timeRangeDisplay = if ($TimeRangeHours -ge 24) { "$([math]::Floor($TimeRangeHours / 24)) day(s)" } else { "$TimeRangeHours hour(s)" }

# Build the list of storage accounts to analyze
$storageAccountsToAnalyze = [System.Collections.Generic.List[PSCustomObject]]::new()

if ($autoDiscoverMode) {
    Write-Host "[DISCOVERY] Auto-discovering storage accounts from Log Analytics Workspace..." -ForegroundColor Yellow
    Write-Host "[INFO] Workspace ID: $WorkspaceId" -ForegroundColor Gray
    Write-Host "[INFO] Time range: $($startTime.ToString('yyyy-MM-dd HH:mm')) to $($endTime.ToString('yyyy-MM-dd HH:mm')) ($timeRangeDisplay)" -ForegroundColor Gray
    Write-Host ""
    
    $discoveredAccounts = Get-StorageAccountsFromLAW -WorkspaceId $WorkspaceId -StartTime $startTime -EndTime $endTime
    
    if ($null -eq $discoveredAccounts -or $discoveredAccounts.Count -eq 0) {
        Write-Host "[ERROR] No storage accounts found streaming StorageFileLogs to this workspace in the specified time range." -ForegroundColor Red
        Write-Host ""
        Write-Host "Please verify:" -ForegroundColor Yellow
        Write-Host "  1. The Workspace ID is correct" -ForegroundColor Gray
        Write-Host "  2. StorageFileLogs diagnostic setting is enabled on at least one storage account" -ForegroundColor Gray
        Write-Host "  3. Logs have been ingested (allow 15-30 min after enabling)" -ForegroundColor Gray
        Write-Host ""
        exit 1
    }
    
    Write-Host "[DISCOVERY] Found $($discoveredAccounts.Count) storage account(s) in LAW:" -ForegroundColor Green
    
    foreach ($discovered in $discoveredAccounts) {
        $accountName = $discovered.AccountName
        Write-Host "  - Looking up $accountName in Azure..." -ForegroundColor Gray
        
        try {
            $sa = Get-AzStorageAccount | Where-Object { $_.StorageAccountName -eq $accountName }
            if ($sa) {
                $storageAccountsToAnalyze.Add([PSCustomObject]@{
                    StorageAccountName = $sa.StorageAccountName
                    ResourceGroupName  = $sa.ResourceGroupName
                    StorageAccount     = $sa
                })
                Write-Host "    Found in resource group: $($sa.ResourceGroupName)" -ForegroundColor Green
            }
            else {
                Write-Host "    [WARNING] Not found in current subscription - skipping" -ForegroundColor Yellow
            }
        }
        catch {
            Write-Host "    [WARNING] Failed to look up: $($_.Exception.Message) - skipping" -ForegroundColor Yellow
        }
    }
    
    if ($storageAccountsToAnalyze.Count -eq 0) {
        Write-Host ""
        Write-Host "[ERROR] None of the discovered storage accounts are accessible in the current subscription." -ForegroundColor Red
        exit 1
    }
    
    Write-Host ""
    Write-Host "[INFO] Will analyze $($storageAccountsToAnalyze.Count) storage account(s)" -ForegroundColor Green
}
else {
    # Single storage account mode
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
    $storageAccountsToAnalyze.Add([PSCustomObject]@{
        StorageAccountName = $StorageAccountName
        ResourceGroupName  = $ResourceGroupName
        StorageAccount     = $storageAccount
    })
}

Write-Host ""
Write-Host "[INFO] Analyzing metrics from $($startTime.ToString('yyyy-MM-dd HH:mm')) to $($endTime.ToString('yyyy-MM-dd HH:mm')) ($timeRangeDisplay)" -ForegroundColor Yellow
Write-Host ""

# Build the consolidated results table
$results = [System.Collections.Generic.List[PSCustomObject]]::new()

# ============================================================================
# Loop over each storage account
# ============================================================================
foreach ($saEntry in $storageAccountsToAnalyze) {
    $currentSAName = $saEntry.StorageAccountName
    $currentRGName = $saEntry.ResourceGroupName
    $storageAccount = $saEntry.StorageAccount
    
    Write-Host "=============================================================================" -ForegroundColor Cyan
    Write-Host "  Storage Account: $currentSAName (RG: $currentRGName)" -ForegroundColor Cyan
    Write-Host "=============================================================================" -ForegroundColor Cyan
    
    $isPremiumAccount = $storageAccount.Sku.Name -like "*Premium*"
    Write-Host "[INFO] SKU: $($storageAccount.Sku.Name) | Kind: $($storageAccount.Kind) | Location: $($storageAccount.Location)" -ForegroundColor Green
    
    # Fetch pricing for cost-based tier recommendation
    $redundancy = ($storageAccount.Sku.Name -split '_')[1]  # e.g., "Standard_LRS" -> "LRS"
    $accountPricing = Get-AzureFilesPricing -Region $storageAccount.Location -Redundancy $redundancy
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
        Write-Host "[WARNING] Failed to list file shares for $currentSAName via data plane: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "[INFO] Trying ARM API (Get-AzRmStorageShare) instead..." -ForegroundColor Gray
        
        try {
            $fileShares = Get-AzRmStorageShare -ResourceGroupName $currentRGName -StorageAccountName $currentSAName -ErrorAction Stop
        }
        catch {
            Write-Host "[WARNING] Could not list file shares for $currentSAName - skipping (Error: $($_.Exception.Message))" -ForegroundColor Yellow
            Write-Host ""
            continue
        }
    }
    
    # Filter to specific file share if provided
    if ($FileShareName) {
        $fileShares = $fileShares | Where-Object { $_.Name -eq $FileShareName }
        if ($fileShares.Count -eq 0) {
            Write-Host "[WARNING] File share '$FileShareName' not found in $currentSAName - skipping" -ForegroundColor Yellow
            Write-Host ""
            continue
        }
        Write-Host "[INFO] Analyzing specific file share: $FileShareName" -ForegroundColor Green
    }
    
    if ($null -eq $fileShares -or @($fileShares).Count -eq 0) {
        Write-Host "[WARNING] No file shares found in $currentSAName - skipping" -ForegroundColor Yellow
        Write-Host ""
        continue
    }
    
    Write-Host "[INFO] Found $(@($fileShares).Count) file share(s)" -ForegroundColor Green
    Write-Host ""
    
    # Determine data source for this storage account
    $useLAW = -not [string]::IsNullOrEmpty($WorkspaceId)
    $lawMetrics = $null
    if ($useLAW) {
        Write-Host "[INFO] Data Source: Log Analytics Workspace" -ForegroundColor Green
        Write-Host "[INFO] Querying LAW for file share metrics..." -ForegroundColor Yellow
        $lawMetrics = Get-FileShareMetricsFromLAW -WorkspaceId $WorkspaceId -StorageAccountName $currentSAName -FileShareName $FileShareName -StartTime $startTime -EndTime $endTime
        
        if ($null -eq $lawMetrics -or $lawMetrics.Count -eq 0) {
            Write-Host "[WARNING] No metrics found in LAW for $currentSAName. Falling back to Azure Monitor." -ForegroundColor Yellow
            $useLAW = $false
        }
        else {
            Write-Host "[INFO] Found metrics for $($lawMetrics.Count) file share(s) in LAW" -ForegroundColor Green
        }
    }
    else {
        Write-Host "[INFO] Data Source: Azure Monitor Metrics" -ForegroundColor Yellow
    }
    Write-Host ""
    
    foreach ($share in $fileShares) {
        $shareName = $share.Name
        Write-Host "[ANALYZING] File share: $shareName" -ForegroundColor Cyan
        
        # Get share properties using Get-AzRmStorageShare for accurate usage stats
        $shareProperties = $null
        $usageBytes = 0
        $quotaGB = 0
        $currentTier = "TransactionOptimized"
        
        try {
            $shareProperties = Get-AzRmStorageShare -ResourceGroupName $currentRGName -StorageAccountName $currentSAName -Name $shareName -GetShareUsage -ErrorAction Stop
            
            $quotaGB = $shareProperties.QuotaGiB
            $currentTier = if ($shareProperties.AccessTier) { $shareProperties.AccessTier } else { "TransactionOptimized" }
            $usageBytes = if ($shareProperties.ShareUsageBytes) { $shareProperties.ShareUsageBytes } else { 0 }
        }
        catch {
            Write-Host "  - [WARNING] Could not get share properties via ARM, trying data plane..." -ForegroundColor Yellow
            
            try {
                $sharePropertiesDP = Get-AzStorageShare -Context $storageContext -Name $shareName -ErrorAction Stop
                $quotaGB = $sharePropertiesDP.ShareProperties.QuotaInGB
                $currentTier = if ($sharePropertiesDP.ShareProperties.AccessTier) { $sharePropertiesDP.ShareProperties.AccessTier } else { "TransactionOptimized" }
                
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
    $otherTransactions = 0
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
            $otherTransactions = [long]$shareMetrics.OtherTransactions
            $avgLatencyMs = [double]$shareMetrics.AvgLatencyMs
            $uniqueCallerIPs = [int]$shareMetrics.UniqueCallerIPs
            $bytesRead = [long]$shareMetrics.TotalBytesRead
            $bytesWritten = [long]$shareMetrics.TotalBytesWritten
            
            Write-Host "  - Total Transactions ($timeRangeDisplay): $(Format-Number $totalTransactions)" -ForegroundColor Gray
            Write-Host "  - Write/List/Read/Other/Delete: $(Format-Number $writeTransactions)/$(Format-Number $listTransactions)/$(Format-Number $readTransactions)/$(Format-Number $otherTransactions)/$(Format-Number $deleteTransactions)" -ForegroundColor Gray
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
    
    # Normalize transactions to per-day and project to monthly (30 days) for cost estimation
    $daysAnalyzed = [math]::Max(1, $TimeRangeHours / 24)
    $transactionsPerDay = [math]::Ceiling($totalTransactions / $daysAnalyzed)
    $monthlyMultiplier = 30 / $daysAnalyzed
    
    # Get tier recommendation using cost-based analysis
    $recommendation = Get-TierRecommendation `
        -Pricing $accountPricing `
        -StorageUsedGiB $usageGB `
        -WriteTransactionsPerMonth ([long]($writeTransactions * $monthlyMultiplier)) `
        -ListTransactionsPerMonth ([long]($listTransactions * $monthlyMultiplier)) `
        -ReadTransactionsPerMonth ([long]($readTransactions * $monthlyMultiplier)) `
        -OtherTransactionsPerMonth ([long]($otherTransactions * $monthlyMultiplier)) `
        -DeleteTransactionsPerMonth ([long]($deleteTransactions * $monthlyMultiplier)) `
        -DataReadGiBPerMonth ([double]($bytesRead / 1GB * $monthlyMultiplier)) `
        -CurrentTier $currentTier `
        -IsPremium $isPremiumAccount
    
    # Determine if action is needed
    $actionNeeded = $recommendation.RecommendedTier -ne $currentTier
    
    Write-Host "  - Recommended Tier: $($recommendation.RecommendedTier)" -ForegroundColor $(if ($actionNeeded) { "Yellow" } else { "Green" })
    
    # Add to results with enhanced metrics
    $transPerGBPerDay = if ($usageGB -gt 0) { [math]::Round($transactionsPerDay / $usageGB, 1) } else { 0 }
    
    $results.Add([PSCustomObject]@{
        StorageAccountName  = $currentSAName
        ResourceGroupName   = $currentRGName
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
        OtherTransactions   = $otherTransactions
        AvgLatencyMs        = [math]::Round($avgLatencyMs, 2)
        UniqueCallerIPs     = $uniqueCallerIPs
        DataReadGB          = [math]::Round($bytesRead / 1GB, 2)
        DataWrittenGB       = [math]::Round($bytesWritten / 1GB, 2)
        ActionNeeded        = if ($actionNeeded) { "Yes" } else { "No" }
        Reason              = $recommendation.Reason
        PotentialSavings    = $recommendation.PotentialSavings
        EstCost_TransOpt    = $recommendation.EstCost_TransactionOptimized
        EstCost_Hot         = $recommendation.EstCost_Hot
        EstCost_Cool        = $recommendation.EstCost_Cool
        CurrentEstCost      = $recommendation.CurrentCost
        AnalysisPeriod      = $timeRangeDisplay
        DataSource          = if ($useLAW) { "LogAnalytics" } else { "AzureMonitor" }
    })
    
    Write-Host ""
    } # end foreach share
} # end foreach storage account

# Display results table
Write-Host ""
Write-Host "=============================================================================" -ForegroundColor Cyan
Write-Host "  ANALYSIS RESULTS (Data from $timeRangeDisplay)" -ForegroundColor Cyan
Write-Host "=============================================================================" -ForegroundColor Cyan
Write-Host ""

# Summary table
$results | Format-Table -Property @(
    @{Label="Storage Account"; Expression={$_.StorageAccountName}; Width=22},
    @{Label="File Share"; Expression={$_.FileShareName}; Width=22},
    @{Label="Current"; Expression={$_.CurrentTier}; Width=18},
    @{Label="Recommended"; Expression={$_.RecommendedTier}; Width=18},
    @{Label="Used (GB)"; Expression={$_.UsedStorageGB}; Width=9},
    @{Label="Est.TransOpt"; Expression={"`$$($_.EstCost_TransOpt)"}; Width=12},
    @{Label="Est.Hot"; Expression={"`$$($_.EstCost_Hot)"}; Width=10},
    @{Label="Est.Cool"; Expression={"`$$($_.EstCost_Cool)"}; Width=10},
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
        Write-Host "📁 $($item.StorageAccountName) / $($item.FileShareName)" -ForegroundColor Cyan
        Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
        Write-Host ""
        
        # Current State
        Write-Host "   CURRENT STATE:" -ForegroundColor White
        Write-Host "   ├─ Storage Account:    $($item.StorageAccountName) (RG: $($item.ResourceGroupName))" -ForegroundColor Gray
        Write-Host "   ├─ Access Tier:        $($item.CurrentTier)" -ForegroundColor Gray
        Write-Host "   ├─ Storage Used:       $($item.UsedStorageGB) GB / $($item.QuotaGB) GB quota" -ForegroundColor Gray
        Write-Host "   ├─ Transactions/Day:   $(Format-Number $item.TransactionsPerDay)" -ForegroundColor Gray
        Write-Host "   ├─ Trans/GB/Day:       $($item.TransPerGBPerDay)" -ForegroundColor Gray
        if ($item.DataSource -eq "LogAnalytics") {
            Write-Host "   ├─ Write Operations:   $(Format-Number $item.WriteTransactions) (billing)" -ForegroundColor Gray
            Write-Host "   ├─ List Operations:    $(Format-Number $item.ListTransactions) (billing)" -ForegroundColor Gray
            Write-Host "   ├─ Read Operations:    $(Format-Number $item.ReadTransactions) (billing)" -ForegroundColor Gray
            Write-Host "   ├─ Other Operations:   $(Format-Number $item.OtherTransactions) (billing)" -ForegroundColor Gray
            Write-Host "   ├─ Delete Operations:  $(Format-Number $item.DeleteTransactions) (free)" -ForegroundColor Gray
            Write-Host "   ├─ Data Read:          $($item.DataReadGB) GB" -ForegroundColor Gray
            Write-Host "   ├─ Data Written:       $($item.DataWrittenGB) GB" -ForegroundColor Gray
            Write-Host "   ├─ Avg Latency:        $($item.AvgLatencyMs) ms" -ForegroundColor Gray
            Write-Host "   └─ Unique Clients:     $($item.UniqueCallerIPs) IPs" -ForegroundColor Gray
        }
        else {
            Write-Host "   └─ Read/Write:         $(Format-Number $item.ReadTransactions) / $(Format-Number $item.WriteTransactions)" -ForegroundColor Gray
        }
        Write-Host ""
        
        # Cost Comparison
        if ($item.EstCost_TransOpt -gt 0 -or $item.EstCost_Hot -gt 0 -or $item.EstCost_Cool -gt 0) {
            Write-Host "   ESTIMATED MONTHLY COST:" -ForegroundColor White
            Write-Host "   ├─ Transaction Optimized: `$$($item.EstCost_TransOpt)/month" -ForegroundColor $(if ($item.RecommendedTier -eq 'TransactionOptimized') { 'Green' } else { 'Gray' })
            Write-Host "   ├─ Hot:                   `$$($item.EstCost_Hot)/month" -ForegroundColor $(if ($item.RecommendedTier -eq 'Hot') { 'Green' } else { 'Gray' })
            Write-Host "   └─ Cool:                  `$$($item.EstCost_Cool)/month" -ForegroundColor $(if ($item.RecommendedTier -eq 'Cool') { 'Green' } else { 'Gray' })
            Write-Host ""
        }
        
        # Recommendation
        Write-Host "   RECOMMENDATION:" -ForegroundColor Green
        Write-Host "   ├─ Change to:          $($item.RecommendedTier)" -ForegroundColor Green
        Write-Host "   ├─ Reason:             $($item.Reason)" -ForegroundColor White
        Write-Host "   └─ Estimated Savings:  $($item.PotentialSavings)" -ForegroundColor Yellow
        Write-Host ""
        
        # Azure CLI/PowerShell commands
        Write-Host "   IMPLEMENTATION:" -ForegroundColor Magenta
        Write-Host "   PowerShell:" -ForegroundColor Gray
        Write-Host "   Update-AzRmStorageShare -ResourceGroupName '$($item.ResourceGroupName)' -StorageAccountName '$($item.StorageAccountName)' -Name '$($item.FileShareName)' -AccessTier '$($item.RecommendedTier)'" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "   Azure CLI:" -ForegroundColor Gray
        Write-Host "   az storage share-rm update --resource-group '$($item.ResourceGroupName)' --storage-account '$($item.StorageAccountName)' --name '$($item.FileShareName)' --access-tier '$($item.RecommendedTier)'" -ForegroundColor DarkGray
        Write-Host ""
    }
    
    # Summary
    $uniqueSAs = ($actionableItems | Select-Object -ExpandProperty StorageAccountName -Unique).Count
    $totalCurrentCost = ($actionableItems | Measure-Object -Property CurrentEstCost -Sum).Sum
    $totalOptimalCost = ($actionableItems | ForEach-Object {
        @($_.EstCost_TransOpt, $_.EstCost_Hot, $_.EstCost_Cool) | Where-Object { $_ -gt 0 } | Sort-Object | Select-Object -First 1
    } | Measure-Object -Sum).Sum
    $totalMonthlySavings = [math]::Round($totalCurrentCost - $totalOptimalCost, 2)
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow
    Write-Host "   SUMMARY: $($actionableItems.Count) file share(s) across $uniqueSAs storage account(s) can be optimized" -ForegroundColor Yellow
    if ($totalMonthlySavings -gt 0) {
        Write-Host "   TOTAL ESTIMATED SAVINGS: ~`$$totalMonthlySavings/month (~`$$([math]::Round($totalMonthlySavings * 12, 2))/year)" -ForegroundColor Yellow
    }
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow
    Write-Host ""
    
    # Batch command for all changes
    if ($actionableItems.Count -gt 1) {
        Write-Host "   BATCH UPDATE (all shares at once):" -ForegroundColor Magenta
        Write-Host "   # PowerShell script to update all recommended tiers:" -ForegroundColor Gray
        foreach ($item in $actionableItems) {
            Write-Host "   Update-AzRmStorageShare -ResourceGroupName '$($item.ResourceGroupName)' -StorageAccountName '$($item.StorageAccountName)' -Name '$($item.FileShareName)' -AccessTier '$($item.RecommendedTier)'" -ForegroundColor DarkGray
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

$fileNameLabel = if ($autoDiscoverMode) { "AllAccounts" } else { $StorageAccountName }
$exportFileName = "FileShareTierAnalysis_$($fileNameLabel)_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$exportPath = Join-Path $exportDir $exportFileName
$results | Export-Csv -Path $exportPath -NoTypeInformation

Write-Host "[INFO] Analysis complete!" -ForegroundColor Green
Write-Host "[INFO] Storage accounts analyzed: $($storageAccountsToAnalyze.Count)" -ForegroundColor Green
Write-Host "[INFO] Total file shares analyzed: $($results.Count)" -ForegroundColor Green
Write-Host "[INFO] Results exported to: $exportPath" -ForegroundColor Green
Write-Host "[INFO] Analysis period: $timeRangeDisplay" -ForegroundColor Gray
Write-Host ""

# Return results object for pipeline usage
return $results

#endregion
