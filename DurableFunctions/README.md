# Azure Durable Functions - File Inventory Scanner

This is an Azure Durable Functions implementation of the File Inventory Scanner, designed to handle large file shares (2TB+) without timeout limitations.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           HTTP Trigger (start-scan)                             │
└─────────────────────────────────────┬───────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                        Main Orchestrator (orchestrator_main)                    │
│  • Lists all file shares                                                        │
│  • Fans out to sub-orchestrators                                                │
│  • Aggregates final results                                                     │
└─────────────────────────────────────┬───────────────────────────────────────────┘
                                      │ Fan-out (parallel)
                    ┌─────────────────┼─────────────────┐
                    ▼                 ▼                 ▼
┌───────────────────────┐ ┌───────────────────────┐ ┌───────────────────────┐
│  File Share Orchestrator │ │  File Share Orchestrator │ │  File Share Orchestrator │
│  (orchestrator_file_share) │ (orchestrator_file_share) │ (orchestrator_file_share) │
│  • BFS directory traversal │ │  • BFS directory traversal │ │  • BFS directory traversal │
│  • Batches to Log Analytics│ │  • Batches to Log Analytics│ │  • Batches to Log Analytics│
└─────────────┬─────────────┘ └─────────────┬─────────────┘ └─────────────┬─────────────┘
              │                             │                             │
              ▼ Fan-out (parallel)          ▼                             ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                        Activity Functions (per directory)                       │
│  ┌────────────────────┐  ┌────────────────────┐  ┌────────────────────┐        │
│  │ activity_scan_dir  │  │ activity_scan_dir  │  │ activity_scan_dir  │  ...   │
│  │ (Folder A)         │  │ (Folder B)         │  │ (Folder C)         │        │
│  └────────────────────┘  └────────────────────┘  └────────────────────┘        │
└─────────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    Activity: Send to Log Analytics                              │
│                    (activity_send_to_log_analytics)                             │
└─────────────────────────────────────────────────────────────────────────────────┘
```

## Why Durable Functions?

| Challenge | Solution |
|-----------|----------|
| **3-hour timeout** | Durable Functions have no timeout - can run for days |
| **Memory limits** | Each activity function processes one directory, then releases memory |
| **Scalability** | Parallel processing of directories across multiple instances |
| **Resilience** | Built-in checkpointing - resumes from last checkpoint on failure |
| **Monitoring** | Status endpoints for real-time progress tracking |

## Project Structure

```
DurableFunctions/
├── function_app.py                    # HTTP triggers (start, status, cancel)
├── host.json                          # Function app configuration
├── requirements.txt                   # Python dependencies
├── local.settings.template.json       # Environment variables template
├── shared/                            # Shared utilities
│   ├── __init__.py
│   └── models.py
├── orchestrator_main/                 # Main orchestrator
│   ├── __init__.py
│   └── function.json
├── orchestrator_file_share/           # Sub-orchestrator per share
│   ├── __init__.py
│   └── function.json
├── activity_list_file_shares/         # List shares activity
│   ├── __init__.py
│   └── function.json
├── activity_scan_directory/           # Scan directory activity
│   ├── __init__.py
│   └── function.json
└── activity_send_to_log_analytics/    # Send to LA activity
    ├── __init__.py
    └── function.json
```

## Prerequisites

1. **Azure CLI** installed and logged in
2. **Azure Functions Core Tools** v4.x
3. **Python 3.9+**
4. **Azure Storage Account** with File Shares
5. **Log Analytics Workspace** with DCE/DCR configured

## Quick Start

### 1. Clone and Configure

```bash
cd DurableFunctions

# Copy template and edit with your values
cp local.settings.template.json local.settings.json
```

Edit `local.settings.json` with your values:
```json
{
  "Values": {
    "AzureWebJobsStorage": "<your-storage-connection-string>",
    "STORAGE_ACCOUNT_NAME": "<storage-account-to-scan>",
    "STORAGE_ACCOUNT_KEY": "<storage-account-key>",
    "LOG_ANALYTICS_DCE_ENDPOINT": "https://dce-xxx.region.ingest.monitor.azure.com",
    "LOG_ANALYTICS_DCR_IMMUTABLE_ID": "dcr-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    "LOG_ANALYTICS_STREAM_NAME": "Custom-FileInventory_CL"
  }
}
```

### 2. Install Dependencies

```bash
python -m venv .venv
.venv\Scripts\activate  # Windows
# source .venv/bin/activate  # Linux/Mac

pip install -r requirements.txt
```

### 3. Run Locally

```bash
func start
```

### 4. Start a Scan

```bash
curl -X POST http://localhost:7071/api/start-scan \
  -H "Content-Type: application/json" \
  -d '{
    "storageAccountName": "mystorageaccount",
    "fileShareNames": ["share1"],
    "skipHashComputation": true
  }'
