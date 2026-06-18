#!/bin/bash
# tag-lib.sh -- shared helpers for the per-RPM scratch-tag model.
#
# The rpm-repo stores EVERY RPM as its own scratch tag, keyed on the RPM's full
# identity (NVRA -- Name-Version-Release-Arch, i.e. the RPM filename). Because
# the key is unique per built artifact, tags ADD and never overwrite: a new
# version is a new tag, so nothing is ever clobbered. The served yum images
# (:latest-el8 / :latest-el9) are rebuilt purely from these tags -- the tags are
# the single, durable source of truth (built AND grandfathered RPMs alike).
#
# Source this file: . "$(dirname "$0")/tag-lib.sh"

# rpm_tag_for <path-or-filename.rpm> -> echoes the scratch tag name.
# Tag = "rpm-" + RPM basename without the trailing ".rpm".
#
# CASE IS PRESERVED. OCI/GHCR tags allow [a-zA-Z0-9._-] (up to 128 chars), and
# several gemini packages differ only by case in practice (gemUtil, enetPLC5,
# drvSerial, geminiRec, AbDf1). Lowercasing would risk collapsing two distinct
# RPMs onto one tag -- and these RPMs are irreplaceable. So we do NOT lowercase.
# We map any character OUTSIDE the OCI tag charset to "-"; in practice the
# gemini RPM filenames contain only [A-Za-z0-9._-] so this never fires, but it
# is a safety net. (If a future RPM name needed it, the tag-count / truncation
# guards in sync_repo.sh would catch a resulting collision as a shrink.)
rpm_tag_for() {
    local base
    base=$(basename "$1")
    base="${base%.rpm}"
    printf 'rpm-%s' "$base" | sed 's/[^A-Za-z0-9._-]/-/g'
}

# rpm_el_for <path.rpm> -> echoes el8 / el9 / ... (the dist tag), or "noel".
rpm_el_for() {
    rpm -qp --queryformat '%{RELEASE}' "$1" 2>/dev/null | grep -oE 'el[0-9]+' | head -1 || true
}

# docker_push_retry <image:tag> -- push with a per-attempt timeout and retries.
# A plain `docker push` has NO timeout: a stalled large-blob upload (e.g. the
# ~553MB epics-base RPM) hangs forever. Here each attempt is bounded by
# DOCKER_PUSH_TIMEOUT (default 600s); a stall is killed and retried up to
# DOCKER_PUSH_RETRIES (default 4) times with backoff. Returns non-zero only if
# every attempt fails -- so the caller (set -e) still fails loudly on a genuine
# problem, but survives transient registry stalls.
DOCKER_PUSH_TIMEOUT="${DOCKER_PUSH_TIMEOUT:-600}"
DOCKER_PUSH_RETRIES="${DOCKER_PUSH_RETRIES:-4}"
docker_push_retry() {
    local ref="$1" attempt=1 rc
    while [ "$attempt" -le "$DOCKER_PUSH_RETRIES" ]; do
        if timeout "$DOCKER_PUSH_TIMEOUT" docker push "$ref"; then
            return 0
        fi
        rc=$?
        echo "  push attempt $attempt/$DOCKER_PUSH_RETRIES failed (rc=$rc) for $ref" >&2
        # rc 124 == timeout fired. Either way, back off and retry.
        attempt=$((attempt + 1))
        sleep $((attempt * 5))
    done
    echo "ERROR: docker push failed after $DOCKER_PUSH_RETRIES attempts: $ref" >&2
    return 1
}
