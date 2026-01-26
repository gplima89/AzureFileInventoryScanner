<#
.SYNOPSIS
    Deploys Azure infrastructure for the File Inventory Scanner solution.

.DESCRIPTION
    This script creates all required Azure resources for the Azure File Storage Inventory Scanner:
    - Resource Group
    - Log Analytics Workspace
    - Data Collection Endpoint (DCE)
    - Data Collection Rule (DCR)
    - Custom Log Analytics Table
    - Automation Account with System-Assigned Managed Identity
    - Required RBAC role assignments

.PARAMETER ResourceGroupName
    Name of the resource group to create or use.

.PARAMETER Location
    Azure region for resources (e.g., eastus, westus2, westeurope).

.PARAMETER AutomationAccountName
    Name for the Azure Automation Account.

.PARAMETER LogAnalyticsWorkspaceName
    Name for the Log Analytics Workspace.

.PARAMETER StorageAccountResourceId
    Optional: Resource ID of an existing storage account to grant permissions.

.PARAMETER Tags
    Optional: Hashtable of tags to apply to resources.

.EXAMPLE
    .\Deploy-AzureInfrastructure.ps1 `
        -ResourceGroupName "rg-file-inventory" `
        -Location "eastus" `
        -AutomationAccountName "aa-file-inventory" `
        -LogAnalyticsWorkspaceName "law-file-inventory"

.EXAMPLE
    .\Deploy-AzureInfrastructure.ps1 `
        -ResourceGroupName "rg-file-inventory" `
        -Location "westeurope" `
        -AutomationAccountName "aa-file-inventory" `
        -LogAnalyticsWorkspaceName "law-file-inventory" `
        -StorageAccountResourceId "/subscriptions/xxx/resourceGroups/xxx/providers/Microsoft.Storage/storageAccounts/xxx" `
        -Tags @{Environment="Production"; Project="FileInventory"}

.NOTES
    Version: 1.0.0
    Author: Azure File Storage Lifecycle Team
    Requires: Az PowerShell module, Contributor role on subscription
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory = $true)]
    [ValidateSet(
        "eastus", "eastus2", "westus", "westus2", "westus3", "centralus", "northcentralus", "southcentralus",
        "westeurope", "northeurope", "uksouth", "ukwest", "francecentral", "germanywestcentral",
        "australiaeast", "australiasoutheast", "eastasia", "southeastasia", "japaneast", "japanwest",
        "brazilsouth", "canadacentral", "canadaeast", "centralindia", "southindia", "koreacentral"
    )]
    [string]$Location,
    
    [Parameter(Mandatory = $true)]
    [string]$AutomationAccountName,
    
    [Parameter(Mandatory = $true)]
    [string]$LogAnalyticsWorkspaceName,
    
    [Parameter(Mandatory = $false)]
    [string]$StorageAccountResourceId = "",
    
    [Parameter(Mandatory = $false)]
    [hashtable]$Tags = @{}
)

#region Helper Functions

function Write-StepHeader {
    param([string]$Message)
    Write-Host "`n$('=' * 80)" -ForegroundColor Cyan
    Write-Host "  $Message" -ForegroundColor Cyan
    Write-Host "$('=' * 80)" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "  ✓ $Message" -ForegroundColor Green
}

function Write-Info {
    param([string]$Message)
    Write-Host "  ℹ $Message" -ForegroundColor Yellow
}

function Write-ErrorMessage {
    param([string]$Message)
    Write-Host "  ✗ $Message" -ForegroundColor Red
}

#endregion

#region Main Script

$ErrorActionPreference = "Stop"

Write-Host @"

╔═══════════════════════════════════════════════════════════════════════════════╗
║                                                                               ║
║            Azure File Storage Inventory Scanner - Infrastructure              ║
║                           Deployment Script v1.0                              ║
║                                                                               ║
╚═══════════════════════════════════════════════════════════════════════════════╝

"@ -ForegroundColor Magenta

