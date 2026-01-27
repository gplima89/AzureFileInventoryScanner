<#
.SYNOPSIS
    Comprehensive troubleshooting script for Azure File Inventory Scanner setup.

.DESCRIPTION
    This script validates all components of the File Inventory Scanner:
    - Azure authentication
    - Data Collection Endpoint (DCE)
    - Data Collection Rule (DCR)
    - Log Analytics Workspace (LAW) and custom table
    - Automation Account configuration
    - RBAC permissions
    - End-to-end data ingestion test

.PARAMETER SubscriptionId
    Azure Subscription ID

.PARAMETER ResourceGroupName
    Resource group containing all resources

.PARAMETER AutomationAccountName
    Name of the Automation Account

.PARAMETER WorkspaceName
    Log Analytics Workspace name

.PARAMETER DceName
    Data Collection Endpoint name

.PARAMETER DcrName
    Data Collection Rule name

.PARAMETER TableName
    Custom table name (without _CL suffix)

.PARAMETER RunIngestionTest
    If specified, sends a test record to verify end-to-end ingestion

.EXAMPLE
    .\Test-FileInventorySetup.ps1 `
        -SubscriptionId "dd8df97d-4198-4753-855e-40b86901b818" `
        -ResourceGroupName "rg-file-lifecycle" `
        -AutomationAccountName "aa-file-lifecycle" `
        -WorkspaceName "stgfilelifecycle" `
        -DceName "StgFileLifeCycleDCEdp" `
        -DcrName "StgFileLifeCycleDCR" `
        -TableName "StorageLifeCycle01" `
        -RunIngestionTest

.NOTES
    Author: Azure File Storage Lifecycle Team
    Version: 1.0.0
    Requires: Az.Accounts, Az.Monitor, Az.OperationalInsights modules
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory = $true)]
    [string]$AutomationAccountName,
    
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceName,
    
    [Parameter(Mandatory = $true)]
    [string]$DceName,
    
    [Parameter(Mandatory = $true)]
    [string]$DcrName,
    
    [Parameter(Mandatory = $true)]
    [string]$TableName,
    
    [Parameter(Mandatory = $false)]
    [switch]$RunIngestionTest
)

#region Helper Functions

function Write-TestResult {
    param(
        [string]$TestName,
        [bool]$Passed,
        [string]$Message = "",
        [string]$Details = ""
    )
    
    $status = if ($Passed) { "[PASS]" } else { "[FAIL]" }
    $color = if ($Passed) { "Green" } else { "Red" }
    
    Write-Host "$status $TestName" -ForegroundColor $color
    if ($Message) {
        Write-Host "       $Message" -ForegroundColor Gray
    }
    if ($Details -and -not $Passed) {
        Write-Host "       Details: $Details" -ForegroundColor Yellow
    }
    
    return [PSCustomObject]@{
        TestName = $TestName
        Passed = $Passed
        Message = $Message
        Details = $Details
    }
}

function Write-SectionHeader {
    param([string]$Title)
    Write-Host ""
    Write-Host "═" * 70 -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "═" * 70 -ForegroundColor Cyan
}

#endregion

#region Main Script

$ErrorActionPreference = "Continue"
$results = @()

Write-Host @"

╔═══════════════════════════════════════════════════════════════════════════════╗
║                                                                               ║
║          Azure File Inventory Scanner - Setup Validation Script               ║
║                                                                               ║
╚═══════════════════════════════════════════════════════════════════════════════╝

"@ -ForegroundColor Cyan

Write-Host "Configuration:" -ForegroundColor White
Write-Host "  Subscription:        $SubscriptionId" -ForegroundColor Gray
Write-Host "  Resource Group:      $ResourceGroupName" -ForegroundColor Gray
Write-Host "  Automation Account:  $AutomationAccountName" -ForegroundColor Gray
Write-Host "  Workspace:           $WorkspaceName" -ForegroundColor Gray
Write-Host "  DCE:                 $DceName" -ForegroundColor Gray
Write-Host "  DCR:                 $DcrName" -ForegroundColor Gray
Write-Host "  Table:               ${TableName}_CL" -ForegroundColor Gray
Write-Host ""

$fullTableName = "${TableName}_CL"
$streamName = "Custom-${TableName}_CL"

#region 1. Authentication Tests

Write-SectionHeader "1. AUTHENTICATION & SUBSCRIPTION"

