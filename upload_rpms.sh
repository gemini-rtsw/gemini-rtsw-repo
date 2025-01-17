#!/bin/bash

# Variables
TOKEN="glpat-eX-vwr3j7nPZmtYohnXF" # Replace this with your token
PROJECT_ID="66226575" # GitLab project ID
RPM_DIR="./rpms" # Directory where RPMs are stored

# Upload each RPM in the directory
for rpm in "$RPM_DIR"/*.rpm; do
  if [[ -f "$rpm" ]]; then
    echo "Processing $rpm..."
    
    # Extract RPM metadata
    NAME=$(rpm -qp --queryformat '%{NAME}' "$rpm")
    VERSION=$(rpm -qp --queryformat '%{VERSION}' "$rpm")
    RELEASE=$(rpm -qp --queryformat '%{RELEASE}' "$rpm")
    ARCH=$(rpm -qp --queryformat '%{ARCH}' "$rpm")
    
    # Create JSON payload
    JSON_PAYLOAD=$(jq -n \
      --arg name "$NAME" \
      --arg version "$VERSION" \
      --arg release "$RELEASE" \
      --arg arch "$ARCH" \
      '{
        "name": $name,
        "version": $version,
        "release": $release,
        "arch": $arch,
        "distribution": "el9"
      }')

    echo "Uploading $rpm..."
    curl --header "PRIVATE-TOKEN: $TOKEN" \
         --header "Content-Type: application/json" \
         --data "$JSON_PAYLOAD" \
         --upload-file "$rpm" \
         "https://gitlab.com/api/v4/projects/$PROJECT_ID/packages/rpm/rpms"
    
    echo "Uploaded: $rpm"
  else
    echo "No RPMs found in $RPM_DIR"
  fi
done

