#!/bin/bash

# Variables
TOKEN="glpat-eX-vwr3j7nPZmtYohnXF"
PROJECT_ID="66226575"
PACKAGE_ID="34287433"
RPM_DIR="./rpms"
PER_PAGE=100

# Ensure RPM directory exists
if [ ! -d "$RPM_DIR" ]; then
    echo "Creating RPM directory: $RPM_DIR"
    mkdir -p "$RPM_DIR"
fi

echo "1. Getting list of remote RPMs..."
remote_files=$(curl --silent --header "PRIVATE-TOKEN: $TOKEN" \
    "https://gitlab.com/api/v4/projects/$PROJECT_ID/packages/generic/rpm-repo/1.0" | \
    grep -o '"name":"[^"]*\.rpm"' | sed 's/"name":"//;s/"//')

echo "2. Syncing RPMs..."
# First upload any local RPMs that don't exist remotely or have different sizes
for local_file in "$RPM_DIR"/*.rpm; do
    if [ -f "$local_file" ]; then
        base_name=$(basename "$local_file")
        local_size=$(stat -f%z "$local_file")
        
        # Get remote file size
        remote_size=$(curl --silent --head --header "PRIVATE-TOKEN: $TOKEN" \
            "https://gitlab.com/api/v4/projects/$PROJECT_ID/packages/generic/rpm-repo/1.0/$base_name" | \
            grep -i "content-length" | awk '{print $2}' | tr -d '\r')
        
        # Check if file exists in remote list and compare sizes
        if ! echo "$remote_files" | grep -q "^${base_name}$" || [ "$local_size" != "$remote_size" ]; then
            echo "Uploading new/updated RPM: $base_name"
            curl --header "PRIVATE-TOKEN: $TOKEN" \
                 --upload-file "$local_file" \
                 "https://gitlab.com/api/v4/projects/$PROJECT_ID/packages/generic/rpm-repo/1.0/$base_name"
        else
            echo "Skipping unchanged RPM: $base_name"
        fi
    fi
done

# Then download any remote RPMs we don't have
for remote_file in $remote_files; do
    if [ ! -f "$RPM_DIR/$remote_file" ] && [[ "$remote_file" == *.rpm ]]; then
        echo "Downloading: $remote_file"
        curl --silent --header "PRIVATE-TOKEN: $TOKEN" \
            "https://gitlab.com/api/v4/projects/$PROJECT_ID/packages/generic/rpm-repo/1.0/$remote_file" \
            --output "$RPM_DIR/$remote_file"
    fi
done

echo "3. Cleaning old repository metadata..."
rm -rf "$RPM_DIR/repodata"

echo "4. Generating repository metadata..."
docker run --rm \
    -v "$(pwd)/$RPM_DIR:/repo:Z" \
    rockylinux:9 \
    bash -c "set -x && \
             dnf install -y createrepo_c && \
             echo 'Contents of /repo:' && \
             ls -la /repo && \
             createrepo_c --verbose /repo"

echo "5. Uploading metadata files..."
# First, delete old repodata from GitLab
echo "Deleting old repodata from GitLab..."
curl --silent --header "PRIVATE-TOKEN: $TOKEN" \
    "https://gitlab.com/api/v4/projects/$PROJECT_ID/packages/generic/rpm-repo/1.0" | \
    grep -o '"name":"repodata/[^"]*"' | sed 's/"name":"//;s/"//' | \
while read -r file; do
    echo "Deleting: $file"
    curl --silent --request DELETE --header "PRIVATE-TOKEN: $TOKEN" \
        "https://gitlab.com/api/v4/projects/$PROJECT_ID/packages/generic/rpm-repo/1.0/$file"
done

# Then upload new repodata
echo "Uploading new repodata..."
find "$RPM_DIR/repodata" -type f | while read -r file; do
    relative_path=${file#"$RPM_DIR/"}
    echo "Uploading: $relative_path"
    curl --header "PRIVATE-TOKEN: $TOKEN" \
         --upload-file "$file" \
         "https://gitlab.com/api/v4/projects/$PROJECT_ID/packages/generic/rpm-repo/1.0/$relative_path"
done

echo "Repository sync complete!" 