# Test Azure CLI login
try {
    $account = az account show 2>$null | ConvertFrom-Json
    if ($account) {
        $results += Write-TestResult -TestName "Azure CLI Login" -Passed $true -Message "Logged in as: $($account.user.name)"
    } else {
        $results += Write-TestResult -TestName "Azure CLI Login" -Passed $false -Message "Not logged in" -Details "Run 'az login'"
    }
} catch {
    $results += Write-TestResult -TestName "Azure CLI Login" -Passed $false -Message "Error checking login" -Details $_.Exception.Message
}

# Test subscription access
try {
    az account set --subscription $SubscriptionId 2>$null
    $currentSub = az account show --query id -o tsv 2>$null
    if ($currentSub -eq $SubscriptionId) {
        $results += Write-TestResult -TestName "Subscription Access" -Passed $true -Message "Subscription set successfully"
    } else {
        $results += Write-TestResult -TestName "Subscription Access" -Passed $false -Message "Could not set subscription"
    }
} catch {
    $results += Write-TestResult -TestName "Subscription Access" -Passed $false -Details $_.Exception.Message
}

# Test PowerShell Az module
try {
    $azContext = Get-AzContext -ErrorAction SilentlyContinue
    if ($azContext) {
        $results += Write-TestResult -TestName "PowerShell Az Module" -Passed $true -Message "Context: $($azContext.Account.Id)"
    } else {
        # Try to connect
        Connect-AzAccount -Subscription $SubscriptionId -ErrorAction Stop | Out-Null
        $results += Write-TestResult -TestName "PowerShell Az Module" -Passed $true -Message "Connected successfully"
    }
} catch {
    $results += Write-TestResult -TestName "PowerShell Az Module" -Passed $false -Details "Run 'Connect-AzAccount'"
}

#endregion

#region 2. Resource Group Tests

Write-SectionHeader "2. RESOURCE GROUP"

try {
    $rg = az group show --name $ResourceGroupName 2>$null | ConvertFrom-Json
    if ($rg) {
        $results += Write-TestResult -TestName "Resource Group Exists" -Passed $true -Message "Location: $($rg.location)"
    } else {
        $results += Write-TestResult -TestName "Resource Group Exists" -Passed $false -Details "Resource group not found"
    }
} catch {
    $results += Write-TestResult -TestName "Resource Group Exists" -Passed $false -Details $_.Exception.Message
}

#endregion

#region 3. Data Collection Endpoint Tests

Write-SectionHeader "3. DATA COLLECTION ENDPOINT (DCE)"

$dceEndpoint = $null
try {
    $dce = az monitor data-collection endpoint show --name $DceName --resource-group $ResourceGroupName 2>$null | ConvertFrom-Json
    if ($dce) {
        $results += Write-TestResult -TestName "DCE Exists" -Passed $true -Message "ID: $($dce.id)"
        
        # Check logs ingestion endpoint
        $dceEndpoint = $dce.logsIngestion.endpoint
        if ($dceEndpoint) {
            $results += Write-TestResult -TestName "DCE Logs Ingestion Endpoint" -Passed $true -Message $dceEndpoint
        } else {
            $results += Write-TestResult -TestName "DCE Logs Ingestion Endpoint" -Passed $false -Details "Logs ingestion endpoint is empty"
        }
        
        # Check public network access
        $networkAccess = $dce.networkAcls.publicNetworkAccess
        $results += Write-TestResult -TestName "DCE Public Network Access" -Passed ($networkAccess -eq "Enabled") -Message "Status: $networkAccess"
        
    } else {
        $results += Write-TestResult -TestName "DCE Exists" -Passed $false -Details "DCE not found"
    }
} catch {
    $results += Write-TestResult -TestName "DCE Exists" -Passed $false -Details $_.Exception.Message
}

#endregion

#region 4. Data Collection Rule Tests

Write-SectionHeader "4. DATA COLLECTION RULE (DCR)"

