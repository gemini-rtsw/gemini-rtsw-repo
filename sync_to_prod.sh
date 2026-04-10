#!/bin/bash

# Copies all RPMs from the default GHCR container (rpm-repo:latest)
# to the production container (rpm-repo:prod).

RPM_REPO_IMAGE="ghcr.io/gemini-rtsw/rpm-repo"

# Parse command line options
NO_PUSH=false
while getopts "n-:" opt; do
    case $opt in
        n) NO_PUSH=true ;;
        -)
            case "${OPTARG}" in
                no-push) NO_PUSH=true ;;
                *) echo "Invalid option: --${OPTARG}" >&2; exit 1 ;;
            esac ;;
        ?) echo "Invalid option: -${OPTARG}" >&2; exit 1 ;;
    esac
done
shift $((OPTIND-1))

WORK_DIR=$(mktemp -d)
mkdir -p "$WORK_DIR/default" "$WORK_DIR/prod"

echo "1. Pulling default RPM repo container..."
if ! docker pull "$RPM_REPO_IMAGE:latest" 2>/dev/null; then
    echo "No default repository found - nothing to sync"
    rm -rf "$WORK_DIR"
    exit 1
fi

CID=$(docker create "$RPM_REPO_IMAGE:latest")
docker cp "$CID:/rpm-repo/." "$WORK_DIR/default/" 2>/dev/null || true
docker rm "$CID" > /dev/null
rm -rf "$WORK_DIR/default/repodata"

echo "2. Getting list of RPMs from default repository..."
default_files=$(find "$WORK_DIR/default" -maxdepth 1 -type f -name "*.rpm" -exec basename {} \; | sort -u)

if [ -z "$default_files" ]; then
    echo "No RPMs found in default repository - nothing to sync"
    rm -rf "$WORK_DIR"
    exit 0
fi

echo "Found RPMs in default repository:"
echo "$default_files"

echo "3. Pulling production RPM repo container..."
if docker pull "$RPM_REPO_IMAGE:prod" 2>/dev/null; then
    CID=$(docker create "$RPM_REPO_IMAGE:prod")
    docker cp "$CID:/rpm-repo/." "$WORK_DIR/prod/" 2>/dev/null || true
    docker rm "$CID" > /dev/null
    rm -rf "$WORK_DIR/prod/repodata"
fi

prod_files=$(find "$WORK_DIR/prod" -maxdepth 1 -type f -name "*.rpm" -exec basename {} \; | sort -u)
echo "Found RPMs in production repository:"
echo "$prod_files"

echo "4. Copying RPMs to production..."
copied=0
for rpm_file in $default_files; do
    if echo "$prod_files" | grep -q "^${rpm_file}$"; then
        echo "Skipping $rpm_file (already exists in production)"
    else
        echo "Copying: $rpm_file to production"
        cp "$WORK_DIR/default/$rpm_file" "$WORK_DIR/prod/$rpm_file"
        ((copied++))
    fi
done

if [ "$copied" -eq 0 ]; then
    echo "No new RPMs to copy to production"
    rm -rf "$WORK_DIR"
    exit 0
fi

# Copy prod RPMs into rpms/ so the pipeline picks them up
mkdir -p ./rpms
cp "$WORK_DIR/prod/"*.rpm ./rpms/ 2>/dev/null || true

# Cleanup
rm -rf "$WORK_DIR"

# Trigger pipeline via git push unless --no-push was specified
if [ "$NO_PUSH" = false ]; then
    echo "5. Triggering repository sync pipeline via git push..."
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    git commit --allow-empty -m "[PROD_SYNC] Trigger sync after promoting $copied RPMs to production"
    git push github "$CURRENT_BRANCH" 2>/dev/null || git push origin "$CURRENT_BRANCH"
    echo "Pipeline triggered via push"
else
    echo "Skipping repository sync pipeline trigger (--no-push specified)"
fi

echo "Sync to production complete!"
