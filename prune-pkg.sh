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
    echo "Usage: $0 <package>   (e.g. epics-base, rtems)" >&2
    exit 1
fi

RPM_REPO_IMAGE="ghcr.io/gemini-rtsw/rpm-repo"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/tag-lib.sh"

# Resolve GITHUB_TOKEN/GITHUB_ACTOR up front (from env, gh, or docker login) so
# they're available to the upload-time query below. Without this, set -u trips.
ghcr_resolve_creds || exit 1

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

# nvr_no_el GROUPKEY -> the "name|rel|arch" with EL removed, so el8 and el9 of
# the same package share ONE key (and therefore ONE chosen keeper hash). The
# group key from hashfree_group is "rel|el|arch"; drop the middle (el) field.
nvr_no_el() { printf '%s|%s' "${1%%|*}" "${1##*|}"; }

# extract git short-hash from a tag (after .git. , drop el/arch suffix)
declare_hash() {
    case "$1" in
        *.git.*) local r="${1##*.git.}"; r="${r%%.el[0-9]*}"; r="${r%.x86_64}"; r="${r%.noarch}"; printf '%s' "$r" ;;
        *) printf '' ;;
    esac
}

# LATEST = newest CONTAINER (the GHCR scratch image's upload time). No git, no
# GitHub repo, no specs -- just the registry. Fetch every tag's created_at once
# from the GHCR package-versions API (token already resolved).
echo "Fetching container upload times..."
created="$WORK/created"; : > "$created"   # "tag<TAB>YYYYMMDDhhmmss"
python3 - "$GITHUB_TOKEN" "$created" <<'PY' 2>/dev/null || true
import json,urllib.request,sys,re
tok,out=sys.argv[1],sys.argv[2]; page=1; rows=[]
while True:
    req=urllib.request.Request(
        f"https://api.github.com/orgs/gemini-rtsw/packages/container/rpm-repo/versions?per_page=100&page={page}",
        headers={"Authorization":f"Bearer {tok}","Accept":"application/vnd.github+json"})
    try: d=json.load(urllib.request.urlopen(req))
    except Exception: break
    if not isinstance(d,list) or not d: break
    for v in d:
        c=re.sub(r'\D','',v.get('created_at','') or '')   # ISO -> sortable digits
        for t in (v.get('metadata',{}).get('container',{}).get('tags') or []):
            rows.append((t,c))
    if len(d)<100: break
    page+=1
with open(out,'w') as f:
    for t,c in rows: f.write(f"{t}\t{c or 0}\n")
PY
ct_of() { awk -F'\t' -v k="$1" '$1==k{print $2; exit}' "$created"; }

# sort_by_date FILE -> prints the tags in FILE newest-upload first. Prepends
# each tag's upload time, numeric-sorts descending, strips the time.
sort_by_date() {
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        c=$(ct_of "$t"); case "$c" in ''|*[!0-9]*) c=0 ;; esac
        printf '%s\t%s\n' "$c" "$t"
    done < "$1" | sort -t$'\t' -k1,1nr | cut -f2-
}

# Keeper per NVR (ignoring EL, so el8+el9 keep the SAME hash) = the hash whose
# container was uploaded most recently. Rank by upload time.
keeper_hash="$WORK/keeper_hash"; : > "$keeper_hash"   # "nvr_no_el<TAB>hash"
cut -f1 "$WORK/groups" | while IFS= read -r gk; do nvr_no_el "$gk"; echo; done \
    | sort -u | while IFS= read -r nk; do
    [ -n "$nk" ] || continue
    best="" bct=-1
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        [ "$(nvr_no_el "$(hashfree_group "$t")")" = "$nk" ] || continue
        h=$(declare_hash "$t"); [ -n "$h" ] || continue
        ct=$(ct_of "$t"); case "$ct" in ''|*[!0-9]*) ct=0 ;; esac
        if [ "$ct" -gt "$bct" ]; then bct="$ct"; best="$h"; fi
    done < <(cut -f2 "$WORK/groups")
    [ -n "$best" ] && printf '%s\t%s\n' "$nk" "$best" >> "$keeper_hash"
done

# KEEP = the newest-container hash for each NVR (consistent across ELs).
# DELETE = every older hash.
keep_list="$WORK/keep"; : > "$keep_list"
del_list="$WORK/delete"; : > "$del_list"
while IFS= read -r t; do
    [ -n "$t" ] || continue
    th=$(declare_hash "$t")
    nk=$(nvr_no_el "$(hashfree_group "$t")")
    kh=$(awk -F'\t' -v k="$nk" '$1==k{print $2; exit}' "$keeper_hash")
    if [ -n "$kh" ] && [ "$th" = "$kh" ]; then echo "$t" >> "$keep_list"; else echo "$t" >> "$del_list"; fi
