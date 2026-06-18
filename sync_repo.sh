#!/bin/bash

# Rebuilds the served yum images (rpm-repo:latest-el8 / :latest-el9) PURELY from
# the per-RPM scratch tags -- the tags are the single, durable source of truth.
#
# Model: every RPM lives in its own scratch tag rpm-<NVRA> (pushed by
# upload-rpm.sh / the one-time backfill). This script lists every rpm-* tag,
# pulls each, sorts them by EL, runs createrepo, and pushes one image per EL.
# It does NOT pull the existing :latest-el* images to merge into -- so there is
# no read-modify-write, no cross-build race, and no 6GB base pull. A rebuild
# always deterministically reconstructs the full repo from the tag set.
#
# Safe to run standalone (it is also the HEAL command):
#   ./sync_repo.sh
#
# SAFETY: the tags are the only source, so a missing tag = a missing RPM. Two
# guards protect the irreplaceable (grandfathered) RPMs:
#   1. Anti-truncation: each per-EL image must contain at least as many RPMs as
#      the previous publish recorded (in a tiny rpm-count-el<N> marker tag).
#      A shrink fails the publish loudly instead of silently dropping RPMs.
#   2. Tag-pull failures are fatal (set -e) -- a flaky pull turns the build red.
#
# Requires: docker, GHCR auth (docker login) with read+write on rpm-repo, plus
# GITHUB_TOKEN (or CR_PAT) for the tag-list API. GITHUB_ACTOR/whoami = user.

set -euo pipefail

RPM_REPO_IMAGE="ghcr.io/gemini-rtsw/rpm-repo"
RPM_DIR="./rpms"
BUILD_DIR="./rpm-repo"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/tag-lib.sh"

mkdir -p "$RPM_DIR"
cleanup() { rm -rf "$BUILD_DIR"; }
trap cleanup EXIT

# --- 1. List every rpm-* scratch tag --------------------------------------
echo "1. Listing rpm-* scratch tags..."
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

# Paginate with an explicit cursor instead of parsing the Link: header.
# The registry returns up to PAGE_SIZE tags per request and accepts ?last=<tag>
# to continue after the last tag seen. We loop until a page returns fewer than
# PAGE_SIZE tags (the final page). This does not depend on the exact Link-header
# format, so it cannot silently stop early -- critical now that there are 600+
# tags across several pages (a missed page = dropped RPMs).
PAGE_SIZE=100
tags=""
last=""
while :; do
    if [ -z "$last" ]; then
        url="https://ghcr.io/v2/gemini-rtsw/rpm-repo/tags/list?n=${PAGE_SIZE}"
    else
        url="https://ghcr.io/v2/gemini-rtsw/rpm-repo/tags/list?n=${PAGE_SIZE}&last=${last}"
    fi
    body=$(curl -s -H "Authorization: Bearer $bearer" "$url")
    page=$(printf '%s' "$body" | python3 -c "import json,sys; d=json.load(sys.stdin); print('\n'.join(d.get('tags') or []))" 2>/dev/null || true)
    count=$(printf '%s\n' "$page" | grep -c . || true)
    [ "$count" -eq 0 ] && break
    tags="${tags}${page}"$'\n'
    last=$(printf '%s\n' "$page" | grep . | tail -1)
    # Last page returns fewer than a full page -> done.
    [ "$count" -lt "$PAGE_SIZE" ] && break
done

# Only the per-RPM tags (rpm-...), excluding the count-marker tags.
rpm_tags=$(printf '%s\n' "$tags" | grep '^rpm-' | sort -u || true)
TAG_COUNT=$(printf '%s\n' "$rpm_tags" | grep -c . || true)
echo "   found $TAG_COUNT rpm-* tag(s)"
if [ "$TAG_COUNT" -eq 0 ]; then
    echo "ERROR: no rpm-* tags found -- refusing to publish an empty repo." >&2
    echo "       (Has the one-time backfill been run? See backfill-tags.sh.)" >&2
    exit 1
fi

