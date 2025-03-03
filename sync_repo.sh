#!/bin/bash

# Variables will be replaced by CI job
TOKEN="glpat-eX-vwr3j7nPZmtYohnXF"
PROJECT_ID="66226575"
PACKAGE_NAME="rpm"  # The package name in GitLab package registry
RPM_DIR="./rpms"
REPO_PATH="rpm-repo/1.0"  # Default repository path

# Parse command line options
PROD=false
while getopts "p-:" opt; do
    case $opt in
        p) PROD=true ;;
        -)
            case "${OPTARG}" in
                prod) PROD=true ;;
                *) echo "Invalid option: --${OPTARG}" >&2; exit 1 ;;
            esac ;;
        ?) echo "Invalid option: -${OPTARG}" >&2; exit 1 ;;
    esac
done
shift $((OPTIND-1))

# Set repository path based on prod flag
if [ "$PROD" = true ]; then
    REPO_PATH="prod/1.0"
    PACKAGE_NAME="prod"  # Change package name for prod repository
    echo "Using production repository"
fi

# Set API URL based on environment
if [ -z "$CI_API_V4_URL" ]; then
    API_URL="https://gitlab.com/api/v4"
    IS_CI=false
else
    API_URL="${CI_API_V4_URL}"
    IS_CI=true
fi

# Set auth header based on environment
if [ -z "$CI_JOB_TOKEN" ]; then
    AUTH_HEADER="PRIVATE-TOKEN: $TOKEN"
else
    AUTH_HEADER="JOB-TOKEN: $CI_JOB_TOKEN"
fi

# Ensure RPM directory exists
if [ ! -d "$RPM_DIR" ]; then
    echo "Creating RPM directory: $RPM_DIR"
    mkdir -p "$RPM_DIR"
fi

echo "1. Getting package ID for $PACKAGE_NAME..."
# Use environment variable if set, otherwise fetch dynamically
if [ -n "$PACKAGE_ID" ]; then
    echo "Using package ID from environment: $PACKAGE_ID"
else
    # Get the package ID dynamically
    PACKAGE_ID=$(curl --silent --header "$AUTH_HEADER" \
        "$API_URL/projects/${PROJECT_ID}/packages?package_name=${PACKAGE_NAME}" | \
        grep -o '"id":[0-9]*' | head -1 | cut -d':' -f2)

    if [ -z "$PACKAGE_ID" ]; then
        echo "No remote repository found - will create it by uploading local packages"
        remote_files=""
    else
        echo "Found package ID: $PACKAGE_ID"
    fi
fi

if [ -n "$PACKAGE_ID" ]; then
    echo "2. Getting list of remote RPMs..."
    # Get package versions from the package registry with pagination
    page=1
    remote_files=""
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
            remote_files="${remote_files}${page_files}"$'\n'
        else
            break
        fi
        
        ((page++))
    done

    # Remove empty lines and duplicates
    remote_files=$(echo "$remote_files" | grep -v '^$' | sort -u)

    echo "Found remote RPMs:"
    echo "$remote_files"
fi

# Get list of local RPMs
echo "2. Getting list of local RPMs..."
local_files=$(find "$RPM_DIR" -maxdepth 1 -type f -name "*.rpm" -exec basename {} \;)
echo "Found local RPMs:"
echo "$local_files"

# Create temporary files for comparison
echo "$remote_files" > /tmp/remote_rpms.txt
echo "$local_files" > /tmp/local_rpms.txt

echo "3. Syncing RPMs..."
# Download missing RPMs from remote
while IFS= read -r remote_file; do
    # Skip if filename is empty
    if [ -z "$remote_file" ]; then
        continue
    fi
    
    if ! grep -q "^${remote_file}$" /tmp/local_rpms.txt; then
        echo "Downloading: $remote_file"
        
        # Download using direct package file URL
        curl --silent --location --header "$AUTH_HEADER" \
            --output "$RPM_DIR/$remote_file" \
            "$API_URL/projects/${PROJECT_ID}/packages/generic/$REPO_PATH/$remote_file"
        
        # Verify download
        if [ ! -s "$RPM_DIR/$remote_file" ]; then
            echo "Warning: Failed to download $remote_file or file is empty"
            rm -f "$RPM_DIR/$remote_file"
        else
            # Verify it's a valid RPM
            if file "$RPM_DIR/$remote_file" | grep -q "RPM"; then
                echo "Successfully downloaded: $remote_file"
            else
                echo "Warning: Downloaded file is not a valid RPM"
                rm -f "$RPM_DIR/$remote_file"
            fi
        fi
    fi
done < /tmp/remote_rpms.txt

# Upload missing RPMs to remote
while IFS= read -r local_file; do
    if ! grep -q "^${local_file}$" /tmp/remote_rpms.txt; then
        echo "Uploading: $local_file"
        if file "$RPM_DIR/$local_file" | grep -q "RPM"; then
            curl --silent --header "$AUTH_HEADER" \
                --upload-file "$RPM_DIR/$local_file" \
                "$API_URL/projects/${PROJECT_ID}/packages/generic/$REPO_PATH/$local_file"
            echo "Successfully uploaded: $local_file"
        else
            echo "Warning: Local file is not a valid RPM, skipping: $local_file"
        fi
    fi
done < /tmp/local_rpms.txt

# Cleanup temporary files
rm -f /tmp/remote_rpms.txt /tmp/local_rpms.txt

echo "4. Cleaning old repository metadata..."
rm -rf "$RPM_DIR/repodata"

echo "5. Generating repository metadata..."
if [ "$IS_CI" = true ]; then
    docker run --rm \
        -v "$(pwd)/$RPM_DIR:/repo:Z" \
        rockylinux:9 \
        bash -c "set -x && \
                 dnf install -y createrepo_c && \
                 echo 'Contents of /repo:' && \
                 ls -la /repo && \
                 createrepo_c --verbose /repo"

    echo "6. Uploading metadata files..."
    # First, delete old repodata from GitLab
    echo "Deleting old repodata from GitLab..."
    curl --silent --header "$AUTH_HEADER" \
        "$API_URL/projects/${PROJECT_ID}/packages/generic/$REPO_PATH/repodata/repomd.xml" \
        --output /dev/null

    # Delete all repodata files in one go
    curl --silent --request DELETE --header "$AUTH_HEADER" \
        "$API_URL/projects/${PROJECT_ID}/packages/generic/$REPO_PATH/repodata"

    # Then upload new repodata
    echo "Uploading new repodata..."
    find "$RPM_DIR/repodata" -type f | while read -r file; do
        relative_path=${file#"$RPM_DIR/"}
        echo "Uploading: $relative_path"
        curl --header "$AUTH_HEADER" \
             --upload-file "$file" \
             "$API_URL/projects/${PROJECT_ID}/packages/generic/$REPO_PATH/$relative_path"
    done

    echo "Repository sync complete!"
else
    echo "Not running in CI - skipping metadata generation and triggering pipeline instead..."
fi

# Only trigger pipeline if not running in CI
if [ "$IS_CI" = false ]; then
    echo "Triggering repository sync pipeline via git push..."
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    git commit --allow-empty -m "Trigger sync after repository update for $REPO_PATH"
    git push origin $CURRENT_BRANCH
    echo "Pipeline triggered via push"
fi 