#!/bin/bash

# upload-rpm.sh -- the single entry point for adding RPM(s) to the GHCR yum repo.
#
# Used by both CI (gemini-rtsw-ci/build_rpm.sh) and humans uploading manually.
#
# What it does:
#   1. Packs the given RPM(s) into a tiny `FROM scratch` image and pushes it as
#      a per-package tag on the rpm-repo package:  rpm-repo:rpm-<pkgname>
#      The tag is keyed by package name only (no version/hash), so re-uploading
#      a package OVERWRITES its tag -- one current RPM image per package.
#   2. Lists every rpm-* tag on the package, pulls each, and copies the RPM(s)
#      out into ./rpms -- so ./rpms ends up holding the latest of every package.
#   3. Hands off to sync_repo.sh UNCHANGED, which additionally merges in the
#      RPMs already in rpm-repo:latest (preserving old/manually-added versions),
#      runs createrepo, and pushes rpm-repo:latest.
#
# The rpm-* tags ADD/overwrite but never remove; sync_repo.sh's pull of :latest
# is what retains history. Concurrent runs converge: each rebuilds :latest from
# the same tag set + the same old :latest, so nothing is lost (no lock needed).
#
# Requires: docker, rpm (for querying names), python3, and an existing
#           `docker login ghcr.io` (CI uses the workflow GITHUB_TOKEN).
#
# Usage: ./upload-rpm.sh path/to/foo.rpm [path/to/foo-devel.rpm ...]

set -euo pipefail

RPM_REPO_IMAGE="ghcr.io/gemini-rtsw/rpm-repo"
RPM_DIR="./rpms"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <rpm> [more.rpm ...]" >&2
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

# --- 2. Pull every rpm-* tag and collect RPMs into ./rpms ------------------
mkdir -p "$RPM_DIR"

echo "2. Listing rpm-* tags..."
# Get a GHCR pull token for the registry v2 API. In CI the ambient creds are
# the workflow GITHUB_TOKEN (already logged in); reuse them via docker config
# is awkward, so request an anonymous-scope token signed by our login. The
# token endpoint accepts the same basic creds docker login stored.
gh_user="${GITHUB_ACTOR:-$(whoami)}"
gh_pass="${GITHUB_TOKEN:-${CR_PAT:-}}"
if [ -z "$gh_pass" ]; then
    echo "ERROR: set GITHUB_TOKEN (or CR_PAT) so tags can be listed" >&2
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

# Follow pagination via the Link: rel="next" header. NOTE: keep grep/sed out of
# the way of `set -e` -- a single page has no Link header, and grep exiting 1
# on no-match would otherwise abort the script.
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

echo "3. Pulling each rpm-* tag and extracting RPMs into ${RPM_DIR}..."
for t in $rpm_tags; do
    [ -n "$t" ] || continue
    docker pull -q "${RPM_REPO_IMAGE}:${t}" >/dev/null
    # `docker create` records a command but never runs it for `docker cp`; a
    # scratch image has no default CMD, so supply a dummy one to satisfy create.
    cid=$(docker create "${RPM_REPO_IMAGE}:${t}" x)
    # scratch image has no shell; copy the whole rootfs (just the RPMs) out.
    docker cp "${cid}:/." "$RPM_DIR/" 2>/dev/null || true
    docker rm "$cid" >/dev/null
done
# Drop anything that isn't an RPM (scratch images contain only the .rpm files,
# but be defensive).
find "$RPM_DIR" -type f ! -name '*.rpm' -delete 2>/dev/null || true
echo "   ${RPM_DIR} now has $(ls -1 "$RPM_DIR"/*.rpm 2>/dev/null | wc -l | tr -d ' ') RPM(s)"

# --- 3. Hand off to the unchanged sync_repo.sh -----------------------------
echo "4. Handing off to sync_repo.sh..."
chmod +x "$SCRIPT_DIR/sync_repo.sh"
"$SCRIPT_DIR/sync_repo.sh"
