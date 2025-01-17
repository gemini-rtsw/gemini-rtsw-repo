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
    
    echo "Uploading $rpm..."
    curl --silent --show-error \
         --header "PRIVATE-TOKEN: $TOKEN" \
         --form "file=@$rpm" \
         --form "name=$NAME" \
         --form "version=$VERSION" \
         --form "release=$RELEASE" \
         --form "arch=$ARCH" \
         --form "distribution=el8" \
         "https://gitlab.com/api/v4/projects/$PROJECT_ID/packages/rpm/rpms"

    if [ $? -eq 0 ]; then
      echo "Successfully uploaded: $rpm"
    else
      echo "Failed to upload: $rpm"
      exit 1
    fi
  else
    echo "No RPMs found in $RPM_DIR"
    exit 1
  fi
done

