<#
.SYNOPSIS
    Sets up an Azure Automation Hybrid Runbook Worker for the File Inventory Scanner.

.DESCRIPTION
    This script automates the setup of a Hybrid Runbook Worker including:
    - Creating a Windows VM (optional)
    - Enabling Managed Identity
    - Creating a Hybrid Worker Group
    - Adding the VM to the worker group
    - Configuring RBAC permissions

.PARAMETER ResourceGroupName
    Resource group for the Hybrid Worker resources.

.PARAMETER Location
    Azure region for resources.

.PARAMETER AutomationAccountName
    Name of the existing Automation Account.

.PARAMETER VmName
    Name for the Hybrid Worker VM.

.PARAMETER VmSize
    Size of the VM. Default: Standard_D2s_v3

.PARAMETER WorkerGroupName
    Name for the Hybrid Worker Group. Default: file-inventory-workers

.PARAMETER CreateNewVm
    If true, creates a new VM. If false, uses existing VM.

.PARAMETER TargetStorageAccountId
    Resource ID of the storage account to scan (for RBAC assignment).

.PARAMETER DcrResourceId
    Resource ID of the Data Collection Rule (for RBAC assignment).

.EXAMPLE
    # Create new VM and set up Hybrid Worker
    .\Setup-HybridWorker.ps1 `
        -ResourceGroupName "rg-file-inventory" `
        -Location "eastus" `
        -AutomationAccountName "aa-file-inventory" `
        -VmName "vm-hybrid-worker" `
        -CreateNewVm $true

.EXAMPLE
    # Use existing VM
    .\Setup-HybridWorker.ps1 `
        -ResourceGroupName "rg-file-inventory" `
        -Location "eastus" `
        -AutomationAccountName "aa-file-inventory" `
        -VmName "existing-vm" `
        -CreateNewVm $false

.NOTES
    Prerequisites:
    - Azure CLI installed and logged in
    - Az PowerShell module
    - Contributor access to subscription
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory = $true)]
    [string]$Location,
    
    [Parameter(Mandatory = $true)]
    [string]$AutomationAccountName,
    
    [Parameter(Mandatory = $true)]
    [string]$VmName,
    
    [Parameter(Mandatory = $false)]
    [string]$VmSize = "Standard_D2s_v3",
    
    [Parameter(Mandatory = $false)]
    [string]$WorkerGroupName = "file-inventory-workers",
    
    [Parameter(Mandatory = $false)]
    [bool]$CreateNewVm = $false,
    
    [Parameter(Mandatory = $false)]
    [string]$TargetStorageAccountId = "",
    
    [Parameter(Mandatory = $false)]
    [string]$DcrResourceId = ""
)

$ErrorActionPreference = "Stop"

Write-Host @"

╔═══════════════════════════════════════════════════════════════════════════════╗
║                                                                               ║
║              Azure Automation Hybrid Worker Setup Script                      ║
║                                                                               ║
╚═══════════════════════════════════════════════════════════════════════════════╝

"@ -ForegroundColor Cyan

Write-Host "Configuration:" -ForegroundColor White
Write-Host "  Resource Group:      $ResourceGroupName" -ForegroundColor Gray
Write-Host "  Location:            $Location" -ForegroundColor Gray
Write-Host "  Automation Account:  $AutomationAccountName" -ForegroundColor Gray
Write-Host "  VM Name:             $VmName" -ForegroundColor Gray
Write-Host "  Worker Group:        $WorkerGroupName" -ForegroundColor Gray
Write-Host "  Create New VM:       $CreateNewVm" -ForegroundColor Gray
Write-Host ""

# Check Azure CLI login
Write-Host "Step 1: Checking Azure CLI login..." -ForegroundColor Cyan
$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Host "  Not logged in. Running 'az login'..." -ForegroundColor Yellow
    az login
    $account = az account show | ConvertFrom-Json
}
Write-Host "  ✓ Logged in as: $($account.user.name)" -ForegroundColor Green
Write-Host "  ✓ Subscription: $($account.name)" -ForegroundColor Green

$subscriptionId = $account.id

