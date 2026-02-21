# Analyze-CostSavingsOpportunities - Implementation Guide

## Overview

The `Analyze-CostSavingsOpportunities.ps1` script queries the **FileInventory_CL** custom table in Azure Log Analytics Workspace (LAW) and produces a comprehensive cost savings analysis report. It identifies three categories of optimization opportunities:

1. **Archive or Delete Cold Files** — Files not modified in 5+ years
2. **Remove Redundant and Duplicate Files** — Identical files detected via MD5 hash or name+size
3. **Compress Large PDF Files** — Oversized PDFs that can be reduced via compression

## Prerequisites

| Requirement | Details |
|---|---|
| **PowerShell** | 7.x recommended (5.1 compatible) |
| **Az Modules** | `Az.Accounts`, `Az.OperationalInsights` |
| **Data Source** | FileInventory_CL table populated by AzureFileInventoryScanner runbook |
| **Permissions** | Reader access to the Log Analytics Workspace |
| **Azure Login** | `Connect-AzAccount` before running |

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `WorkspaceId` | Yes | — | Log Analytics Workspace ID containing FileInventory_CL |
| `StorageAccountFilter` | No | — | Filter to a specific storage account |
| `FileShareFilter` | No | — | Filter to a specific file share |
| `ColdFileAgeDays` | No | `1825` (5 years) | Age threshold for cold file detection |
| `PdfSizeThresholdMB` | No | `50` | Minimum PDF size in MB to flag for compression |
| `PdfCompressionRatio` | No | `0.40` | Expected final size ratio after compression (0.40 = 60% reduction) |
| `LookbackHours` | No | `48` | How far back to query for the latest scan data |
| `StorageCostPerGiBMonth` | No | `0.0255` | Storage cost per GiB/month for savings calculation |
| `OutputPath` | No | Script directory | Directory for CSV report output |
| `TimeoutSeconds` | No | `600` | KQL query timeout |

## Usage Examples

### Basic Analysis (all storage accounts)
```powershell
.\Analyze-CostSavingsOpportunities.ps1 -WorkspaceId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

### Single Storage Account
```powershell
.\Analyze-CostSavingsOpportunities.ps1 `
    -WorkspaceId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -StorageAccountFilter "mystorageaccount"
```

### Custom Thresholds
```powershell
.\Analyze-CostSavingsOpportunities.ps1 `
    -WorkspaceId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -ColdFileAgeDays 730 `
    -PdfSizeThresholdMB 100 `
    -PdfCompressionRatio 0.50
```

### With Custom Storage Cost (e.g., Cool LRS)
```powershell
.\Analyze-CostSavingsOpportunities.ps1 `
    -WorkspaceId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -StorageCostPerGiBMonth 0.015
```

## Analysis Phases

### Phase 0: Data Validation
- Queries FileInventory_CL to verify data exists within the lookback window
- Reports total files, storage, hash availability, and average file age
- Exits with error if no data is available

### Phase 1: Cold Files Analysis
Identifies files not modified in `ColdFileAgeDays`+ days. These are candidates for:
- **Archival** to a cheaper storage tier (Cool or Archive)
- **Deletion** if no longer needed

**KQL Logic:**
```kql
FileInventory_CL
| where AgeInDays >= 1825  // 5 years
```

**Breakdowns provided:**
- By Storage Account + File Share
- By File Category (Documents, Images, etc.)
- By Age Bracket (5-7y, 7-10y, 10+y)
- Top 500 largest cold files (exported to CSV)

### Phase 2: Duplicate Files Analysis
Two detection methods are used:

**Method 1: MD5 Hash Match (high confidence)**
- Uses the `FileHash` column (computed by the inventory scanner)
- Filters out `SKIPPED`, `SKIPPED_TOO_LARGE`, `ERROR`, `SKIPPED_PERFORMANCE` values
- Groups by `FileHash + FileName + FileSizeBytes`
- Calculates wasted storage from redundant copies

**Method 2: Name + Size Match (when hash unavailable)**
- For files where hash was skipped (e.g., too large, performance mode)
- Groups by `FileName + FileSizeBytes`
- Lower confidence — may include false positives

**Breakdowns provided:**
- Top 200 duplicate groups by wasted space
- Duplicates by Storage Account + File Share
- Combined wasted storage and savings estimate

### Phase 3: PDF Compression Analysis
Identifies PDF files above the size threshold that may benefit from compression.

**Assumptions:**
- Default threshold: 50 MB (configurable via `-PdfSizeThresholdMB`)
- Default expected compression: 60% size reduction (configurable via `-PdfCompressionRatio`)
- Large PDFs often contain uncompressed images and can be significantly reduced

**Breakdowns provided:**
- PDF size distribution (50-100 MB, 100-200 MB, etc.)
- By Storage Account + File Share
- Top 500 largest PDFs with estimated compressed size
- Overall PDF statistics for context

### Phase 4: Summary & Export
- Displays combined savings summary across all three categories
- Exports four CSV reports

## Output Files

The script generates four CSV files with a timestamp suffix:

| File | Content |
|---|---|
| `CostSavings_ColdFiles_{timestamp}.csv` | Top 500 largest cold files with path, size, age, and estimated cost |
| `CostSavings_Duplicates_{timestamp}.csv` | Duplicate groups with detection method, locations, and wasted storage |
| `CostSavings_LargePDFs_{timestamp}.csv` | Large PDFs with estimated compressed size and savings |
| `CostSavings_Summary_{timestamp}.csv` | Executive summary with totals per category |

## Cost Estimation

Storage cost savings are estimated using the `StorageCostPerGiBMonth` parameter.

**Default: $0.0255/GiB/month** (Azure Files Transaction Optimized LRS, East US)

Common Azure Files storage rates (pay-as-you-go, LRS, East US):

| Tier | $/GiB/month |
|---|---|
| Transaction Optimized | $0.0255 |
| Hot | $0.0255 |
| Cool | $0.015 |

> **Note:** Actual savings depend on your tier, redundancy (LRS/ZRS/GRS), and region. Use the `-StorageCostPerGiBMonth` parameter to match your environment.

## FileInventory_CL Schema Reference

Key columns used by this analysis:

| Column | Type | Used For |
|---|---|---|
| `StorageAccount` | string | Grouping and filtering |
| `FileShare` | string | Grouping and filtering |
| `FilePath` | string | File location |
| `FileName` | string | Duplicate detection |
| `FileExtension` | string | PDF identification |
| `FileCategory` | string | Category breakdown |
| `FileSizeBytes` | long | Duplicate detection |
| `FileSizeMB` | real | PDF threshold comparison |
| `FileSizeGB` | real | Storage calculations |
| `LastModified` | datetime | Age reference |
| `AgeInDays` | int | Cold file detection |
| `FileHash` | string | MD5-based duplicate detection |
| `AgeBucket` | string | Pre-categorized age ranges |

## Troubleshooting

| Issue | Resolution |
|---|---|
| "No FileInventory_CL data found" | Ensure the inventory scanner runbook has run recently. Increase `-LookbackHours`. |
| Low hash coverage | The scanner may have skipped hashing for large files or performance mode. Name+size matching is used as fallback. |
| Query timeout | Increase `-TimeoutSeconds`. Large workspaces (27M+ files) may need 600-900s. |
| Inaccurate cost estimates | Adjust `-StorageCostPerGiBMonth` to match your actual Azure region and tier. |
| PDF compression overestimated | Already-compressed PDFs won't shrink further. Adjust `-PdfCompressionRatio` (e.g., 0.70 for 30% reduction). |
