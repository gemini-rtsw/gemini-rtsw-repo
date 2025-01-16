#!/bin/bash

# Variables
TOKEN="glpat-eX-vwr3j7nPZmtYohnXF"
PROJECT_ID="66226575"
RPM_DIR="./rpms"
REPO_DIR="./repo_temp"

# Create temporary directory structure
rm -rf "$REPO_DIR"
mkdir -p "$REPO_DIR"

# Copy RPMs to temporary directory
echo "Copying RPMs to temporary directory..."
cp "$RPM_DIR"/*.rpm "$REPO_DIR/"

# Create repository metadata using Docker
echo "Creating repository metadata..."
docker run --rm \
    -v "$(pwd)/$REPO_DIR:/repo" \
    rockylinux:9 \
    bash -c "dnf install -y createrepo_c && createrepo_c /repo"

# Get list of existing files and their sizes
echo "Getting existing files from repository..."
existing_files=$(curl --silent --header "PRIVATE-TOKEN: $TOKEN" \
    "https://gitlab.com/api/v4/projects/$PROJECT_ID/packages/generic/rpm-repo/1.0" | \
    jq -r '.[] | "\(.name) \(.size)"' || echo "")

# Sync repository files
echo "Syncing repository files..."
find "$REPO_DIR" -type f | while read -r file; do
    relative_path=${file#"$REPO_DIR/"}
    local_size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file")
    
    # Extract remote size for this file if it exists
    remote_size=$(echo "$existing_files" | grep "^${relative_path} " | awk '{print $2}' || echo "0")
    
    if [ -z "$remote_size" ] || [ "$local_size" != "$remote_size" ]; then
        echo "Uploading new/changed file: $relative_path"
        curl --header "PRIVATE-TOKEN: $TOKEN" \
             --upload-file "$file" \
             "https://gitlab.com/api/v4/projects/$PROJECT_ID/packages/generic/rpm-repo/1.0/$relative_path"
    else
        echo "Skipping unchanged file: $relative_path"
    fi
done

# Clean up
echo "Cleaning up temporary files..."
rm -rf "$REPO_DIR"

echo "Repository sync complete!" 