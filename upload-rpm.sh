#!/bin/bash

# upload-rpm.sh -- register RPM(s) in the GHCR yum repo as a per-package tag,
# then publish.
#
# Used by both CI (gemini-rtsw-ci/build_rpm.sh) and humans uploading manually.
#
# What it does:
#   1. Packs the given RPM(s) into a tiny `FROM scratch` image and pushes it as
#      a per-package, per-EL tag:  rpm-repo:rpm-<pkgname>-el<N>
#      The tag is keyed by package name + EL (no version/hash), so re-uploading
#      a package OVERWRITES its tag -- one current RPM image per package per EL.
#      Per-package-per-EL tags never collide, so concurrent builds (including
#      both legs of an el8/el9 matrix) can push tags in parallel without locks.
#   2. Hands off to sync_repo.sh, which is the SINGLE WRITER of :latest: it
#      pulls EVERY rpm-* tag + the old :latest, runs createrepo, and pushes
#      :latest.
#
# NOTE: the tag push (step 1) is race-free, but the :latest rebuild in step 2
# is a read-modify-write on one shared tag. If you call upload-rpm.sh from
# multiple builds at once they will race on :latest (last writer wins) -- the
# loser's RPM survives in its scratch tag and is re-merged by the next sync, so
# nothing is lost, but it may be briefly absent from :latest. To avoid that,
# CI runs step 1 in each build leg and step 2 ONCE in a separate publish job;
# see gemini-rtsw-ci. For a one-off manual upload, calling both here is fine.
#
# Requires: docker, rpm (for querying names), python3, and an existing
#           `docker login ghcr.io` (CI uses the workflow GITHUB_TOKEN).
#
# Usage: ./upload-rpm.sh path/to/foo.rpm [path/to/foo-devel.rpm ...]
#        ./upload-rpm.sh --tag-only path/to/foo.rpm ...   # push tag, no sync

set -euo pipefail

RPM_REPO_IMAGE="ghcr.io/gemini-rtsw/rpm-repo"
RPM_DIR="./rpms"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

TAG_ONLY=0
if [ "${1:-}" = "--tag-only" ]; then
    TAG_ONLY=1
    shift
fi

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 [--tag-only] <rpm> [more.rpm ...]" >&2
    exit 1
fi

for f in "$@"; do
    [ -f "$f" ] || { echo "ERROR: not a file: $f" >&2; exit 1; }
done

# --- 1. Push the uploaded RPM(s) as a per-package scratch image tag ---------
# Key the tag off the "primary" package name: prefer the first non-devel RPM,
# else just the first. Strip any -devel suffix so foo + foo-devel share one tag.
primary=""
for f in "$@"; do
    name=$(rpm -qp --queryformat '%{NAME}' "$f" 2>/dev/null)
    case "$name" in
        *-devel) [ -z "$primary" ] && primary="${name%-devel}" ;;
        *) primary="$name"; break ;;
    esac
done
[ -n "$primary" ] || { echo "ERROR: could not determine package name" >&2; exit 1; }
# Scope the scratch tag by EL (.el8/.el9/...) so the el8 and el9 builds of the
# SAME package don't collide on one tag and clobber each other. Derive the EL
# from the RPM Release (dist tag).
eltag=$(rpm -qp --queryformat '%{RELEASE}' "$1" 2>/dev/null | grep -oE 'el[0-9]+' | head -1)
[ -n "$eltag" ] || eltag="noel"
TAG="rpm-${primary}-${eltag}"

echo "1. Pushing scratch image ${RPM_REPO_IMAGE}:${TAG} with $# RPM(s)..."
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp "$@" "$STAGE/"
cat > "$STAGE/Dockerfile" <<'EOF'
FROM scratch
COPY *.rpm /
EOF
docker build -t "${RPM_REPO_IMAGE}:${TAG}" "$STAGE"
docker push "${RPM_REPO_IMAGE}:${TAG}"
echo "   pushed ${RPM_REPO_IMAGE}:${TAG}"

# --- 2. Publish (rebuild :latest), unless --tag-only -----------------------
# sync_repo.sh is the single writer of :latest. It pulls EVERY rpm-* tag (incl.
# the one just pushed) + the old :latest, so it always reflects the full set.
# In CI, build legs pass --tag-only (push tag, no publish) and a separate
# publish job runs sync_repo.sh once -- avoiding the concurrent :latest race.
if [ "$TAG_ONLY" -eq 1 ]; then
    echo "2. --tag-only: skipping :latest rebuild (a later sync_repo.sh will publish)."
    exit 0
fi

echo "2. Handing off to sync_repo.sh to rebuild and push :latest..."
chmod +x "$SCRIPT_DIR/sync_repo.sh"
"$SCRIPT_DIR/sync_repo.sh"
