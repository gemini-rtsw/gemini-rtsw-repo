#!/bin/bash

# Script to download all RPMs from both default and production repositories for backup purposes

# Variables
TOKEN="glpat-eX-vwr3j7nPZmtYohnXF" # Replace this with your token
PROJECT_ID="66226575" # GitLab project ID
DEFAULT_REPO="rpm-repo/1.0"
PROD_REPO="prod/1.0"
DEFAULT_PACKAGE_NAME="rpm"
PROD_PACKAGE_NAME="prod"
BACKUP_DIR="./rpm_backup"
DEFAULT_BACKUP_DIR="$BACKUP_DIR/default"
PROD_BACKUP_DIR="$BACKUP_DIR/prod"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Parse command line options
COMPRESS=false
while getopts "c-:" opt; do
    case $opt in
        c) COMPRESS=true ;;
        -)
            case "${OPTARG}" in
                compress) COMPRESS=true ;;
                *) echo "Invalid option: --${OPTARG}" >&2; exit 1 ;;
            esac ;;
        ?) echo "Invalid option: -${OPTARG}" >&2; exit 1 ;;
    esac
done
shift $((OPTIND-1))

# Set API URL based on environment
if [ -z "$CI_API_V4_URL" ]; then
    API_URL="https://gitlab.com/api/v4"
else
    API_URL="${CI_API_V4_URL}"
fi

# Set auth header based on environment
if [ -z "$CI_JOB_TOKEN" ]; then
    AUTH_HEADER="PRIVATE-TOKEN: $TOKEN"
else
    AUTH_HEADER="JOB-TOKEN: $CI_JOB_TOKEN"
fi

# Create backup directories
mkdir -p "$DEFAULT_BACKUP_DIR"
mkdir -p "$PROD_BACKUP_DIR"

echo "Starting repository backup at $TIMESTAMP"

# Function to download RPMs from a repository
download_repository() {
    local repo_name=$1
    local package_name=$2
    local repo_path=$3
    local backup_dir=$4
    
    echo "Backing up $repo_name repository..."
    
    echo "1. Getting package ID for $repo_name repository ($package_name)..."
    # Get the package ID dynamically
    PACKAGE_ID=$(curl --silent --header "$AUTH_HEADER" \
        "$API_URL/projects/${PROJECT_ID}/packages?package_name=${package_name}" | \
        grep -o '"id":[0-9]*' | head -1 | cut -d':' -f2)

    if [ -z "$PACKAGE_ID" ]; then
        echo "No $repo_name repository found - nothing to backup"
        return
    fi

    echo "Found $repo_name repository package ID: $PACKAGE_ID"

    echo "2. Getting list of RPMs from $repo_name repository..."
    # Get package versions from the package registry with pagination
    page=1
    files=""
    while true; do
        response=$(curl --silent --header "$AUTH_HEADER" \
            "$API_URL/projects/${PROJECT_ID}/packages/${PACKAGE_ID}/package_files?per_page=100&page=${page}")
        
        # Break if empty response or no more items
        if [ -z "$response" ] || [ "$response" = "[]" ]; then
            break
        fi
        
        # Extract filenames and append to list
        page_files=$(echo "$response" | grep -o '"file_name":"[^"]*\.rpm"' | sed 's/"file_name":"//;s/"//')
        if [ -n "$page_files" ]; then
            files="${files}${page_files}"$'\n'
        else
            break
        fi
        
        ((page++))
    done

    # Remove empty lines and duplicates
    files=$(echo "$files" | grep -v '^$' | sort -u)

    if [ -z "$files" ]; then
        echo "No RPMs found in $repo_name repository - nothing to backup"
        return
    fi

    echo "Found $(echo "$files" | wc -l | tr -d ' ') RPMs in $repo_name repository"

    echo "3. Downloading RPMs from $repo_name repository..."
    # Download all RPMs
    for rpm_file in $files; do
        echo "Downloading: $rpm_file"
        curl --silent --location --header "$AUTH_HEADER" \
            --output "$backup_dir/$rpm_file" \
            "$API_URL/projects/${PROJECT_ID}/packages/generic/$repo_path/$rpm_file"
        
        # Verify download
        if [ ! -s "$backup_dir/$rpm_file" ]; then
            echo "Warning: Failed to download $rpm_file or file is empty"
            rm -f "$backup_dir/$rpm_file"
        else
            # Verify it's a valid RPM
            if file "$backup_dir/$rpm_file" | grep -q "RPM"; then
                echo "Successfully downloaded: $rpm_file"
            else
                echo "Warning: Downloaded file is not a valid RPM"
                rm -f "$backup_dir/$rpm_file"
            fi
        fi
    done
    
    echo "4. Downloading repository metadata..."
    mkdir -p "$backup_dir/repodata"
    
    # Get list of metadata files
    metadata_files=$(curl --silent --header "$AUTH_HEADER" \
        "$API_URL/projects/${PROJECT_ID}/packages/generic/$repo_path/repodata" | \
        grep -o '"file_name":"[^"]*"' | sed 's/"file_name":"//;s/"//')
    
    for metadata_file in $metadata_files; do
        echo "Downloading metadata: $metadata_file"
        curl --silent --location --header "$AUTH_HEADER" \
            --output "$backup_dir/repodata/$metadata_file" \
            "$API_URL/projects/${PROJECT_ID}/packages/generic/$repo_path/repodata/$metadata_file"
    done
    
    echo "$repo_name repository backup complete"
}

# Download default repository
download_repository "default" "$DEFAULT_PACKAGE_NAME" "$DEFAULT_REPO" "$DEFAULT_BACKUP_DIR"

# Download production repository
download_repository "production" "$PROD_PACKAGE_NAME" "$PROD_REPO" "$PROD_BACKUP_DIR"

# Create a manifest file with timestamp and counts
echo "Creating backup manifest..."
echo "Backup created: $TIMESTAMP" > "$BACKUP_DIR/manifest.txt"
echo "Default repository RPMs: $(find "$DEFAULT_BACKUP_DIR" -maxdepth 1 -name "*.rpm" | wc -l)" >> "$BACKUP_DIR/manifest.txt"
echo "Production repository RPMs: $(find "$PROD_BACKUP_DIR" -maxdepth 1 -name "*.rpm" | wc -l)" >> "$BACKUP_DIR/manifest.txt"

# Compress the backup if requested
if [ "$COMPRESS" = true ]; then
    echo "Compressing backup..."
    ARCHIVE_NAME="rpm_backup_${TIMESTAMP}.tar.gz"
    tar -czf "$ARCHIVE_NAME" "$BACKUP_DIR"
    echo "Backup compressed to $ARCHIVE_NAME"
    
    # Add compression info to manifest
    echo "Compressed archive: $ARCHIVE_NAME" >> "$BACKUP_DIR/manifest.txt"
fi

echo "Backup complete!"
echo "Backup location: $BACKUP_DIR"
echo "Backup manifest: $BACKUP_DIR/manifest.txt" 