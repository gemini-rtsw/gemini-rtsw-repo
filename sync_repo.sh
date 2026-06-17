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
    # Defensive: a previous build may have served RPMs nested in bucket dirs.
    # Flatten any bNN/ subdirs back to the top so none are missed below.
    for sub in "$BUILD_DIR"/b[0-9][0-9]; do
        [ -d "$sub" ] || continue
        mv "$sub"/*.rpm "$BUILD_DIR/" 2>/dev/null || true
        rmdir "$sub" 2>/dev/null || true
    done
    echo "Existing RPMs in container:"
    ls -1 "$BUILD_DIR"/*.rpm 2>/dev/null || echo "  (none)"
else
    echo "No existing container found, starting fresh"
fi

# Anti-truncation guard: remember how many RPMs the existing repo had. The
# rebuilt repo must never contain FEWER than this (a shrinking publish is
# always a bug and would take down every consumer of rpm-repo:latest).
BASE_COUNT=$(find "$BUILD_DIR" -maxdepth 1 -name '*.rpm' | wc -l | tr -d ' ')
echo "Base repo RPM count (from existing :latest): $BASE_COUNT"

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
#
# NUM_BUCKETS MUST equal the number of "COPY ... b<NN>/" lines in
# Dockerfile.rpm-repo. If they disagree, RPMs in the unreferenced buckets would
# be silently dropped from the served repo -- the guard below fails loudly
# instead. To change the count: update BOTH this value and the Dockerfile, and
# accept a one-time full re-push (every RPM re-hashes to a new bucket).
NUM_BUCKETS=32

# Guard: the Dockerfile must COPY exactly NUM_BUCKETS buckets.
DOCKERFILE="$SCRIPT_DIR/Dockerfile.rpm-repo"
COPY_BUCKETS=$(grep -cE "buckets/b[0-9][0-9]/" "$DOCKERFILE")
if [ "$COPY_BUCKETS" -ne "$NUM_BUCKETS" ]; then
    echo "ERROR: NUM_BUCKETS=$NUM_BUCKETS but Dockerfile.rpm-repo COPYs $COPY_BUCKETS buckets." >&2
    echo "       They must match, or RPMs in unreferenced buckets are silently dropped." >&2
    echo "       Update both NUM_BUCKETS and the COPY lines in Dockerfile.rpm-repo." >&2
    exit 1
fi

# Count the full flat set right before bucketing -- this is the authoritative
# number of RPMs that MUST end up in the image.
PREBUCKET_COUNT=$(find "$BUILD_DIR" -maxdepth 1 -name '*.rpm' | wc -l | tr -d ' ')
echo "Total RPMs to publish (pre-bucket): $PREBUCKET_COUNT"

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
BUCKETED_COUNT=0
for b in $(seq 0 $((NUM_BUCKETS - 1))); do
    d="$BUILD_DIR/$(printf 'b%02d' "$b")"
    n=$(find "$d" -maxdepth 1 -name '*.rpm' | wc -l | tr -d ' ')
    BUCKETED_COUNT=$((BUCKETED_COUNT + n))
    echo "  $(basename "$d"): $n rpm(s)"
done
# Also catch any stray RPMs left at the top level (failed to bucket).
# Use find (exits 0 on no match) so the no-match case does not trip set -e/pipefail.
STRAY=$(find "$BUILD_DIR" -maxdepth 1 -name '*.rpm' | wc -l | tr -d ' ')

# --- Hard safety gates: refuse to publish a truncated/lossy repo -----------
echo "Counts: base=$BASE_COUNT prebucket=$PREBUCKET_COUNT bucketed=$BUCKETED_COUNT stray=$STRAY"
if [ "$STRAY" -ne 0 ]; then
    echo "ERROR: $STRAY RPM(s) failed to land in a bucket. Aborting (would lose them)." >&2
    exit 1
fi
if [ "$BUCKETED_COUNT" -ne "$PREBUCKET_COUNT" ]; then
    echo "ERROR: bucketing lost RPMs ($PREBUCKET_COUNT -> $BUCKETED_COUNT). Aborting." >&2
    exit 1
fi
if [ "$BUCKETED_COUNT" -lt "$BASE_COUNT" ]; then
    echo "ERROR: rebuilt repo ($BUCKETED_COUNT) is SMALLER than the existing one ($BASE_COUNT)." >&2
    echo "       A shrinking publish is always a bug; refusing to push and take down consumers." >&2
    exit 1
fi

echo "4. Building container..."
docker build -f "$SCRIPT_DIR/Dockerfile.rpm-repo" \
    --build-arg NUM_BUCKETS=$NUM_BUCKETS \
    -t "$RPM_REPO_IMAGE:$TAG" "$SCRIPT_DIR"

echo "5. Pushing container..."
docker push "$RPM_REPO_IMAGE:$TAG"

echo "Sync complete! Pushed $RPM_REPO_IMAGE:$TAG"
