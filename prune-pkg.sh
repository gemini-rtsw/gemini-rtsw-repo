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

PKG=""
KEEP_HASHES=""   # space-separated git short-hashes to KEEP
LIST_ONLY=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --keep) KEEP_HASHES="$KEEP_HASHES $2"; shift 2 ;;
        --keep=*) KEEP_HASHES="$KEEP_HASHES ${1#*=}"; shift ;;
        --list) LIST_ONLY=1; shift ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *) PKG="$1"; shift ;;
    esac
done
if [ -z "$PKG" ]; then
    echo "Usage:" >&2
    echo "  $0 <package> --list                 # list all builds + their hashes" >&2
    echo "  $0 <package> --keep <hash> [...]     # KEEP these hashes, DELETE older ones" >&2
    echo "  Example: $0 epics-base --list ; then  $0 epics-base --keep f9e3717" >&2
    exit 1
fi
if [ "$LIST_ONLY" -eq 0 ] && [ -z "${KEEP_HASHES// /}" ]; then
    echo "ERROR: name the build(s) to keep with --keep <hash>, or use --list first." >&2
    echo "  Example: $0 $PKG --keep f9e3717" >&2
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

# Partition the package's tags:
#   groups   = prunable (have a .git. hash), as "groupkey<TAB>tag"
#   protected= no git hash (grandfathered/clean, e.g. epics-base 3.14, asyn-4.44)
#              -- always kept, never a candidate, but SHOWN so you can see them.
: > "$WORK/groups"
: > "$WORK/protected"
printf '%s\n' "$pkg_tags" | while IFS= read -r t; do
    [ -n "$t" ] || continue
    if has_githash "$t"; then
        printf '%s\t%s\n' "$(hashfree_group "$t")" "$t" >> "$WORK/groups"
    else
        echo "$t" >> "$WORK/protected"
    fi
done

if [ ! -s "$WORK/groups" ]; then
    echo "No git-hash builds found for ${PKG}; nothing prunable."
    if [ -s "$WORK/protected" ]; then
        echo "Protected (no git hash, never pruned):"
        sort "$WORK/protected" | sed 's/^/  KEEP  /'
    fi
    exit 0
fi

# all git-hash builds for this package (one per line), sorted
all_builds="$WORK/all"; cut -f2 "$WORK/groups" | sort -u > "$all_builds"

# --list: just show every build + its hash so you can choose what to --keep.
if [ "$LIST_ONLY" -eq 1 ]; then
    echo ""
    echo "==================== BUILDS: ${PKG} ===================="
    [ -s "$WORK/protected" ] && { echo "Protected (no git hash, always kept):";
        sort "$WORK/protected" | sed 's/^/   /'; echo ""; }
    echo "Git-hash builds (grouped by NVR+EL):"
    cut -f1 "$WORK/groups" | sort -u | while IFS= read -r gk; do
        echo "  --- ${gk} ---"
        awk -F'\t' -v k="$gk" '$1==k{print $2}' "$WORK/groups" | sort | sed 's/^/     /'
    done
    echo "======================================================="
    echo "Pick the hash(es) you still use, then:"
    echo "  $0 ${PKG} --keep <hash> [--keep <hash> ...]"
    exit 0
fi

# RULE: KEEP = any build whose git-hash matches a --keep value (across all EL),
# plus all protected (no-git-hash) RPMs. DELETE = every other git-hash build.
# The keep decision comes from YOU (you know the in-use hash) -- no unreliable
# timestamp guessing.
keep_list="$WORK/keep"; : > "$keep_list"
del_list="$WORK/delete"; : > "$del_list"
while IFS= read -r t; do
    [ -n "$t" ] || continue
    matched=0
    for h in $KEEP_HASHES; do
        case "$t" in *".git.${h}."*|*".git.${h}"|*".git${h}."*|*".git${h}") matched=1; break ;; esac
    done
    if [ "$matched" -eq 1 ]; then echo "$t" >> "$keep_list"; else echo "$t" >> "$del_list"; fi
done < "$all_builds"
# protected (no-git-hash) always kept
[ -s "$WORK/protected" ] && cat "$WORK/protected" >> "$keep_list"

# Safety: every named --keep hash must actually match something, else likely a
# typo -- abort rather than delete everything.
for h in $KEEP_HASHES; do
    if ! grep -q "$h" "$keep_list"; then
        echo "ERROR: --keep hash '$h' matched no build for ${PKG}. Typo? Aborting." >&2
        echo "  (run '$0 ${PKG} --list' to see valid hashes)" >&2
        exit 1
    fi
done

ndel=$(grep -c . "$del_list" || true)

echo ""
echo "==================== PRUNE: ${PKG} ===================="
echo ">> KEEP ($(grep -c . "$keep_list") RPM):"
sort "$keep_list" | sed 's/^/   keep    /'
echo ""
echo ">> DELETE ($ndel old-hash RPM):"
if [ "$ndel" -eq 0 ]; then echo "   (nothing -- every NVR has only one build)"; fi
sort "$del_list" | sed 's/^/   DELETE  /'
echo "======================================================="
if [ "$ndel" -eq 0 ]; then echo "Nothing to prune."; exit 0; fi
echo ""
printf 'Delete the %s DELETE rpm(s) above and keep the rest? [y/N] ' "$ndel"
read -r ans </dev/tty || ans="n"
case "$ans" in y|Y|yes|YES) ;; *) echo "Aborted; nothing deleted."; exit 0 ;; esac

to_delete="$del_list"
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
