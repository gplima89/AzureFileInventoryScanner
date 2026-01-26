"""
Shared models and utilities for the Azure File Inventory Scanner.
"""

from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from typing import List, Optional
import os
import fnmatch


@dataclass
class ScanConfig:
    """Configuration for a file share scan operation."""
    storage_account_name: str
    storage_account_key: str
    file_share_name: str
    subscription_id: str = ""
    resource_group: str = ""
    batch_size: int = 500
    max_file_size_for_hash_mb: int = 100
    skip_hash_computation: bool = True
    exclude_patterns: List[str] = field(default_factory=lambda: ["*.tmp", "~$*", ".DS_Store", "Thumbs.db"])
    execution_id: str = ""
    
    def to_dict(self) -> dict:
        return asdict(self)
    
    @classmethod
    def from_dict(cls, data: dict) -> 'ScanConfig':
        return cls(**data)


@dataclass
class DirectoryScanTask:
    """Represents a directory to be scanned."""
    storage_account_name: str
    storage_account_key: str
    file_share_name: str
    directory_path: str
    execution_id: str
    batch_size: int = 500
    max_file_size_for_hash_mb: int = 100
    skip_hash_computation: bool = True
    exclude_patterns: List[str] = field(default_factory=list)
    
    def to_dict(self) -> dict:
        return asdict(self)
    
    @classmethod
    def from_dict(cls, data: dict) -> 'DirectoryScanTask':
        return cls(**data)


@dataclass
class FileRecord:
    """Represents a single file inventory record."""
    StorageAccount: str
    FileShare: str
    FilePath: str
    FileName: str
    FileExtension: str
    FileSizeBytes: int
    FileSizeMB: float
    FileSizeGB: float
    LastModified: Optional[str]
    Created: Optional[str]
    AgeInDays: int
    FileHash: str
    IsDuplicate: str = "Unknown"
    DuplicateCount: int = 0
    DuplicateGroupId: str = ""
    FileCategory: str = "Other"
    AgeBucket: str = ""
    SizeBucket: str = ""
    ScanTimestamp: str = ""
    ExecutionId: str = ""
    TimeGenerated: str = ""
    
    def to_dict(self) -> dict:
        return asdict(self)


@dataclass
class ScanResult:
    """Result from scanning a directory."""
    directory_path: str
    files_processed: int
    bytes_processed: int
    subdirectories: List[str]
    errors: List[str] = field(default_factory=list)
    
    def to_dict(self) -> dict:
        return asdict(self)
    
    @classmethod
    def from_dict(cls, data: dict) -> 'ScanResult':
        return cls(**data)


@dataclass
class BatchResult:
    """Result from sending a batch to Log Analytics."""
    success: bool
    records_sent: int
    message: str = ""
    
    def to_dict(self) -> dict:
        return asdict(self)


# Utility functions

def get_file_category(extension: str) -> str:
    """Categorize file by extension."""
    ext = extension.lower()
    
    document_exts = {'.doc', '.docx', '.pdf', '.txt', '.rtf', '.odt', '.xls', '.xlsx', '.ppt', '.pptx', '.csv'}
    image_exts = {'.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tiff', '.svg', '.ico', '.webp', '.raw'}
    video_exts = {'.mp4', '.avi', '.mkv', '.mov', '.wmv', '.flv', '.webm', '.m4v'}
    audio_exts = {'.mp3', '.wav', '.flac', '.aac', '.ogg', '.wma', '.m4a'}
    archive_exts = {'.zip', '.rar', '.7z', '.tar', '.gz', '.bz2', '.xz'}
    code_exts = {'.cs', '.js', '.ts', '.py', '.java', '.cpp', '.h', '.ps1', '.psm1', '.sh', '.json', '.xml', '.yaml', '.yml'}
    executable_exts = {'.exe', '.dll', '.msi', '.bat', '.cmd', '.com'}
    database_exts = {'.sql', '.mdf', '.ldf', '.bak', '.db', '.sqlite'}
    log_exts = {'.log', '.evt', '.evtx'}
    temp_exts = {'.tmp', '.temp', '.bak', '.swp', '.cache'}
    
    if ext in document_exts:
        return "Documents"
    elif ext in image_exts:
        return "Images"
    elif ext in video_exts:
        return "Videos"
    elif ext in audio_exts:
        return "Audio"
    elif ext in archive_exts:
        return "Archives"
    elif ext in code_exts:
        return "Code"
    elif ext in executable_exts:
        return "Executables"
    elif ext in database_exts:
        return "Databases"
    elif ext in log_exts:
        return "Logs"
    elif ext in temp_exts:
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
    KB = 1024
    MB = KB * 1024
    GB = MB * 1024
    
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


def format_datetime(dt: Optional[datetime]) -> Optional[str]:
    """Format datetime for Log Analytics."""
    if dt is None:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def get_config_from_env() -> dict:
    """Get configuration from environment variables."""
    return {
        "storage_account_name": os.environ.get("STORAGE_ACCOUNT_NAME", ""),
        "storage_account_key": os.environ.get("STORAGE_ACCOUNT_KEY", ""),
        "dce_endpoint": os.environ.get("LOG_ANALYTICS_DCE_ENDPOINT", ""),
        "dcr_immutable_id": os.environ.get("LOG_ANALYTICS_DCR_IMMUTABLE_ID", ""),
        "stream_name": os.environ.get("LOG_ANALYTICS_STREAM_NAME", "Custom-FileInventory_CL"),
        "batch_size": int(os.environ.get("BATCH_SIZE", "500")),
        "max_file_size_for_hash_mb": int(os.environ.get("MAX_FILE_SIZE_FOR_HASH_MB", "100")),
        "skip_hash_computation": os.environ.get("SKIP_HASH_COMPUTATION", "true").lower() == "true",
        "exclude_patterns": os.environ.get("EXCLUDE_PATTERNS", "*.tmp,~$*,.DS_Store,Thumbs.db").split(",")
    }
