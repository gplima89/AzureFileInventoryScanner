<#
.SYNOPSIS
    Deploys the Azure Durable Functions File Inventory Scanner to Azure.

.DESCRIPTION
    This script creates all required Azure resources and deploys the Durable Functions app:
    - Resource Group (optional)
    - Storage Account for Function App
    - Application Insights
    - Function App (Consumption plan)
    - Deploys the function code
    - Configures app settings

.PARAMETER ResourceGroupName
    Name of the resource group.

.PARAMETER Location
    Azure region for resources.

.PARAMETER FunctionAppName
    Name for the Azure Function App.

.PARAMETER StorageAccountName
    Name for the storage account (used by Function App, not the one being scanned).

.PARAMETER TargetStorageAccountName
    Name of the storage account to scan (optional - can be set later).

.PARAMETER TargetStorageAccountKey
    Key for the storage account to scan (optional - can be set later).

.PARAMETER LogAnalyticsDceEndpoint
    Data Collection Endpoint URI (optional - can be set later).

.PARAMETER LogAnalyticsDcrImmutableId
    DCR Immutable ID (optional - can be set later).

.EXAMPLE
    .\Deploy-DurableFunctions.ps1 `
        -ResourceGroupName "rg-file-inventory" `
        -Location "eastus" `
        -FunctionAppName "func-file-inventory" `
        -StorageAccountName "stfuncinventory"

.NOTES
    Requires: Azure CLI, Azure Functions Core Tools
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory = $true)]
    [string]$Location,
    
    [Parameter(Mandatory = $true)]
    [string]$FunctionAppName,
    
    [Parameter(Mandatory = $true)]
    [string]$StorageAccountName,
    
    [Parameter(Mandatory = $false)]
    [string]$TargetStorageAccountName = "",
    
    [Parameter(Mandatory = $false)]
    [string]$TargetStorageAccountKey = "",
    
    [Parameter(Mandatory = $false)]
    [string]$LogAnalyticsDceEndpoint = "",
    
    [Parameter(Mandatory = $false)]
    [string]$LogAnalyticsDcrImmutableId = "",
    
    [Parameter(Mandatory = $false)]
    [string]$LogAnalyticsStreamName = "Custom-FileInventory_CL"
)

$ErrorActionPreference = "Stop"

Write-Host @"

╔═══════════════════════════════════════════════════════════════════════════════╗
║                                                                               ║
║         Azure Durable Functions - File Inventory Scanner Deployment           ║
║                                                                               ║
╚═══════════════════════════════════════════════════════════════════════════════╝

"@ -ForegroundColor Cyan

# Get script directory
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Check prerequisites
Write-Host "Checking prerequisites..." -ForegroundColor Yellow

# Check Azure CLI
try {
    $azVersion = az version 2>$null | ConvertFrom-Json
    Write-Host "  ✓ Azure CLI: $($azVersion.'azure-cli')" -ForegroundColor Green
}
catch {
    Write-Host "  ✗ Azure CLI not found. Please install: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli" -ForegroundColor Red
    exit 1
}

# Check Azure Functions Core Tools
try {
    $funcVersion = func --version 2>$null
    Write-Host "  ✓ Azure Functions Core Tools: $funcVersion" -ForegroundColor Green
}
catch {
    Write-Host "  ✗ Azure Functions Core Tools not found. Please install: npm install -g azure-functions-core-tools@4" -ForegroundColor Red
    exit 1
}

# Check Azure login
$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Host "  ℹ Not logged in to Azure. Running 'az login'..." -ForegroundColor Yellow
    az login
    $account = az account show | ConvertFrom-Json
}
Write-Host "  ✓ Logged in as: $($account.user.name)" -ForegroundColor Green
Write-Host "  ✓ Subscription: $($account.name)" -ForegroundColor Green

Write-Host ""
Write-Host "Deployment Configuration:" -ForegroundColor White
Write-Host "  Resource Group:    $ResourceGroupName" -ForegroundColor Gray
Write-Host "  Location:          $Location" -ForegroundColor Gray
Write-Host "  Function App:      $FunctionAppName" -ForegroundColor Gray
Write-Host "  Storage Account:   $StorageAccountName" -ForegroundColor Gray
Write-Host ""

