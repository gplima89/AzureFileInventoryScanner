<#
.SYNOPSIS
    Configures Automation Variables for the File Inventory Scanner.

.DESCRIPTION
    This script helps configure the required Automation Variables for the
    Azure File Storage Inventory Scanner runbook. Use this after deploying
    the infrastructure or when you need to update configuration values.

.PARAMETER ResourceGroupName
    Name of the resource group containing the Automation Account.

.PARAMETER AutomationAccountName
    Name of the Azure Automation Account.

.PARAMETER DceEndpoint
    Data Collection Endpoint URI (e.g., https://dce-xxx.region.ingest.monitor.azure.com).

.PARAMETER DcrImmutableId
    Data Collection Rule immutable ID (e.g., dcr-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx).

.PARAMETER StreamName
    Stream name for Log Analytics (default: Custom-FileInventory_CL).

.PARAMETER TableName
    Table name in Log Analytics (default: FileInventory_CL).

.PARAMETER ExcludePatterns
    Comma-separated file patterns to exclude from scanning.

.EXAMPLE
    .\Configure-AutomationVariables.ps1 `
        -ResourceGroupName "rg-file-inventory" `
        -AutomationAccountName "aa-file-inventory" `
        -DceEndpoint "https://dce-fileinventory.eastus-1.ingest.monitor.azure.com" `
        -DcrImmutableId "dcr-12345678-1234-1234-1234-123456789abc"

.NOTES
    Version: 1.0.0
    Author: Azure File Storage Lifecycle Team
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory = $true)]
    [string]$AutomationAccountName,
    
    [Parameter(Mandatory = $false)]
    [string]$DceEndpoint,
    
    [Parameter(Mandatory = $false)]
    [string]$DcrImmutableId,
    
    [Parameter(Mandatory = $false)]
    [string]$StreamName = "Custom-FileInventory_CL",
    
    [Parameter(Mandatory = $false)]
    [string]$TableName = "FileInventory_CL",
    
    [Parameter(Mandatory = $false)]
    [string]$ExcludePatterns = "*.tmp,~`$*,.DS_Store,Thumbs.db"
)

$ErrorActionPreference = "Stop"

Write-Host @"

╔═══════════════════════════════════════════════════════════════════════════════╗
║                                                                               ║
║            Azure File Inventory Scanner - Variable Configuration              ║
║                                                                               ║
╚═══════════════════════════════════════════════════════════════════════════════╝

"@ -ForegroundColor Cyan

# Verify Azure connection
try {
    $context = Get-AzContext -ErrorAction Stop
    if (-not $context) {
        Write-Host "No Azure context found. Please sign in..." -ForegroundColor Yellow
        Connect-AzAccount -ErrorAction Stop
    }
    Write-Host "Connected to Azure: $($context.Subscription.Name)" -ForegroundColor Green
}
catch {
    Write-Error "Failed to connect to Azure: $_"
    throw
}

# Verify Automation Account exists
try {
    $aa = Get-AzAutomationAccount -ResourceGroupName $ResourceGroupName -Name $AutomationAccountName -ErrorAction Stop
    Write-Host "Found Automation Account: $AutomationAccountName" -ForegroundColor Green
}
catch {
    Write-Error "Automation Account '$AutomationAccountName' not found in resource group '$ResourceGroupName'"
    throw
}

# Interactive mode if parameters not provided
if (-not $DceEndpoint) {
    Write-Host "`nData Collection Endpoint not provided." -ForegroundColor Yellow
    Write-Host "You can find this in Azure Portal:" -ForegroundColor Gray
    Write-Host "  1. Go to Azure Monitor > Data Collection Endpoints" -ForegroundColor Gray
    Write-Host "  2. Select your DCE" -ForegroundColor Gray
    Write-Host "  3. Copy the 'Logs Ingestion' endpoint URL" -ForegroundColor Gray
    $DceEndpoint = Read-Host "`nEnter DCE Endpoint URL"
}

if (-not $DcrImmutableId) {
    Write-Host "`nData Collection Rule Immutable ID not provided." -ForegroundColor Yellow
    Write-Host "You can find this in Azure Portal:" -ForegroundColor Gray
    Write-Host "  1. Go to Azure Monitor > Data Collection Rules" -ForegroundColor Gray
    Write-Host "  2. Select your DCR" -ForegroundColor Gray
    Write-Host "  3. Go to JSON View and find 'immutableId'" -ForegroundColor Gray
    $DcrImmutableId = Read-Host "`nEnter DCR Immutable ID"
}

# Define variables to create/update
$variables = @(
    @{
        Name        = "FileInventory_LogAnalyticsDceEndpoint"
        Value       = $DceEndpoint
        Description = "Data Collection Endpoint URI for Log Analytics ingestion"
    }
    @{
        Name        = "FileInventory_LogAnalyticsDcrImmutableId"
        Value       = $DcrImmutableId
        Description = "Data Collection Rule immutable ID"
    }
    @{
        Name        = "FileInventory_LogAnalyticsStreamName"
        Value       = $StreamName
        Description = "Stream name for the custom log table"
    }
    @{
        Name        = "FileInventory_LogAnalyticsTableName"
        Value       = $TableName
        Description = "Custom table name in Log Analytics"
    }
    @{
        Name        = "FileInventory_ExcludePatterns"
        Value       = $ExcludePatterns
        Description = "Comma-separated file patterns to exclude from scanning"
    }
)

Write-Host "`nConfiguring Automation Variables..." -ForegroundColor Cyan
Write-Host "-" * 60 -ForegroundColor Gray

foreach ($var in $variables) {
    try {
        $existing = Get-AzAutomationVariable `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -Name $var.Name `
            -ErrorAction SilentlyContinue
        
        if ($existing) {
            Set-AzAutomationVariable `
                -ResourceGroupName $ResourceGroupName `
                -AutomationAccountName $AutomationAccountName `
                -Name $var.Name `
                -Value $var.Value `
                -Encrypted $false `
                -ErrorAction Stop | Out-Null
            Write-Host "  ✓ Updated: $($var.Name)" -ForegroundColor Yellow
        }
        else {
            New-AzAutomationVariable `
                -ResourceGroupName $ResourceGroupName `
                -AutomationAccountName $AutomationAccountName `
                -Name $var.Name `
                -Value $var.Value `
                -Description $var.Description `
                -Encrypted $false `
                -ErrorAction Stop | Out-Null
            Write-Host "  ✓ Created: $($var.Name)" -ForegroundColor Green
        }
    }
    catch {
        Write-Host "  ✗ Failed: $($var.Name) - $_" -ForegroundColor Red
    }
}

Write-Host "`n" + "=" * 60 -ForegroundColor Cyan
Write-Host "Configuration Complete!" -ForegroundColor Green
Write-Host "=" * 60 -ForegroundColor Cyan

Write-Host "`nConfigured Values:" -ForegroundColor White
Write-Host "  DCE Endpoint:     $DceEndpoint" -ForegroundColor Gray
Write-Host "  DCR Immutable ID: $DcrImmutableId" -ForegroundColor Gray
Write-Host "  Stream Name:      $StreamName" -ForegroundColor Gray
Write-Host "  Table Name:       $TableName" -ForegroundColor Gray
Write-Host "  Exclude Patterns: $ExcludePatterns" -ForegroundColor Gray

Write-Host "`nNext Steps:" -ForegroundColor Yellow
Write-Host "  1. Import and publish the runbook if not done already" -ForegroundColor Gray
Write-Host "  2. Test the runbook with a small file share first" -ForegroundColor Gray
Write-Host "  3. Create a schedule for regular inventory scans" -ForegroundColor Gray
