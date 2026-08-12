#!/bin/bash

# prune-pkg.sh -- delete RPM scratch tags by name.
#
#   ./prune-pkg.sh epics-base-7.0.7-0.git.f9e3717.el8.x86_64
#   ./prune-pkg.sh 'softTCS_mk-0.1-34.git.*'      # glob -- QUOTE it
#
# Names are exactly as ./list_rpms.sh prints them. A name matching nothing
# aborts the run.
#
# The deleting happens in the `prune` GitHub workflow, because a local token
# cannot delete packages (that needs delete:packages). That workflow rebuilds
# :latest afterwards, which takes ~20 minutes -- so name EVERY tag you want gone
# in one run, and you pay for one rebuild instead of one per tag.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/tag-lib.sh"

[ $# -gt 0 ] || { echo "usage: $0 <name>...   (names from ./list_rpms.sh, globs ok)" >&2; exit 1; }

ghcr_resolve_creds || exit 1
all=$(ghcr_list_rpm_tags)

# Match each name against the tag list. An unquoted $name in `case` glob-matches,
# so a plain name matches itself and a glob matches many.
sel=""
for name in "$@"; do
    hits=""
    while IFS= read -r t; do
        case "${t#rpm-}" in $name) hits="${hits}${t}"$'\n' ;; esac
    done <<< "$all"
    [ -n "$hits" ] || { echo "ERROR: nothing matches '$name' -- nothing deleted." >&2; exit 1; }
    sel="${sel}${hits}"
done
sel=$(printf '%s' "$sel" | grep . | sort -u)
count=$(printf '%s\n' "$sel" | wc -l | tr -d ' ')

echo ""
echo "Delete these $count scratch tag(s) permanently:"
printf '%s\n' "$sel" | sed 's/^rpm-/  /'
if printf '%s\n' "$sel" | grep -qvE '\.(x86_64|i686|noarch)$'; then
    echo ""
    echo "WARNING: that list includes a leftover tag holding SEVERAL RPMs."
fi

echo ""
printf 'Type DELETE to confirm: '
read -r ans </dev/tty || ans=""
[ "$ans" = "DELETE" ] || { echo "Aborted; nothing deleted."; exit 0; }

printf 'Submit to GitHub? [y/N]: '
read -r go </dev/tty || go=""
case "$go" in [Yy]*) ;; *) echo "Aborted; nothing deleted."; exit 0 ;; esac

# Tag names are [A-Za-z0-9._-] only, so this is safe to paste into JSON.
tags=$(printf '%s ' $sel)
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/gemini-rtsw/gemini-rtsw-repo/actions/workflows/prune.yml/dispatches" \
    -d "{\"ref\":\"master\",\"inputs\":{\"tags\":\"$tags\",\"allow_shrink\":\"true\"}}")

echo ""
case "$code" in
    20[0-9])
        echo "Deleting $count tag(s), then rebuilding :latest (~20 min)."
        echo "Watch: Actions -> prune. The image shrinks when it finishes." ;;
    *)
        echo "FAILED: dispatch returned HTTP $code -- nothing was deleted." >&2
        echo "Run it by hand: Actions -> prune -> Run workflow, and paste:" >&2
        echo "$tags" >&2
        exit 1 ;;
esac