# Step 1: Create Resource Group
Write-Host "Step 1: Creating Resource Group..." -ForegroundColor Cyan
$rgExists = az group exists --name $ResourceGroupName 2>$null
if ($rgExists -eq "true") {
    Write-Host "  ℹ Resource group '$ResourceGroupName' already exists" -ForegroundColor Yellow
}
else {
    az group create --name $ResourceGroupName --location $Location --output none
    Write-Host "  ✓ Created resource group '$ResourceGroupName'" -ForegroundColor Green
}

# Step 2: Create Storage Account
Write-Host "Step 2: Creating Storage Account for Function App..." -ForegroundColor Cyan
$saExists = az storage account show --name $StorageAccountName --resource-group $ResourceGroupName 2>$null
if ($saExists) {
    Write-Host "  ℹ Storage account '$StorageAccountName' already exists" -ForegroundColor Yellow
}
else {
    az storage account create `
        --name $StorageAccountName `
        --resource-group $ResourceGroupName `
        --location $Location `
        --sku Standard_LRS `
        --kind StorageV2 `
        --output none
    Write-Host "  ✓ Created storage account '$StorageAccountName'" -ForegroundColor Green
}

# Step 3: Create Application Insights
Write-Host "Step 3: Creating Application Insights..." -ForegroundColor Cyan
$appInsightsName = "$FunctionAppName-insights"
$aiExists = az monitor app-insights component show --app $appInsightsName --resource-group $ResourceGroupName 2>$null
if ($aiExists) {
    Write-Host "  ℹ Application Insights '$appInsightsName' already exists" -ForegroundColor Yellow
    $instrumentationKey = (az monitor app-insights component show --app $appInsightsName --resource-group $ResourceGroupName --query instrumentationKey -o tsv)
}
else {
    $aiResult = az monitor app-insights component create `
        --app $appInsightsName `
        --resource-group $ResourceGroupName `
        --location $Location `
        --kind web `
        --application-type web `
        --output json | ConvertFrom-Json
    $instrumentationKey = $aiResult.instrumentationKey
    Write-Host "  ✓ Created Application Insights '$appInsightsName'" -ForegroundColor Green
}

# Step 4: Create Function App
Write-Host "Step 4: Creating Function App..." -ForegroundColor Cyan
$funcExists = az functionapp show --name $FunctionAppName --resource-group $ResourceGroupName 2>$null
if ($funcExists) {
    Write-Host "  ℹ Function App '$FunctionAppName' already exists" -ForegroundColor Yellow
}
else {
    az functionapp create `
        --name $FunctionAppName `
        --resource-group $ResourceGroupName `
        --storage-account $StorageAccountName `
        --consumption-plan-location $Location `
        --runtime python `
        --runtime-version 3.10 `
        --functions-version 4 `
        --os-type Linux `
        --app-insights $appInsightsName `
        --output none
    
    Write-Host "  ✓ Created Function App '$FunctionAppName'" -ForegroundColor Green
    
    # Wait for function app to be ready
    Write-Host "  ℹ Waiting for Function App to be ready..." -ForegroundColor Yellow
    Start-Sleep -Seconds 30
}

# Step 5: Enable System-Assigned Managed Identity
Write-Host "Step 5: Enabling Managed Identity..." -ForegroundColor Cyan
$identity = az functionapp identity assign `
    --name $FunctionAppName `
    --resource-group $ResourceGroupName `
    --output json | ConvertFrom-Json
$principalId = $identity.principalId
Write-Host "  ✓ Managed Identity Principal ID: $principalId" -ForegroundColor Green

# Step 6: Configure App Settings
Write-Host "Step 6: Configuring App Settings..." -ForegroundColor Cyan

$settings = @(
    "FUNCTIONS_WORKER_RUNTIME=python",
    "BATCH_SIZE=500",
    "MAX_FILE_SIZE_FOR_HASH_MB=100",
    "SKIP_HASH_COMPUTATION=true",
    "EXCLUDE_PATTERNS=*.tmp,~`$*,.DS_Store,Thumbs.db"
)

if ($TargetStorageAccountName) {
    $settings += "STORAGE_ACCOUNT_NAME=$TargetStorageAccountName"
}

if ($TargetStorageAccountKey) {
    $settings += "STORAGE_ACCOUNT_KEY=$TargetStorageAccountKey"
}

if ($LogAnalyticsDceEndpoint) {
    $settings += "LOG_ANALYTICS_DCE_ENDPOINT=$LogAnalyticsDceEndpoint"
}

if ($LogAnalyticsDcrImmutableId) {
    $settings += "LOG_ANALYTICS_DCR_IMMUTABLE_ID=$LogAnalyticsDcrImmutableId"
}

