<#
.SYNOPSIS
    Sets up an Azure Automation Hybrid Runbook Worker on a Linux VM.

.DESCRIPTION
    This script automates the setup of a Linux Hybrid Runbook Worker including:
    - Verifying the Linux VM exists and is running
    - Enabling System-Assigned Managed Identity
    - Creating a Hybrid Worker Group
    - Registering the worker via REST API
    - Installing the HybridWorkerForLinux extension
    - Configuring RBAC permissions

.PARAMETER ResourceGroupName
    Resource group where the Automation Account is located.

.PARAMETER AutomationAccountName
    Name of the existing Automation Account.

.PARAMETER VmName
    Name of the existing Linux VM to configure as a Hybrid Worker.

.PARAMETER VmResourceGroupName
    Resource group where the Linux VM is located. If not specified, uses ResourceGroupName.

.PARAMETER WorkerGroupName
    Name for the Hybrid Worker Group. Default: Linux

.PARAMETER TargetStorageAccountId
    Resource ID of the storage account to scan (for RBAC assignment). Optional.

.PARAMETER DcrResourceId
    Resource ID of the Data Collection Rule (for RBAC assignment). Optional.

.EXAMPLE
    # Basic setup
    .\Setup-LinuxHybridWorker.ps1 `
        -ResourceGroupName "rg-file-lifecycle" `
        -AutomationAccountName "aa-file-lifecycle" `
        -VmName "LinuxHybridWorker01" `
        -VmResourceGroupName "LABAZSTG"

.EXAMPLE
    # Full setup with RBAC assignments
    .\Setup-LinuxHybridWorker.ps1 `
        -ResourceGroupName "rg-file-lifecycle" `
        -AutomationAccountName "aa-file-lifecycle" `
        -VmName "LinuxHybridWorker01" `
        -VmResourceGroupName "LABAZSTG" `
        -WorkerGroupName "LinuxWorkers" `
        -TargetStorageAccountId "/subscriptions/.../storageAccounts/mystorageaccount" `
        -DcrResourceId "/subscriptions/.../dataCollectionRules/mydcr"

.NOTES
    Prerequisites:
    - Azure CLI installed and logged in
    - Contributor access to both resource groups
    - User Access Administrator to assign RBAC roles
    - Linux VM must be running (Ubuntu 18.04+, RHEL 7+, SUSE 12+)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory = $true)]
    [string]$AutomationAccountName,
    
    [Parameter(Mandatory = $true)]
    [string]$VmName,
    
    [Parameter(Mandatory = $false)]
    [string]$VmResourceGroupName = "",
    
    [Parameter(Mandatory = $false)]
    [string]$WorkerGroupName = "Linux",
    
    [Parameter(Mandatory = $false)]
    [string]$TargetStorageAccountId = "",
    
    [Parameter(Mandatory = $false)]
    [string]$DcrResourceId = ""
)

$ErrorActionPreference = "Stop"

# Use same resource group for VM if not specified
if ([string]::IsNullOrEmpty($VmResourceGroupName)) {
    $VmResourceGroupName = $ResourceGroupName
}

Write-Host @"

╔═══════════════════════════════════════════════════════════════════════════════╗
║                                                                               ║
║           Azure Automation Linux Hybrid Worker Setup Script                   ║
║                                                                               ║
╚═══════════════════════════════════════════════════════════════════════════════╝

"@ -ForegroundColor Cyan

Write-Host "Configuration:" -ForegroundColor White
Write-Host "  Automation Account RG:  $ResourceGroupName" -ForegroundColor Gray
Write-Host "  Automation Account:     $AutomationAccountName" -ForegroundColor Gray
Write-Host "  VM Resource Group:      $VmResourceGroupName" -ForegroundColor Gray
Write-Host "  VM Name:                $VmName" -ForegroundColor Gray
Write-Host "  Worker Group:           $WorkerGroupName" -ForegroundColor Gray
Write-Host ""

#region Step 1: Check Azure CLI login
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
#endregion

#region Step 2: Verify Automation Account exists
Write-Host "`nStep 2: Verifying Automation Account..." -ForegroundColor Cyan
$aa = az automation account show --name $AutomationAccountName --resource-group $ResourceGroupName 2>$null | ConvertFrom-Json
if (-not $aa) {
    Write-Host "  ✗ Automation Account '$AutomationAccountName' not found in resource group '$ResourceGroupName'!" -ForegroundColor Red
    exit 1
}
Write-Host "  ✓ Found Automation Account: $AutomationAccountName" -ForegroundColor Green

