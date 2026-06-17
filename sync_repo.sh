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

# At this point $RPM_DIR holds the FULL set: every rpm-* scratch tag's RPMs
# plus whatever was grandfathered in the existing :latest (copied into
# $BUILD_DIR above). Fold the grandfathered ones into $RPM_DIR too, so $RPM_DIR
# is the single authoritative source the per-image builds filter from.
for rpm in "$BUILD_DIR"/*.rpm; do
    [ -f "$rpm" ] || continue
    cp -n "$rpm" "$RPM_DIR/" 2>/dev/null || true
done
TOTAL_RPMS=$(find "$RPM_DIR" -maxdepth 1 -name '*.rpm' | wc -l | tr -d ' ')
echo "Authoritative RPM set: $TOTAL_RPMS RPM(s)"

# NUM_BUCKETS MUST equal the number of "COPY ... b<NN>/" lines in
# Dockerfile.rpm-repo. If they disagree, RPMs in unreferenced buckets would be
# silently dropped -- the guard below fails loudly instead.
NUM_BUCKETS=32
DOCKERFILE="$SCRIPT_DIR/Dockerfile.rpm-repo"
COPY_BUCKETS=$(grep -cE "buckets/b[0-9][0-9]/" "$DOCKERFILE")
if [ "$COPY_BUCKETS" -ne "$NUM_BUCKETS" ]; then
    echo "ERROR: NUM_BUCKETS=$NUM_BUCKETS but Dockerfile.rpm-repo COPYs $COPY_BUCKETS buckets." >&2
    echo "       They must match, or RPMs in unreferenced buckets are silently dropped." >&2
    exit 1
fi

# build_one TAG FILTER -- assemble an image from the RPMs in $RPM_DIR whose
# filename matches FILTER ('' = all), bucket them into stable layers, run the
# anti-truncation guards (compared against the existing image of the SAME tag),
# build, and push as $RPM_REPO_IMAGE:TAG.
#
# We publish two tags:
#   :latest-el8  -- only .el8 RPMs (~half size; consumers pull this)
#   :latest-el9  -- only .el9 RPMs
# Per-EL images halve what each build runner must pull. The old combined
# :latest is NO LONGER maintained (all consumers pull per-EL) -- the stale tag
# is left in place but never rebuilt, so we don't waste build time/space on the
# full ~6GB image.
build_one() {
    local tag="$1" filter="$2"
    local bdir="./build-${tag}"
    rm -rf "$bdir"; mkdir -p "$bdir"

    # Existing image of this tag -> base count for the truncation guard.
    local base=0
    if docker pull "$RPM_REPO_IMAGE:$tag" 2>/dev/null; then
        local cid; cid=$(docker create "$RPM_REPO_IMAGE:$tag" true)
        docker cp "$cid:/usr/share/nginx/html/rpm-repo/." "$bdir/" 2>/dev/null || true
        docker rm "$cid" >/dev/null
        rm -rf "$bdir/repodata"
        for sub in "$bdir"/b[0-9][0-9]; do
            [ -d "$sub" ] || continue
            mv "$sub"/*.rpm "$bdir/" 2>/dev/null || true
            rmdir "$sub" 2>/dev/null || true
        done
    fi
    base=$(find "$bdir" -maxdepth 1 -name '*.rpm' | wc -l | tr -d ' ')

    # Copy in the matching RPMs from the authoritative set.
    local added=0
    for rpm in "$RPM_DIR"/*.rpm; do
        [ -f "$rpm" ] || continue
        local bn; bn=$(basename "$rpm")
        if [ -n "$filter" ]; then case "$bn" in *"$filter"*) ;; *) continue ;; esac; fi
        [ -f "$bdir/$bn" ] || { cp "$rpm" "$bdir/"; added=$((added+1)); }
    done

    local prebucket; prebucket=$(find "$bdir" -maxdepth 1 -name '*.rpm' | wc -l | tr -d ' ')
    echo "[$tag] base=$base added=$added prebucket=$prebucket (filter='${filter:-ALL}')"
    if [ "$prebucket" -eq 0 ]; then
        echo "[$tag] no RPMs match; skipping (not pushing an empty image)."
        rm -rf "$bdir"; return 0
    fi

    for b in $(seq 0 $((NUM_BUCKETS - 1))); do mkdir -p "$bdir/$(printf 'b%02d' "$b")"; done
    for rpm in "$bdir"/*.rpm; do
        [ -f "$rpm" ] || continue
        local bn; bn=$(basename "$rpm")
        local h; h=$(printf '%s' "$bn" | cksum | cut -d' ' -f1)
        mv "$rpm" "$bdir/$(printf 'b%02d' "$((h % NUM_BUCKETS))")/"
    done
    local bucketed=0
    for b in $(seq 0 $((NUM_BUCKETS - 1))); do
        bucketed=$((bucketed + $(find "$bdir/$(printf 'b%02d' "$b")" -maxdepth 1 -name '*.rpm' | wc -l | tr -d ' ')))
    done
    local stray; stray=$(find "$bdir" -maxdepth 1 -name '*.rpm' | wc -l | tr -d ' ')

    # Anti-truncation guards (per tag).
    if [ "$stray" -ne 0 ]; then echo "ERROR [$tag]: $stray RPM(s) failed to bucket." >&2; exit 1; fi
    if [ "$bucketed" -ne "$prebucket" ]; then echo "ERROR [$tag]: bucketing lost RPMs ($prebucket -> $bucketed)." >&2; exit 1; fi
    if [ "$bucketed" -lt "$base" ]; then
        echo "ERROR [$tag]: rebuilt ($bucketed) SMALLER than existing ($base); refusing shrinking publish." >&2
        exit 1
    fi

    echo "[$tag] building + pushing $RPM_REPO_IMAGE:$tag ($bucketed RPMs)..."
    # The Dockerfile COPYs from ./rpm-repo; point that at this tag's build dir.
    rm -rf "$BUILD_DIR"; mv "$bdir" "$BUILD_DIR"
    docker build -f "$SCRIPT_DIR/Dockerfile.rpm-repo" \
        --build-arg NUM_BUCKETS=$NUM_BUCKETS \
        -t "$RPM_REPO_IMAGE:$tag" "$SCRIPT_DIR"
    docker push "$RPM_REPO_IMAGE:$tag"
    rm -rf "$BUILD_DIR"

    # Reclaim disk before the NEXT per-EL build. Each build pulls a multi-GB
    # base image and produces another multi-GB image; without this the el8
    # leftovers + el9 build overflow the runner disk (the COPY layers fail with
    # "no space left on device"). We have already pushed this tag, so its local
    # image is safe to drop. RPMs are kept on disk in $RPM_DIR (extracted
    # files), not in these images, so pruning is lossless. We drop built images
    # + dangling layers but KEEP the build cache (prune --filter dangling) so
    # the next run still gets "Layer already exists" on unchanged buckets.
    docker rmi -f "$RPM_REPO_IMAGE:$tag" 2>/dev/null || true
    docker image prune -af 2>/dev/null || true
    docker builder prune -f 2>/dev/null || true
    df -h / 2>/dev/null || true
    echo "[$tag] pushed."
}

# Per-EL images only. The combined :latest is intentionally not rebuilt.
build_one "latest-el8" ".el8."
build_one "latest-el9" ".el9."

echo "Sync complete! Pushed :latest-el8, :latest-el9 (:latest no longer maintained)"
