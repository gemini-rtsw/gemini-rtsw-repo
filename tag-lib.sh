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
# GNU timeout(1) is `timeout` on Linux (CI runners, gem hosts) but `gtimeout` on
# macOS with coreutils, and absent on a stock Mac. Resolve once; if neither
# exists we still push, just unbounded -- an unbounded push is what we had before
# the timeout was added, and it beats failing every push with 127.
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"
[ -n "$TIMEOUT_BIN" ] || echo "WARN: no timeout(1)/gtimeout found; docker push will run unbounded (brew install coreutils)" >&2
docker_push_retry() {
    local ref="$1" attempt=1 rc
    while [ "$attempt" -le "$DOCKER_PUSH_RETRIES" ]; do
        # `|| rc=$?` keeps the push in an OR-list so `set -e` in the calling
        # script cannot abort mid-retry, and captures the PUSH status -- reading
        # $? after an `if` compound yields the if's status (0), not the command's.
        rc=0
        if [ -n "$TIMEOUT_BIN" ]; then
            "$TIMEOUT_BIN" "$DOCKER_PUSH_TIMEOUT" docker push "$ref" || rc=$?
        else
            docker push "$ref" || rc=$?
        fi
        if [ "$rc" -eq 0 ]; then
            return 0
        fi
        echo "  push attempt $attempt/$DOCKER_PUSH_RETRIES failed (rc=$rc) for $ref" >&2
        # rc 124 == timeout fired. Either way, back off and retry.
        attempt=$((attempt + 1))
        sleep $((attempt * 5))
    done
    echo "ERROR: docker push failed after $DOCKER_PUSH_RETRIES attempts: $ref" >&2
    return 1
}

# Extra `docker buildx` args selecting the builder, set by ensure_buildx_builder.
# Empty means "whatever builder is active", which is what we want when the caller
# already provisioned a good one (e.g. via docker/setup-buildx-action).
BUILDX_BUILDER_ARGS=""
BUILDX_BUILDER_NAME="${BUILDX_BUILDER_NAME:-rpm-repo-repro}"

# ensure_buildx_builder -- guarantee a builder that can push directly, i.e. the
# docker-container driver. The default "docker" driver cannot do
# `--output type=image,push=true`, which is how we get reproducible timestamps.
#
# Self-provisioning on purpose (REL-5016): sync_repo.sh is cloned and run by
# workflows we do not own -- notably gemini-rtsw-ci's publish.yml, which does a
# bare `git clone` of this repo and calls ./sync_repo.sh with no build setup of
# its own. Requiring every caller to add a setup-buildx step would silently break
# the next publish. Creating our own named builder keeps the change self-contained.
#
# We never pass --use: the active builder is the developer's, not ours. If one
# already has the right driver we simply use it; otherwise we target ours by name.
ensure_buildx_builder() {
    if ! docker buildx version >/dev/null 2>&1; then
        echo "ERROR: docker buildx not found (needed for reproducible layer timestamps)." >&2
        echo "       On a Mac with Homebrew docker the plugin ships in" >&2
        echo "       \$(brew --prefix)/lib/docker/cli-plugins but is not on the CLI's" >&2
        echo "       search path; link it once:" >&2
        echo "         mkdir -p ~/.docker/cli-plugins" >&2
        echo "         ln -sf \$(brew --prefix)/lib/docker/cli-plugins/docker-buildx ~/.docker/cli-plugins/" >&2
        return 1
    fi

    local drv
    drv=$(docker buildx inspect 2>/dev/null | awk '/^Driver:/{print $2; exit}')
    if [ "$drv" = "docker-container" ]; then
        BUILDX_BUILDER_ARGS=""
        echo "buildx: active builder already uses the docker-container driver."
        return 0
    fi

    echo "buildx: active driver is '${drv:-none}', which cannot push directly;"
    echo "        provisioning builder '$BUILDX_BUILDER_NAME' (docker-container)..."
    # create fails if it already exists from a previous run -- that is fine, we
    # only need it to exist. Not --use: leave the caller's active builder alone.
    docker buildx create --name "$BUILDX_BUILDER_NAME" --driver docker-container >/dev/null 2>&1 || true
    drv=$(docker buildx inspect "$BUILDX_BUILDER_NAME" 2>/dev/null | awk '/^Driver:/{print $2; exit}')
    if [ "$drv" != "docker-container" ]; then
        echo "ERROR: could not provision a docker-container buildx builder." >&2
        echo "       Create one by hand and re-run:" >&2
        echo "         docker buildx create --name $BUILDX_BUILDER_NAME --driver docker-container" >&2
        return 1
    fi
    BUILDX_BUILDER_ARGS="--builder $BUILDX_BUILDER_NAME"
    return 0
}