$dcrImmutableId = $null
try {
    $dcr = az monitor data-collection rule show --name $DcrName --resource-group $ResourceGroupName 2>$null | ConvertFrom-Json
    if ($dcr) {
        $results += Write-TestResult -TestName "DCR Exists" -Passed $true -Message "Immutable ID: $($dcr.immutableId)"
        $dcrImmutableId = $dcr.immutableId
        
        # Check DCE association
        if ($dcr.dataCollectionEndpointId) {
            $dceMatch = $dcr.dataCollectionEndpointId -like "*$DceName*"
            $results += Write-TestResult -TestName "DCR linked to DCE" -Passed $dceMatch -Message "Endpoint: $($dcr.dataCollectionEndpointId)"
        } else {
            $results += Write-TestResult -TestName "DCR linked to DCE" -Passed $false -Details "No DCE associated with DCR"
        }
        
        # Check stream declarations
        $streamExists = $dcr.streamDeclarations.PSObject.Properties.Name -contains $streamName
        $results += Write-TestResult -TestName "DCR Stream Declaration" -Passed $streamExists -Message "Stream: $streamName"
        
        if ($streamExists) {
            $columnCount = $dcr.streamDeclarations.$streamName.columns.Count
            $results += Write-TestResult -TestName "DCR Stream Columns" -Passed ($columnCount -gt 0) -Message "Column count: $columnCount"
        }
        
        # Check data flows
        if ($dcr.dataFlows -and $dcr.dataFlows.Count -gt 0) {
            $dataFlow = $dcr.dataFlows[0]
            $results += Write-TestResult -TestName "DCR Data Flow Configured" -Passed $true -Message "Output stream: $($dataFlow.outputStream)"
            
            # Check transform KQL
            $transformKql = $dataFlow.transformKql
            if ($transformKql -and $transformKql -ne "source") {
                $results += Write-TestResult -TestName "DCR Transform KQL" -Passed $true -Message "Custom transform configured"
            } else {
                $results += Write-TestResult -TestName "DCR Transform KQL" -Passed $true -Message "Using default 'source' transform"
            }
        } else {
            $results += Write-TestResult -TestName "DCR Data Flow Configured" -Passed $false -Details "No data flows configured"
        }
        
        # Check destinations
        if ($dcr.destinations.logAnalytics -and $dcr.destinations.logAnalytics.Count -gt 0) {
            $workspace = $dcr.destinations.logAnalytics[0]
            $workspaceMatch = $workspace.workspaceResourceId -like "*$WorkspaceName*"
            $results += Write-TestResult -TestName "DCR Destination Workspace" -Passed $workspaceMatch -Message "Workspace ID: $($workspace.workspaceId)"
        } else {
            $results += Write-TestResult -TestName "DCR Destination Workspace" -Passed $false -Details "No Log Analytics destination"
        }
        
    } else {
        $results += Write-TestResult -TestName "DCR Exists" -Passed $false -Details "DCR not found"
    }
} catch {
    $results += Write-TestResult -TestName "DCR Exists" -Passed $false -Details $_.Exception.Message
}

#endregion

#region 5. Log Analytics Workspace Tests

Write-SectionHeader "5. LOG ANALYTICS WORKSPACE"

$workspaceId = $null
try {
    $law = az monitor log-analytics workspace show --workspace-name $WorkspaceName --resource-group $ResourceGroupName 2>$null | ConvertFrom-Json
    if ($law) {
        $results += Write-TestResult -TestName "Workspace Exists" -Passed $true -Message "Workspace ID: $($law.customerId)"
        $workspaceId = $law.customerId
    } else {
        $results += Write-TestResult -TestName "Workspace Exists" -Passed $false -Details "Workspace not found"
    }
} catch {
    $results += Write-TestResult -TestName "Workspace Exists" -Passed $false -Details $_.Exception.Message
}

# Check custom table
try {
    $table = az monitor log-analytics workspace table show --workspace-name $WorkspaceName --resource-group $ResourceGroupName --name $fullTableName 2>$null | ConvertFrom-Json
    if ($table) {
        $results += Write-TestResult -TestName "Custom Table Exists" -Passed $true -Message "Table: $fullTableName"
        
        # Check table type
        $tableType = $table.schema.tableSubType
        $results += Write-TestResult -TestName "Table Type" -Passed ($tableType -eq "DataCollectionRuleBased") -Message "Type: $tableType"
        
        # Check column count
        $tableColumns = $table.schema.columns
        $results += Write-TestResult -TestName "Table Schema" -Passed ($tableColumns.Count -gt 2) -Message "Column count: $($tableColumns.Count)"
        
        # Expected columns
        $expectedColumns = @(
            "TimeGenerated", "StorageAccount", "FileShare", "FilePath", "FileName", 
            "FileExtension", "FileSizeBytes", "FileSizeMB", "FileSizeGB", "LastModified",
            "Created", "AgeInDays", "FileHash", "IsDuplicate", "DuplicateCount",
            "DuplicateGroupId", "FileCategory", "AgeBucket", "SizeBucket", 
            "ScanTimestamp", "ExecutionId"
        )
        
        $tableColumnNames = $tableColumns.name
        $missingColumns = $expectedColumns | Where-Object { $_ -notin $tableColumnNames }
        
        if ($missingColumns.Count -eq 0) {
            $results += Write-TestResult -TestName "Table Has All Required Columns" -Passed $true -Message "All 21 columns present"
        } else {
            $results += Write-TestResult -TestName "Table Has All Required Columns" -Passed $false -Details "Missing: $($missingColumns -join ', ')"
        }
        
    } else {
        $results += Write-TestResult -TestName "Custom Table Exists" -Passed $false -Details "Table $fullTableName not found"
    }
} catch {
    $results += Write-TestResult -TestName "Custom Table Exists" -Passed $false -Details $_.Exception.Message
}