Write-Host "Deployment Configuration:" -ForegroundColor White
Write-Host "  Resource Group:         $ResourceGroupName" -ForegroundColor Gray
Write-Host "  Location:               $Location" -ForegroundColor Gray
Write-Host "  Automation Account:     $AutomationAccountName" -ForegroundColor Gray
Write-Host "  Log Analytics:          $LogAnalyticsWorkspaceName" -ForegroundColor Gray
if ($StorageAccountResourceId) {
    Write-Host "  Storage Account:        $($StorageAccountResourceId.Split('/')[-1])" -ForegroundColor Gray
}

# Verify Azure connection
Write-StepHeader "Step 1: Verifying Azure Connection"
try {
    $context = Get-AzContext -ErrorAction Stop
    if (-not $context) {
        Write-Info "No Azure context found. Please sign in..."
        Connect-AzAccount -ErrorAction Stop
        $context = Get-AzContext
    }
    Write-Success "Connected to Azure"
    Write-Success "Subscription: $($context.Subscription.Name) ($($context.Subscription.Id))"
    Write-Success "Tenant: $($context.Tenant.Id)"
}
catch {
    Write-ErrorMessage "Failed to connect to Azure: $_"
    throw
}

$subscriptionId = $context.Subscription.Id

# Create Resource Group
Write-StepHeader "Step 2: Creating Resource Group"
try {
    $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
    if ($rg) {
        Write-Info "Resource group '$ResourceGroupName' already exists"
    }
    else {
        $rg = New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Tag $Tags -ErrorAction Stop
        Write-Success "Created resource group '$ResourceGroupName'"
    }
}
catch {
    Write-ErrorMessage "Failed to create resource group: $_"
    throw
}

# Create Log Analytics Workspace
Write-StepHeader "Step 3: Creating Log Analytics Workspace"
try {
    $law = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -Name $LogAnalyticsWorkspaceName -ErrorAction SilentlyContinue
    if ($law) {
        Write-Info "Log Analytics workspace '$LogAnalyticsWorkspaceName' already exists"
    }
    else {
        $law = New-AzOperationalInsightsWorkspace `
            -ResourceGroupName $ResourceGroupName `
            -Name $LogAnalyticsWorkspaceName `
            -Location $Location `
            -Sku PerGB2018 `
            -RetentionInDays 90 `
            -Tag $Tags `
            -ErrorAction Stop
        Write-Success "Created Log Analytics workspace '$LogAnalyticsWorkspaceName'"
    }
    
    $workspaceResourceId = $law.ResourceId
    $workspaceId = $law.CustomerId
    Write-Success "Workspace ID: $workspaceId"
}
catch {
    Write-ErrorMessage "Failed to create Log Analytics workspace: $_"
    throw
}

# Create Data Collection Endpoint
Write-StepHeader "Step 4: Creating Data Collection Endpoint"
$dceName = "dce-$($AutomationAccountName.ToLower() -replace '[^a-z0-9]', '')"
try {
    # Check if DCE exists
    $dceUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/dataCollectionEndpoints/$dceName`?api-version=2022-06-01"
    $token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com").Token
    $headers = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }
    
    try {
        $dceResponse = Invoke-RestMethod -Uri $dceUri -Method Get -Headers $headers -ErrorAction Stop
        Write-Info "Data Collection Endpoint '$dceName' already exists"
        $dceEndpoint = $dceResponse.properties.logsIngestion.endpoint
    }
    catch {
        if ($_.Exception.Response.StatusCode -eq 404) {
            # Create DCE
            $dceBody = @{
                location = $Location
                properties = @{
                    networkAcls = @{
                        publicNetworkAccess = "Enabled"
                    }
                }
                tags = $Tags
            } | ConvertTo-Json -Depth 10
            
            $dceResponse = Invoke-RestMethod -Uri $dceUri -Method Put -Headers $headers -Body $dceBody -ErrorAction Stop
            Write-Success "Created Data Collection Endpoint '$dceName'"
            
            # Wait for provisioning
            Start-Sleep -Seconds 10
            $dceResponse = Invoke-RestMethod -Uri $dceUri -Method Get -Headers $headers -ErrorAction Stop
            $dceEndpoint = $dceResponse.properties.logsIngestion.endpoint
        }
        else {
            throw $_
        }
    }
    
    Write-Success "DCE Endpoint: $dceEndpoint"
}
catch {
    Write-ErrorMessage "Failed to create Data Collection Endpoint: $_"
    throw
}

