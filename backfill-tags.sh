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

for tag in latest-el8 latest-el9; do
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
        sdir=$(mktemp -d)
        cp "$rpm" "$sdir/"
        printf 'FROM scratch\nCOPY *.rpm /\n' > "$sdir/Dockerfile"
        docker build -t "$RPM_REPO_IMAGE:$t" "$sdir" >/dev/null
        docker_push_retry "$RPM_REPO_IMAGE:$t" >/dev/null
        rm -rf "$sdir"
        total_pushed=$((total_pushed + 1))
        echo "  [$total_pushed] $t"
    done < <(find "$dir" -maxdepth 1 -name '*.rpm' | sort)

    # Seed the anti-truncation floor for this image at its current full count,
    # so the first pure-from-tags publish cannot truncate below it.
    write_count_marker "$tag" "$n"
done

echo ""
echo "================ BACKFILL SUMMARY ================"
echo "RPMs found in source images : $total_in_images"
echo "Scratch tags pushed         : $total_pushed"
# Note: a built RPM that exists in BOTH el8 and el9 has different filenames
# (.el8 vs .el9) so it is two tags; identical-named RPMs across images would
# collapse to one tag (idempotent). total_pushed >= distinct NVRAs is expected.
if [ "$total_pushed" -lt "$total_in_images" ]; then
    echo "WARNING: pushed fewer tags than RPMs found -- investigate before relying" >&2
    echo "         on pure-from-tags publishing." >&2
    exit 1
fi
echo "OK: every RPM in the served images now has a scratch tag."
echo "================================================="