#endregion

#region 6. Automation Account Tests

Write-SectionHeader "6. AUTOMATION ACCOUNT"

$aaPrincipalId = $null
try {
    $aa = az resource show --name $AutomationAccountName --resource-group $ResourceGroupName --resource-type "Microsoft.Automation/automationAccounts" 2>$null | ConvertFrom-Json
    if ($aa) {
        $results += Write-TestResult -TestName "Automation Account Exists" -Passed $true -Message "Name: $($aa.name)"
        
        # Check managed identity
        if ($aa.identity -and $aa.identity.principalId) {
            $aaPrincipalId = $aa.identity.principalId
            $results += Write-TestResult -TestName "Managed Identity Enabled" -Passed $true -Message "Principal ID: $aaPrincipalId"
        } else {
            $results += Write-TestResult -TestName "Managed Identity Enabled" -Passed $false -Details "System-assigned managed identity not enabled"
        }
    } else {
        $results += Write-TestResult -TestName "Automation Account Exists" -Passed $false -Details "Automation Account not found"
    }
} catch {
    $results += Write-TestResult -TestName "Automation Account Exists" -Passed $false -Details $_.Exception.Message
}

# Check automation variables
Write-Host ""
Write-Host "  Checking Automation Variables..." -ForegroundColor Gray

$requiredVariables = @(
    "FileInventory_LogAnalyticsDceEndpoint",
    "FileInventory_LogAnalyticsDcrImmutableId",
    "FileInventory_LogAnalyticsStreamName",
    "FileInventory_LogAnalyticsTableName"
)

foreach ($varName in $requiredVariables) {
    try {
        $varUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName/variables/${varName}?api-version=2023-11-01"
        $token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com").Token
        $var = Invoke-RestMethod -Uri $varUri -Headers @{"Authorization"="Bearer $token"} -Method Get -ErrorAction SilentlyContinue
        
        if ($var) {
            $isEncrypted = $var.properties.isEncrypted
            $hasValue = -not [string]::IsNullOrEmpty($var.properties.value)
            $status = if ($isEncrypted) { "Encrypted" } elseif ($hasValue) { "Set" } else { "Empty" }
            $results += Write-TestResult -TestName "Variable: $varName" -Passed ($isEncrypted -or $hasValue) -Message "Status: $status"
        } else {
            $results += Write-TestResult -TestName "Variable: $varName" -Passed $false -Details "Variable not found"
        }
    } catch {
        $results += Write-TestResult -TestName "Variable: $varName" -Passed $false -Details "Could not check variable"
    }
}

#endregion

#region 7. RBAC Permission Tests

Write-SectionHeader "7. RBAC PERMISSIONS"

if ($aaPrincipalId) {
    # Check Monitoring Metrics Publisher on DCR
    try {
        $dcrScope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/dataCollectionRules/$DcrName"
        $roleAssignments = az role assignment list --scope $dcrScope --assignee $aaPrincipalId 2>$null | ConvertFrom-Json
        
        $hasMetricsPublisher = $roleAssignments | Where-Object { $_.roleDefinitionName -eq "Monitoring Metrics Publisher" }
        $results += Write-TestResult -TestName "AA has Monitoring Metrics Publisher on DCR" -Passed ($null -ne $hasMetricsPublisher) `
            -Message $(if ($hasMetricsPublisher) { "Role assigned" } else { "Role missing" }) `
            -Details $(if (-not $hasMetricsPublisher) { "Assign 'Monitoring Metrics Publisher' role to the Automation Account's managed identity on the DCR" })
    } catch {
        $results += Write-TestResult -TestName "AA has Monitoring Metrics Publisher on DCR" -Passed $false -Details $_.Exception.Message
    }
    
    # Check Storage permissions (generic check)
    Write-Host ""
    Write-Host "  Note: Storage account permissions must be verified separately for each target storage account." -ForegroundColor Yellow
    Write-Host "        Required role: 'Storage Account Key Operator Service Role' or 'Storage File Data SMB Share Reader'" -ForegroundColor Yellow
}

