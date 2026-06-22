#!/bin/bash

# repo-usage.sh -- report how much space each package uses in the rpm-repo
# scratch tags, so you can spot the big consumers (e.g. epics-base) and target
# them with prune-pkg.sh.
#
#   ./repo-usage.sh            # table sorted by total size, biggest first
#
# How: every RPM is its own scratch tag (rpm-<NVRA>); the tag's image manifest
# reports the compressed layer size, which is ~the RPM size. We sum sizes and
# count tags per package NAME (grouping epics-base + epics-base-devel under
# "epics-base"). No image pulls -- just manifest HEADs, so it is fast and uses
# no disk.
#
# Requires: GITHUB_TOKEN/CR_PAT + GITHUB_ACTOR (for the registry API).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/tag-lib.sh"

gh_user="${GITHUB_ACTOR:-$(whoami)}"
gh_pass="${GITHUB_TOKEN:-${CR_PAT:-}}"
if [ -z "$gh_pass" ]; then echo "ERROR: set GITHUB_TOKEN (or CR_PAT)" >&2; exit 1; fi
basic=$(printf '%s:%s' "$gh_user" "$gh_pass" | base64 | tr -d '\n')
bearer=$(curl -s -H "Authorization: Basic $basic" \
    "https://ghcr.io/token?service=ghcr.io&scope=repository:gemini-rtsw/rpm-repo:pull" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)
[ -n "$bearer" ] || { echo "ERROR: GHCR token request failed" >&2; exit 1; }

echo "Listing scratch tags..."
tags=$(ghcr_list_rpm_tags)
total_tags=$(printf '%s\n' "$tags" | grep -c . || true)
echo "  $total_tags tag(s); fetching sizes (manifests, no pulls)..."

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
sizes="$WORK/sizes"; : > "$sizes"

# For each tag, GET its manifest and sum the layer sizes. Scratch images are
# tiny (1 layer = the RPM), so this is one small request per tag, parallelised.
fetch_size() {
    local t="$1"
    local m
    m=$(curl -s -H "Authorization: Bearer $BEARER" \
        -H "Accept: application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json" \
        "https://ghcr.io/v2/gemini-rtsw/rpm-repo/manifests/${t}")
    # sum layer sizes (bytes)
    local bytes
    bytes=$(printf '%s' "$m" | python3 -c "import json,sys
try:
    d=json.load(sys.stdin); print(sum(l.get('size',0) for l in d.get('layers',[])))
except Exception: print(0)" 2>/dev/null || echo 0)
    # package name = tag minus 'rpm-' minus version onward; collapse -devel.
    # rpm-epics-base-devel-7.0.7-... -> epics-base ; rpm-slalib-1.9.7-... -> slalib
    local name="${t#rpm-}"
    name="${name%%-[0-9]*}"        # cut at first -<digit> (start of version)
    name="${name%-devel}"          # collapse subpackage
    printf '%s\t%s\n' "$name" "$bytes"
}
export -f fetch_size
export BEARER="$bearer"

printf '%s\n' "$tags" | grep . | xargs -P 16 -I{} bash -c 'fetch_size "$@"' _ {} >> "$sizes"

echo ""
echo "=================== rpm-repo usage by package ==================="
printf '%-28s %8s  %12s\n' "PACKAGE" "TAGS" "SIZE"
echo "-----------------------------------------------------------------"
# aggregate: sum bytes + count per name, sort by bytes desc, human-readable
python3 - "$sizes" <<'PY'
import sys, collections
b=collections.defaultdict(int); c=collections.defaultdict(int)
for line in open(sys.argv[1]):
    line=line.rstrip("\n")
    if not line or "\t" not in line: continue
    name,by=line.split("\t",1)
    try: by=int(by)
    except: by=0
    b[name]+=by; c[name]+=1
def hr(n):
    for u in ("B","KB","MB","GB","TB"):
        if n<1024: return f"{n:.1f}{u}"
        n/=1024
    return f"{n:.1f}PB"
tot=0; ntag=0
for name in sorted(b, key=lambda k:-b[k]):
    print(f"{name:<28} {c[name]:>8}  {hr(b[name]):>12}")
    tot+=b[name]; ntag+=c[name]
print("-"*65)
print(f"{'TOTAL':<28} {ntag:>8}  {hr(tot):>12}")
PY
echo "================================================================="
echo "Tip: prune a big one with  ./prune-pkg.sh <package>"
