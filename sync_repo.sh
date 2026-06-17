#!/bin/bash

# Rebuilds rpm-repo:latest (the served yum repo) from the durable source of
# truth: the per-package scratch tags (rpm-<pkg>-el<N>) PLUS whatever RPMs are
# already in :latest (grandfathered/manually-added) PLUS anything in ./rpms.
#
# This is the SINGLE WRITER of :latest. It is safe to run standalone:
#   ./sync_repo.sh            # heal/force-rebuild :latest from all scratch tags
# Because it pulls every rpm-* tag itself, running it alone re-merges any RPM
# that a racing build dropped from :latest -- no rebuild of the package needed.
#
# upload-rpm.sh pushes a package's scratch tag, then calls this to publish.
#
# Requires: docker, GHCR authentication (docker login ghcr.io) with read AND
# write on the rpm-repo package, plus GITHUB_TOKEN (or CR_PAT) for the tag-list
# API. GITHUB_ACTOR/whoami supplies the registry user.

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

# --- Collect every rpm-* scratch tag into ./rpms ---------------------------
# The scratch tags (rpm-<pkg>-el<N>, pushed by upload-rpm.sh) are the durable
# source of truth: a racing publish may drop a package from :latest, but never
# from its scratch tag. Pulling them all here is what makes a standalone run of
# this script HEAL :latest. RPMs land in $RPM_DIR and are merged in below.
echo "1b. Listing rpm-* scratch tags..."
gh_user="${GITHUB_ACTOR:-$(whoami)}"
gh_pass="${GITHUB_TOKEN:-${CR_PAT:-}}"
if [ -z "$gh_pass" ]; then
    echo "ERROR: set GITHUB_TOKEN (or CR_PAT) so scratch tags can be listed" >&2
    exit 1
fi
basic=$(printf '%s:%s' "$gh_user" "$gh_pass" | base64 | tr -d '\n')
token_resp=$(curl -s -H "Authorization: Basic $basic" \
    "https://ghcr.io/token?service=ghcr.io&scope=repository:gemini-rtsw/rpm-repo:pull")
bearer=$(printf '%s' "$token_resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)
if [ -z "$bearer" ]; then
    echo "ERROR: failed to get GHCR bearer token. Response was:" >&2
    echo "$token_resp" >&2
    exit 1
fi

# Follow pagination via the Link: rel="next" header. Keep grep/sed clear of
# set -e: a single page has no Link header and grep exiting 1 would abort.
url="https://ghcr.io/v2/gemini-rtsw/rpm-repo/tags/list?n=100"
tags=""
while [ -n "$url" ]; do
    hdrs=$(mktemp)
    body=$(curl -s -D "$hdrs" -H "Authorization: Bearer $bearer" "$url")
    page=$(printf '%s' "$body" | python3 -c "import json,sys; d=json.load(sys.stdin); print('\n'.join(d.get('tags') or []))" 2>/dev/null || true)
    tags="${tags}${page}"$'\n'
    next=$(sed -n 's/.*<\([^>]*\)>; *rel="next".*/\1/Ip' "$hdrs" || true)
    rm -f "$hdrs"
    if [ -n "$next" ]; then
        case "$next" in /*) url="https://ghcr.io${next}" ;; *) url="$next" ;; esac
    else
        url=""
    fi
done

rpm_tags=$(printf '%s\n' "$tags" | grep '^rpm-' | sort -u || true)
echo "   found $(printf '%s\n' "$rpm_tags" | grep -c . || true) rpm-* tag(s)"

echo "1c. Pulling each rpm-* tag and extracting RPMs into ${RPM_DIR}..."
for t in $rpm_tags; do
    [ -n "$t" ] || continue
    docker pull -q "${RPM_REPO_IMAGE}:${t}" >/dev/null
    # `docker create` records but never runs the command; scratch images have no
    # default CMD, so pass a dummy arg to satisfy create, then copy the rootfs.
    cid=$(docker create "${RPM_REPO_IMAGE}:${t}" x)
    docker cp "${cid}:/." "$RPM_DIR/" 2>/dev/null || true
    docker rm "$cid" >/dev/null
done
# Scratch images contain only the .rpm files; drop anything else defensively.
find "$RPM_DIR" -type f ! -name '*.rpm' -delete 2>/dev/null || true
echo "   ${RPM_DIR} now has $(find "$RPM_DIR" -maxdepth 1 -name '*.rpm' | wc -l | tr -d ' ') RPM(s)"

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
