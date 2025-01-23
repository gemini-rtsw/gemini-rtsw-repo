#!/bin/bash

# Variables
TOKEN="glpat-eX-vwr3j7nPZmtYohnXF" # Replace this with your token
PROJECT_ID="66226575" # GitLab project ID

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

# Check if an RPM name was provided as an argument
if [ $# -ne 1 ]; then
    echo "Usage: $0 <rpm-filename>"
    echo "Example: $0 my-package.rpm"
    exit 1
fi

RPM_NAME="$1"

# Check if the filename has .rpm extension
if [[ ! "$RPM_NAME" =~ \.rpm$ ]]; then
    echo "Error: '$RPM_NAME' is not an RPM file (must have .rpm extension)"
    exit 1
fi

# Delete the specific RPM file
echo "Deleting $RPM_NAME from GitLab package registry..."
RESPONSE=$(curl --silent --write-out '%{http_code}' --output /dev/null \
     --header "$AUTH_HEADER" \
     --request DELETE \
     "$API_URL/projects/${PROJECT_ID}/packages/generic/rpm-repo/1.0/$RPM_NAME")

if [ "$RESPONSE" -eq 204 ] || [ "$RESPONSE" -eq 404 ]; then
    echo "Successfully deleted $RPM_NAME"
    
    # Trigger pipeline via git push to update repository
    if [ "$IS_CI" = false ]; then
        echo "Triggering repository sync pipeline via git push..."
        CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
        git commit --allow-empty -m "Trigger sync after deleting $RPM_NAME"
        git push origin $CURRENT_BRANCH
        echo "Pipeline triggered via push"
    fi
else
    echo "Error: Failed to delete $RPM_NAME (HTTP response code: $RESPONSE)"
    exit 1
fi 