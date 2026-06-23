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
# tag_exists <image:tag> -- true if the tag already exists in the registry.
# Uses `docker manifest inspect`, which queries the registry WITHOUT pulling the
# image (no build, no layer download). Lets backfill skip already-present tags
# cheaply so a re-run only does work for genuinely missing tags.
tag_exists() {
    docker manifest inspect "$1" >/dev/null 2>&1
}

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

# ghcr_resolve_creds -- ensure GITHUB_TOKEN + GITHUB_ACTOR are set. Order:
#   1. existing env (GITHUB_TOKEN / CR_PAT, GITHUB_ACTOR) -- e.g. in CI
#   2. the `gh` CLI (gh auth token / gh api user), if installed
#   3. the Docker GHCR login -- the same credential `docker pull ghcr.io/...`
#      uses (inline auth in ~/.docker/config.json, or a credential helper like
#      docker-credential-desktop). This is why the scripts work locally with no
#      extra setup whenever `build_rpm.sh` can already pull from GHCR.
# Exports GITHUB_TOKEN and GITHUB_ACTOR.
#
# NOTE: a token from the Docker login may be a PAT scoped only for registry
# pull. Listing tags / reading sizes works; DELETING tags (prune) needs
# delete:packages and goes through the GitHub REST API -- if that 403s, set a
# GITHUB_TOKEN/CR_PAT with delete:packages, or run the prune in CI.
ghcr_resolve_creds() {
    GITHUB_TOKEN="${GITHUB_TOKEN:-${CR_PAT:-}}"
    # 2. gh CLI
    if [ -z "${GITHUB_TOKEN:-}" ] && command -v gh >/dev/null 2>&1; then
        GITHUB_TOKEN="$(gh auth token 2>/dev/null || true)"
        [ -z "${GITHUB_ACTOR:-}" ] && GITHUB_ACTOR="$(gh api user --jq .login 2>/dev/null || true)"
    fi
    # 3. Docker GHCR credential (inline or via credential helper)
    if [ -z "${GITHUB_TOKEN:-}" ]; then
        local cfg="${HOME}/.docker/config.json" helper inline
        if [ -f "$cfg" ]; then
            # inline base64 auth?
            inline=$(python3 -c "import json,base64,sys
try:
 a=json.load(open('$cfg')).get('auths',{}).get('ghcr.io',{}).get('auth','')
 u,_,t=base64.b64decode(a).decode().partition(':') if a else ('','','')
 print(u+'\t'+t)
except Exception: print('\t')" 2>/dev/null || printf '\t')
            GITHUB_ACTOR="${GITHUB_ACTOR:-${inline%%	*}}"
            GITHUB_TOKEN="${inline##*	}"
            # credential helper (e.g. docker-credential-desktop)?
            if [ -z "${GITHUB_TOKEN:-}" ]; then
                helper=$(python3 -c "import json; print(json.load(open('$cfg')).get('credsStore',''))" 2>/dev/null || true)
                if [ -n "$helper" ] && command -v "docker-credential-$helper" >/dev/null 2>&1; then
                    local out; out=$(printf 'ghcr.io' | "docker-credential-$helper" get 2>/dev/null || true)
                    GITHUB_ACTOR="${GITHUB_ACTOR:-$(printf '%s' "$out" | python3 -c "import json,sys; print(json.load(sys.stdin).get('Username',''))" 2>/dev/null || true)}"
                    GITHUB_TOKEN="$(printf '%s' "$out" | python3 -c "import json,sys; print(json.load(sys.stdin).get('Secret',''))" 2>/dev/null || true)"
                fi
            fi
        fi
    fi
    GITHUB_ACTOR="${GITHUB_ACTOR:-$(whoami)}"
    export GITHUB_TOKEN GITHUB_ACTOR
    if [ -z "${GITHUB_TOKEN:-}" ]; then
        echo "ERROR: no GitHub token found (env, gh, or docker login)." >&2
        echo "       Set GITHUB_TOKEN/CR_PAT, or 'docker login ghcr.io', or run in CI." >&2
        return 1
    fi
}

# ghcr_list_rpm_tags -> prints every rpm-* scratch tag (one per line), excluding
# the rpm-count-* anti-truncation markers. Uses cursor pagination so it can't
# silently stop early. Resolves creds via ghcr_resolve_creds.
ghcr_list_rpm_tags() {
    local gh_user gh_pass basic bearer url page count last="" all=""
    ghcr_resolve_creds || return 1
    gh_user="${GITHUB_ACTOR}"
    gh_pass="${GITHUB_TOKEN}"
    basic=$(printf '%s:%s' "$gh_user" "$gh_pass" | base64 | tr -d '\n')
    bearer=$(curl -s -H "Authorization: Basic $basic" \
        "https://ghcr.io/token?service=ghcr.io&scope=repository:gemini-rtsw/rpm-repo:pull" \
        | python3 -c "import json,sys; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)
    if [ -z "$bearer" ]; then echo "ERROR: GHCR token request failed" >&2; return 1; fi
    while :; do
        if [ -z "$last" ]; then url="https://ghcr.io/v2/gemini-rtsw/rpm-repo/tags/list?n=100"
        else url="https://ghcr.io/v2/gemini-rtsw/rpm-repo/tags/list?n=100&last=${last}"; fi
        page=$(curl -s -H "Authorization: Bearer $bearer" "$url" \
            | python3 -c "import json,sys; d=json.load(sys.stdin); print('\n'.join(d.get('tags') or []))" 2>/dev/null || true)
        count=$(printf '%s\n' "$page" | grep -c . || true)
        [ "$count" -eq 0 ] && break
        all="${all}${page}"$'\n'
        last=$(printf '%s\n' "$page" | grep . | tail -1)
        [ "$count" -lt 100 ] && break
    done
    printf '%s\n' "$all" | grep '^rpm-' | grep -v '^rpm-count-' | sort -u | grep . || true
}

# ghcr_delete_tag <tag> -- delete one scratch tag's package-version from GHCR.
# The OCI registry has no tag-delete, so we resolve the tag to its package-
# version id via the GitHub REST API and DELETE that version. Uses curl + the
# resolved GITHUB_TOKEN (NO `gh` -- it may not be installed). The token needs
# delete:packages scope. Paginates all version pages. Returns nonzero on fail.
ghcr_delete_tag() {
    local tag="$1" vid
    ghcr_resolve_creds || return 1
    vid=$(python3 - "$GITHUB_TOKEN" "$tag" <<'PY' 2>/dev/null
import json,urllib.request,sys
tok,tag=sys.argv[1],sys.argv[2]; page=1
while True:
    req=urllib.request.Request(
        f"https://api.github.com/orgs/gemini-rtsw/packages/container/rpm-repo/versions?per_page=100&page={page}",
        headers={"Authorization":f"Bearer {tok}","Accept":"application/vnd.github+json"})
    try: d=json.load(urllib.request.urlopen(req))
    except Exception: break
    if not isinstance(d,list) or not d: break
    for v in d:
        if tag in (v.get('metadata',{}).get('container',{}).get('tags') or []):
            print(v['id']); sys.exit(0)
    if len(d)<100: break
    page+=1
PY
)
    if [ -z "$vid" ]; then
        echo "  WARN: no version id found for tag $tag (already gone?)" >&2
        return 1
    fi
    # DELETE the version via curl; success = HTTP 204.
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
        -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" \
        "https://api.github.com/orgs/gemini-rtsw/packages/container/rpm-repo/versions/${vid}")
    case "$code" in 20[0-9]) return 0 ;; *) echo "  WARN: delete HTTP $code for $tag" >&2; return 1 ;; esac
}