$settings += "LOG_ANALYTICS_STREAM_NAME=$LogAnalyticsStreamName"

az functionapp config appsettings set `
    --name $FunctionAppName `
    --resource-group $ResourceGroupName `
    --settings $settings `
    --output none

Write-Host "  ✓ Configured app settings" -ForegroundColor Green

# Step 7: Deploy Function Code
Write-Host "Step 7: Deploying Function Code..." -ForegroundColor Cyan
Write-Host "  ℹ This may take a few minutes..." -ForegroundColor Yellow

Push-Location $scriptDir
try {
    func azure functionapp publish $FunctionAppName --python
    Write-Host "  ✓ Deployed function code" -ForegroundColor Green
}
catch {
    Write-Host "  ✗ Deployment failed: $_" -ForegroundColor Red
    Write-Host "  ℹ You can manually deploy later with: func azure functionapp publish $FunctionAppName --python" -ForegroundColor Yellow
}
finally {
    Pop-Location
}

# Get Function App URL
$funcUrl = "https://$FunctionAppName.azurewebsites.net"

# Summary
Write-Host @"

╔═══════════════════════════════════════════════════════════════════════════════╗
║                         DEPLOYMENT COMPLETED                                   ║
╚═══════════════════════════════════════════════════════════════════════════════╝

"@ -ForegroundColor Green

Write-Host "Resources Created:" -ForegroundColor White
Write-Host "  • Resource Group:       $ResourceGroupName" -ForegroundColor Gray
Write-Host "  • Storage Account:      $StorageAccountName" -ForegroundColor Gray
Write-Host "  • Application Insights: $appInsightsName" -ForegroundColor Gray
Write-Host "  • Function App:         $FunctionAppName" -ForegroundColor Gray
Write-Host "  • Function App URL:     $funcUrl" -ForegroundColor Gray
Write-Host "  • Managed Identity:     $principalId" -ForegroundColor Gray
Write-Host ""

Write-Host "API Endpoints:" -ForegroundColor White
Write-Host "  • Start Scan:           POST $funcUrl/api/start-scan" -ForegroundColor Cyan
Write-Host "  • Check Status:         GET  $funcUrl/api/scan-status/{instanceId}" -ForegroundColor Cyan
Write-Host "  • Cancel Scan:          POST $funcUrl/api/cancel-scan/{instanceId}" -ForegroundColor Cyan
Write-Host ""

if (-not $TargetStorageAccountName -or -not $LogAnalyticsDceEndpoint) {
    Write-Host "⚠️  IMPORTANT: Configure these settings before running scans:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "az functionapp config appsettings set \" -ForegroundColor Cyan
    Write-Host "    --name $FunctionAppName \" -ForegroundColor Cyan
    Write-Host "    --resource-group $ResourceGroupName \" -ForegroundColor Cyan
    Write-Host "    --settings \" -ForegroundColor Cyan
    
    if (-not $TargetStorageAccountName) {
        Write-Host "        STORAGE_ACCOUNT_NAME=<storage-account-to-scan> \" -ForegroundColor Cyan
        Write-Host "        STORAGE_ACCOUNT_KEY=<storage-account-key> \" -ForegroundColor Cyan
    }
    if (-not $LogAnalyticsDceEndpoint) {
        Write-Host "        LOG_ANALYTICS_DCE_ENDPOINT=<dce-endpoint> \" -ForegroundColor Cyan
        Write-Host "        LOG_ANALYTICS_DCR_IMMUTABLE_ID=<dcr-id>" -ForegroundColor Cyan
    }
    Write-Host ""
}

Write-Host "RBAC Permissions Needed:" -ForegroundColor Yellow
Write-Host "  1. Grant 'Storage Account Key Operator Service Role' on target storage account" -ForegroundColor Gray
Write-Host "  2. Grant 'Monitoring Metrics Publisher' on Data Collection Rule" -ForegroundColor Gray
Write-Host ""
Write-Host "Example:" -ForegroundColor White
Write-Host "az role assignment create --assignee $principalId --role 'Storage Account Key Operator Service Role' --scope /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<storage>" -ForegroundColor Cyan
Write-Host ""

Write-Host "Test the deployment:" -ForegroundColor White
Write-Host @"
curl -X POST "$funcUrl/api/start-scan" `
    -H "Content-Type: application/json" `
    -d '{"storageAccountName": "yourstorageaccount", "fileShareNames": ["testshare"]}'
"@ -ForegroundColor Cyan
