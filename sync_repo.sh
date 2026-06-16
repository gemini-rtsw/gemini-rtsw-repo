#!/bin/bash

# Syncs RPMs from the local rpms/ directory into the GHCR RPM repo container.
# Pulls the existing container, merges in local RPMs, rebuilds, and pushes.
#
# Requires: docker, GHCR authentication (docker login ghcr.io)

set -euo pipefail

RPM_REPO_IMAGE="ghcr.io/gemini-rtsw/rpm-repo"
TAG="latest"
RPM_DIR="./rpms"
BUILD_DIR="./rpm-repo"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$RPM_DIR"
mkdir -p "$BUILD_DIR"

cleanup() {
    rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

echo "1. Pulling existing RPM repo container ($TAG)..."
if docker pull "$RPM_REPO_IMAGE:$TAG" 2>/dev/null; then
    CID=$(docker create "$RPM_REPO_IMAGE:$TAG" true)
    docker cp "$CID:/usr/share/nginx/html/rpm-repo/." "$BUILD_DIR/" 2>/dev/null || true
    docker rm "$CID" > /dev/null
    rm -rf "$BUILD_DIR/repodata"
    echo "Existing RPMs in container:"
    ls -1 "$BUILD_DIR"/*.rpm 2>/dev/null || echo "  (none)"
else
    echo "No existing container found, starting fresh"
fi

echo "2. Adding local RPMs..."
NEW_COUNT=0
for rpm in "$RPM_DIR"/*.rpm; do
    [ -f "$rpm" ] || continue
    BASENAME=$(basename "$rpm")
    if [ ! -f "$BUILD_DIR/$BASENAME" ]; then
        echo "  Adding: $BASENAME"
        cp "$rpm" "$BUILD_DIR/"
        NEW_COUNT=$((NEW_COUNT + 1))
    else
        echo "  Already exists: $BASENAME"
    fi
done
echo "Added $NEW_COUNT new RPM(s)"

echo "3. Final RPM list:"
ls -1 "$BUILD_DIR"/*.rpm 2>/dev/null || { echo "  No RPMs to sync"; exit 0; }

# Distribute RPMs into a fixed number of buckets so the container stores them
# in several stable layers instead of one monolithic ~6GB layer. Each build
# then re-pushes/pulls only the bucket(s) whose contents changed; unchanged
# buckets stay cached ("Layer already exists"). Bucketing is by a deterministic
# hash of the filename, so a given RPM always lands in the same bucket.
NUM_BUCKETS=16
echo "3b. Distributing RPMs into $NUM_BUCKETS buckets..."
for b in $(seq 0 $((NUM_BUCKETS - 1))); do
    mkdir -p "$BUILD_DIR/$(printf 'b%02d' "$b")"
done
for rpm in "$BUILD_DIR"/*.rpm; do
    [ -f "$rpm" ] || continue
    BASENAME=$(basename "$rpm")
    # cksum gives a stable integer hash of the name; mod into a bucket.
    H=$(printf '%s' "$BASENAME" | cksum | cut -d' ' -f1)
    BUCKET=$(printf 'b%02d' "$((H % NUM_BUCKETS))")
    mv "$rpm" "$BUILD_DIR/$BUCKET/"
done
echo "Bucket sizes:"
for b in $(seq 0 $((NUM_BUCKETS - 1))); do
    d="$BUILD_DIR/$(printf 'b%02d' "$b")"
    echo "  $(basename "$d"): $(ls -1 "$d"/*.rpm 2>/dev/null | wc -l | tr -d ' ') rpm(s)"
done

echo "4. Building container..."
docker build -f "$SCRIPT_DIR/Dockerfile.rpm-repo" \
    --build-arg NUM_BUCKETS=$NUM_BUCKETS \
    -t "$RPM_REPO_IMAGE:$TAG" "$SCRIPT_DIR"

echo "5. Pushing container..."
docker push "$RPM_REPO_IMAGE:$TAG"

echo "Sync complete! Pushed $RPM_REPO_IMAGE:$TAG"
