"""
Activity Function: List File Shares

Lists all file shares in a storage account.
"""

import logging
from azure.storage.fileshare import ShareServiceClient


def main(input_data: dict) -> list:
    """
    Lists all file shares in a storage account.
    
    Input:
    {
        "storage_account_name": "account",
        "storage_account_key": "key"
    }
    
    Returns: List of file share names
    """
    storage_account_name = input_data.get("storage_account_name", "")
    storage_account_key = input_data.get("storage_account_key", "")
    
    logging.info(f"Listing file shares for storage account: {storage_account_name}")
    
    try:
        # Create service client
        connection_string = f"DefaultEndpointsProtocol=https;AccountName={storage_account_name};AccountKey={storage_account_key};EndpointSuffix=core.windows.net"
        service_client = ShareServiceClient.from_connection_string(connection_string)
        
        # List all shares (excluding snapshots)
        shares = []
        for share in service_client.list_shares():
            if not share.get("snapshot"):
                shares.append(share["name"])
        
        logging.info(f"Found {len(shares)} file shares: {shares}")
        return shares
        
    except Exception as e:
        logging.error(f"Error listing file shares: {str(e)}")
        raise
