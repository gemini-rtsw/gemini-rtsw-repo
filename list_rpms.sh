#!/bin/bash

# list_rpms.sh -- list the RPM scratch tags, one line per RPM.
#
#   ./list_rpms.sh                 # everything
#   ./list_rpms.sh epics-base      # only names containing "epics-base"
#   ./list_rpms.sh --no-size foo   # skip the size column (much faster)
#
# The tag name IS the RPM filename, so the full NVR and git hash are right
# there. Sizes come from each tag's manifest -- nothing is pulled.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/tag-lib.sh"

SIZES=1
if [ "${1:-}" = "--no-size" ]; then SIZES=0; shift; fi
PATTERN="${1:-}"

ghcr_resolve_creds || exit 1

tags=$(ghcr_list_rpm_tags | sed 's/^rpm-//' | sort)
if [ -n "$PATTERN" ]; then
    tags=$(printf '%s\n' "$tags" | grep -i -- "$PATTERN" || true)
fi
if [ -z "$tags" ]; then echo "No RPMs match '${PATTERN}'." >&2; exit 1; fi

# A tag not ending in an arch is a leftover pre-migration tag holding SEVERAL
# RPMs. Deleting an RPM that one of these also holds will not shrink the repo.
mark_of() {
    case "$1" in
        *.x86_64|*.i686|*.noarch) echo "" ;;
        *) echo "  [bundle: holds several RPMs]" ;;
    esac
}

if [ "$SIZES" = "0" ]; then
    while IFS= read -r n; do printf '%s%s\n' "$n" "$(mark_of "$n")"; done <<< "$tags"
else
    basic=$(printf '%s:%s' "$GITHUB_ACTOR" "$GITHUB_TOKEN" | base64 | tr -d '\n')
    BEARER=$(curl -s -H "Authorization: Basic $basic" \
        "https://ghcr.io/token?service=ghcr.io&scope=repository:gemini-rtsw/rpm-repo:pull" \
        | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
    [ -n "$BEARER" ] || { echo "ERROR: GHCR token request failed" >&2; exit 1; }

    line_for() {
        local n="$1" bytes hum
        bytes=$(curl -s -H "Authorization: Bearer $BEARER" \
            -H 'Accept: application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json' \
            "https://ghcr.io/v2/gemini-rtsw/rpm-repo/manifests/rpm-${n}" \
            | tr -d ' ' | tr ',' '\n' | sed -n 's/.*"size":\([0-9][0-9]*\).*/\1/p' \
            | awk '{s+=$1} END{print s+0}')
        hum=$(awk -v b="$bytes" 'BEGIN{split("B KB MB GB",u," ");i=1;
              while(b>=1024&&i<4){b/=1024;i++} printf "%.1f%s",b,u[i]}')
        printf '%-58s %9s%s\n' "$n" "$hum" "$(mark_of "$n")"
    }
    export -f line_for mark_of
    export BEARER
    printf '%s\n' "$tags" | xargs -P 16 -I{} bash -c 'line_for "$@"' _ {} | sort
fi

echo "---"
echo "$(printf '%s\n' "$tags" | wc -l | tr -d ' ') rpm(s). Delete with: ./prune-pkg.sh <name>"