# Verify Automation Account exists
Write-Host "`nStep 2: Verifying Automation Account..." -ForegroundColor Cyan
$aa = az automation account show --name $AutomationAccountName --resource-group $ResourceGroupName 2>$null | ConvertFrom-Json
if (-not $aa) {
    Write-Host "  ✗ Automation Account '$AutomationAccountName' not found!" -ForegroundColor Red
    exit 1
}
Write-Host "  ✓ Found Automation Account: $AutomationAccountName" -ForegroundColor Green

# Create or verify VM
Write-Host "`nStep 3: Setting up VM..." -ForegroundColor Cyan

if ($CreateNewVm) {
    Write-Host "  Creating new VM '$VmName'..." -ForegroundColor Yellow
    
    # Generate random password
    $password = -join ((65..90) + (97..122) + (48..57) + (33, 35, 36, 37, 38, 42) | Get-Random -Count 16 | ForEach-Object { [char]$_ })
    $password = "P@" + $password + "1!"  # Ensure complexity
    
    # Create VM
    az vm create `
        --resource-group $ResourceGroupName `
        --name $VmName `
        --image Win2022Datacenter `
        --size $VmSize `
        --admin-username azureadmin `
        --admin-password $password `
        --public-ip-sku Standard `
        --output none
    
    Write-Host "  ✓ Created VM '$VmName'" -ForegroundColor Green
    Write-Host "  ✓ Admin Username: azureadmin" -ForegroundColor Green
    Write-Host "  ✓ Admin Password: $password" -ForegroundColor Green
    Write-Host ""
    Write-Host "  ⚠️  SAVE THIS PASSWORD - it will not be shown again!" -ForegroundColor Yellow
    Write-Host ""
}
else {
    Write-Host "  Verifying existing VM '$VmName'..." -ForegroundColor Yellow
    $vm = az vm show --name $VmName --resource-group $ResourceGroupName 2>$null | ConvertFrom-Json
    if (-not $vm) {
        Write-Host "  ✗ VM '$VmName' not found!" -ForegroundColor Red
        exit 1
    }
    Write-Host "  ✓ Found VM: $VmName" -ForegroundColor Green
}

# Enable Managed Identity
Write-Host "`nStep 4: Enabling Managed Identity on VM..." -ForegroundColor Cyan
$identity = az vm identity assign --name $VmName --resource-group $ResourceGroupName --output json | ConvertFrom-Json
$vmPrincipalId = $identity.systemAssignedIdentity
Write-Host "  ✓ Managed Identity Principal ID: $vmPrincipalId" -ForegroundColor Green

# Create Hybrid Worker Group
Write-Host "`nStep 5: Creating Hybrid Worker Group..." -ForegroundColor Cyan
$existingGroup = az automation hrwg show `
    --automation-account-name $AutomationAccountName `
    --resource-group $ResourceGroupName `
    --name $WorkerGroupName 2>$null

if ($existingGroup) {
    Write-Host "  ℹ Hybrid Worker Group '$WorkerGroupName' already exists" -ForegroundColor Yellow
}
else {
    az automation hrwg create `
        --automation-account-name $AutomationAccountName `
        --resource-group $ResourceGroupName `
        --name $WorkerGroupName `
        --output none
    Write-Host "  ✓ Created Hybrid Worker Group: $WorkerGroupName" -ForegroundColor Green
}

# Get VM resource ID
$vmResourceId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Compute/virtualMachines/$VmName"

# Add VM to Hybrid Worker Group
Write-Host "`nStep 6: Adding VM to Hybrid Worker Group..." -ForegroundColor Cyan
Write-Host "  ℹ This installs the Hybrid Worker extension on the VM..." -ForegroundColor Yellow

try {
    az automation hrwg hrw create `
        --automation-account-name $AutomationAccountName `
        --resource-group $ResourceGroupName `
        --hybrid-runbook-worker-group-name $WorkerGroupName `
        --name $VmName `
        --vm-resource-id $vmResourceId `
        --output none 2>$null
    Write-Host "  ✓ Added VM to Hybrid Worker Group" -ForegroundColor Green
}
catch {
    Write-Host "  ℹ VM may already be in the worker group or extension is installing..." -ForegroundColor Yellow
}

# Assign RBAC permissions
Write-Host "`nStep 7: Assigning RBAC permissions..." -ForegroundColor Cyan

