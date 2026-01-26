"""
Main Orchestrator Function for the File Inventory Scanner.

This orchestrator coordinates the entire scanning process using the fan-out/fan-in pattern:
1. Lists all file shares (or uses provided list)
2. Fans out to sub-orchestrators for each file share
3. Each sub-orchestrator fans out to scan directories in parallel
4. Aggregates results from all shares
"""

import azure.durable_functions as df
import logging
from datetime import datetime


def orchestrator_main(context: df.DurableOrchestrationContext):
    """
    Main orchestrator that coordinates the file share scanning.
    
    Input:
    {
        "execution_id": "guid",
        "storage_account_name": "account",
        "storage_account_key": "key",
        "file_share_names": [],  // empty = scan all
        "skip_hash_computation": true,
        "batch_size": 500,
        "max_file_size_for_hash_mb": 100,
        "exclude_patterns": ["*.tmp", ...]
    }
    """
    input_data = context.get_input()
    execution_id = input_data.get("execution_id", "")
    storage_account = input_data.get("storage_account_name", "")
    
    if not context.is_replaying:
        logging.info(f"[{execution_id}] Main orchestrator started for storage account: {storage_account}")
    
    # Update custom status
    context.set_custom_status({
        "phase": "Initializing",
        "storageAccount": storage_account,
        "startTime": datetime.utcnow().isoformat()
    })
    
    # Step 1: Get list of file shares to scan
    file_share_names = input_data.get("file_share_names", [])
    
    if not file_share_names:
        # Discover all file shares
        context.set_custom_status({"phase": "Discovering file shares"})
        
        file_share_names = yield context.call_activity(
            "activity_list_file_shares",
            {
                "storage_account_name": input_data["storage_account_name"],
                "storage_account_key": input_data["storage_account_key"]
            }
        )
        
        if not context.is_replaying:
            logging.info(f"[{execution_id}] Discovered {len(file_share_names)} file shares")
    
    if not file_share_names:
        return {
            "status": "completed",
            "message": "No file shares found to scan",
            "execution_id": execution_id,
            "total_shares": 0
        }
    
    # Step 2: Fan out - Start sub-orchestrator for each file share
    context.set_custom_status({
        "phase": "Scanning file shares",
        "totalShares": len(file_share_names),
        "shares": file_share_names
    })
    
    # Create tasks for parallel execution of file share scans
    share_tasks = []
    for share_name in file_share_names:
        share_input = {
            "execution_id": execution_id,
            "storage_account_name": input_data["storage_account_name"],
            "storage_account_key": input_data["storage_account_key"],
            "file_share_name": share_name,
            "skip_hash_computation": input_data.get("skip_hash_computation", True),
            "batch_size": input_data.get("batch_size", 500),
            "max_file_size_for_hash_mb": input_data.get("max_file_size_for_hash_mb", 100),
            "exclude_patterns": input_data.get("exclude_patterns", [])
        }
        
        task = context.call_sub_orchestrator("orchestrator_file_share", share_input)
        share_tasks.append(task)
    
    # Fan in - Wait for all file shares to complete
    share_results = yield context.task_all(share_tasks)
    
    # Step 3: Aggregate results
    context.set_custom_status({"phase": "Aggregating results"})
    
    total_files = sum(r.get("files_processed", 0) for r in share_results if r)
    total_bytes = sum(r.get("bytes_processed", 0) for r in share_results if r)
    total_batches = sum(r.get("batches_sent", 0) for r in share_results if r)
    total_errors = sum(len(r.get("errors", [])) for r in share_results if r)
    
    result = {
        "status": "completed",
        "execution_id": execution_id,
        "storage_account": storage_account,
        "total_shares_scanned": len(file_share_names),
        "total_files_processed": total_files,
        "total_bytes_processed": total_bytes,
        "total_gb_processed": round(total_bytes / (1024**3), 2),
        "total_batches_sent": total_batches,
        "total_errors": total_errors,
        "share_results": share_results,
        "completed_at": datetime.utcnow().isoformat()
    }
    
    if not context.is_replaying:
        logging.info(f"[{execution_id}] Scan completed: {total_files} files, {result['total_gb_processed']} GB")
    
    context.set_custom_status({"phase": "Completed", **result})
    
    return result


main = df.Orchestrator.create(orchestrator_main)