# Check current user permissions
try {
    $currentUser = az ad signed-in-user show --query id -o tsv 2>$null
    if ($currentUser) {
        $dcrScope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/dataCollectionRules/$DcrName"
        $userRoles = az role assignment list --scope $dcrScope --assignee $currentUser 2>$null | ConvertFrom-Json
        
        $userHasMetricsPublisher = $userRoles | Where-Object { $_.roleDefinitionName -eq "Monitoring Metrics Publisher" }
        $results += Write-TestResult -TestName "Current User has Monitoring Metrics Publisher" -Passed ($null -ne $userHasMetricsPublisher) `
            -Message $(if ($userHasMetricsPublisher) { "Role assigned (needed for ingestion test)" } else { "Role missing (ingestion test may fail)" })
    }
} catch {
    Write-Host "  Could not check current user permissions" -ForegroundColor Yellow
}

#endregion

#region 8. DCR-Table Schema Comparison

Write-SectionHeader "8. DCR-TABLE SCHEMA COMPARISON"

if ($dcr -and $table) {
    try {
        $dcrColumns = $dcr.streamDeclarations.$streamName.columns | Sort-Object name
        $tableColumns = $table.schema.columns | Where-Object { $_.name -notin @("TenantId", "_ResourceId") } | Sort-Object name
        
        $schemaMatches = $true
        $mismatches = @()
        
        foreach ($dcrCol in $dcrColumns) {
            $tableCol = $tableColumns | Where-Object { $_.name -eq $dcrCol.name }
            if (-not $tableCol) {
                $schemaMatches = $false
                $mismatches += "Column '$($dcrCol.name)' in DCR but not in table"
            } elseif ($tableCol.type -ne $dcrCol.type) {
                $schemaMatches = $false
                $mismatches += "Column '$($dcrCol.name)' type mismatch: DCR=$($dcrCol.type), Table=$($tableCol.type)"
            }
        }
        
        if ($schemaMatches) {
            $results += Write-TestResult -TestName "DCR-Table Schema Match" -Passed $true -Message "All columns match"
        } else {
            $results += Write-TestResult -TestName "DCR-Table Schema Match" -Passed $false -Details ($mismatches -join "; ")
        }
    } catch {
        $results += Write-TestResult -TestName "DCR-Table Schema Match" -Passed $false -Details $_.Exception.Message
    }
}

#endregion

#region 9. End-to-End Ingestion Test

if ($RunIngestionTest -and $dceEndpoint -and $dcrImmutableId) {
    Write-SectionHeader "9. END-TO-END INGESTION TEST"
    
    try {
        # Get token
        $token = (Get-AzAccessToken -ResourceUrl "https://monitor.azure.com").Token
        
        $testExecutionId = "test-$(Get-Date -Format 'yyyyMMddHHmmss')"
        
        # Create test payload
        $testData = @(
            @{
                TimeGenerated    = (Get-Date).ToUniversalTime().ToString("o")
                StorageAccount   = "SetupValidationTest"
                FileShare        = "ValidationShare"
                FilePath         = "/validation/test.txt"
                FileName         = "test.txt"
                FileExtension    = ".txt"
                FileSizeBytes    = 12345
                FileSizeMB       = 0.012
                FileSizeGB       = 0.000012
                LastModified     = (Get-Date).AddDays(-1).ToUniversalTime().ToString("o")
                Created          = (Get-Date).AddDays(-5).ToUniversalTime().ToString("o")
                AgeInDays        = 1
                FileHash         = "VALIDATION-HASH"
                IsDuplicate      = "No"
                DuplicateCount   = 0
                DuplicateGroupId = ""
                FileCategory     = "Documents"
                AgeBucket        = "0-7 days"
                SizeBucket       = "1 KB - 1 MB"
                ScanTimestamp    = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                ExecutionId      = $testExecutionId
            }
        )
        
        $body = $testData | ConvertTo-Json -Depth 10 -AsArray
        $uri = "$dceEndpoint/dataCollectionRules/$dcrImmutableId/streams/$streamName`?api-version=2023-01-01"
        
        Write-Host "  Sending test record..." -ForegroundColor Gray
        Write-Host "  ExecutionId: $testExecutionId" -ForegroundColor Gray
        
        try {
            Invoke-RestMethod -Uri $uri -Method Post -Headers @{
                "Authorization" = "Bearer $token"
                "Content-Type"  = "application/json"
            } -Body $body -ErrorAction Stop
            
            $results += Write-TestResult -TestName "Data Ingestion API Call" -Passed $true -Message "Record sent successfully"
            
            # Wait and verify
            Write-Host "  Waiting 2 minutes for data to appear in Log Analytics..." -ForegroundColor Yellow
            Start-Sleep -Seconds 120
            
            # Query for the test record
            $queryToken = (Get-AzAccessToken -ResourceUrl "https://api.loganalytics.io").Token
            $query = "$fullTableName | where ExecutionId == '$testExecutionId' | project TimeGenerated, StorageAccount, FileShare, ExecutionId"
            $queryBody = @{ query = $query } | ConvertTo-Json
            $queryUri = "https://api.loganalytics.io/v1/workspaces/$workspaceId/query"
            
            $queryResult = Invoke-RestMethod -Uri $queryUri -Method Post -Headers @{
                "Authorization" = "Bearer $queryToken"
                "Content-Type"  = "application/json"
            } -Body $queryBody
            
            if ($queryResult.tables[0].rows.Count -gt 0) {
                $row = $queryResult.tables[0].rows[0]
                $storageAccountValue = $row[1]
                
                if ($storageAccountValue -eq "SetupValidationTest") {
                    $results += Write-TestResult -TestName "Data Ingestion Verified" -Passed $true -Message "Record found with correct data!"
                } else {
                    $results += Write-TestResult -TestName "Data Ingestion Verified" -Passed $false -Details "Record found but columns are empty. Check DCR transform."
                }
            } else {
                $results += Write-TestResult -TestName "Data Ingestion Verified" -Passed $false -Details "Record not found. May need more time or check DCR configuration."
            }
            
        } catch {
            $errorMessage = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($errorMessage) {
                $results += Write-TestResult -TestName "Data Ingestion API Call" -Passed $false -Details $errorMessage.error.message
            } else {
                $results += Write-TestResult -TestName "Data Ingestion API Call" -Passed $false -Details $_.Exception.Message
            }
        }
        
    } catch {
        $results += Write-TestResult -TestName "Ingestion Test Setup" -Passed $false -Details $_.Exception.Message
    }
}

