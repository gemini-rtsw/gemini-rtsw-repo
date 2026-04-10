#!/bin/bash

# Downloads all RPMs from a GHCR RPM repo container for backup

RPM_REPO_IMAGE="ghcr.io/gemini-rtsw/rpm-repo"
TAG="${1:-latest}"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_DIR="./rpm_backup_${TAG}_${TIMESTAMP}"

echo "Backing up $RPM_REPO_IMAGE:$TAG..."

if ! docker pull "$RPM_REPO_IMAGE:$TAG" 2>/dev/null; then
    echo "No container found ($RPM_REPO_IMAGE:$TAG)"
    exit 1
fi

mkdir -p "$BACKUP_DIR"
CID=$(docker create "$RPM_REPO_IMAGE:$TAG" true)
docker cp "$CID:/usr/share/nginx/html/rpm-repo/." "$BACKUP_DIR/" 2>/dev/null || true
docker rm "$CID" > /dev/null

count=$(find "$BACKUP_DIR" -maxdepth 1 -name "*.rpm" 2>/dev/null | wc -l | tr -d ' ')
echo "Backed up $count RPMs to $BACKUP_DIR"
