#!/bin/bash

# Copies all RPMs from the default repository (rpm-repo/) to the production
# repository (prod/) on the gh-pages branch.

DEFAULT_REPO="rpm-repo"
PROD_REPO="prod"

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

# Clone gh-pages into temp directory
TEMP_DIR=$(mktemp -d)
REPO_URL=$(git remote get-url github 2>/dev/null || git remote get-url origin)

echo "1. Cloning gh-pages branch..."
if ! git clone --branch gh-pages --single-branch "$REPO_URL" "$TEMP_DIR" 2>/dev/null; then
    echo "No gh-pages branch found - nothing to sync"
    rm -rf "$TEMP_DIR"
    exit 1
fi

mkdir -p "$TEMP_DIR/$PROD_REPO"

echo "2. Getting list of RPMs from default repository..."
default_files=$(find "$TEMP_DIR/$DEFAULT_REPO" -maxdepth 1 -type f -name "*.rpm" -exec basename {} \; 2>/dev/null | sort -u)

if [ -z "$default_files" ]; then
    echo "No RPMs found in default repository - nothing to sync"
    rm -rf "$TEMP_DIR"
    exit 0
fi

echo "Found RPMs in default repository:"
echo "$default_files"

echo "3. Getting list of RPMs from production repository..."
prod_files=$(find "$TEMP_DIR/$PROD_REPO" -maxdepth 1 -type f -name "*.rpm" -exec basename {} \; 2>/dev/null | sort -u)
echo "Found RPMs in production repository:"
echo "$prod_files"

echo "4. Copying RPMs to production repository..."
copied=0
for rpm_file in $default_files; do
    if echo "$prod_files" | grep -q "^${rpm_file}$"; then
        echo "Skipping $rpm_file (already exists in production)"
    else
        echo "Copying: $rpm_file to production"
        cp "$TEMP_DIR/$DEFAULT_REPO/$rpm_file" "$TEMP_DIR/$PROD_REPO/$rpm_file"
        ((copied++))
    fi
done

if [ "$copied" -eq 0 ]; then
    echo "No new RPMs to copy to production"
    rm -rf "$TEMP_DIR"
    exit 0
fi

echo "5. Pushing changes to gh-pages..."
cd "$TEMP_DIR"
git add -A
git commit -m "Promote $copied RPM(s) from $DEFAULT_REPO to $PROD_REPO"
git push origin gh-pages
cd -

# Cleanup
rm -rf "$TEMP_DIR"

# Trigger pipeline via git push unless --no-push was specified
if [ "$NO_PUSH" = false ]; then
    echo "6. Triggering repository sync pipeline via git push..."
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    git commit --allow-empty -m "[PROD_SYNC] Trigger sync after promoting RPMs to production"
    git push github "$CURRENT_BRANCH" 2>/dev/null || git push origin "$CURRENT_BRANCH"
    echo "Pipeline triggered via push"
else
    echo "Skipping repository sync pipeline trigger (--no-push specified)"
fi

echo "Sync to production complete!"