# --- 2. Pull every tag, extracting RPMs into $RPM_DIR ----------------------
# Parallelised: each scratch image is tiny, but there are hundreds. set -e makes
# any pull failure fatal (we must never silently drop an irreplaceable RPM).
echo "2. Pulling $TAG_COUNT tags into $RPM_DIR ..."
PROGRESS_FILE=$(mktemp)
echo 0 > "$PROGRESS_FILE"
pull_one() {
    local t="$1"
    docker pull -q "${RPM_REPO_IMAGE}:${t}" >/dev/null
    local cid; cid=$(docker create "${RPM_REPO_IMAGE}:${t}" x)
    docker cp "${cid}:/." "$RPM_DIR/" >/dev/null 2>&1 || true
    docker rm "$cid" >/dev/null
    # Progress: bump a shared counter, print every 25 tags so the log shows
    # the pull is advancing (otherwise it looks hung for many minutes).
    local n
    n=$(( $(cat "$PROGRESS_FILE") + 1 ))
    echo "$n" > "$PROGRESS_FILE"
    if [ $((n % 25)) -eq 0 ]; then echo "   ... pulled $n/$TAG_COUNT tags"; fi
}
export -f pull_one
export RPM_REPO_IMAGE RPM_DIR PROGRESS_FILE TAG_COUNT
# xargs -P for concurrency. A pull failure would silently drop an RPM, so we
# guard below. NOTE: we do NOT require EXTRACTED == TAG_COUNT. Legacy per-package
# tags may hold overlapping RPMs (dedup'd on extraction), so EXTRACTED can be <
# TAG_COUNT. The real safety net is the per-EL anti-truncation marker.
printf '%s\n' $rpm_tags | xargs -P 16 -I{} bash -c 'pull_one "$@"' _ {}
rm -f "$PROGRESS_FILE"
find "$RPM_DIR" -type f ! -name '*.rpm' -delete 2>/dev/null || true
EXTRACTED=$(find "$RPM_DIR" -maxdepth 1 -name '*.rpm' | wc -l | tr -d ' ')
echo "   extracted $EXTRACTED distinct RPM(s) from $TAG_COUNT tag(s)"
if [ "$EXTRACTED" -eq 0 ]; then
    echo "ERROR: extracted 0 RPMs from $TAG_COUNT tags -- all pulls failed?" >&2
    exit 1
fi

# --- bucket/guard/build/push helper ---------------------------------------
NUM_BUCKETS=32
DOCKERFILE="$SCRIPT_DIR/Dockerfile.rpm-repo"
COPY_BUCKETS=$(grep -cE "buckets/b[0-9][0-9]/" "$DOCKERFILE")
if [ "$COPY_BUCKETS" -ne "$NUM_BUCKETS" ]; then
    echo "ERROR: NUM_BUCKETS=$NUM_BUCKETS but Dockerfile.rpm-repo COPYs $COPY_BUCKETS buckets." >&2
    exit 1
fi

# read_count_marker TAG -> previous RPM count for this image (0 if none).
# Stored as a tiny scratch tag rpm-count-<tag> whose single file is named
# "<N>.count", so we read it without pulling the multi-GB image.
read_count_marker() {
    local tag="$1" cdir n
    cdir=$(mktemp -d)
    if docker pull -q "$RPM_REPO_IMAGE:rpm-count-${tag}" >/dev/null 2>&1; then
        local cid; cid=$(docker create "$RPM_REPO_IMAGE:rpm-count-${tag}" x)
        docker cp "${cid}:/." "$cdir/" >/dev/null 2>&1 || true
        docker rm "$cid" >/dev/null
    fi
    n=$(basename "$(find "$cdir" -name '*.count' 2>/dev/null | head -1)" .count 2>/dev/null)
    rm -rf "$cdir"
    case "$n" in ''|*[!0-9]*) echo 0 ;; *) echo "$n" ;; esac
}

# write_count_marker TAG N -- record this publish's RPM count for next time.
write_count_marker() {
    local tag="$1" n="$2" sdir
    sdir=$(mktemp -d)
    : > "$sdir/${n}.count"
    printf 'FROM scratch\nCOPY *.count /\n' > "$sdir/Dockerfile"
    docker build -t "$RPM_REPO_IMAGE:rpm-count-${tag}" "$sdir" >/dev/null
    docker_push_retry "$RPM_REPO_IMAGE:rpm-count-${tag}" >/dev/null
    rm -rf "$sdir"
}

