#!/bin/bash

# Promotes an RPM repo container tag to production.
# Simply tags the source image as 'prod' and pushes it.

RPM_REPO_IMAGE="ghcr.io/gemini-rtsw/rpm-repo"
SOURCE_TAG="${1:-latest}"

echo "Promoting $RPM_REPO_IMAGE:$SOURCE_TAG to $RPM_REPO_IMAGE:prod..."

docker pull "$RPM_REPO_IMAGE:$SOURCE_TAG" || { echo "Failed to pull $SOURCE_TAG"; exit 1; }
docker tag "$RPM_REPO_IMAGE:$SOURCE_TAG" "$RPM_REPO_IMAGE:prod"
docker push "$RPM_REPO_IMAGE:prod" || { echo "Failed to push prod tag"; exit 1; }

echo "Done. $RPM_REPO_IMAGE:prod is now $SOURCE_TAG"