done < <(cut -f2 "$WORK/groups" | sort -u)
# protected (no-git-hash) always kept
[ -s "$WORK/protected" ] && cat "$WORK/protected" >> "$keep_list"

ndel=$(grep -c . "$del_list" || true)

echo ""
echo "==================== PRUNE: ${PKG} ===================="
echo ">> KEEP ($(grep -c . "$keep_list") RPM), newest first:"
sort_by_date "$keep_list" | sed 's/^/   keep    /'
echo ""
if [ "$ndel" -eq 0 ]; then
    echo ">> DELETE (0): nothing -- every NVR has only one build."
    echo "======================================================="
    echo "Nothing to prune."; exit 0
fi

# Numbered DELETE list (newest upload first) -- scroll and pick any to EXCLUDE.
sort_by_date "$del_list" > "$WORK/del_sorted"
echo ">> DELETE candidates ($ndel) -- numbered, newest first:"
nl -w3 -s'  ' "$WORK/del_sorted" | sed 's/^/   /'
echo "======================================================="
echo ""
echo "Enter the NUMBERS to EXCLUDE (keep), space-separated (e.g. 2 5 9),"
printf 'or press Enter to delete ALL listed: '
read -r picks </dev/tty || picks=""

# Move excluded numbers from delete -> keep.
final_del="$WORK/final_del"; : > "$final_del"
i=0
while IFS= read -r line; do
    i=$((i+1))
    keepit=0
    for p in $picks; do [ "$p" = "$i" ] && keepit=1 && break; done
    if [ "$keepit" -eq 1 ]; then echo "$line" >> "$keep_list"; else echo "$line" >> "$final_del"; fi
done < "$WORK/del_sorted"
del_list="$final_del"
ndel=$(grep -c . "$del_list" || true)

echo ""
if [ "$ndel" -eq 0 ]; then echo "Everything excluded; nothing to delete."; exit 0; fi

# ---- VERIFY SCREEN (final confirmation before any deletion) ----
echo "##############################################################"
echo "#                    FINAL VERIFY -- ${PKG}"
echo "#  This permanently removes the DELETE scratch tags from GHCR."
echo "##############################################################"
echo "## KEEP ($(grep -c . "$keep_list")), newest first:"
sort_by_date "$keep_list" | sed 's/^/   keep    /'
echo "##############################################################"
echo "## DELETE ($ndel), newest first:"
sort_by_date "$del_list" | sed 's/^/   DELETE  /'
echo "##############################################################"
echo ""
printf 'Type DELETE (all caps) to remove these %s rpm(s), anything else aborts: ' "$ndel"
read -r ans </dev/tty || ans=""
if [ "$ans" != "DELETE" ]; then echo "Aborted; nothing deleted."; exit 0; fi

to_delete="$del_list"
echo "Deleting tags..."
while IFS= read -r t; do
    [ -n "$t" ] || continue
    if ghcr_delete_tag "$t"; then echo "  deleted $t"; else echo "  FAILED  $t (continuing)"; fi
done < "$to_delete"

echo ""
echo "Triggering the rebuild-latest workflow on GitHub (runs on a runner --"
echo "we do NOT rebuild the multi-GB images locally)..."
# Dispatch the rebuild-latest workflow with allow_shrink=true so its sync_repo.sh
# run is prune-aware (the anti-truncation guard permits this intentional shrink).
# Needs a token with 'workflow'/actions:write scope.
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/gemini-rtsw/gemini-rtsw-repo/actions/workflows/rebuild-latest.yml/dispatches" \
    -d '{"ref":"master","inputs":{"allow_shrink":"true"}}')
case "$code" in
    20[0-9]) echo "Dispatched. Watch: Actions -> rebuild-latest. The pruned RPMs leave"
             echo "the served images once it completes." ;;
    *) echo "WARN: workflow dispatch returned HTTP $code." >&2
       echo "  Tags were deleted, but the images weren't rebuilt. Trigger it manually:" >&2
       echo "  Actions -> rebuild-latest -> Run workflow (allow_shrink = true)." >&2 ;;
esac
echo "Prune complete for ${PKG} (deletions done; rebuild running on GitHub)."
