#!/bin/sh
# Pull helper for the rpm-repo-mirror units. Runs as root from systemd.
#
#   --if-missing  pull only if IMAGE is not on the host (service start)
#   --update      pull; restart rpm-repo-mirror.service if the image changed,
#                 then delete the old image (timer)
#
# The pull runs as PULL_USER (default software) so it uses that user's GHCR
# login; root never holds a token. PULL_USER empty = pull as root.
set -eu

IMAGE=${IMAGE:-ghcr.io/gemini-rtsw/rpm-repo:latest}
PULL_USER=${PULL_USER-software}
CONTAINER=rpm-repo
UNIT=rpm-repo-mirror.service

image_id() { docker image inspect -f '{{.Id}}' "$1" 2>/dev/null || true; }

die() { echo "rpm-repo-mirror: ERROR: $1" >&2; shift; [ $# -eq 0 ] || printf '%s\n' "$@" >&2; exit 1; }

login_help() {
    who=${PULL_USER:-root}
    printf '%s\n' \
        "  Fix: log in to GHCR as $who (one time, the login is saved in ~$who/.docker/config.json):" \
        "    sudo -iu $who docker login ghcr.io -u <github-user>" \
        "  Password: a GitHub classic PAT with the read:packages scope." \
        "  Then: sudo systemctl start rpm-repo-mirror-update" >&2
}

# Fail before pulling, with a clear message, when the pull user has no login.
check_login() {
    if [ -n "$PULL_USER" ]; then
        pw=$(getent passwd "$PULL_USER") ||
            die "PULL_USER=$PULL_USER does not exist on this host." \
                "  Set PULL_USER in /etc/sysconfig/rpm-repo-mirror to a docker-group user with a GHCR login."
        home=$(echo "$pw" | cut -d: -f6)
    else
        home=/root
    fi
    cfg=$home/.docker/config.json
    if ! grep -qs 'ghcr\.io' "$cfg"; then
        echo "rpm-repo-mirror: ERROR: ${PULL_USER:-root} has no GHCR login ($cfg has no ghcr.io entry)," \
             "so $IMAGE (private) cannot be pulled." >&2
        login_help
        exit 1
    fi
}

pull() {
    check_login
    if [ -n "$PULL_USER" ]; then
        out=$(runuser -u "$PULL_USER" -- docker pull -q "$IMAGE" 2>&1)
    else
        out=$(docker pull -q "$IMAGE" 2>&1)
    fi && return 0
    echo "$out" >&2
    case "$out" in
    *denied*|*unauthorized*|*authentication\ required*)
        echo "rpm-repo-mirror: ERROR: GHCR refused ${PULL_USER:-root}'s login for $IMAGE:" \
             "the PAT has expired, was revoked, or lacks read:packages." >&2
        login_help
        ;;
    *)
        echo "rpm-repo-mirror: ERROR: docker pull $IMAGE failed (see above; network or registry problem?)." \
             "The mirror keeps serving the image it already has." >&2
        ;;
    esac
    return 1
}

case "${1:-}" in
--if-missing)
    [ -n "$(image_id "$IMAGE")" ] && exit 0
    pull
    ;;
--update)
    old=$(image_id "$IMAGE")
    pull
    new=$(image_id "$IMAGE")
    running=$(docker inspect -f '{{.Image}}' "$CONTAINER" 2>/dev/null || true)
    if [ "$new" = "$running" ]; then
        echo "rpm-repo mirror is current (${new#sha256:})"
        exit 0
    fi
    echo "New rpm-repo image ${new#sha256:}; restarting $UNIT"
    # try-restart: leave the mirror stopped if someone stopped it.
    systemctl try-restart "$UNIT"
    # The image is several GB: drop the old one once nothing uses it.
    if [ -n "$old" ] && [ "$old" != "$new" ]; then
        docker image rm "$old" >/dev/null 2>&1 || echo "Old image $old kept (still in use)"
    fi
    ;;
*)
    echo "usage: $0 --if-missing | --update" >&2
    exit 2
    ;;
esac