$automationAccountUrl = $aa.automationHybridServiceUrl
Write-Host "  ✓ Hybrid Service URL: $automationAccountUrl" -ForegroundColor Green
#endregion

#region Step 3: Verify Linux VM exists and is running
Write-Host "`nStep 3: Verifying Linux VM..." -ForegroundColor Cyan
$vm = az vm show --name $VmName --resource-group $VmResourceGroupName 2>$null | ConvertFrom-Json
if (-not $vm) {
    Write-Host "  ✗ VM '$VmName' not found in resource group '$VmResourceGroupName'!" -ForegroundColor Red
    exit 1
}

# Check OS type
$osType = $vm.storageProfile.osDisk.osType
if ($osType -ne "Linux") {
    Write-Host "  ✗ VM '$VmName' is not a Linux VM (OS Type: $osType)!" -ForegroundColor Red
    Write-Host "  ℹ Use Setup-HybridWorker.ps1 for Windows VMs." -ForegroundColor Yellow
    exit 1
}
Write-Host "  ✓ Found Linux VM: $VmName" -ForegroundColor Green

# Check VM is running
$vmStatus = az vm get-instance-view --name $VmName --resource-group $VmResourceGroupName --query "instanceView.statuses[1].displayStatus" -o tsv
if ($vmStatus -ne "VM running") {
    Write-Host "  ✗ VM is not running (Status: $vmStatus)!" -ForegroundColor Red
    Write-Host "  ℹ Please start the VM and try again." -ForegroundColor Yellow
    exit 1
}
Write-Host "  ✓ VM is running" -ForegroundColor Green

$vmResourceId = "/subscriptions/$subscriptionId/resourceGroups/$VmResourceGroupName/providers/Microsoft.Compute/virtualMachines/$VmName"
#endregion

#region Step 4: Check and remove any failed Hybrid Worker extension
Write-Host "`nStep 4: Checking for existing Hybrid Worker extensions..." -ForegroundColor Cyan
$existingExtensions = az vm extension list --vm-name $VmName --resource-group $VmResourceGroupName --query "[?contains(name, 'HybridWorker')]" -o json | ConvertFrom-Json

foreach ($ext in $existingExtensions) {
    if ($ext.provisioningState -eq "Failed" -or $ext.typePropertiesType -eq "HybridWorkerForWindows") {
        Write-Host "  ⚠️  Found problematic extension: $($ext.name) (State: $($ext.provisioningState), Type: $($ext.typePropertiesType))" -ForegroundColor Yellow
        Write-Host "  Removing extension..." -ForegroundColor Yellow
        az vm extension delete --vm-name $VmName --resource-group $VmResourceGroupName --name $ext.name --no-wait 2>$null
        Start-Sleep -Seconds 10
        Write-Host "  ✓ Extension removal initiated" -ForegroundColor Green
    }
    elseif ($ext.provisioningState -eq "Succeeded" -and $ext.typePropertiesType -eq "HybridWorkerForLinux") {
        Write-Host "  ℹ HybridWorkerForLinux extension already installed and healthy" -ForegroundColor Yellow
    }
}

if ($existingExtensions.Count -eq 0) {
    Write-Host "  ✓ No existing Hybrid Worker extensions found" -ForegroundColor Green
}
#endregion

#region Step 5: Enable Managed Identity
Write-Host "`nStep 5: Enabling Managed Identity on VM..." -ForegroundColor Cyan
$identity = az vm identity assign --name $VmName --resource-group $VmResourceGroupName --output json 2>$null | ConvertFrom-Json

