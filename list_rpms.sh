#!/bin/bash

# Variables
TOKEN="glpat-eX-vwr3j7nPZmtYohnXF" # Replace this with your token
PROJECT_ID="66226575" # GitLab project ID
PACKAGE_ID="34287433"

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

echo "Fetching list of RPMs from GitLab package registry..."

# Get package files from the package registry with pagination
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

# Remove empty lines and duplicates, then sort
remote_files=$(echo "$remote_files" | grep -v '^$' | sort -u)

echo "Available RPM packages:"
echo "----------------------"
echo "$remote_files"
echo "----------------------"
COUNT=$(echo "$remote_files" | grep -c "^")
echo "Total RPMs: $COUNT" 