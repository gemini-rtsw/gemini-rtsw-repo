#!/bin/bash

# layer-digests.sh -- print the layer digests of a published tag, one per line.
#
# For checking that the image is REPRODUCIBLE: an unchanged bucket must serialise
# to the same bytes, and therefore the same digest, on every rebuild. If it does
# not, every consumer re-pulls the whole multi-GB image on every publish (this is
# exactly what REL-5016 fixed -- see the SOURCE_DATE_EPOCH note in sync_repo.sh).
#
# Usage, rehearsing a packing change without touching :latest:
#   1. Actions -> rebuild-latest -> Run workflow, from your branch,
#      with publish_tag = repro-test
#   2. ./layer-digests.sh repro-test > run1.txt
#   3. Run the same workflow again, unchanged
#   4. ./layer-digests.sh repro-test > run2.txt
#   5. diff run1.txt run2.txt   # no output = reproducible
#
# Reads the manifest only -- no image pull, no disk. Needs `docker login ghcr.io`.

set -euo pipefail

RPM_REPO_IMAGE="${RPM_REPO_IMAGE:-ghcr.io/gemini-rtsw/rpm-repo}"
TAG="${1:-}"

if [ -z "$TAG" ]; then
    echo "Usage: $0 <tag>            e.g. $0 repro-test" >&2
    exit 1
fi

if ! docker buildx version >/dev/null 2>&1; then
    echo "ERROR: needs docker buildx (imagetools). On a Mac with Homebrew docker:" >&2
    echo "  mkdir -p ~/.docker/cli-plugins" >&2
    echo "  ln -sf \$(brew --prefix)/lib/docker/cli-plugins/docker-buildx ~/.docker/cli-plugins/" >&2
    exit 1
fi

docker buildx imagetools inspect --raw "${RPM_REPO_IMAGE}:${TAG}" \
    | python3 -c '
import json, sys
m = json.load(sys.stdin)
layers = m.get("layers")
if layers is None:
    # An OCI index rather than a plain manifest -- attestations are meant to be
    # off (see buildx_build_push), so surface it instead of printing nothing.
    sys.exit("ERROR: got an index, not an image manifest -- attestations enabled?")
for l in layers:
    print("%s  %s" % (l["digest"], l["size"]))
'