# buildx_build_push <image:tag> -- build Dockerfile.rpm-repo and push it, with the
# same timeout/retry policy as docker_push_retry. Requires $SCRIPT_DIR, and
# ensure_buildx_builder to have run.
#
# Why buildx and not `docker build` + docker_push_retry (REL-5016): only buildx
# offers rewrite-timestamp, which clamps timestamps in the layers the build
# creates to $SOURCE_DATE_EPOCH. That is what makes an unchanged bucket produce
# the same layer digest twice, so consumers pull only what actually changed.
# Freezing mtimes in the build context is necessary but NOT sufficient: the
# builder also stamps the COPY destination directories (/usr/share/nginx/html and
# .../rpm-repo) with the build time, and those entries appear in every one of the
# 32 bucket layers -- nothing outside the builder can reach them.
#
# --provenance/--sbom off: attestations would make the pushed artifact an OCI
# index rather than a plain manifest, which tag_exists and repo-usage.sh do not
# expect, and their embedded build times are non-reproducible by definition.
#
# buildx builds AND pushes in one step, so the timeout has to cover the build
# too (4x DOCKER_PUSH_TIMEOUT), and a retry redoes the build. The build is mostly
# cached, so a retry is cheaper than the multiplier suggests.
#
# $BUILDX_BUILDER_ARGS is deliberately unquoted: it is either empty or
# "--builder <name>", and a builder name never contains whitespace.
buildx_build_push() {
    local ref="$1" attempt=1 rc to=$((DOCKER_PUSH_TIMEOUT * 4))
    : "${SOURCE_DATE_EPOCH:?buildx_build_push: SOURCE_DATE_EPOCH must be set}"
    while [ "$attempt" -le "$DOCKER_PUSH_RETRIES" ]; do
        # `|| rc=$?` for the same reason as in docker_push_retry: keep the
        # command in an OR-list so `set -e` cannot abort mid-retry.
        rc=0
        if [ -n "$TIMEOUT_BIN" ]; then
            "$TIMEOUT_BIN" "$to" docker buildx ${BUILDX_BUILDER_ARGS} build \
                -f "$SCRIPT_DIR/Dockerfile.rpm-repo" \
                --output "type=image,name=${ref},push=true,rewrite-timestamp=true" \
                --provenance=false --sbom=false \
                "$SCRIPT_DIR" || rc=$?
        else
            docker buildx ${BUILDX_BUILDER_ARGS} build \
                -f "$SCRIPT_DIR/Dockerfile.rpm-repo" \
                --output "type=image,name=${ref},push=true,rewrite-timestamp=true" \
                --provenance=false --sbom=false \
                "$SCRIPT_DIR" || rc=$?
        fi
        if [ "$rc" -eq 0 ]; then
            return 0
        fi
        echo "  build+push attempt $attempt/$DOCKER_PUSH_RETRIES failed (rc=$rc) for $ref" >&2
        attempt=$((attempt + 1))
        sleep $((attempt * 10))
    done
    echo "ERROR: buildx build+push failed after $DOCKER_PUSH_RETRIES attempts: $ref" >&2
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
# <tag> may omit the rpm- prefix; it is added if missing.
ghcr_delete_tag() {
    local tag="$1" vid
    # Accept a name in EITHER form: the real GHCR tag (rpm-<NVRA>) or the name as
    # list_rpms.sh prints it (prefix stripped). Pasting the listing straight into
    # the prune workflow used to fail every tag with "no version id found".
    case "$tag" in rpm-*) ;; *) tag="rpm-${tag}" ;; esac
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
