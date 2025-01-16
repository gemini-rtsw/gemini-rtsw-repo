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
    almalinux:9 \
    bash -c "dnf install -y createrepo_c && createrepo_c /repo"

# Upload all repository files
echo "Uploading repository files..."
find "$REPO_DIR" -type f | while read -r file; do
    relative_path=${file#"$REPO_DIR/"}
    echo "Uploading: $relative_path"
    curl --header "PRIVATE-TOKEN: $TOKEN" \
         --upload-file "$file" \
         "https://gitlab.com/api/v4/projects/$PROJECT_ID/packages/generic/rpm-repo/1.0/$relative_path"
done

# Clean up
echo "Cleaning up temporary files..."
rm -rf "$REPO_DIR"

echo "Repository creation and upload complete!" 