#!/bin/bash

# fast_publish.sh -- INCREMENTAL publish of the served yum image.
#
# Same end result as sync_repo.sh, reached without rebuilding the whole image:
# pull the current :latest, add only the RPMs that are not in it yet, merge the
# metadata, `docker commit`, push. Nothing is re-snapshotted, re-exported or
# re-timestamp-rewritten, so the disk cost is the pull plus the new RPMs
# instead of ~5x the repo size.
#
# WHY THIS EXISTS (REL-5019). sync_repo.sh always builds FROM nginx:alpine, so
# every publish re-derives all ~8GB of bucket layers even though ~all of them
# are byte-identical to what GHCR already holds. BuildKit needs roughly five
# concurrent copies of the RPM set to do that (build context on disk, context
# snapshot in the builder, bucket snapshots, exported layers, and the
# rewrite-timestamp duplicate of those layers) -- ~40GB against the ~43GB a
# cleaned 72GB GitHub runner offers. Runners come in 72GB and 145GB flavours
# with no way to ask for one, so publishes were failing on a coin flip:
#   ERROR: ... /var/lib/buildkit/.../ingest/...: no space left on device
#
# SAFETY MODEL. The scratch tags remain the single source of truth; this script
# only changes how :latest is assembled from them. Everything here is
# best-effort: ANY doubt -- pull failure, too many new RPMs, too many layers, a
# failed verification -- falls through to sync_repo.sh, which still
# deterministically reconstructs the full repo from the tag set. The worst case
# is therefore today's behaviour, never something worse.
#
# TAGS DO NOT MAP 1:1 TO FILES. Most tags are rpm-<NVRA> holding that one RPM,
# but ~22 legacy tags are bare package names (rpm-abdf1, rpm-timeProbe, ...)
# holding SEVERAL RPMs whose filenames have nothing to do with the tag name.
# So a tag name is only a HINT about what might be missing: we pull anything
# that looks unaccounted for and then decide what is genuinely new from the
# filenames actually extracted. Those bundles are re-pulled every run (they are
# small and can never be "resolved" by name), which is the price of not keeping
# a side index of tag->contents.
#
# Deliberately NOT done here:
#   * Removals. An added layer can hide a file (whiteout) but its bytes stay in
#     the base layers, so pull size would never shrink. A prune must reclaim,
#     so it stays with prune-pkg.sh -> sync_repo.sh (PRUNE_REBUILD=1). If tags
#     disappeared without a rebuild we just warn and leave the extras alone.
#   * The rpm-count-* marker. sync_repo.sh's anti-truncation guard reads it and
#     refuses to publish a shrink; if this script ever wrote a too-high count it
#     would block the very fallback it depends on. sync_repo.sh keeps sole
#     ownership. A stale-low marker is harmless (the guard only blocks shrinks).
#
# Usage (same as sync_repo.sh -- no arguments):
#   FAST_PUBLISH=1 ./fast_publish.sh
# With the gate unset it immediately delegates, so wiring this into CI is a
# behavioural no-op until someone opts in.
#
# Requires: docker, GHCR auth, GITHUB_TOKEN (or CR_PAT) for the tag-list API.

set -euo pipefail

# Byte collation for every sort/comm below. The whole script is set arithmetic
# over RPM filenames, and comm(1) silently produces nonsense if its two inputs
# were sorted under different collations. Locale collation also folds case at
# the primary level -- and tag-lib.sh documents that case is significant here
# (gemUtil, AbDf1, geminiRec, drvSerial, enetPLC5 differ only by case), so a
# locale-aware `sort -u` could merge two genuinely distinct RPMs.
export LC_ALL=C

RPM_REPO_IMAGE="ghcr.io/gemini-rtsw/rpm-repo"
REPO_PATH="/usr/share/nginx/html/rpm-repo"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/tag-lib.sh"

# PUBLISH_TAG mirrors sync_repo.sh: override the published tag to exercise this
# path end to end -- real tag set, real image -- without touching :latest.
PUBLISH_TAG="${PUBLISH_TAG:-latest}"

