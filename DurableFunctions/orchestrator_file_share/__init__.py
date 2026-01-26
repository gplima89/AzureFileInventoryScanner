"""
File Share Sub-Orchestrator Function.

This sub-orchestrator handles scanning a single file share:
1. Lists top-level directories
2. Fans out to activity functions for parallel directory scanning
3. Recursively processes subdirectories
4. Sends batches to Log Analytics
"""

import azure.durable_functions as df
import logging
from datetime import datetime


def orchestrator_file_share(context: df.DurableOrchestrationContext):
    """
    Sub-orchestrator that scans a single file share.
    
    Uses a BFS (breadth-first) approach with fan-out for parallel processing:
    - Process directories in waves
    - Each wave processes multiple directories in parallel
    - Discovered subdirectories are queued for the next wave
    """
    input_data = context.get_input()
    execution_id = input_data.get("execution_id", "")
    share_name = input_data.get("file_share_name", "")
    storage_account = input_data.get("storage_account_name", "")
    
    if not context.is_replaying:
        logging.info(f"[{execution_id}] Starting scan of file share: {share_name}")
    
    context.set_custom_status({
        "phase": "Starting",
        "fileShare": share_name
    })
    
    # Initialize tracking
    total_files_processed = 0
    total_bytes_processed = 0
    total_batches_sent = 0
    all_errors = []
    current_batch = []
    batch_size = input_data.get("batch_size", 500)
    
    # Queue of directories to process (BFS)
    directories_to_process = [""]  # Start with root
    processed_directories = set()
    
    wave_number = 0
    max_parallel_dirs = 10  # Process up to 10 directories in parallel per wave
    
    while directories_to_process:
        wave_number += 1
        
        # Take a batch of directories to process in parallel
        current_wave_dirs = []
        while directories_to_process and len(current_wave_dirs) < max_parallel_dirs:
            dir_path = directories_to_process.pop(0)
            if dir_path not in processed_directories:
                current_wave_dirs.append(dir_path)
                processed_directories.add(dir_path)
        
        if not current_wave_dirs:
            continue
        
        context.set_custom_status({
            "phase": f"Wave {wave_number}",
            "fileShare": share_name,
            "directoriesInWave": len(current_wave_dirs),
            "directoriesQueued": len(directories_to_process),
            "filesProcessed": total_files_processed,
            "bytesProcessed": total_bytes_processed
        })
        
        if not context.is_replaying:
            logging.info(f"[{execution_id}][{share_name}] Wave {wave_number}: Processing {len(current_wave_dirs)} directories, {len(directories_to_process)} queued")
        
        # Fan out - scan directories in parallel
        scan_tasks = []
        for dir_path in current_wave_dirs:
            task_input = {
                "storage_account_name": storage_account,
                "storage_account_key": input_data["storage_account_key"],
                "file_share_name": share_name,
                "directory_path": dir_path,
                "execution_id": execution_id,
                "batch_size": batch_size,
                "max_file_size_for_hash_mb": input_data.get("max_file_size_for_hash_mb", 100),
                "skip_hash_computation": input_data.get("skip_hash_computation", True),
                "exclude_patterns": input_data.get("exclude_patterns", [])
            }
            task = context.call_activity("activity_scan_directory", task_input)
            scan_tasks.append(task)
        
        # Fan in - wait for all directory scans to complete
        scan_results = yield context.task_all(scan_tasks)
        
        # Process results
        for result in scan_results:
            if result:
                # Add discovered subdirectories to queue
                for subdir in result.get("subdirectories", []):
                    if subdir not in processed_directories:
                        directories_to_process.append(subdir)
                
                # Accumulate file records
                file_records = result.get("file_records", [])
                current_batch.extend(file_records)
                
                total_files_processed += result.get("files_processed", 0)
                total_bytes_processed += result.get("bytes_processed", 0)
                all_errors.extend(result.get("errors", []))
                
                # Send batch if threshold reached
                while len(current_batch) >= batch_size:
                    batch_to_send = current_batch[:batch_size]
                    current_batch = current_batch[batch_size:]
                    
                    send_result = yield context.call_activity(
                        "activity_send_to_log_analytics",
                        {"records": batch_to_send}
                    )
                    
                    if send_result and send_result.get("success"):
                        total_batches_sent += 1
                        if not context.is_replaying:
                            logging.info(f"[{execution_id}][{share_name}] Sent batch {total_batches_sent}: {send_result.get('records_sent', 0)} records")
    
    # Send remaining records
    if current_batch:
        send_result = yield context.call_activity(
            "activity_send_to_log_analytics",
            {"records": current_batch}
        )
        
        if send_result and send_result.get("success"):
            total_batches_sent += 1
            if not context.is_replaying:
                logging.info(f"[{execution_id}][{share_name}] Sent final batch {total_batches_sent}: {send_result.get('records_sent', 0)} records")
    
    result = {
        "file_share": share_name,
        "status": "completed",
        "files_processed": total_files_processed,
        "bytes_processed": total_bytes_processed,
        "gb_processed": round(total_bytes_processed / (1024**3), 2),
        "directories_processed": len(processed_directories),
        "batches_sent": total_batches_sent,
        "waves_completed": wave_number,
        "errors": all_errors[:100],  # Limit errors to avoid large outputs
        "error_count": len(all_errors),
        "completed_at": datetime.utcnow().isoformat()
    }
    
    if not context.is_replaying:
        logging.info(f"[{execution_id}][{share_name}] Completed: {total_files_processed} files, {result['gb_processed']} GB, {len(processed_directories)} directories")
    
    return result


main = df.Orchestrator.create(orchestrator_file_share)
