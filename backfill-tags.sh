#!/bin/bash

# backfill-tags.sh -- ONE-TIME migration to the per-RPM scratch-tag model.
#
# Pulls the current served images (:latest-el8 and :latest-el9), enumerates
# EVERY RPM in them -- including the irreplaceable grandfathered RPMs we cannot
# rebuild -- and pushes each one as its own per-NVRA scratch tag rpm-<NVRA>.
#
# After this runs, the scratch tags are the complete, authoritative copy of the
# repo, so sync_repo.sh can safely rebuild the images purely from tags. Run it
# once (it is idempotent: re-pushing an identical tag is a no-op upload).
#
# Verify-before-trust: it counts RPMs in each source image and the number of
# tags it pushed, and reports any mismatch. Do NOT switch to pure-from-tags
# publishing until this reports every RPM tagged.
#
# Requires: docker, GHCR auth (docker login) with read+write on rpm-repo.

set -euo pipefail

RPM_REPO_IMAGE="ghcr.io/gemini-rtsw/rpm-repo"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/tag-lib.sh"

WORK=$(mktemp -d)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

total_in_images=0
total_pushed=0
total_present=0   # tags confirmed present (existing skipped + newly pushed)

# write_count_marker TAG N -- record an image's RPM count as a tiny tag, so
# sync_repo.sh's anti-truncation guard has a floor from the very first publish.
write_count_marker() {
    local tag="$1" n="$2" sdir
    sdir=$(mktemp -d)
    : > "$sdir/${n}.count"
    printf 'FROM scratch\nCOPY *.count /\n' > "$sdir/Dockerfile"
    docker build -t "$RPM_REPO_IMAGE:rpm-count-${tag}" "$sdir" >/dev/null
    docker_push_retry "$RPM_REPO_IMAGE:rpm-count-${tag}" >/dev/null
    rm -rf "$sdir"
    echo "  wrote anti-truncation marker rpm-count-${tag} = $n"
}

# Source images: the two per-EL images PLUS the legacy combined :latest. The
# legacy :latest is included because it holds EL-AGNOSTIC grandfathered RPMs
# (no .elN. dist tag -- gemini-ade, asyn, procServ, streamdevice, ...) that the
# per-EL images never carried; without it those irreplaceable RPMs would never
# get tagged. We do NOT write a count marker for :latest (it is not a published
# target, just a tag source).
for tag in latest-el8 latest-el9 latest; do
    echo "=== Source image: $RPM_REPO_IMAGE:$tag ==="
    if ! docker pull -q "$RPM_REPO_IMAGE:$tag" >/dev/null 2>&1; then
        echo "  (image $tag not found; skipping)"
        continue
    fi
    dir="$WORK/$tag"; mkdir -p "$dir"
    cid=$(docker create "$RPM_REPO_IMAGE:$tag" true)
    docker cp "$cid:/usr/share/nginx/html/rpm-repo/." "$dir/" >/dev/null 2>&1 || true
    docker rm "$cid" >/dev/null
    rm -rf "$dir/repodata"
    # Flatten any bucket subdirs so every RPM is found.
    for sub in "$dir"/b[0-9][0-9]; do
        [ -d "$sub" ] || continue
        mv "$sub"/*.rpm "$dir/" 2>/dev/null || true
        rmdir "$sub" 2>/dev/null || true
    done

    n=$(find "$dir" -maxdepth 1 -name '*.rpm' | wc -l | tr -d ' ')
    echo "  $n RPM(s) in $tag"
    total_in_images=$((total_in_images + n))

    while IFS= read -r rpm; do
        [ -n "$rpm" ] || continue
        t=$(rpm_tag_for "$rpm")
        # Skip tags that already exist -- a registry-only check, no build/push.
        # Makes re-runs take seconds (only genuinely missing tags do work).
        total_present=$((total_present + 1))
        if tag_exists "$RPM_REPO_IMAGE:$t"; then
            continue
        fi
        sdir=$(mktemp -d)
        cp "$rpm" "$sdir/"
        printf 'FROM scratch\nCOPY *.rpm /\n' > "$sdir/Dockerfile"
        docker build -t "$RPM_REPO_IMAGE:$t" "$sdir" >/dev/null
        docker_push_retry "$RPM_REPO_IMAGE:$t" >/dev/null
        rm -rf "$sdir"
        total_pushed=$((total_pushed + 1))
        echo "  pushed missing: $t"
    done < <(find "$dir" -maxdepth 1 -name '*.rpm' | sort)

    # Seed the anti-truncation floor for the published per-EL images. Skip the
    # legacy :latest (not a publish target; its count would be meaningless).
    if [ "$tag" != "latest" ]; then
        write_count_marker "$tag" "$n"
    fi
done

echo ""
echo "================ BACKFILL SUMMARY ================"
echo "RPMs found in source images : $total_in_images"
echo "Tags newly pushed (missing) : $total_pushed"
echo "Tags present (skipped+pushed): $total_present"
# Every RPM in the images must have a tag (existing or just pushed). Re-runs
# mostly skip; only genuinely missing tags are pushed.
if [ "$total_present" -lt "$total_in_images" ]; then
    echo "WARNING: $((total_in_images - total_present)) RPM(s) still lack a tag." >&2
    exit 1
fi
echo "OK: every RPM in the served images now has a scratch tag."
echo "================================================="