# The gate. Default OFF: the CI workflow can call this script before anyone has
# decided to trust it, and get exactly the old behaviour.
FAST_PUBLISH="${FAST_PUBLISH:-0}"

# Escalation thresholds.
#   MAX_LAYERS -- each commit adds one layer, against Docker's ~127 practical
#     ceiling. :latest sits at 43 today (8 base + 2 RUN + 32 buckets + repodata),
#     so ~57 fast publishes fit before a full rebuild compacts back down.
#   MAX_CANDIDATES -- cap on how many tags we are willing to pull. The ~22
#     legacy bundle tags are candidates on EVERY run, so this floor is never
#     zero; the default leaves generous room above it.
#   MAX_ADD -- cap on genuinely new RPMs, checked after extraction and before
#     anything is mutated. A large delta means something unusual (a backfill, a
#     long outage, a first run); rebuilding is cheaper and safer than stacking a
#     huge layer.
MAX_LAYERS="${MAX_LAYERS:-100}"
MAX_CANDIDATES="${MAX_CANDIDATES:-150}"
MAX_ADD="${MAX_ADD:-50}"

WORK="./fast-${PUBLISH_TAG}"
CID=""

cleanup() {
    [ -n "$CID" ] && docker rm -f "$CID" >/dev/null 2>&1
    rm -rf "$WORK"
    return 0
}
trap cleanup EXIT

# fallback REASON... -- hand the whole publish to sync_repo.sh and never return.
# Cleanup runs first so the rebuild starts with the disk we were holding.
fallback() {
    echo ""
    echo "==> FALLBACK to full rebuild: $*"
    echo ""
    cleanup; trap - EXIT
    exec "$SCRIPT_DIR/sync_repo.sh"
}

[ "$FAST_PUBLISH" = "1" ] || fallback "FAST_PUBLISH is not set to 1"

echo "fast_publish: incremental publish of ${RPM_REPO_IMAGE}:${PUBLISH_TAG}"
df -h / 2>/dev/null || true
mkdir -p "$WORK"

# --- 1. The tag set --------------------------------------------------------
echo "1. Listing rpm-* scratch tags..."
rpm_tags=$(ghcr_list_rpm_tags) || fallback "could not list scratch tags"
printf '%s\n' "$rpm_tags" | grep . | sort -u > "$WORK/tags.txt"
TAG_COUNT=$(wc -l < "$WORK/tags.txt" | tr -d ' ')
[ "$TAG_COUNT" -gt 0 ] || fallback "no rpm-* tags found"
# The name a tag WOULD have if it holds exactly one RPM. A hint, not a fact.
sed 's/^rpm-//; s/$/.rpm/' "$WORK/tags.txt" | sort -u > "$WORK/derived.txt"
echo "   $TAG_COUNT tag(s)"

# --- 2. What the image holds today ----------------------------------------
# No overrides on `docker run`: a run-time --entrypoint/cmd would be baked into
# the committed image's config and silently replace nginx as what the image
# runs. Starting it normally (nginx serves, harmlessly) keeps the config intact.
echo "2. Pulling ${RPM_REPO_IMAGE}:${PUBLISH_TAG}..."
docker pull -q "${RPM_REPO_IMAGE}:${PUBLISH_TAG}" >/dev/null 2>&1 \
    || fallback "cannot pull :${PUBLISH_TAG} (first run? then a full build is what we want)"

LAYERS=$(docker inspect "${RPM_REPO_IMAGE}:${PUBLISH_TAG}" --format '{{len .RootFS.Layers}}' 2>/dev/null || echo 999)
echo "   image has $LAYERS layer(s)"
[ "$LAYERS" -lt "$MAX_LAYERS" ] || fallback "layer count $LAYERS >= $MAX_LAYERS -- time to compact"

CID=$(docker run -d "${RPM_REPO_IMAGE}:${PUBLISH_TAG}") \
    || fallback "could not start a container from the image"
docker exec "$CID" sh -c "cd $REPO_PATH && ls -1 *.rpm 2>/dev/null" | sort -u > "$WORK/actual.txt" \
    || fallback "could not list RPMs inside the image"
