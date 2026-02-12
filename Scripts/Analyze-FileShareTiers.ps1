<#
.SYNOPSIS
    Analyzes Azure File Share access patterns and recommends optimal access tiers for cost savings.

.DESCRIPTION
    This script lists all file shares in a storage account, retrieves performance metrics
    for the last 24 hours, and provides tier recommendations based on Microsoft's guidelines.
    
    Azure Files Access Tier Recommendations:
    - Hot: High storage cost, low transaction cost - best for frequently accessed data
    - Cool: Low storage cost, high transaction cost - best for infrequently accessed data
    - Transaction Optimized: Lowest transaction cost - best for transaction-heavy workloads
    - Premium: SSD-based, lowest latency - best for IO-intensive workloads

.PARAMETER StorageAccountName
    The name of the Azure Storage Account to analyze.

.PARAMETER ResourceGroupName
    The resource group containing the storage account.

.PARAMETER SubscriptionId
    Optional. The subscription ID. If not provided, uses the current context.

.PARAMETER TimeRangeHours
    Optional. Number of hours to analyze metrics. Default is 24.

.PARAMETER FileShareName
    Optional. Name of a specific file share to analyze. If not provided, analyzes all file shares.

.EXAMPLE
    .\Analyze-FileShareTiers.ps1 -StorageAccountName "mystorageaccount" -ResourceGroupName "my-rg"

.EXAMPLE
    .\Analyze-FileShareTiers.ps1 -StorageAccountName "mystorageaccount" -ResourceGroupName "my-rg" -TimeRangeHours 168

.EXAMPLE
    .\Analyze-FileShareTiers.ps1 -StorageAccountName "mystorageaccount" -ResourceGroupName "my-rg" -FileShareName "myfileshare"

.NOTES
    Author: Azure File Storage Lifecycle Team
    Requires: Az.Accounts, Az.Storage, Az.Monitor modules
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$StorageAccountName,
    
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory = $false)]
    [int]$TimeRangeHours = 24,
    
    [Parameter(Mandatory = $false)]
    [string]$FileShareName
)

#region Module Imports
$ErrorActionPreference = "Stop"

try {
    Import-Module Az.Accounts -ErrorAction Stop
    Import-Module Az.Storage -ErrorAction Stop
    Import-Module Az.Monitor -ErrorAction Stop
}
catch {
    Write-Error "Failed to import required Az modules. Please install: Az.Accounts, Az.Storage, Az.Monitor"
    Write-Error "Run: Install-Module Az -Scope CurrentUser"
    throw
}
#endregion

#region Helper Functions

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
$startTime = $endTime.AddHours(-$TimeRangeHours)
Write-Host "[INFO] Analyzing metrics from $($startTime.ToString('yyyy-MM-dd HH:mm')) to $($endTime.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor Yellow
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
    
    # Get metrics for this file share
    # Resource ID for file share metrics
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
    
    # Calculate total transactions
    $totalTransactions = 0
    $readTransactions = 0
    $writeTransactions = 0
    
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
    
    Write-Host "  - Total Transactions (${TimeRangeHours}h): $(Format-Number $totalTransactions)" -ForegroundColor Gray
    
    # Get tier recommendation
    $recommendation = Get-TierRecommendation `
        -TotalTransactions $totalTransactions `
        -ReadTransactions $readTransactions `
        -WriteTransactions $writeTransactions `
        -StorageUsedGB $usageGB `
        -CurrentTier $currentTier `
        -IsPremium $isPremiumAccount
    
    # Determine if action is needed
    $actionNeeded = $recommendation.RecommendedTier -ne $currentTier
    
    Write-Host "  - Recommended Tier: $($recommendation.RecommendedTier)" -ForegroundColor $(if ($actionNeeded) { "Yellow" } else { "Green" })
    
    # Add to results
    $results.Add([PSCustomObject]@{
        FileShareName       = $shareName
        CurrentTier         = $currentTier
        RecommendedTier     = $recommendation.RecommendedTier
        UsedStorageGB       = $usageGB
        QuotaGB             = $quotaGB
        Transactions24h     = $totalTransactions
        TransPerGBPerDay    = if ($usageGB -gt 0) { [math]::Round($totalTransactions / $usageGB, 1) } else { 0 }
        ActionNeeded        = if ($actionNeeded) { "Yes" } else { "No" }
        Reason              = $recommendation.Reason
        PotentialSavings    = $recommendation.PotentialSavings
    })
    
    Write-Host ""
}

# Display results table
Write-Host ""
Write-Host "=============================================================================" -ForegroundColor Cyan
Write-Host "  ANALYSIS RESULTS" -ForegroundColor Cyan
Write-Host "=============================================================================" -ForegroundColor Cyan
Write-Host ""

# Summary table
$results | Format-Table -Property @(
    @{Label="File Share"; Expression={$_.FileShareName}; Width=25},
    @{Label="Current Tier"; Expression={$_.CurrentTier}; Width=20},
    @{Label="Recommended"; Expression={$_.RecommendedTier}; Width=20},
    @{Label="Used (GB)"; Expression={$_.UsedStorageGB}; Width=12},
    @{Label="Trans/24h"; Expression={Format-Number $_.Transactions24h}; Width=12},
    @{Label="Action"; Expression={$_.ActionNeeded}; Width=8}
) -AutoSize

# Detailed recommendations
$actionableItems = $results | Where-Object { $_.ActionNeeded -eq "Yes" }

if ($actionableItems.Count -gt 0) {
    Write-Host ""
    Write-Host "=============================================================================" -ForegroundColor Yellow
    Write-Host "  COST OPTIMIZATION OPPORTUNITIES" -ForegroundColor Yellow
    Write-Host "=============================================================================" -ForegroundColor Yellow
    Write-Host ""
    
    foreach ($item in $actionableItems) {
        Write-Host "📁 $($item.FileShareName)" -ForegroundColor Cyan
        Write-Host "   Current Tier:     $($item.CurrentTier)" -ForegroundColor Gray
        Write-Host "   Recommended Tier: $($item.RecommendedTier)" -ForegroundColor Green
        Write-Host "   Reason:           $($item.Reason)" -ForegroundColor White
        Write-Host "   Potential Savings: $($item.PotentialSavings)" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "   To change tier, run:" -ForegroundColor Gray
        Write-Host "   Update-AzStorageFileServiceProperty -ResourceGroupName '$ResourceGroupName' -StorageAccountName '$StorageAccountName'" -ForegroundColor DarkGray
        Write-Host "   Update-AzRmStorageShare -ResourceGroupName '$ResourceGroupName' -StorageAccountName '$StorageAccountName' -Name '$($item.FileShareName)' -AccessTier '$($item.RecommendedTier)'" -ForegroundColor DarkGray
        Write-Host ""
    }
}
else {
    Write-Host ""
    Write-Host "✅ All file shares are using optimal access tiers based on current usage patterns." -ForegroundColor Green
    Write-Host ""
}

# Export results
$exportPath = Join-Path $PSScriptRoot "FileShareTierAnalysis_$($StorageAccountName)_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$results | Export-Csv -Path $exportPath -NoTypeInformation
Write-Host "[INFO] Results exported to: $exportPath" -ForegroundColor Green
Write-Host ""

# Return results object for pipeline usage
return $results

#endregion