# Create Custom Table
Write-StepHeader "Step 5: Creating Custom Log Analytics Table"
$tableName = "FileInventory_CL"
try {
    $tableUri = "https://management.azure.com$workspaceResourceId/tables/$tableName`?api-version=2022-10-01"
    
    $tableSchema = @{
        properties = @{
            schema = @{
                name = $tableName
                columns = @(
                    @{ name = "TimeGenerated"; type = "datetime"; description = "Time when the record was generated" }
                    @{ name = "StorageAccount"; type = "string"; description = "Name of the Azure Storage Account" }
                    @{ name = "FileShare"; type = "string"; description = "Name of the Azure File Share" }
                    @{ name = "FilePath"; type = "string"; description = "Full path of the file within the share" }
                    @{ name = "FileName"; type = "string"; description = "Name of the file" }
                    @{ name = "FileExtension"; type = "string"; description = "File extension" }
                    @{ name = "FileSizeBytes"; type = "long"; description = "File size in bytes" }
                    @{ name = "FileSizeMB"; type = "real"; description = "File size in megabytes" }
                    @{ name = "FileSizeGB"; type = "real"; description = "File size in gigabytes" }
                    @{ name = "LastModified"; type = "datetime"; description = "Last modified date/time" }
                    @{ name = "Created"; type = "datetime"; description = "Creation date/time" }
                    @{ name = "AgeInDays"; type = "int"; description = "Age in days since last modified" }
                    @{ name = "FileHash"; type = "string"; description = "MD5 hash of the file content" }
                    @{ name = "IsDuplicate"; type = "string"; description = "Whether file is a duplicate" }
                    @{ name = "DuplicateCount"; type = "int"; description = "Number of duplicates found" }
                    @{ name = "DuplicateGroupId"; type = "string"; description = "Group ID for duplicate files" }
                    @{ name = "FileCategory"; type = "string"; description = "Category of file" }
                    @{ name = "AgeBucket"; type = "string"; description = "Age bucket" }
                    @{ name = "SizeBucket"; type = "string"; description = "Size bucket" }
                    @{ name = "ScanTimestamp"; type = "string"; description = "Timestamp when scanned" }
                    @{ name = "ExecutionId"; type = "string"; description = "Unique execution identifier" }
                )
            }
            retentionInDays = 90
            totalRetentionInDays = 365
        }
    } | ConvertTo-Json -Depth 10
    
    try {
        $tableResponse = Invoke-RestMethod -Uri $tableUri -Method Get -Headers $headers -ErrorAction Stop
        Write-Info "Table '$tableName' already exists"
    }
    catch {
        if ($_.Exception.Response.StatusCode -eq 404) {
            $tableResponse = Invoke-RestMethod -Uri $tableUri -Method Put -Headers $headers -Body $tableSchema -ErrorAction Stop
            Write-Success "Created custom table '$tableName'"
        }
        else {
            throw $_
        }
    }
}
catch {
    Write-ErrorMessage "Failed to create custom table: $_"
    throw
}