ACTUAL=$(wc -l < "$WORK/actual.txt" | tr -d ' ')
echo "   image currently holds $ACTUAL RPM(s)"
[ "$ACTUAL" -gt 0 ] || fallback "image contains no RPMs"

# --- 3. Candidate tags -----------------------------------------------------
# Anything whose one-RPM name is not already served. Includes every bundle tag
# on every run, by construction.
comm -23 "$WORK/derived.txt" "$WORK/actual.txt" | sed 's/\.rpm$//; s/^/rpm-/' | sort -u > "$WORK/candidates.txt"
CAND=$(wc -l < "$WORK/candidates.txt" | tr -d ' ')
echo "3. $CAND candidate tag(s) to inspect"
if [ "$CAND" -eq 0 ]; then
    echo "   image already matches the tag set. Nothing to do."
    exit 0
fi
[ "$CAND" -le "$MAX_CANDIDATES" ] || fallback "$CAND candidate tags exceeds MAX_CANDIDATES=$MAX_CANDIDATES"

# --- 4. Pull them and see what actually comes out -------------------------
echo "4. Pulling $CAND tag(s)..."
mkdir -p "$WORK/new"
while read -r t; do
    [ -n "$t" ] || continue
    docker pull -q "${RPM_REPO_IMAGE}:${t}" >/dev/null 2>&1 || fallback "could not pull tag $t"
    c=$(docker create "${RPM_REPO_IMAGE}:${t}" x) || fallback "could not create from tag $t"
    docker cp "${c}:/." "$WORK/new/" >/dev/null 2>&1 \
        || { docker rm "$c" >/dev/null 2>&1; fallback "could not extract tag $t"; }
    docker rm "$c" >/dev/null
done < "$WORK/candidates.txt"
find "$WORK/new" -type f ! -name '*.rpm' -delete 2>/dev/null || true
find "$WORK/new" -maxdepth 1 -name '*.rpm' -exec basename {} \; | sort -u > "$WORK/extracted.txt"
EXTRACTED=$(wc -l < "$WORK/extracted.txt" | tr -d ' ')
echo "   extracted $EXTRACTED distinct RPM(s) from $CAND tag(s)"
[ "$EXTRACTED" -gt 0 ] || fallback "extracted no RPMs from $CAND tag(s)"

# Genuinely new = extracted but not already served. Bundle tags typically
# contribute nothing here, which is exactly right.
comm -23 "$WORK/extracted.txt" "$WORK/actual.txt" > "$WORK/to_add.txt"
ADD=$(wc -l < "$WORK/to_add.txt" | tr -d ' ')
if [ "$ADD" -eq 0 ]; then
    echo "   every extracted RPM is already served. Nothing to do."
    exit 0
fi
echo "   $ADD genuinely new RPM(s):"
sed 's/^/     /' "$WORK/to_add.txt"
[ "$ADD" -le "$MAX_ADD" ] || fallback "$ADD new RPMs exceeds MAX_ADD=$MAX_ADD"

# Now that bundle contents are known, "backed" can be computed honestly, so the
# extras warning cannot fire on a file that a bundle tag legitimately provides.
sort -u "$WORK/derived.txt" "$WORK/extracted.txt" > "$WORK/backed.txt"
comm -23 "$WORK/actual.txt" "$WORK/backed.txt" > "$WORK/extra.txt"
EXTRA=$(wc -l < "$WORK/extra.txt" | tr -d ' ')
if [ "$EXTRA" -gt 0 ]; then
    # Not an error and not ours to fix: tags were pruned without a rebuild, so
    # the image still serves RPMs nothing backs. Reclaiming needs a rebuild.
    echo "   WARNING: $EXTRA RPM(s) in the image are not backed by any scratch tag." >&2
    echo "            Run prune-pkg.sh / sync_repo.sh to reclaim them. Leaving them alone." >&2
    sed 's/^/              /' "$WORK/extra.txt" | head -10 >&2
fi

