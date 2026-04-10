#!/bin/bash

# Downloads all RPMs from the GitLab generic package registry into rpms/
# Usage: GITLAB_TOKEN=glpat-xxx ./download_from_gitlab.sh

set -euo pipefail

TOKEN="${GITLAB_TOKEN:?Set GITLAB_TOKEN}"
PROJECT_ID="66226575"
PACKAGE_ID="34493045"
PACKAGE_NAME="rpm-repo"
PACKAGE_VERSION="1.0"
API_URL="https://gitlab.com/api/v4/projects/${PROJECT_ID}/packages/${PACKAGE_ID}/package_files"
DOWNLOAD_URL="https://gitlab.com/api/v4/projects/${PROJECT_ID}/packages/generic/${PACKAGE_NAME}/${PACKAGE_VERSION}"
RPM_DIR="./rpms"

mkdir -p "$RPM_DIR"

# Get all filenames from all pages
echo "Fetching file list from GitLab..."
PAGE=1
ALL_FILES=""
while true; do
    FILES=$(curl -sf --header "PRIVATE-TOKEN: $TOKEN" "${API_URL}?per_page=100&page=${PAGE}" | \
        python3 -c "import sys,json; [print(f['file_name']) for f in json.load(sys.stdin) if f['file_name'].endswith('.rpm') and f['file_name'] != 'test.rpm']")
    [ -z "$FILES" ] && break
    ALL_FILES="${ALL_FILES}${FILES}"$'\n'
    PAGE=$((PAGE + 1))
done

UNIQUE_FILES=$(echo "$ALL_FILES" | sort -u | grep -v '^$')
TOTAL=$(echo "$UNIQUE_FILES" | wc -l | tr -d ' ')
echo "Found $TOTAL unique RPMs"

# Download each one
COUNT=0
SKIPPED=0
for FILE in $UNIQUE_FILES; do
    COUNT=$((COUNT + 1))
    if [ -f "$RPM_DIR/$FILE" ]; then
        echo "[$COUNT/$TOTAL] Already exists: $FILE"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi
    echo "[$COUNT/$TOTAL] Downloading: $FILE"
    curl -sf --header "PRIVATE-TOKEN: $TOKEN" -o "$RPM_DIR/$FILE" "${DOWNLOAD_URL}/${FILE}" || {
        echo "  FAILED: $FILE"
        rm -f "$RPM_DIR/$FILE"
    }
done

echo "Done. Downloaded $((COUNT - SKIPPED)) new RPMs, skipped $SKIPPED existing."
echo "Run ./sync_repo.sh to push to GHCR."
