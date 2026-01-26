"""
Activity Function: Scan Directory

Scans a single directory in a file share and returns file metadata.
This is the workhorse function that processes files and discovers subdirectories.
"""

import logging
import os
import hashlib
from datetime import datetime, timezone
from typing import List, Dict, Any
from azure.storage.fileshare import ShareDirectoryClient, ShareFileClient
import fnmatch


def get_file_category(extension: str) -> str:
    """Categorize file by extension."""
    ext = extension.lower()
    
    if ext in {'.doc', '.docx', '.pdf', '.txt', '.rtf', '.odt', '.xls', '.xlsx', '.ppt', '.pptx', '.csv'}:
        return "Documents"
    elif ext in {'.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tiff', '.svg', '.ico', '.webp', '.raw'}:
        return "Images"
    elif ext in {'.mp4', '.avi', '.mkv', '.mov', '.wmv', '.flv', '.webm', '.m4v'}:
        return "Videos"
    elif ext in {'.mp3', '.wav', '.flac', '.aac', '.ogg', '.wma', '.m4a'}:
        return "Audio"
    elif ext in {'.zip', '.rar', '.7z', '.tar', '.gz', '.bz2', '.xz'}:
        return "Archives"
    elif ext in {'.cs', '.js', '.ts', '.py', '.java', '.cpp', '.h', '.ps1', '.psm1', '.sh', '.json', '.xml', '.yaml', '.yml'}:
        return "Code"
    elif ext in {'.exe', '.dll', '.msi', '.bat', '.cmd', '.com'}:
        return "Executables"
    elif ext in {'.sql', '.mdf', '.ldf', '.bak', '.db', '.sqlite'}:
        return "Databases"
    elif ext in {'.log', '.evt', '.evtx'}:
        return "Logs"
    elif ext in {'.tmp', '.temp', '.bak', '.swp', '.cache'}:
        return "Temporary"
    else:
        return "Other"


def get_age_bucket(age_in_days: int) -> str:
    """Get age bucket for a file."""
    if age_in_days <= 7:
        return "0-7 days"
    elif age_in_days <= 30:
        return "8-30 days"
    elif age_in_days <= 90:
        return "31-90 days"
    elif age_in_days <= 180:
        return "91-180 days"
    elif age_in_days <= 365:
        return "181-365 days"
    elif age_in_days <= 730:
        return "1-2 years"
    elif age_in_days <= 1825:
        return "2-5 years"
    else:
        return "5+ years"


def get_size_bucket(size_bytes: int) -> str:
    """Get size bucket for a file."""
    KB, MB, GB = 1024, 1024**2, 1024**3
    
    if size_bytes < KB:
        return "< 1 KB"
    elif size_bytes < MB:
        return "1 KB - 1 MB"
    elif size_bytes < 10 * MB:
        return "1 MB - 10 MB"
    elif size_bytes < 100 * MB:
        return "10 MB - 100 MB"
    elif size_bytes < 500 * MB:
        return "100 MB - 500 MB"
    elif size_bytes < GB:
        return "500 MB - 1 GB"
    elif size_bytes < 5 * GB:
        return "1 GB - 5 GB"
    elif size_bytes < 10 * GB:
        return "5 GB - 10 GB"
    else:
        return "10+ GB"


def is_file_excluded(filename: str, exclude_patterns: List[str]) -> bool:
    """Check if a file should be excluded based on patterns."""
    for pattern in exclude_patterns:
        if fnmatch.fnmatch(filename, pattern):
            return True
    return False