```

Response:
```json
{
  "id": "abc123...",
  "statusQueryGetUri": "http://localhost:7071/runtime/webhooks/durabletask/instances/abc123...",
  "executionId": "guid",
  "storageAccount": "mystorageaccount"
}
```

### 5. Check Status

```bash
curl http://localhost:7071/api/scan-status/abc123...
```

## Deploy to Azure

### Using the Deployment Script

```powershell
.\Deploy-DurableFunctions.ps1 `
    -ResourceGroupName "rg-file-inventory" `
    -Location "eastus" `
    -FunctionAppName "func-file-inventory" `
    -StorageAccountName "stfuncstorage"
```

### Manual Deployment

```bash
# Create Function App
az functionapp create \
    --name func-file-inventory \
    --resource-group rg-file-inventory \
    --storage-account stfuncstorage \
    --runtime python \
    --runtime-version 3.10 \
    --functions-version 4 \
    --os-type Linux \
    --consumption-plan-location eastus

# Deploy code
func azure functionapp publish func-file-inventory

# Configure app settings
az functionapp config appsettings set \
    --name func-file-inventory \
    --resource-group rg-file-inventory \
    --settings \
        "STORAGE_ACCOUNT_NAME=<value>" \
        "STORAGE_ACCOUNT_KEY=<value>" \
        "LOG_ANALYTICS_DCE_ENDPOINT=<value>" \
        "LOG_ANALYTICS_DCR_IMMUTABLE_ID=<value>" \
        "LOG_ANALYTICS_STREAM_NAME=Custom-FileInventory_CL"
```

## API Endpoints

### Start Scan
```
POST /api/start-scan
```

**Request Body:**
```json
{
  "storageAccountName": "string (required if not in env)",
  "storageAccountKey": "string (optional, uses env var)",
  "fileShareNames": ["share1", "share2"],  // optional, empty = all
  "skipHashComputation": true,
  "batchSize": 500,
  "maxFileSizeForHashMB": 100,
  "excludePatterns": ["*.tmp", "~$*"]
}
```

### Check Status
```
GET /api/scan-status/{instanceId}
```

### Cancel Scan
```
POST /api/cancel-scan/{instanceId}
```

## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `STORAGE_ACCOUNT_NAME` | Storage account to scan | (required) |
| `STORAGE_ACCOUNT_KEY` | Storage account key | (required) |
| `LOG_ANALYTICS_DCE_ENDPOINT` | Data Collection Endpoint | (required) |
| `LOG_ANALYTICS_DCR_IMMUTABLE_ID` | DCR Immutable ID | (required) |
| `LOG_ANALYTICS_STREAM_NAME` | Stream name | `Custom-FileInventory_CL` |
| `BATCH_SIZE` | Records per batch | `500` |
| `MAX_FILE_SIZE_FOR_HASH_MB` | Max file size for hashing | `100` |
| `SKIP_HASH_COMPUTATION` | Skip MD5 hashing | `true` |
| `EXCLUDE_PATTERNS` | Files to exclude | `*.tmp,~$*,.DS_Store,Thumbs.db` |

### Performance Tuning

In `host.json`:
```json
{
  "extensions": {
    "durableTask": {
      "maxConcurrentActivityFunctions": 10,  // Increase for more parallelism
      "maxConcurrentOrchestratorFunctions": 5
    }
  }
}
```

## Monitoring

### Azure Portal
- Navigate to your Function App → Functions → Monitor
- Check Application Insights for detailed logs

### Durable Functions Monitor
- Use the status endpoint to track progress
- Custom status includes: phase, files processed, directories scanned

### Log Analytics Query
```kusto
FileInventory_CL
| where ExecutionId == "your-execution-id"
| summarize 
    TotalFiles = count(),
    TotalSizeGB = sum(FileSizeGB)
    by FileShare
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| **Orchestration stuck** | Check Activity function logs for errors |
| **Out of memory** | Reduce `maxConcurrentActivityFunctions` |
| **Slow performance** | Increase `maxConcurrentActivityFunctions` |
| **Auth errors** | Ensure Managed Identity has correct permissions |

## Comparison: Automation vs Durable Functions

| Aspect | Automation Runbook | Durable Functions |
|--------|-------------------|-------------------|
| **Max Runtime** | 3 hours (sandbox) | Unlimited |
| **Parallelism** | Limited | High (10+ concurrent) |
| **Checkpointing** | Manual | Automatic |
| **Cost** | Per minute | Per execution |
| **Complexity** | Low | Medium |
| **Scaling** | Single job | Auto-scale |

## License

MIT License - See LICENSE file in the root directory.