# Stage ONLY the new RPMs for metadata generation. Feeding already-served RPMs
# through the merge would collapse them against their existing (identical NEVRA)
# entries and could flip an href onto the bundle's filename.
mkdir -p "$WORK/add"
while read -r f; do
    [ -n "$f" ] || continue
    cp "$WORK/new/$f" "$WORK/add/" || fallback "could not stage $f"
done < "$WORK/to_add.txt"

# --- 5. Metadata: merge, don't regenerate ---------------------------------
# createrepo_c reads RPM headers, so regenerating from scratch would need all
# ~1030 files on disk -- the 8GB extraction this script exists to avoid.
# mergerepo_c works at the METADATA level, so the existing repodata (a ~2MB
# layer) plus metadata for just the new RPMs is enough.
#
# Flags, all load-bearing (verified against the real 1030-package repodata):
#   --all                  keep every NEVRA. WITHOUT it the merge is
#                          first-repo-wins and silently drops every newly added
#                          RPM -- the exact opposite of the intent.
#   --omit-baseurl         emit bare filename hrefs, as the flat served dir needs.
#   --simple-md-filenames  stable names (primary.xml.gz, not <sha>-primary.xml.gz)
#                          so repeated publishes overwrite instead of piling up
#                          orphans. Costs nothing: nginx already serves
#                          repodata/ as no-cache, so checksum names bought
#                          nothing here.
echo "5. Merging metadata..."
mkdir -p "$WORK/old"
docker cp "$CID:$REPO_PATH/repodata/." "$WORK/old/repodata_tmp/" >/dev/null 2>&1 \
    || fallback "could not extract existing repodata"
mv "$WORK/old/repodata_tmp" "$WORK/old/repodata"

run_repotool() {
    # createrepo_c/mergerepo_c on the runner if present, else in a rocky
    # container over a bind mount -- same approach sync_repo.sh already uses,
    # since ubuntu runners do not ship createrepo_c.
    if command -v mergerepo_c >/dev/null 2>&1 && command -v createrepo_c >/dev/null 2>&1; then
        ( cd "$WORK" && eval "$1" )
    else
        docker run --rm -v "$(cd "$WORK" && pwd)":/w -w /w rockylinux:9 bash -c \
            "dnf install -y -q createrepo_c >/dev/null 2>&1 && $1 && chown -R $(id -u):$(id -g) /w"
    fi
}

run_repotool "createrepo_c -q add" || fallback "createrepo_c failed on the new RPMs"
run_repotool "mergerepo_c --all --omit-baseurl --simple-md-filenames --repo=old --repo=add -o merged" \
    || fallback "mergerepo_c failed"
[ -d "$WORK/merged/repodata" ] || fallback "mergerepo_c produced no repodata"

# Sanity-check the merge before it reaches the image: everything that should be
# served must appear in the merged metadata. This is what catches a silently
# dropping merge (identical NEVRAs collapsing, a missing flag, an upstream
# behaviour change).
python3 - "$WORK" <<'PY' || fallback "merged metadata failed verification"
import glob, gzip, re, sys, os
w = sys.argv[1]
f = glob.glob(os.path.join(w, "merged", "repodata", "*primary.xml*"))
if not f:
    print("ERROR: no primary.xml in merged repodata", file=sys.stderr); sys.exit(1)
d = (gzip.open(f[0], "rt", errors="replace").read() if f[0].endswith(".gz")
     else open(f[0], errors="replace").read())
hrefs = set(re.findall(r'<location href="([^"]+)"', d))
slashed = [h for h in hrefs if "/" in h]
if slashed:
    print("ERROR: %d href(s) are not bare filenames, e.g. %s"
          % (len(slashed), slashed[:3]), file=sys.stderr); sys.exit(1)
rd = lambda n: set(x.strip() for x in open(os.path.join(w, n)) if x.strip())
want = rd("actual.txt") | rd("to_add.txt")
missing = sorted(want - hrefs)
if missing:
    print("ERROR: merged metadata is missing %d package(s):" % len(missing), file=sys.stderr)
    for m in missing[:20]:
        print("         " + m, file=sys.stderr)
    sys.exit(1)
