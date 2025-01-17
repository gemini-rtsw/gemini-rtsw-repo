#!/bin/bash

# Variables
TOKEN="glpat-eX-vwr3j7nPZmtYohnXF" # Replace this with your token
PROJECT_ID="66226575" # GitLab project ID
RPM_DIR="./rpms" # Directory where RPMs are stored

# Upload each RPM in the directory
for rpm in "$RPM_DIR"/*.rpm; do
  if [[ -f "$rpm" ]]; then
    echo "Uploading $rpm..."
    curl --header "PRIVATE-TOKEN: $TOKEN" \
         --upload-file "$rpm" \
         "https://gitlab.com/api/v4/projects/$PROJECT_ID/packages/generic/rpm-repo/1.0/$(basename "$rpm")"
    echo "Uploaded: $rpm"
  else
    echo "No RPMs found in $RPM_DIR"
  fi
done