def format_datetime(dt) -> str:
    """Format datetime for Log Analytics."""
    if dt is None:
        return None
    if hasattr(dt, 'datetime'):
        dt = dt.datetime
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def main(input_data: dict) -> dict:
    """
    Scans a single directory and returns file metadata and subdirectories.
    
    Input:
    {
        "storage_account_name": "account",
        "storage_account_key": "key",
        "file_share_name": "share",
        "directory_path": "path/to/dir",  # empty string for root
        "execution_id": "guid",
        "skip_hash_computation": true,
        "max_file_size_for_hash_mb": 100,
        "exclude_patterns": ["*.tmp", ...]
    }
    
    Returns:
    {
        "directory_path": "path",
        "files_processed": 123,
        "bytes_processed": 123456,
        "subdirectories": ["subdir1", "subdir2"],
        "file_records": [...],
        "errors": []
    }
    """
    storage_account_name = input_data.get("storage_account_name", "")
    storage_account_key = input_data.get("storage_account_key", "")
    file_share_name = input_data.get("file_share_name", "")
    directory_path = input_data.get("directory_path", "")
    execution_id = input_data.get("execution_id", "")
    skip_hash = input_data.get("skip_hash_computation", True)
    max_hash_size = input_data.get("max_file_size_for_hash_mb", 100) * 1024 * 1024
    exclude_patterns = input_data.get("exclude_patterns", [])
    
    display_path = directory_path if directory_path else "(root)"
    logging.info(f"[{execution_id}] Scanning directory: {file_share_name}/{display_path}")
    
    result = {
        "directory_path": directory_path,
        "files_processed": 0,
        "bytes_processed": 0,
        "subdirectories": [],
        "file_records": [],
        "errors": []
    }
    
    try:
        # Create directory client
        connection_string = f"DefaultEndpointsProtocol=https;AccountName={storage_account_name};AccountKey={storage_account_key};EndpointSuffix=core.windows.net"
        
        if directory_path:
            directory_client = ShareDirectoryClient.from_connection_string(
                connection_string,
                share_name=file_share_name,
                directory_path=directory_path
            )
        else:
            # Root directory
            from azure.storage.fileshare import ShareClient
            share_client = ShareClient.from_connection_string(connection_string, share_name=file_share_name)
            directory_client = share_client.get_directory_client("")
        
        # List directory contents
        now = datetime.now(timezone.utc)
        scan_timestamp = now.strftime("%Y-%m-%d %H:%M:%S")
        
        for item in directory_client.list_directories_and_files():
            item_name = item["name"]
            
            if item.get("is_directory", False):
                # It's a subdirectory - add to list for later processing
                subdir_path = f"{directory_path}/{item_name}" if directory_path else item_name
                result["subdirectories"].append(subdir_path)
            else:
                # It's a file - process it
                if is_file_excluded(item_name, exclude_patterns):
                    continue
                
                try:
                    file_path = f"{directory_path}/{item_name}" if directory_path else item_name
                    file_size = item.get("size", 0)
                    
                    # Get file properties for timestamps
                    file_client = directory_client.get_file_client(item_name)
                    props = file_client.get_file_properties()
                    
                    last_modified = props.get("last_modified")
                    created = props.get("creation_time")
                    
                    # Calculate age
                    age_in_days = 0
                    if last_modified:
                        lm_dt = last_modified if hasattr(last_modified, 'tzinfo') else datetime.fromisoformat(str(last_modified))
                        if lm_dt.tzinfo is None:
                            lm_dt = lm_dt.replace(tzinfo=timezone.utc)
                        age_in_days = (now - lm_dt).days
                    
                    # Compute hash if enabled
                    file_hash = "SKIPPED"
                    if not skip_hash and file_size <= max_hash_size and file_size <= 10 * 1024 * 1024:
                        try:
                            download = file_client.download_file()
                            content = download.readall()
                            file_hash = hashlib.md5(content).hexdigest().upper()
                        except Exception as hash_error:
                            file_hash = "ERROR"
                            logging.warning(f"Hash error for {file_path}: {str(hash_error)}")
                    elif not skip_hash and file_size > max_hash_size:
                        file_hash = "SKIPPED_TOO_LARGE"
                    
                    # Get file extension
                    _, ext = os.path.splitext(item_name)
                    
                    # Create file record
                    record = {
                        "StorageAccount": storage_account_name,
                        "FileShare": file_share_name,
                        "FilePath": file_path,
                        "FileName": item_name,
                        "FileExtension": ext,
                        "FileSizeBytes": file_size,
                        "FileSizeMB": round(file_size / (1024 * 1024), 2),
                        "FileSizeGB": round(file_size / (1024 ** 3), 4),
                        "LastModified": format_datetime(last_modified),
                        "Created": format_datetime(created),
                        "AgeInDays": age_in_days,
                        "FileHash": file_hash,
                        "IsDuplicate": "Unknown",
                        "DuplicateCount": 0,
                        "DuplicateGroupId": "",
                        "FileCategory": get_file_category(ext),
                        "AgeBucket": get_age_bucket(age_in_days),
                        "SizeBucket": get_size_bucket(file_size),
                        "ScanTimestamp": scan_timestamp,
                        "ExecutionId": execution_id,
                        "TimeGenerated": format_datetime(now)
                    }
                    
                    result["file_records"].append(record)
                    result["files_processed"] += 1
                    result["bytes_processed"] += file_size
                    
                except Exception as file_error:
                    error_msg = f"Error processing file {item_name}: {str(file_error)}"
                    logging.warning(error_msg)
                    result["errors"].append(error_msg)
        
        logging.info(f"[{execution_id}] Completed {display_path}: {result['files_processed']} files, {len(result['subdirectories'])} subdirs")
        
    except Exception as e:
        error_msg = f"Error scanning directory {display_path}: {str(e)}"
        logging.error(error_msg)
        result["errors"].append(error_msg)
    
    return result