# build_one TAG FILTER -- build $RPM_REPO_IMAGE:TAG from the $RPM_DIR RPMs whose
# filename contains FILTER (e.g. ".el8."). Pure from-tags: no pull of the
# existing image to merge. Anti-truncation guard via the count marker.
build_one() {
    local tag="$1" filter="$2"
    local bdir="./build-${tag}"
    rm -rf "$bdir"; mkdir -p "$bdir"

    # An RPM belongs in this EL's image if its filename carries this EL's dist
    # tag (.el8. / .el9.) OR carries NO el dist tag at all. The latter covers
    # grandfathered/external EL-agnostic RPMs (e.g. gemini-ade-2.2-...x86_64.rpm,
    # noarch tools) that must appear in BOTH images -- otherwise the EL filter
    # silently drops them from the served repos.
    local n=0
    for rpm in "$RPM_DIR"/*.rpm; do
        [ -f "$rpm" ] || continue
        local bn; bn=$(basename "$rpm")
        case "$bn" in
            *"$filter"*) cp "$rpm" "$bdir/"; n=$((n+1)) ;;       # this EL
            *.el[0-9]*) : ;;                                      # a DIFFERENT EL -> skip
            *) cp "$rpm" "$bdir/"; n=$((n+1)) ;;                  # no EL tag -> both images
        esac
    done
    echo "[$tag] $n RPM(s) for filter '$filter' (incl. EL-agnostic)"
    if [ "$n" -eq 0 ]; then
        echo "[$tag] no RPMs match; skipping."
        rm -rf "$bdir"; return 0
    fi

    # Visibility: full sorted RPM list going into this image + a spot-check of
    # key packages, so the log shows exactly what was published.
    echo "[$tag] ----- RPMs in this image ($n) -----"
    find "$bdir" -maxdepth 1 -name '*.rpm' -printf '%f\n' | sort | sed "s/^/[$tag]   /"
    echo "[$tag] ----- key-package spot check -----"
    for key in gemini-ade epics-base-devel- asyn- procServ- streamdevice-; do
        c=$(find "$bdir" -maxdepth 1 -name "${key}*.rpm" | wc -l | tr -d ' ')
        echo "[$tag]   ${key}*: $c"
    done

    # Anti-truncation: never publish fewer RPMs than last time.
    local prev; prev=$(read_count_marker "$tag")
    echo "[$tag] previous published count: $prev"
    if [ "$n" -lt "$prev" ]; then
        echo "ERROR [$tag]: would publish $n RPM(s), fewer than previous $prev." >&2
        echo "       Refusing shrinking publish (possible lost/pruned tags)." >&2
        exit 1
    fi

    # Bucket into stable layers.
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
    if [ "$stray" -ne 0 ]; then echo "ERROR [$tag]: $stray RPM(s) failed to bucket." >&2; exit 1; fi
    if [ "$bucketed" -ne "$n" ]; then echo "ERROR [$tag]: bucketing lost RPMs ($n -> $bucketed)." >&2; exit 1; fi

    echo "[$tag] building + pushing $RPM_REPO_IMAGE:$tag ($bucketed RPMs)..."
    rm -rf "$BUILD_DIR"; mv "$bdir" "$BUILD_DIR"
    docker build -f "$SCRIPT_DIR/Dockerfile.rpm-repo" \
        --build-arg NUM_BUCKETS=$NUM_BUCKETS \
        -t "$RPM_REPO_IMAGE:$tag" "$SCRIPT_DIR"
    docker_push_retry "$RPM_REPO_IMAGE:$tag"
    rm -rf "$BUILD_DIR"

    # Record the new count (after a successful push) for next run's guard.
    write_count_marker "$tag" "$bucketed"
    # Stash the published count for the final summary.
    echo "$tag $bucketed" >> "$SUMMARY_FILE"

    # Reclaim disk before the next per-EL build (the built image is pushed; the
    # RPMs persist as files in $RPM_DIR, so this is lossless).
    docker rmi -f "$RPM_REPO_IMAGE:$tag" 2>/dev/null || true
    docker image prune -af 2>/dev/null || true
    docker builder prune -f 2>/dev/null || true
    df -h / 2>/dev/null || true
    echo "[$tag] pushed."
}

SUMMARY_FILE=$(mktemp)
build_one "latest-el8" ".el8."
build_one "latest-el9" ".el9."

echo ""
echo "================ PUBLISH SUMMARY ================"
echo "Source: $TAG_COUNT scratch tags -> $EXTRACTED distinct RPMs"
while read -r t cnt; do echo "  $t : $cnt RPMs published"; done < "$SUMMARY_FILE"
rm -f "$SUMMARY_FILE"
echo "================================================"
echo "Sync complete! Rebuilt :latest-el8 and :latest-el9 purely from the scratch tags."
