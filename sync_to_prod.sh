#!/bin/bash

# Script to sync RPMs from default repository to production repository
# This script copies all RPMs from rpm-repo/1.0 to prod/1.0

# Variables
TOKEN="glpat-eX-vwr3j7nPZmtYohnXF" # Replace this with your token
PROJECT_ID="66226575" # GitLab project ID
DEFAULT_REPO="rpm-repo/1.0"
PROD_REPO="prod/1.0"
DEFAULT_PACKAGE_NAME="rpm"
PROD_PACKAGE_NAME="prod"
TEMP_DIR="./temp_rpms"

# Parse command line options
NO_PUSH=false
while getopts "n-:" opt; do
    case $opt in
        n) NO_PUSH=true ;;
        -)
            case "${OPTARG}" in
                no-push) NO_PUSH=true ;;
                *) echo "Invalid option: --${OPTARG}" >&2; exit 1 ;;
            esac ;;
        ?) echo "Invalid option: -${OPTARG}" >&2; exit 1 ;;
    esac
done
shift $((OPTIND-1))

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

# Create temporary directory
mkdir -p "$TEMP_DIR"

echo "1. Getting package ID for default repository ($DEFAULT_PACKAGE_NAME)..."
# Get the package ID dynamically for default repository
DEFAULT_PACKAGE_ID=$(curl --silent --header "$AUTH_HEADER" \
    "$API_URL/projects/${PROJECT_ID}/packages?package_name=${DEFAULT_PACKAGE_NAME}" | \
    grep -o '"id":[0-9]*' | head -1 | cut -d':' -f2)

if [ -z "$DEFAULT_PACKAGE_ID" ]; then
    echo "No default repository found - nothing to sync"
    exit 1
fi

echo "Found default repository package ID: $DEFAULT_PACKAGE_ID"

echo "2. Getting list of RPMs from default repository..."
# Get package versions from the package registry with pagination
page=1
default_files=""
while true; do
    response=$(curl --silent --header "$AUTH_HEADER" \
        "$API_URL/projects/${PROJECT_ID}/packages/${DEFAULT_PACKAGE_ID}/package_files?per_page=100&page=${page}")
    
    # Break if empty response or no more items
    if [ -z "$response" ] || [ "$response" = "[]" ]; then
        break
    fi
    
    # Extract filenames and append to list
    page_files=$(echo "$response" | grep -o '"file_name":"[^"]*\.rpm"' | sed 's/"file_name":"//;s/"//')
    if [ -n "$page_files" ]; then
        default_files="${default_files}${page_files}"$'\n'
    else
        break
    fi
    
    ((page++))
done

# Remove empty lines and duplicates
default_files=$(echo "$default_files" | grep -v '^$' | sort -u)

if [ -z "$default_files" ]; then
    echo "No RPMs found in default repository - nothing to sync"
    rm -rf "$TEMP_DIR"
    exit 0
fi

echo "Found RPMs in default repository:"
echo "$default_files"

echo "3. Getting package ID for production repository ($PROD_PACKAGE_NAME)..."
# Get the package ID dynamically for production repository
PROD_PACKAGE_ID=$(curl --silent --header "$AUTH_HEADER" \
    "$API_URL/projects/${PROJECT_ID}/packages?package_name=${PROD_PACKAGE_NAME}" | \
    grep -o '"id":[0-9]*' | head -1 | cut -d':' -f2)

# If production repository doesn't exist yet, we'll create it by uploading packages
if [ -z "$PROD_PACKAGE_ID" ]; then
    echo "No production repository found - will create it by uploading packages"
    prod_files=""
else
    echo "Found production repository package ID: $PROD_PACKAGE_ID"

    echo "4. Getting list of RPMs from production repository..."
    # Get package versions from the package registry with pagination
    page=1
    prod_files=""
    while true; do
        response=$(curl --silent --header "$AUTH_HEADER" \
            "$API_URL/projects/${PROJECT_ID}/packages/${PROD_PACKAGE_ID}/package_files?per_page=100&page=${page}")
        
        # Break if empty response or no more items
        if [ -z "$response" ] || [ "$response" = "[]" ]; then
            break
        fi
        
        # Extract filenames and append to list
        page_files=$(echo "$response" | grep -o '"file_name":"[^"]*\.rpm"' | sed 's/"file_name":"//;s/"//')
        if [ -n "$page_files" ]; then
            prod_files="${prod_files}${page_files}"$'\n'
        else
            break
        fi
        
        ((page++))
    done

    # Remove empty lines and duplicates
    prod_files=$(echo "$prod_files" | grep -v '^$' | sort -u)

    echo "Found RPMs in production repository:"
    echo "$prod_files"
fi

echo "5. Downloading RPMs from default repository..."
# Download all RPMs from default repository
for rpm_file in $default_files; do
    echo "Downloading: $rpm_file"
    curl --silent --location --header "$AUTH_HEADER" \
        --output "$TEMP_DIR/$rpm_file" \
        "$API_URL/projects/${PROJECT_ID}/packages/generic/$DEFAULT_REPO/$rpm_file"
    
    # Verify download
    if [ ! -s "$TEMP_DIR/$rpm_file" ]; then
        echo "Warning: Failed to download $rpm_file or file is empty"
        rm -f "$TEMP_DIR/$rpm_file"
    else
        # Verify it's a valid RPM
        if file "$TEMP_DIR/$rpm_file" | grep -q "RPM"; then
            echo "Successfully downloaded: $rpm_file"
        else
            echo "Warning: Downloaded file is not a valid RPM"
            rm -f "$TEMP_DIR/$rpm_file"
        fi
    fi
done

echo "6. Uploading RPMs to production repository..."
# Upload all RPMs to production repository
for rpm_file in $(find "$TEMP_DIR" -type f -name "*.rpm" -exec basename {} \;); do
    # Check if the RPM already exists in production
    if echo "$prod_files" | grep -q "^${rpm_file}$"; then
        echo "Skipping upload of $rpm_file (already exists in production)"
    else
        echo "Uploading: $rpm_file to production"
        curl --silent --header "$AUTH_HEADER" \
            --upload-file "$TEMP_DIR/$rpm_file" \
            "$API_URL/projects/${PROJECT_ID}/packages/generic/$PROD_REPO/$rpm_file"
        echo "Successfully uploaded: $rpm_file to production"
    fi
done

# Clean up temporary directory
echo "7. Cleaning up temporary files..."
rm -rf "$TEMP_DIR"

# Trigger pipeline via git push unless --no-push was specified
if [ "$NO_PUSH" = false ]; then
    echo "8. Triggering repository sync pipeline via git push..."
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    git commit --allow-empty -m "[PROD_SYNC] Trigger sync after promoting RPMs to production"
    git push origin $CURRENT_BRANCH
    echo "Pipeline triggered via push"
else
    echo "Skipping repository sync pipeline trigger (--no-push specified)"
fi

echo "Sync to production complete!" 