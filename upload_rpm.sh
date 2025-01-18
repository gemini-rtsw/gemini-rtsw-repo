#!/bin/bash

# Variables
TOKEN="glpat-eX-vwr3j7nPZmtYohnXF" # Replace this with your token
PROJECT_ID="66226575" # GitLab project ID

# Check if an RPM file was provided as an argument
if [ $# -ne 1 ]; then
    echo "Usage: $0 <path-to-rpm-file>"
    echo "Example: $0 ./my-package.rpm"
    exit 1
fi

RPM_FILE="$1"

# Check if the file exists and is a regular file
if [ ! -f "$RPM_FILE" ]; then
    echo "Error: File '$RPM_FILE' does not exist or is not a regular file"
    exit 1
fi

# Check if the file has .rpm extension
if [[ ! "$RPM_FILE" =~ \.rpm$ ]]; then
    echo "Error: File '$RPM_FILE' is not an RPM file (must have .rpm extension)"
    exit 1
fi

# Upload the RPM
echo "Uploading $RPM_FILE..."
curl --header "PRIVATE-TOKEN: $TOKEN" \
     --upload-file "$RPM_FILE" \
     "https://gitlab.com/api/v4/projects/$PROJECT_ID/packages/generic/rpm-repo/1.0/$(basename "$RPM_FILE")"

echo "Upload complete: $RPM_FILE"

