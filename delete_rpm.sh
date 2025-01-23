#!/bin/bash

# Check if RPM name is provided
if [ $# -ne 1 ]; then
    echo "Usage: $0 <rpm_filename>"
    echo "Example: $0 mypackage-1.0-1.x86_64.rpm"
    exit 1
fi

# Strip any path components from the input filename
RPM_NAME=$(basename "$1")

# Variables will be replaced by CI job
TOKEN="glpat-eX-vwr3j7nPZmtYohnXF"
PROJECT_ID="66226575"
PACKAGE_NAME="rpm"

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

echo "Deleting ${RPM_NAME}..."

# Get the package ID
PACKAGE_ID=$(curl --silent --header "$AUTH_HEADER" \
    "$API_URL/projects/${PROJECT_ID}/packages?package_name=${PACKAGE_NAME}" | \
    grep -o '"id":[0-9]*' | head -1 | cut -d':' -f2)

if [ -n "$PACKAGE_ID" ]; then
    # Delete the package file
    curl --silent --request DELETE --header "$AUTH_HEADER" \
        "$API_URL/projects/${PROJECT_ID}/packages/${PACKAGE_ID}"
fi

# Trigger sync
if [ -z "$CI_JOB_TOKEN" ]; then
    echo "Triggering sync via git push..."
    git commit --allow-empty -m "Trigger sync after deleting $RPM_NAME"
    git push origin "$(git rev-parse --abbrev-ref HEAD)"
fi