# Create Data Collection Rule
Write-StepHeader "Step 6: Creating Data Collection Rule"
$dcrName = "dcr-$($AutomationAccountName.ToLower() -replace '[^a-z0-9]', '')"
$streamName = "Custom-$tableName"
try {
    $dcrUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/dataCollectionRules/$dcrName`?api-version=2022-06-01"
    
    $dcrBody = @{
        location = $Location
        properties = @{
            dataCollectionEndpointId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/dataCollectionEndpoints/$dceName"
            streamDeclarations = @{
                $streamName = @{
                    columns = @(
                        @{ name = "TimeGenerated"; type = "datetime" }
                        @{ name = "StorageAccount"; type = "string" }
                        @{ name = "FileShare"; type = "string" }
                        @{ name = "FilePath"; type = "string" }
                        @{ name = "FileName"; type = "string" }
                        @{ name = "FileExtension"; type = "string" }
                        @{ name = "FileSizeBytes"; type = "long" }
                        @{ name = "FileSizeMB"; type = "real" }
                        @{ name = "FileSizeGB"; type = "real" }
                        @{ name = "LastModified"; type = "datetime" }
                        @{ name = "Created"; type = "datetime" }
                        @{ name = "AgeInDays"; type = "int" }
                        @{ name = "FileHash"; type = "string" }
                        @{ name = "IsDuplicate"; type = "string" }
                        @{ name = "DuplicateCount"; type = "int" }
                        @{ name = "DuplicateGroupId"; type = "string" }
                        @{ name = "FileCategory"; type = "string" }
                        @{ name = "AgeBucket"; type = "string" }
                        @{ name = "SizeBucket"; type = "string" }
                        @{ name = "ScanTimestamp"; type = "string" }
                        @{ name = "ExecutionId"; type = "string" }
                    )
                }
            }
            destinations = @{
                logAnalytics = @(
                    @{
                        workspaceResourceId = $workspaceResourceId
                        name = "logAnalyticsDestination"
                    }
                )
            }
            dataFlows = @(
                @{
                    streams = @($streamName)
                    destinations = @("logAnalyticsDestination")
                    transformKql = "source"
                    outputStream = $streamName
                }
            )
        }
        tags = $Tags
    } | ConvertTo-Json -Depth 10
    
    try {
        $dcrResponse = Invoke-RestMethod -Uri $dcrUri -Method Get -Headers $headers -ErrorAction Stop
        Write-Info "Data Collection Rule '$dcrName' already exists"
        $dcrImmutableId = $dcrResponse.properties.immutableId
    }
    catch {
        if ($_.Exception.Response.StatusCode -eq 404) {
            $dcrResponse = Invoke-RestMethod -Uri $dcrUri -Method Put -Headers $headers -Body $dcrBody -ErrorAction Stop
            Write-Success "Created Data Collection Rule '$dcrName'"
            
            # Wait and retrieve immutable ID
            Start-Sleep -Seconds 5
            $dcrResponse = Invoke-RestMethod -Uri $dcrUri -Method Get -Headers $headers -ErrorAction Stop
            $dcrImmutableId = $dcrResponse.properties.immutableId
        }
        else {
            throw $_
        }
    }
    
    Write-Success "DCR Immutable ID: $dcrImmutableId"
}
catch {
    Write-ErrorMessage "Failed to create Data Collection Rule: $_"
    throw
}

# Create Automation Account
Write-StepHeader "Step 7: Creating Automation Account"
try {
    $aa = Get-AzAutomationAccount -ResourceGroupName $ResourceGroupName -Name $AutomationAccountName -ErrorAction SilentlyContinue
    if ($aa) {
        Write-Info "Automation Account '$AutomationAccountName' already exists"
    }
    else {
        $aa = New-AzAutomationAccount `
            -ResourceGroupName $ResourceGroupName `
            -Name $AutomationAccountName `
            -Location $Location `
            -AssignSystemIdentity `
            -Tag $Tags `
            -ErrorAction Stop
        Write-Success "Created Automation Account '$AutomationAccountName'"
    }
    
    # Get Managed Identity Principal ID
    $aaDetails = Get-AzAutomationAccount -ResourceGroupName $ResourceGroupName -Name $AutomationAccountName
    $principalId = $aaDetails.Identity.PrincipalId
    
    if (-not $principalId) {
        Write-Info "Enabling System-Assigned Managed Identity..."
        Set-AzAutomationAccount -ResourceGroupName $ResourceGroupName -Name $AutomationAccountName -AssignSystemIdentity -ErrorAction Stop
        Start-Sleep -Seconds 10
        $aaDetails = Get-AzAutomationAccount -ResourceGroupName $ResourceGroupName -Name $AutomationAccountName
        $principalId = $aaDetails.Identity.PrincipalId
    }
    
    Write-Success "Managed Identity Principal ID: $principalId"
}
catch {
    Write-ErrorMessage "Failed to create Automation Account: $_"
    throw
}

# Import Required Modules
Write-StepHeader "Step 8: Importing PowerShell Modules"
$modulesToImport = @(
    @{ Name = "Az.Accounts"; Version = "2.12.1" }
    @{ Name = "Az.Storage"; Version = "5.5.0" }
)

foreach ($module in $modulesToImport) {
    try {
        $existingModule = Get-AzAutomationModule -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $module.Name -ErrorAction SilentlyContinue
        if ($existingModule -and $existingModule.ProvisioningState -eq "Succeeded") {
            Write-Info "Module '$($module.Name)' already imported"
        }
        else {
            $contentLink = "https://www.powershellgallery.com/api/v2/package/$($module.Name)"
            New-AzAutomationModule `
                -ResourceGroupName $ResourceGroupName `
                -AutomationAccountName $AutomationAccountName `
                -Name $module.Name `
                -ContentLinkUri $contentLink `
                -RuntimeVersion "7.2" `
                -ErrorAction Stop | Out-Null
            Write-Success "Started import of module '$($module.Name)'"
        }
    }
    catch {
        Write-ErrorMessage "Failed to import module '$($module.Name)': $_"
    }
}

# Assign RBAC Permissions
Write-StepHeader "Step 9: Assigning RBAC Permissions"

# Assign Monitoring Metrics Publisher on DCR
try {
    $dcrResourceId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/dataCollectionRules/$dcrName"
    $existingAssignment = Get-AzRoleAssignment -ObjectId $principalId -Scope $dcrResourceId -RoleDefinitionName "Monitoring Metrics Publisher" -ErrorAction SilentlyContinue
    
    if ($existingAssignment) {
        Write-Info "RBAC role 'Monitoring Metrics Publisher' already assigned on DCR"
    }
    else {
        New-AzRoleAssignment `
            -ObjectId $principalId `
            -RoleDefinitionName "Monitoring Metrics Publisher" `
            -Scope $dcrResourceId `
            -ErrorAction Stop | Out-Null
        Write-Success "Assigned 'Monitoring Metrics Publisher' role on DCR"
    }
}
catch {
    Write-ErrorMessage "Failed to assign RBAC on DCR: $_"
}

# Assign Storage Account Key Operator on Storage Account (if provided)
if ($StorageAccountResourceId) {
    try {
        $existingAssignment = Get-AzRoleAssignment -ObjectId $principalId -Scope $StorageAccountResourceId -RoleDefinitionName "Storage Account Key Operator Service Role" -ErrorAction SilentlyContinue
        
        if ($existingAssignment) {
            Write-Info "RBAC role 'Storage Account Key Operator Service Role' already assigned on Storage Account"
        }
        else {
            New-AzRoleAssignment `
                -ObjectId $principalId `
                -RoleDefinitionName "Storage Account Key Operator Service Role" `
                -Scope $StorageAccountResourceId `
                -ErrorAction Stop | Out-Null
            Write-Success "Assigned 'Storage Account Key Operator Service Role' on Storage Account"
        }
    }
    catch {
        Write-ErrorMessage "Failed to assign RBAC on Storage Account: $_"
    }
}
else {
    Write-Info "No storage account provided - remember to assign 'Storage Account Key Operator Service Role' manually"
}

# Create Automation Variables
Write-StepHeader "Step 10: Creating Automation Variables"
$variables = @(
    @{ Name = "FileInventory_LogAnalyticsDceEndpoint"; Value = $dceEndpoint; Description = "Data Collection Endpoint URI" }
    @{ Name = "FileInventory_LogAnalyticsDcrImmutableId"; Value = $dcrImmutableId; Description = "Data Collection Rule Immutable ID" }
    @{ Name = "FileInventory_LogAnalyticsStreamName"; Value = $streamName; Description = "Log Analytics Stream Name" }
    @{ Name = "FileInventory_LogAnalyticsTableName"; Value = $tableName; Description = "Log Analytics Table Name" }
    @{ Name = "FileInventory_ExcludePatterns"; Value = "*.tmp,~`$*,.DS_Store,Thumbs.db"; Description = "File patterns to exclude from scanning" }
)