if ($identity.systemAssignedIdentity) {
    $vmPrincipalId = $identity.systemAssignedIdentity
}
else {
    # Identity may already exist, get it from the VM
    $vmInfo = az vm show --name $VmName --resource-group $VmResourceGroupName --query "identity.principalId" -o tsv
    $vmPrincipalId = $vmInfo
}

if ([string]::IsNullOrEmpty($vmPrincipalId)) {
    Write-Host "  ✗ Failed to get Managed Identity Principal ID!" -ForegroundColor Red
    exit 1
}
Write-Host "  ✓ Managed Identity Principal ID: $vmPrincipalId" -ForegroundColor Green
#endregion

#region Step 6: Create Hybrid Worker Group
Write-Host "`nStep 6: Creating Hybrid Worker Group..." -ForegroundColor Cyan
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
#endregion

#region Step 7: Register Hybrid Worker via REST API
Write-Host "`nStep 7: Registering Hybrid Worker..." -ForegroundColor Cyan

# Check if worker already exists
$existingWorkers = az automation hrwg hrw list `
    --automation-account-name $AutomationAccountName `
    --resource-group $ResourceGroupName `
    --hybrid-runbook-worker-group-name $WorkerGroupName `
    --query "[?vmResourceId=='$vmResourceId']" -o json | ConvertFrom-Json