if ($TargetStorageAccountId) {
    Write-Host "  Assigning Storage Account Key Operator role..." -ForegroundColor Yellow
    az role assignment create `
        --assignee $vmPrincipalId `
        --role "Storage Account Key Operator Service Role" `
        --scope $TargetStorageAccountId `
        --output none 2>$null
    Write-Host "  ✓ Assigned Storage Account Key Operator role" -ForegroundColor Green
    
    Write-Host "  Assigning Storage File Data Privileged Reader role..." -ForegroundColor Yellow
    az role assignment create `
        --assignee $vmPrincipalId `
        --role "Storage File Data Privileged Reader" `
        --scope $TargetStorageAccountId `
        --output none 2>$null
    Write-Host "  ✓ Assigned Storage File Data Privileged Reader role" -ForegroundColor Green
}
else {
    Write-Host "  ⚠️ TargetStorageAccountId not provided - assign manually later" -ForegroundColor Yellow
}

if ($DcrResourceId) {
    Write-Host "  Assigning Monitoring Metrics Publisher role..." -ForegroundColor Yellow
    az role assignment create `
        --assignee $vmPrincipalId `
        --role "Monitoring Metrics Publisher" `
        --scope $DcrResourceId `
        --output none 2>$null
    Write-Host "  ✓ Assigned Monitoring Metrics Publisher role" -ForegroundColor Green
}
else {
    Write-Host "  ⚠️ DcrResourceId not provided - assign manually later" -ForegroundColor Yellow
}

# Summary
Write-Host @"

╔═══════════════════════════════════════════════════════════════════════════════╗
║                              SETUP COMPLETE                                   ║
╚═══════════════════════════════════════════════════════════════════════════════╝

"@ -ForegroundColor Green

Write-Host "Resources Configured:" -ForegroundColor White
Write-Host "  • VM:                 $VmName" -ForegroundColor Gray
Write-Host "  • Managed Identity:   $vmPrincipalId" -ForegroundColor Gray
Write-Host "  • Worker Group:       $WorkerGroupName" -ForegroundColor Gray
Write-Host ""

Write-Host "⚠️  IMPORTANT: Manual Steps Required" -ForegroundColor Yellow
Write-Host ""
Write-Host "1. Wait 5-10 minutes for the Hybrid Worker extension to install" -ForegroundColor White
Write-Host ""
Write-Host "2. RDP into the VM and install PowerShell modules:" -ForegroundColor White
Write-Host "   Install-Module -Name Az.Accounts -Force -AllowClobber" -ForegroundColor Cyan
Write-Host "   Install-Module -Name Az.Storage -Force -AllowClobber" -ForegroundColor Cyan
Write-Host ""

if (-not $TargetStorageAccountId) {
    Write-Host "3. Assign storage account permissions:" -ForegroundColor White
    Write-Host @"
   # Key-based access (retrieve storage keys)
   az role assignment create ``
       --assignee "$vmPrincipalId" ``
       --role "Storage Account Key Operator Service Role" ``
       --scope "/subscriptions/$subscriptionId/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<storage>"

   # RBAC-based data access (read file share content)
   az role assignment create ``
       --assignee "$vmPrincipalId" ``
       --role "Storage File Data Privileged Reader" ``
       --scope "/subscriptions/$subscriptionId/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<storage>"
"@ -ForegroundColor Cyan
    Write-Host ""
}

if (-not $DcrResourceId) {
    Write-Host "4. Assign DCR permissions:" -ForegroundColor White
    Write-Host @"
   az role assignment create ``
       --assignee "$vmPrincipalId" ``
       --role "Monitoring Metrics Publisher" ``
       --scope "/subscriptions/$subscriptionId/resourceGroups/<rg>/providers/Microsoft.Insights/dataCollectionRules/<dcr>"
"@ -ForegroundColor Cyan
    Write-Host ""
}

Write-Host "Run your scan on the Hybrid Worker:" -ForegroundColor White
Write-Host @"
Start-AzAutomationRunbook ``
    -ResourceGroupName "$ResourceGroupName" ``
    -AutomationAccountName "$AutomationAccountName" ``
    -Name "AzureFileInventoryScanner" ``
    -RunOn "$WorkerGroupName" ``
    -Parameters @{
        StorageAccountName = "<your-storage-account>"
        StorageAccountResourceGroup = "<your-storage-rg>"
        SubscriptionId = "$subscriptionId"
        SkipHashComputation = `$true
    }
"@ -ForegroundColor Cyan
