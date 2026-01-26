"""
HTTP Trigger to start the File Inventory Scanner orchestration.

This function serves as the entry point to kick off the scanning process.
"""

import azure.functions as func
import azure.durable_functions as df
import json
import logging
import uuid
from datetime import datetime

app = df.DFApp(http_auth_level=func.AuthLevel.FUNCTION)


@app.route(route="start-scan", methods=["POST"])
@app.durable_client_input(client_name="client")
async def http_start_scan(req: func.HttpRequest, client: df.DurableOrchestrationClient) -> func.HttpResponse:
    """
    HTTP trigger to start the file inventory scan orchestration.
    
    Request body (JSON):
    {
        "storageAccountName": "mystorageaccount",
        "storageAccountKey": "optional - uses env var if not provided",
        "subscriptionId": "optional",
        "resourceGroup": "optional",
        "fileShareNames": ["share1", "share2"],  // optional - scans all if empty
        "skipHashComputation": true,
        "batchSize": 500
    }
    """
    logging.info("HTTP trigger received request to start file inventory scan")
    
    try:
        # Parse request body
        req_body = req.get_json()
    except ValueError:
        req_body = {}
    
    # Generate execution ID
    execution_id = str(uuid.uuid4())
    
    # Build scan configuration
    import os
    scan_input = {
        "execution_id": execution_id,
        "storage_account_name": req_body.get("storageAccountName", os.environ.get("STORAGE_ACCOUNT_NAME", "")),
        "storage_account_key": req_body.get("storageAccountKey", os.environ.get("STORAGE_ACCOUNT_KEY", "")),
        "subscription_id": req_body.get("subscriptionId", ""),
        "resource_group": req_body.get("resourceGroup", ""),
        "file_share_names": req_body.get("fileShareNames", []),
        "skip_hash_computation": req_body.get("skipHashComputation", os.environ.get("SKIP_HASH_COMPUTATION", "true").lower() == "true"),
        "batch_size": req_body.get("batchSize", int(os.environ.get("BATCH_SIZE", "500"))),
        "max_file_size_for_hash_mb": req_body.get("maxFileSizeForHashMB", int(os.environ.get("MAX_FILE_SIZE_FOR_HASH_MB", "100"))),
        "exclude_patterns": req_body.get("excludePatterns", os.environ.get("EXCLUDE_PATTERNS", "*.tmp,~$*,.DS_Store,Thumbs.db").split(","))
    }
    
    # Validate required parameters
    if not scan_input["storage_account_name"]:
        return func.HttpResponse(
            json.dumps({"error": "storageAccountName is required"}),
            status_code=400,
            mimetype="application/json"
        )
    
    if not scan_input["storage_account_key"]:
        return func.HttpResponse(
            json.dumps({"error": "storageAccountKey is required (or set STORAGE_ACCOUNT_KEY env var)"}),
            status_code=400,
            mimetype="application/json"
        )
    
    # Start the orchestration
    instance_id = await client.start_new("orchestrator_main", client_input=scan_input)
    
    logging.info(f"Started orchestration with ID = '{instance_id}', execution_id = '{execution_id}'")
    
    # Return the status URLs
    response = client.create_check_status_response(req, instance_id)
    
    # Add custom info to response
    response_body = json.loads(response.get_body().decode())
    response_body["executionId"] = execution_id
    response_body["startTime"] = datetime.utcnow().isoformat() + "Z"
    response_body["storageAccount"] = scan_input["storage_account_name"]
    
    return func.HttpResponse(
        json.dumps(response_body, indent=2),
        status_code=202,
        mimetype="application/json"
    )


@app.route(route="scan-status/{instance_id}", methods=["GET"])
@app.durable_client_input(client_name="client")
async def http_scan_status(req: func.HttpRequest, client: df.DurableOrchestrationClient) -> func.HttpResponse:
    """
    HTTP trigger to check the status of a running scan.
    """
    instance_id = req.route_params.get("instance_id")
    
    if not instance_id:
        return func.HttpResponse(
            json.dumps({"error": "instance_id is required"}),
            status_code=400,
            mimetype="application/json"
        )
    
    status = await client.get_status(instance_id, show_history=False, show_history_output=False)
    
    if not status:
        return func.HttpResponse(
            json.dumps({"error": f"Instance {instance_id} not found"}),
            status_code=404,
            mimetype="application/json"
        )
    
    response = {
        "instanceId": status.instance_id,
        "runtimeStatus": status.runtime_status.name if status.runtime_status else "Unknown",
        "createdTime": status.created_time.isoformat() if status.created_time else None,
        "lastUpdatedTime": status.last_updated_time.isoformat() if status.last_updated_time else None,
        "output": status.output,
        "customStatus": status.custom_status
    }
    
    return func.HttpResponse(
        json.dumps(response, indent=2, default=str),
        mimetype="application/json"
    )


@app.route(route="cancel-scan/{instance_id}", methods=["POST"])
@app.durable_client_input(client_name="client")
async def http_cancel_scan(req: func.HttpRequest, client: df.DurableOrchestrationClient) -> func.HttpResponse:
    """
    HTTP trigger to cancel a running scan.
    """
    instance_id = req.route_params.get("instance_id")
    
    if not instance_id:
        return func.HttpResponse(
            json.dumps({"error": "instance_id is required"}),
            status_code=400,
            mimetype="application/json"
        )
    
    await client.terminate(instance_id, "Cancelled by user request")
    
    return func.HttpResponse(
        json.dumps({"message": f"Termination request sent for instance {instance_id}"}),
        mimetype="application/json"
    )
