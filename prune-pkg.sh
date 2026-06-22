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

# NO auto-keeper. We deliberately do NOT try to pick "the newest" to keep:
#  - a git hash is not chronologically ordered, and
#  - GHCR created_at is unreliable here (the one-time backfill batch-created all
#    tags with ~identical timestamps), and
#  - which hash is actually in use is unknowable (pins span branches, release
#    tags, and repos outside this org).
# Guessing a keeper risks offering the IN-USE hash for deletion (it did, for
# epics-base f9e3717.el8). So instead: present EVERY git-hash build, GROUPED by
# NVR+EL so you can see how many share an identity, and YOU choose what to keep.
# Default is always KEEP; nothing goes without your explicit per-RPM "d".
#
# Build a display list: for each group with >1 build, list all its tags.
candidates="$WORK/candidates"; : > "$candidates"
echo ""
echo "================ PRUNE PREVIEW: ${PKG} ================"
echo "Every git-hash build below is a candidate. Builds are grouped by"
echo "NVR+EL (same identity, different commit). YOU pick what to delete;"
echo "default is KEEP. (Grandfathered/clean RPMs without a .git. hash are"
echo "not shown -- they are never pruned.)"
cut -f1 "$WORK/groups" | sort -u | while IFS= read -r gk; do
    grp=$(awk -F'\t' -v k="$gk" '$1==k{print $2}' "$WORK/groups" | sort)
    cnt=$(printf '%s\n' "$grp" | grep -c .)
    echo ""
    echo "  --- group: ${gk} (${cnt} build(s)) ---"
    printf '%s\n' "$grp" | sed 's/^/      /'
    printf '%s\n' "$grp" >> "$candidates"
done
ncand=$(grep -c . "$candidates" || true)
echo ""
echo "======================================================="
echo "$ncand build(s) across all groups. Confirm each (default = KEEP)."
echo "Tip: within a group, keep the hash you still build/pin; delete the rest."
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
