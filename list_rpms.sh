#!/bin/bash

# Lists RPMs in the GHCR RPM repo container

RPM_REPO_IMAGE="ghcr.io/gemini-rtsw/rpm-repo"
TAG="latest"

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

if [ "$PROD" = true ]; then
    TAG="prod"
    echo "Listing production repository packages"
fi

echo "1. Pulling RPM repo container..."
if ! docker pull "$RPM_REPO_IMAGE:$TAG" 2>/dev/null; then
    echo "No RPM repo container found ($RPM_REPO_IMAGE:$TAG) - no packages to list"
    exit 0
fi

echo "2. Getting list of RPMs..."
TEMP_DIR=$(mktemp -d)
CID=$(docker create "$RPM_REPO_IMAGE:$TAG")
docker cp "$CID:/rpm-repo/." "$TEMP_DIR/" 2>/dev/null || true
docker rm "$CID" > /dev/null

remote_files=$(find "$TEMP_DIR" -maxdepth 1 -type f -name "*.rpm" -exec basename {} \; | sort -u)
rm -rf "$TEMP_DIR"

if [ -z "$remote_files" ]; then
    echo "No RPMs found in repository"
else
    echo "Found remote RPMs:"
    echo "$remote_files"
fi