print("   merged metadata lists %d package(s); all %d expected present" % (len(hrefs), len(want)))
PY

# --- 6. Update the container ----------------------------------------------
# repodata is replaced wholesale rather than copied over: the CURRENT image was
# built by sync_repo.sh with checksum-prefixed metadata filenames, so simply
# copying simple-named files in would leave the old <sha>-primary.xml.gz files
# behind forever. repomd.xml would still be correct, but the directory (served
# with autoindex on) would accumulate orphans on every publish.
echo "6. Updating the container..."
while read -r f; do
    [ -n "$f" ] || continue
    docker cp "$WORK/add/$f" "$CID:$REPO_PATH/" >/dev/null \
        || fallback "could not copy $f into the image"
done < "$WORK/to_add.txt"
docker exec "$CID" rm -rf "$REPO_PATH/repodata" || fallback "could not clear old repodata"
docker cp "$WORK/merged/repodata" "$CID:$REPO_PATH/" >/dev/null \
    || fallback "could not copy merged repodata into the image"

# Verify against the real filesystem we are about to commit, not against what we
# believe we copied.
docker exec "$CID" sh -c "cd $REPO_PATH && ls -1 *.rpm 2>/dev/null" | sort -u > "$WORK/final.txt"
if comm -23 "$WORK/to_add.txt" "$WORK/final.txt" | grep -q .; then
    echo "ERROR: these new RPMs are missing from the updated image:" >&2
    comm -23 "$WORK/to_add.txt" "$WORK/final.txt" | sed 's/^/     /' | head -20 >&2
    fallback "post-update verification failed (new RPMs)"
fi
if comm -23 "$WORK/actual.txt" "$WORK/final.txt" | grep -q .; then
    echo "ERROR: the update LOST previously served RPMs:" >&2
    comm -23 "$WORK/actual.txt" "$WORK/final.txt" | sed 's/^/     /' | head -20 >&2
    fallback "post-update verification failed (lost RPMs)"
fi
docker exec "$CID" sh -c "test -s $REPO_PATH/repodata/repomd.xml" \
    || fallback "repomd.xml missing or empty in the updated image"
echo "   verified: $ADD added, none lost"

# --- 7. Commit and push ----------------------------------------------------
# Stop the container first. Committing a RUNNING nginx captures /run/nginx.pid
# into the layer -- harmless (it is never served, and the next publish replaces
# it) but it is runtime noise in an artifact that should hold only the repo.
# StopSignal is SIGQUIT, so nginx shuts down gracefully and unlinks the pidfile
# itself. Nothing below needs `docker exec` any more; `docker cp` and `commit`
# both work on a stopped container.
docker stop "$CID" >/dev/null 2>&1 || true

# `docker commit` carries the source image's config forward (Cmd, Entrypoint,
# ExposedPorts, WorkingDir, StopSignal), so nginx still starts the same way.
echo "7. Committing and pushing ${RPM_REPO_IMAGE}:${PUBLISH_TAG}..."
docker commit "$CID" "${RPM_REPO_IMAGE}:${PUBLISH_TAG}" >/dev/null \
    || fallback "docker commit failed"
docker_push_retry "${RPM_REPO_IMAGE}:${PUBLISH_TAG}" >/dev/null \
    || fallback "push failed"

FINAL=$(wc -l < "$WORK/final.txt" | tr -d ' ')
echo ""
echo "================ FAST PUBLISH SUMMARY ================"
echo "Source : $TAG_COUNT scratch tags"
echo "Added  : $ADD RPM(s)"
echo "Image  : $FINAL RPM(s), $((LAYERS + 1)) layer(s) (compaction at $MAX_LAYERS)"
[ "$EXTRA" -gt 0 ] && echo "Extras : $EXTRA RPM(s) not backed by tags -- run prune-pkg.sh to reclaim"
echo "Pushed : ${RPM_REPO_IMAGE}:${PUBLISH_TAG}"
echo "====================================================="
df -h / 2>/dev/null || true
