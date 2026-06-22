#!/bin/bash

# prune-pkg.sh -- targeted, interactive pruning of OLD git-hash builds of ONE
# package from the rpm-repo scratch tags, to reclaim space.
#
#   ./prune-pkg.sh epics-base
#   ./prune-pkg.sh rtems
#
# What it does:
#   1. Lists every rpm-* scratch tag for the given package (and its subpackages,
#      e.g. epics-base + epics-base-devel).
#   2. Groups them by NVR-without-the-git-hash + EL + arch. Within each group it
#      KEEPS the newest git-hash build and marks the older hashes as prune
#      candidates (keep-newest-1).
#   3. Shows a PREVIEW, then prompts per candidate: [d]elete / [k]eep / [q]uit.
#      Default is KEEP (press Enter) -- you must explicitly choose delete.
#   4. Deletes only the tags you confirmed, then rebuilds the served :latest
#      image so the pruned RPMs leave the repo (prune-aware: the anti-truncation
#      guard is told the shrink is intentional).
#
# SAFETY: there is NO automated "is this pinned?" check -- pins live across many
# branches/tags and even in repos OUTSIDE this GitHub org, so it is impossible
# to know for sure. YOU are the safety net: review the preview, keep anything a
# release/consumer might still need. Nothing is deleted without your per-RPM
# confirmation. The grandfathered EL-agnostic RPMs (no .git. in the release) are
# never offered as candidates.
#
# Requires: docker, gh (authenticated, with delete:packages), GITHUB_TOKEN/
# CR_PAT + GITHUB_ACTOR for tag listing.

set -euo pipefail

PKG="${1:-}"
if [ -z "$PKG" ]; then
    echo "Usage: $0 <package-name>   (e.g. epics-base, rtems)" >&2
    exit 1
fi

RPM_REPO_IMAGE="ghcr.io/gemini-rtsw/rpm-repo"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/tag-lib.sh"

echo "Listing scratch tags for '${PKG}'..."
# Match the package and its subpackages: rpm-<PKG>... and rpm-<PKG>-devel...
# Anchor on "rpm-<PKG>-" so "epics-base" doesn't also match an unrelated pkg.
all_tags=$(ghcr_list_rpm_tags)
pkg_tags=$(printf '%s\n' "$all_tags" | grep -E "^rpm-${PKG}(-devel)?-[0-9]" || true)
n=$(printf '%s\n' "$pkg_tags" | grep -c . || true)
echo "  found $n tag(s) for ${PKG}"
if [ "$n" -eq 0 ]; then echo "Nothing to do."; exit 0; fi

# group_key TAG -> "name|version-releasebase|el|arch" with the .git.<hash>
# stripped from the release. Tags look like:
#   rpm-epics-base-devel-7.0.7-0.git.f9e3717.el8.x86_64
#   rpm-slalib-devel-1.9.7-6.git.67.7872e05.el8.x86_64
#   rpm-asyn-4.44-1.x86_64                     (no el, no git hash)
# We strip a trailing ".el<N>.<arch>" off, remember el+arch, then strip a
# ".git.*" or ".git<...>" segment from what's left to get the hash-free key.
hashfree_group() {
    local t="$1" body el arch rel
    body="${t#rpm-}"                       # drop leading rpm-
    # peel arch (last dot-field) and el (the .elN. before arch), if present
    arch="${body##*.}"                      # x86_64 / noarch
    body="${body%.*}"                       # drop .arch
    case "$body" in
        *.el[0-9]*) el="el${body##*.el}"; el="${el%%.*}"; el="el${el#el}"; body="${body%.el[0-9]*}" ;;
        *) el="noel" ;;
    esac
    # body is now name-version-release(.git.<hash>?). Strip the git-hash segment.
    # The hash segment is ".git." onward (covers .git.<h> and .git.<n>.<h>).
    case "$body" in
        *.git.*) rel="${body%%.git.*}" ;;   # everything before .git.
        *.git*)  rel="${body%%.git*}" ;;    # rare ".git<h>" malformed form
        *)       rel="$body" ;;             # no git hash -> grandfathered
    esac
    printf '%s|%s|%s' "$rel" "$el" "$arch"
}

# has_githash TAG -> 0 if the tag carries a .git hash (prunable), 1 if not
# (grandfathered/clean -- never a candidate).
has_githash() { case "$1" in *.git.*|*.git[0-9a-f]*) return 0 ;; *) return 1 ;; esac; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# Build: groups file with "groupkey<TAB>tag" for prunable (git-hash) tags only.
: > "$WORK/groups"
printf '%s\n' "$pkg_tags" | while IFS= read -r t; do
    [ -n "$t" ] || continue
    if has_githash "$t"; then
        printf '%s\t%s\n' "$(hashfree_group "$t")" "$t" >> "$WORK/groups"
    fi
