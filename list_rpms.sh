#!/bin/bash

# Variables will be replaced by CI job
TOKEN="glpat-eX-vwr3j7nPZmtYohnXF"
PROJECT_ID="66226575"
PACKAGE_NAME="rpm"  # The package name in GitLab package registry

# Parse command line options
PROD=false
while getopts "p-:" opt; do
    case $opt in
        p) PROD=true ;;
        -)
            case "${OPTARG}" in
                prod) PROD=true ;;
                *) echo "Invalid option: --${OPTARG}" >&2; exit 1 ;;
            esac ;;
        ?) echo "Invalid option: -${OPTARG}" >&2; exit 1 ;;
    esac
done
shift $((OPTIND-1))

# Set package name based on prod flag
if [ "$PROD" = true ]; then
    PACKAGE_NAME="prod"  # Change package name for prod repository
    echo "Listing production repository packages"
fi

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

echo "1. Getting package ID for $PACKAGE_NAME..."
# Get the package ID dynamically
PACKAGE_ID=$(curl --silent --header "$AUTH_HEADER" \
    "$API_URL/projects/${PROJECT_ID}/packages?package_name=${PACKAGE_NAME}" | \
    grep -o '"id":[0-9]*' | head -1 | cut -d':' -f2)

if [ -z "$PACKAGE_ID" ]; then
    echo "No remote repository found - no packages to list"
    exit 0
fi

echo "Found package ID: $PACKAGE_ID"

echo "2. Getting list of remote RPMs..."
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
