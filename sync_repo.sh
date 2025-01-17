#!/bin/bash

# Variables will be replaced by CI job
TOKEN="glpat-eX-vwr3j7nPZmtYohnXF"
PROJECT_ID="66226575"
PACKAGE_ID="34287433"
RPM_DIR="./rpms"

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

# Ensure RPM directory exists
if [ ! -d "$RPM_DIR" ]; then
    echo "Creating RPM directory: $RPM_DIR"
    mkdir -p "$RPM_DIR"
fi

echo "1. Getting list of remote RPMs..."
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
    if ! grep -q "^${remote_file}$" /tmp/local_rpms.txt; then
        echo "Downloading: $remote_file"
        
        # Download using direct package file URL
        curl --silent --location --header "$AUTH_HEADER" \
            --output "$RPM_DIR/$remote_file" \
            "$API_URL/projects/${PROJECT_ID}/packages/generic/rpm-repo/1.0/$remote_file"
        
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
                "$API_URL/projects/${PROJECT_ID}/packages/generic/rpm-repo/1.0/$local_file"
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
    "$API_URL/projects/${PROJECT_ID}/packages/generic/rpm-repo/1.0/repodata/repomd.xml" \
    --output /dev/null

# Delete all repodata files in one go
curl --silent --request DELETE --header "$AUTH_HEADER" \
    "$API_URL/projects/${PROJECT_ID}/packages/generic/rpm-repo/1.0/repodata"

# Then upload new repodata
echo "Uploading new repodata..."
find "$RPM_DIR/repodata" -type f | while read -r file; do
    relative_path=${file#"$RPM_DIR/"}
    echo "Uploading: $relative_path"
    curl --header "$AUTH_HEADER" \
         --upload-file "$file" \
         "$API_URL/projects/${PROJECT_ID}/packages/generic/rpm-repo/1.0/$relative_path"
done

echo "Repository sync complete!" 