done

if [ ! -s "$WORK/groups" ]; then
    echo "No git-hash builds found for ${PKG} (only grandfathered/clean RPMs); nothing prunable."
    exit 0
fi

# For each group, the KEEPER is the NEWEST tag by GHCR creation time -- NOT by
# version/hash sort, because a git hash is not chronologically ordered (it would
# pick the alphabetically-highest hash, which may be an older commit). We query
# each tag's created_at once and cache it. If a timestamp can't be determined,
# that tag is treated as a CANDIDATE (offered for review) rather than silently
# kept -- you confirm every deletion anyway.
echo "Determining newest build per group (by GHCR creation time)..."
created="$WORK/created"; : > "$created"   # "tag<TAB>iso8601"
gh api --paginate "/orgs/gemini-rtsw/packages/container/rpm-repo/versions" \
    --jq '.[] | .created_at as $c | .metadata.container.tags[]? | "\(.)\t\($c)"' \
    2>/dev/null | grep -E '^rpm-' > "$created" || true

ts_of() {  # tag -> sortable timestamp ("" if unknown)
    awk -F'\t' -v t="$1" '$1==t{print $2; exit}' "$created"
}

candidates="$WORK/candidates"; : > "$candidates"
keepers="$WORK/keepers"; : > "$keepers"
cut -f1 "$WORK/groups" | sort -u | while IFS= read -r gk; do
    grp=$(awk -F'\t' -v k="$gk" '$1==k{print $2}' "$WORK/groups")
    # pick keeper = max created_at; tags with unknown ts can't be the keeper
    keeper=""; keeper_ts=""
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        cts=$(ts_of "$t")
        [ -n "$cts" ] || continue
        if [ -z "$keeper_ts" ] || [ "$cts" \> "$keeper_ts" ]; then keeper="$t"; keeper_ts="$cts"; fi
    done <<< "$grp"
    # Fallback: if NO timestamps were found for the whole group, keep the
    # version-sorted last (better than deleting all of them).
    [ -n "$keeper" ] || keeper=$(printf '%s\n' "$grp" | sort -V | tail -1)
    echo "$keeper" >> "$keepers"
    printf '%s\n' "$grp" | grep -vxF "$keeper" >> "$candidates" || true
done

ncand=$(grep -c . "$candidates" || true)
echo ""
echo "================ PRUNE PREVIEW: ${PKG} ================"
echo "Keeping (newest per NVR-group):"
sort "$keepers" | sed 's/^/  KEEP  /'
echo ""
echo "Prune candidates (older git-hashes):"
if [ "$ncand" -eq 0 ]; then
    echo "  (none -- every group has only one build)"; echo "Nothing to prune."; exit 0
fi
sort "$candidates" | sed 's/^/  PRUNE? /'
echo "======================================================="
echo "$ncand candidate(s). You will confirm each one (default = KEEP)."
echo ""

# Interactive per-candidate prompt. Default (Enter) = KEEP.
to_delete="$WORK/to_delete"; : > "$to_delete"
while IFS= read -r t; do
    [ -n "$t" ] || continue
    ans=""
    printf '  delete %s ? [d/K/q] ' "$t"
    read -r ans </dev/tty || ans="q"
    case "$ans" in
        d|D) echo "$t" >> "$to_delete"; echo "    -> will DELETE" ;;
        q|Q) echo "    -> quit; proceeding with selections so far"; break ;;
        *)   echo "    -> keep" ;;
    esac
done < <(sort "$candidates")

ndel=$(grep -c . "$to_delete" || true)
echo ""
if [ "$ndel" -eq 0 ]; then echo "No tags selected for deletion. Done."; exit 0; fi
echo "About to DELETE these $ndel tag(s):"
sed 's/^/  /' "$to_delete"
printf 'Type "DELETE" to confirm: '
read -r final </dev/tty || final=""
if [ "$final" != "DELETE" ]; then echo "Aborted; nothing deleted."; exit 0; fi

echo "Deleting tags..."
while IFS= read -r t; do
    [ -n "$t" ] || continue
    if ghcr_delete_tag "$t"; then echo "  deleted $t"; else echo "  FAILED  $t (continuing)"; fi
done < "$to_delete"

echo ""
echo "Rebuilding :latest so pruned RPMs leave the served repo..."
echo "(prune-aware: the anti-truncation guard is allowed to shrink this once)"
chmod +x "$SCRIPT_DIR/sync_repo.sh"
PRUNE_REBUILD=1 "$SCRIPT_DIR/sync_repo.sh"
echo "Prune complete for ${PKG}."
