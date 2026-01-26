"""
Activity Function: Send to Log Analytics

Sends a batch of file records to Azure Log Analytics via the Data Collection API.
"""

import logging
import os
import json
import gzip
from datetime import datetime, timezone
from typing import List, Dict, Any

from azure.identity import DefaultAzureCredential
from azure.monitor.ingestion import LogsIngestionClient
from azure.core.exceptions import HttpResponseError


def main(input_data: dict) -> dict:
    """
    Sends a batch of file records to Log Analytics.
    
    Input:
    {
        "records": [
            { "StorageAccount": "...", "FilePath": "...", ... },
            ...
        ]
    }
    
    Returns:
    {
        "success": true/false,
        "records_sent": 123,
        "message": "..."
    }
    """
    records = input_data.get("records", [])
    
    if not records:
        return {
            "success": True,
            "records_sent": 0,
            "message": "No records to send"
        }
    
    # Get configuration from environment
    dce_endpoint = os.environ.get("LOG_ANALYTICS_DCE_ENDPOINT", "")
    dcr_immutable_id = os.environ.get("LOG_ANALYTICS_DCR_IMMUTABLE_ID", "")
    stream_name = os.environ.get("LOG_ANALYTICS_STREAM_NAME", "Custom-FileInventory_CL")
    
    if not dce_endpoint or not dcr_immutable_id:
        error_msg = "LOG_ANALYTICS_DCE_ENDPOINT and LOG_ANALYTICS_DCR_IMMUTABLE_ID environment variables are required"
        logging.error(error_msg)
        return {
            "success": False,
            "records_sent": 0,
            "message": error_msg
        }
    
    logging.info(f"Sending {len(records)} records to Log Analytics")
    
    try:
        # Use DefaultAzureCredential (works with Managed Identity in Azure, or local dev credentials)
        credential = DefaultAzureCredential()
        
        # Create the ingestion client
        client = LogsIngestionClient(endpoint=dce_endpoint, credential=credential)
        
        # Ensure TimeGenerated is set for all records
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
        for record in records:
            if not record.get("TimeGenerated"):
                record["TimeGenerated"] = now
        
        # Send the data
        client.upload(
            rule_id=dcr_immutable_id,
            stream_name=stream_name,
            logs=records
        )
        
        logging.info(f"Successfully sent {len(records)} records to Log Analytics")
        
        return {
            "success": True,
            "records_sent": len(records),
            "message": f"Successfully sent {len(records)} records"
        }
        
    except HttpResponseError as e:
        error_msg = f"HTTP error sending to Log Analytics: {e.status_code} - {e.message}"
        logging.error(error_msg)
        return {
            "success": False,
            "records_sent": 0,
            "message": error_msg
        }
    except Exception as e:
        error_msg = f"Error sending to Log Analytics: {str(e)}"
        logging.error(error_msg)
        return {
            "success": False,
            "records_sent": 0,
            "message": error_msg
        }