foreach ($var in $variables) {
    try {
        $existingVar = Get-AzAutomationVariable -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $var.Name -ErrorAction SilentlyContinue
        if ($existingVar) {
            Set-AzAutomationVariable `
                -ResourceGroupName $ResourceGroupName `
                -AutomationAccountName $AutomationAccountName `
                -Name $var.Name `
                -Value $var.Value `
                -Encrypted $false `
                -ErrorAction Stop | Out-Null
            Write-Info "Updated variable '$($var.Name)'"
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
            Write-Success "Created variable '$($var.Name)'"
        }
    }
    catch {
        Write-ErrorMessage "Failed to create variable '$($var.Name)': $_"
    }
}

# Summary
Write-Host @"

╔═══════════════════════════════════════════════════════════════════════════════╗
║                         DEPLOYMENT COMPLETED SUCCESSFULLY                      ║
╚═══════════════════════════════════════════════════════════════════════════════╝

"@ -ForegroundColor Green

Write-Host "Resources Created/Configured:" -ForegroundColor White
Write-Host "  • Resource Group:        $ResourceGroupName" -ForegroundColor Gray
Write-Host "  • Log Analytics:         $LogAnalyticsWorkspaceName" -ForegroundColor Gray
Write-Host "  • Custom Table:          $tableName" -ForegroundColor Gray
Write-Host "  • DCE:                   $dceName" -ForegroundColor Gray
Write-Host "  • DCR:                   $dcrName" -ForegroundColor Gray
Write-Host "  • Automation Account:    $AutomationAccountName" -ForegroundColor Gray
Write-Host ""

