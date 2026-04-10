#!/bin/bash

# Syncs RPMs between the local rpms/ directory and the GHCR RPM repo container,
# then triggers the pipeline to rebuild the container with updated RPMs + repodata.
#
# In CI: handled by the GitHub Actions workflow directly
# Locally: pulls the container, syncs RPMs, triggers pipeline

RPM_REPO_IMAGE="ghcr.io/gemini-rtsw/rpm-repo"
TAG="latest"
REPO_DIR="rpm-repo"
RPM_DIR="./rpms"

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
    REPO_DIR="prod"
    echo "Using production repository"
fi

# Ensure RPM directory exists
mkdir -p "$RPM_DIR"

# Create temp working directory
WORK_DIR=$(mktemp -d)
mkdir -p "$WORK_DIR/rpm-repo"

echo "1. Pulling existing RPM repo container..."
if docker pull "$RPM_REPO_IMAGE:$TAG" 2>/dev/null; then
    CID=$(docker create "$RPM_REPO_IMAGE:$TAG")
    docker cp "$CID:/rpm-repo/." "$WORK_DIR/rpm-repo/" 2>/dev/null || true
    docker rm "$CID"
    rm -rf "$WORK_DIR/rpm-repo/repodata"
    echo "Extracted existing RPMs"
else
    echo "No existing container image found, starting fresh"
fi

echo "2. Getting list of remote RPMs..."
remote_files=$(find "$WORK_DIR/rpm-repo" -maxdepth 1 -type f -name "*.rpm" -exec basename {} \; | sort -u)
echo "Found remote RPMs:"
echo "$remote_files"

echo "3. Getting list of local RPMs..."
local_files=$(find "$RPM_DIR" -maxdepth 1 -type f -name "*.rpm" -exec basename {} \; | sort -u)
echo "Found local RPMs:"
echo "$local_files"

echo "4. Syncing RPMs..."
# Download remote RPMs not in local
for remote_file in $remote_files; do
    [ -z "$remote_file" ] && continue
    if ! echo "$local_files" | grep -q "^${remote_file}$"; then
        echo "Downloading: $remote_file"
        cp "$WORK_DIR/rpm-repo/$remote_file" "$RPM_DIR/$remote_file"
    fi
done

# Copy local RPMs into work dir for the pipeline
for local_file in $local_files; do
    [ -z "$local_file" ] && continue
    if ! echo "$remote_files" | grep -q "^${local_file}$"; then
        echo "Adding to repo: $local_file"
        cp "$RPM_DIR/$local_file" "$WORK_DIR/rpm-repo/$local_file"
    fi
done

# Cleanup
rm -rf "$WORK_DIR"

echo "5. Triggering pipeline to rebuild container..."
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
COMMIT_MSG="Trigger sync after repository update for $REPO_DIR"
if [ "$PROD" = true ]; then
    COMMIT_MSG="[PROD_SYNC] $COMMIT_MSG"
fi
git commit --allow-empty -m "$COMMIT_MSG"
git push github "$CURRENT_BRANCH" 2>/dev/null || git push origin "$CURRENT_BRANCH"
echo "Pipeline triggered via push"

echo "Repository sync complete!"