#endregion

#region Summary

Write-Host ""
Write-Host "═" * 70 -ForegroundColor Cyan
Write-Host "  SUMMARY" -ForegroundColor Cyan
Write-Host "═" * 70 -ForegroundColor Cyan

$passed = ($results | Where-Object { $_.Passed }).Count
$failed = ($results | Where-Object { -not $_.Passed }).Count
$total = $results.Count

Write-Host ""
Write-Host "  Total Tests: $total" -ForegroundColor White
Write-Host "  Passed:      $passed" -ForegroundColor Green
Write-Host "  Failed:      $failed" -ForegroundColor $(if ($failed -gt 0) { "Red" } else { "Green" })
Write-Host ""

if ($failed -gt 0) {
    Write-Host "  Failed Tests:" -ForegroundColor Red
    $results | Where-Object { -not $_.Passed } | ForEach-Object {
        Write-Host "    - $($_.TestName)" -ForegroundColor Red
        if ($_.Details) {
            Write-Host "      $($_.Details)" -ForegroundColor Yellow
        }
    }
}

Write-Host ""
Write-Host "═" * 70 -ForegroundColor Cyan

# Output key values for reference
Write-Host ""
Write-Host "  KEY VALUES FOR AUTOMATION ACCOUNT VARIABLES:" -ForegroundColor Yellow
Write-Host ""
if ($dceEndpoint) {
    Write-Host "  FileInventory_LogAnalyticsDceEndpoint:" -ForegroundColor White
    Write-Host "    $dceEndpoint" -ForegroundColor Cyan
}
if ($dcrImmutableId) {
    Write-Host ""
    Write-Host "  FileInventory_LogAnalyticsDcrImmutableId:" -ForegroundColor White
    Write-Host "    $dcrImmutableId" -ForegroundColor Cyan
}
Write-Host ""
Write-Host "  FileInventory_LogAnalyticsStreamName:" -ForegroundColor White
Write-Host "    $streamName" -ForegroundColor Cyan
Write-Host ""
Write-Host "  FileInventory_LogAnalyticsTableName:" -ForegroundColor White
Write-Host "    $fullTableName" -ForegroundColor Cyan
Write-Host ""

#endregion

# Return results for programmatic use
return $results

#endregion