Write-Host "Configuration Values (saved to Automation Variables):" -ForegroundColor White
Write-Host "  • DCE Endpoint:          $dceEndpoint" -ForegroundColor Gray
Write-Host "  • DCR Immutable ID:      $dcrImmutableId" -ForegroundColor Gray
Write-Host "  • Stream Name:           $streamName" -ForegroundColor Gray
Write-Host "  • Table Name:            $tableName" -ForegroundColor Gray
Write-Host ""

Write-Host "Next Steps:" -ForegroundColor Yellow
Write-Host "  1. Wait 5-10 minutes for module imports to complete" -ForegroundColor Gray
Write-Host "  2. Import the runbook from Runbooks/AzureFileInventoryScanner.ps1" -ForegroundColor Gray
Write-Host "  3. Assign storage account permissions (if not done already)" -ForegroundColor Gray
Write-Host "  4. Run the runbook with your storage account parameters" -ForegroundColor Gray
Write-Host ""

if (-not $StorageAccountResourceId) {
    Write-Host "IMPORTANT: Run the following command to grant storage permissions:" -ForegroundColor Yellow
    Write-Host @"
  New-AzRoleAssignment ``
      -ObjectId "$principalId" ``
      -RoleDefinitionName "Storage Account Key Operator Service Role" ``
      -Scope "/subscriptions/<subscription-id>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<storage-account>"
"@ -ForegroundColor Cyan
}

#endregion