if ($existingWorkers.Count -gt 0) {
    Write-Host "  ℹ VM is already registered as a Hybrid Worker" -ForegroundColor Yellow
    $workerId = $existingWorkers[0].name
}
else {
    $workerId = (New-Guid).Guid
    
    # Create body JSON file to avoid PowerShell quoting issues
    $bodyContent = @{
        properties = @{
            vmResourceId = $vmResourceId
        }
    } | ConvertTo-Json
    
    $bodyFile = Join-Path $env:TEMP "hw-body-$workerId.json"
    $bodyContent | Out-File $bodyFile -Encoding utf8 -NoNewline
    
    $apiUrl = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName/hybridRunbookWorkerGroups/$WorkerGroupName/hybridRunbookWorkers/$workerId`?api-version=2021-06-22"
    
    $result = az rest --method PUT --url $apiUrl --body "@$bodyFile" -o json 2>&1
    
    # Clean up temp file
    Remove-Item $bodyFile -Force -ErrorAction SilentlyContinue
    
    Write-Host "  ✓ Registered Hybrid Worker: $workerId" -ForegroundColor Green
}
#endregion

#region Step 8: Install HybridWorkerForLinux Extension
Write-Host "`nStep 8: Installing HybridWorkerForLinux extension..." -ForegroundColor Cyan

# Check if extension already exists and is healthy
$currentExtension = az vm extension show --vm-name $VmName --resource-group $VmResourceGroupName --name "HybridWorkerForLinux" 2>$null | ConvertFrom-Json

if ($currentExtension -and $currentExtension.provisioningState -eq "Succeeded") {
    Write-Host "  ℹ HybridWorkerForLinux extension already installed and healthy" -ForegroundColor Yellow
}
else {
    # Create settings JSON file to avoid PowerShell quoting issues
    $settingsContent = @{
        AutomationAccountURL = $automationAccountUrl
    } | ConvertTo-Json
    
    $settingsFile = Join-Path $env:TEMP "hw-settings-$VmName.json"
    $settingsContent | Out-File $settingsFile -Encoding utf8 -NoNewline
    
    Write-Host "  Installing extension (this may take a few minutes)..." -ForegroundColor Yellow
    
    $extensionResult = az vm extension set `
        --vm-name $VmName `
        --resource-group $VmResourceGroupName `
        --name "HybridWorkerForLinux" `
        --publisher "Microsoft.Azure.Automation.HybridWorker" `
        --version "1.1" `
        --enable-auto-upgrade true `
        --settings "@$settingsFile" 2>&1
    
    # Clean up temp file
    Remove-Item $settingsFile -Force -ErrorAction SilentlyContinue
    
    # Verify installation
    $extensionStatus = az vm extension show --vm-name $VmName --resource-group $VmResourceGroupName --name "HybridWorkerForLinux" --query "provisioningState" -o tsv 2>$null
    
    if ($extensionStatus -eq "Succeeded") {
        Write-Host "  ✓ HybridWorkerForLinux extension installed successfully" -ForegroundColor Green
    }
    else {
        Write-Host "  ✗ Extension installation failed or is still in progress" -ForegroundColor Red
        Write-Host "  ℹ Check the Azure Portal for detailed error messages" -ForegroundColor Yellow
        Write-Host "  ℹ Common issues:" -ForegroundColor Yellow
        Write-Host "     - VM cannot reach Azure Automation endpoints" -ForegroundColor Gray
        Write-Host "     - Managed Identity not properly configured" -ForegroundColor Gray
        Write-Host "     - Unsupported Linux distribution" -ForegroundColor Gray
        exit 1
    }
}
#endregion

#region Step 9: Assign RBAC permissions
Write-Host "`nStep 9: Assigning RBAC permissions..." -ForegroundColor Cyan

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
#endregion

#region Step 10: Verify worker is online
Write-Host "`nStep 10: Verifying Hybrid Worker status..." -ForegroundColor Cyan
Start-Sleep -Seconds 5

$workerInfo = az automation hrwg hrw list `
    --automation-account-name $AutomationAccountName `
    --resource-group $ResourceGroupName `
    --hybrid-runbook-worker-group-name $WorkerGroupName `
    --query "[?vmResourceId=='$vmResourceId'] | [0]" -o json | ConvertFrom-Json

if ($workerInfo -and $workerInfo.ip) {
    Write-Host "  ✓ Worker is online!" -ForegroundColor Green
    Write-Host "    - Worker Name: $($workerInfo.workerName)" -ForegroundColor Gray
    Write-Host "    - IP Address:  $($workerInfo.ip)" -ForegroundColor Gray
    Write-Host "    - Last Seen:   $($workerInfo.lastSeenDateTime)" -ForegroundColor Gray
}
else {
    Write-Host "  ℹ Worker registered but may take a minute to come online" -ForegroundColor Yellow
}
#endregion

#region Summary
Write-Host @"

╔═══════════════════════════════════════════════════════════════════════════════╗
║                              SETUP COMPLETE                                   ║
╚═══════════════════════════════════════════════════════════════════════════════╝

"@ -ForegroundColor Green

Write-Host "Resources Configured:" -ForegroundColor White
Write-Host "  • VM:                 $VmName" -ForegroundColor Gray
Write-Host "  • Managed Identity:   $vmPrincipalId" -ForegroundColor Gray
Write-Host "  • Worker Group:       $WorkerGroupName" -ForegroundColor Gray
Write-Host "  • Worker ID:          $workerId" -ForegroundColor Gray
Write-Host ""

if (-not $TargetStorageAccountId -or -not $DcrResourceId) {
    Write-Host "⚠️  IMPORTANT: Manual Steps Required" -ForegroundColor Yellow
    Write-Host ""
}

if (-not $TargetStorageAccountId) {
    Write-Host "Assign storage account permissions:" -ForegroundColor White
    Write-Host @"
   az role assignment create ``
       --assignee "$vmPrincipalId" ``
       --role "Storage Account Key Operator Service Role" ``
       --scope "/subscriptions/$subscriptionId/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<storage>"

   az role assignment create ``
       --assignee "$vmPrincipalId" ``
       --role "Storage File Data Privileged Reader" ``
       --scope "/subscriptions/$subscriptionId/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<storage>"
"@ -ForegroundColor Cyan
    Write-Host ""
}

if (-not $DcrResourceId) {
    Write-Host "Assign DCR permissions:" -ForegroundColor White
    Write-Host @"
   az role assignment create ``
       --assignee "$vmPrincipalId" ``
       --role "Monitoring Metrics Publisher" ``
       --scope "/subscriptions/$subscriptionId/resourceGroups/<rg>/providers/Microsoft.Insights/dataCollectionRules/<dcr>"
"@ -ForegroundColor Cyan
    Write-Host ""
}

Write-Host "Run your scan on the Linux Hybrid Worker:" -ForegroundColor White
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
#endregion
