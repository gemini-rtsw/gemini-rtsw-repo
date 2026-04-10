#!/bin/bash

# Lists RPMs in the GHCR RPM repo container

RPM_REPO_IMAGE="ghcr.io/gemini-rtsw/rpm-repo"
TAG="${1:-latest}"

echo "Pulling RPM repo container ($TAG)..."
if ! docker pull "$RPM_REPO_IMAGE:$TAG" 2>/dev/null; then
    echo "No RPM repo container found ($RPM_REPO_IMAGE:$TAG)"
    exit 0
fi

echo "Getting list of RPMs..."
TEMP_DIR=$(mktemp -d)
CID=$(docker create "$RPM_REPO_IMAGE:$TAG" true)
docker cp "$CID:/usr/share/nginx/html/rpm-repo/." "$TEMP_DIR/" 2>/dev/null || true
docker rm "$CID" > /dev/null

remote_files=$(find "$TEMP_DIR" -maxdepth 1 -type f -name "*.rpm" -exec basename {} \; | sort -u)
rm -rf "$TEMP_DIR"

if [ -z "$remote_files" ]; then
    echo "No RPMs found"
else
    echo "$remote_files"
fi
