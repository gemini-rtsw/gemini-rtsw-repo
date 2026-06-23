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

# tag_hash TAG -> the git short-hash in the tag, or "" if none.
# A hash is a 7-40 char hex token that CONTAINS at least one letter a-f (so it
# can't be confused with a pure-numeric version/release field). This covers
# every release format we use:
#   epics-base-7.0.7-0.git.f9e3717   -> f9e3717   (.git.<hash>)
#   rtems-6.2-0.83035d4              -> 83035d4   (0.<hash>, no .git.)
#   rtems-6-d111efb.1_rc2           -> d111efb
#   asyn-4.44-1 / epics-base-3.14.12-8 -> ""       (grandfathered, no hash)
tag_hash() {
    printf '%s\n' "$1" | grep -oE '[0-9a-f]{7,40}' | grep -E '[a-f]' | grep -vE '^[0-9]+$' | head -1
}

# hashfree_group TAG -> "rel|el|arch" identity with the hash blanked + EL
# removed, so different builds of the same package/version (and el8 vs el9)
# collapse to one group.
hashfree_group() {
    local t="$1" body el arch h
    body="${t#rpm-}"
    arch="${body##*.}"; body="${body%.*}"          # peel .arch
    case "$body" in
        *.el[0-9]*) el="el${body##*.el}"; el="${el%%.*}"; el="el${el#el}"; body="${body%.el[0-9]*}" ;;
        *) el="noel" ;;
    esac
    h=$(tag_hash "$body")
    [ -n "$h" ] && body=$(printf '%s' "$body" | sed "s/$h/HASH/")
    printf '%s|%s|%s' "$body" "$el" "$arch"
}

# has_githash TAG -> 0 if the tag carries a hash (prunable), 1 if not
# (grandfathered/clean -- never a candidate).
has_githash() { [ -n "$(tag_hash "$1")" ]; }

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

# extract the git short-hash from a tag (handles .git.<h> and 0.<h> forms);
# delegates to tag_hash so all hash detection stays in one place.
declare_hash() { tag_hash "$1"; }

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

# Hand off to CI: the local box only picked the list. Build a space-joined tag
# list and dispatch the `prune` workflow, which deletes the tags AND rebuilds
# the image ON A RUNNER (proper token + bandwidth; nothing heavy runs locally).
tags_str=$(tr '\n' ' ' < "$del_list" | sed 's/  */ /g; s/^ //; s/ $//')

# GUARD: workflow_dispatch inputs are limited (GitHub caps a single input around
# 65535 chars / the whole inputs object similarly). Refuse rather than send a
# truncated list that would leave tags un-deleted or mis-parsed. ~50 chars/tag,
# so the practical ceiling is well over a thousand tags -- but check explicitly.
LIMIT=60000
len=${#tags_str}
if [ "$len" -gt "$LIMIT" ]; then
    echo "" >&2
    echo "WARNING: the delete list is too large to send to the CI job in one go." >&2
    echo "  ($ndel tags, ${len} chars; the workflow_dispatch input limit is ~${LIMIT})." >&2
    echo "  Nothing was deleted. Prune in smaller batches (exclude more this run)," >&2
    echo "  or run fewer NVRs at a time." >&2
    exit 1
fi

echo ""
echo "Dispatching the 'prune' workflow on GitHub (deletes tags + rebuilds image"
echo "on a runner -- nothing heavy runs locally). Needs a token with 'workflow'"
echo "(actions:write) scope."
payload=$(python3 -c "import json,sys; print(json.dumps({'ref':'master','inputs':{'tags':sys.argv[1],'allow_shrink':'true'}}))" "$tags_str")
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/gemini-rtsw/gemini-rtsw-repo/actions/workflows/prune.yml/dispatches" \
    -d "$payload")
case "$code" in
    20[0-9]) echo "Dispatched. Watch: Actions -> prune. It deletes the $ndel tag(s) and"
             echo "rebuilds the image. Nothing was changed locally." ;;
    *) echo "WARN: prune-workflow dispatch returned HTTP $code -- nothing deleted." >&2
       echo "  Likely the token lacks 'workflow' scope, or prune.yml isn't on master yet." >&2
       echo "  You can run it manually: Actions -> prune -> Run workflow, paste the tags." >&2
       exit 1 ;;
esac
echo "Prune dispatched for ${PKG}."
