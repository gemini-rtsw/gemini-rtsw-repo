#!/bin/bash

# Syncs RPMs between the local rpms/ directory and the gh-pages branch,
# then regenerates repodata.
#
# In CI: operates on the checked-out gh-pages worktree at ./gh-pages
# Locally: clones gh-pages into a temp dir, syncs, pushes, and triggers the workflow

REPO_DIR="rpm-repo"
RPM_DIR="./rpms"

# Parse command line options
PROD=false
while getopts "p-:" opt; do
    case $opt in
        p) PROD=true ;;
        -)
            case "${OPTARG}" in
                prod) PROD=true ;;
                *) echo "Invalid option: --${OPTARG}" >&2; exit 1 ;;
            esac ;;
        ?) echo "Invalid option: -${OPTARG}" >&2; exit 1 ;;
    esac
done
shift $((OPTIND-1))

if [ "$PROD" = true ]; then
    REPO_DIR="prod"
    echo "Using production repository"
fi

# Detect CI vs local
if [ -n "$GITHUB_ACTIONS" ]; then
    IS_CI=true
else
    IS_CI=false
fi

# Ensure RPM directory exists
mkdir -p "$RPM_DIR"

if [ "$IS_CI" = true ]; then
    # In CI, the workflow handles gh-pages checkout at ./gh-pages
    GH_PAGES_DIR="./gh-pages"
    mkdir -p "$GH_PAGES_DIR/$REPO_DIR"

    echo "1. Getting list of remote RPMs from gh-pages..."
    remote_files=$(find "$GH_PAGES_DIR/$REPO_DIR" -maxdepth 1 -type f -name "*.rpm" -exec basename {} \; | sort -u)
    echo "Found remote RPMs:"
    echo "$remote_files"

    echo "2. Getting list of local RPMs..."
    local_files=$(find "$RPM_DIR" -maxdepth 1 -type f -name "*.rpm" -exec basename {} \; | sort -u)
    echo "Found local RPMs:"
    echo "$local_files"

    echo "3. Syncing RPMs..."
    # Copy remote RPMs not in local
    for remote_file in $remote_files; do
        if ! echo "$local_files" | grep -q "^${remote_file}$"; then
            echo "Downloading: $remote_file"
            cp "$GH_PAGES_DIR/$REPO_DIR/$remote_file" "$RPM_DIR/$remote_file"
        fi
    done

    # Copy local RPMs not in remote
    for local_file in $local_files; do
        if ! echo "$remote_files" | grep -q "^${local_file}$"; then
            echo "Uploading: $local_file"
            cp "$RPM_DIR/$local_file" "$GH_PAGES_DIR/$REPO_DIR/$local_file"
        fi
    done

    echo "4. Cleaning old repository metadata..."
    rm -rf "$GH_PAGES_DIR/$REPO_DIR/repodata"

    echo "5. Generating repository metadata..."
    createrepo_c "$GH_PAGES_DIR/$REPO_DIR"

    echo "6. Deploying to gh-pages..."
    cd "$GH_PAGES_DIR"
    git config user.name "github-actions[bot]"
    git config user.email "github-actions[bot]@users.noreply.github.com"
    git add -A
    if git diff --cached --quiet; then
        echo "No changes to deploy"
    else
        git commit -m "Sync RPM repository ($REPO_DIR)"
        git push origin gh-pages
    fi

    echo "Repository sync complete!"
else
    echo "Not running in CI - syncing locally and triggering pipeline..."

    # Clone gh-pages into temp directory
    TEMP_DIR=$(mktemp -d)
    REPO_URL=$(git remote get-url github 2>/dev/null || git remote get-url origin)

    echo "1. Cloning gh-pages branch..."
    if ! git clone --branch gh-pages --single-branch "$REPO_URL" "$TEMP_DIR" 2>/dev/null; then
        echo "gh-pages branch doesn't exist yet - creating it"
        git clone "$REPO_URL" "$TEMP_DIR"
        cd "$TEMP_DIR"
        git checkout --orphan gh-pages
        git rm -rf . 2>/dev/null || true
        echo "# RPM Repository" > README.md
        git add README.md
        git commit -m "Initialize gh-pages branch"
        git push origin gh-pages
        cd -
    fi

    mkdir -p "$TEMP_DIR/$REPO_DIR"

    echo "2. Getting list of remote RPMs..."
    remote_files=$(find "$TEMP_DIR/$REPO_DIR" -maxdepth 1 -type f -name "*.rpm" -exec basename {} \; | sort -u)
    echo "$remote_files"

    echo "3. Getting list of local RPMs..."
    local_files=$(find "$RPM_DIR" -maxdepth 1 -type f -name "*.rpm" -exec basename {} \; | sort -u)
    echo "$local_files"

    echo "4. Syncing RPMs..."
    # Download remote RPMs not in local
    for remote_file in $remote_files; do
        [ -z "$remote_file" ] && continue
        if ! echo "$local_files" | grep -q "^${remote_file}$"; then
            echo "Downloading: $remote_file"
            cp "$TEMP_DIR/$REPO_DIR/$remote_file" "$RPM_DIR/$remote_file"
        fi
    done

    # Upload local RPMs not in remote
    for local_file in $local_files; do
        [ -z "$local_file" ] && continue
        if ! echo "$remote_files" | grep -q "^${local_file}$"; then
            echo "Uploading: $local_file"
            cp "$RPM_DIR/$local_file" "$TEMP_DIR/$REPO_DIR/$local_file"
        fi
    done

    echo "5. Pushing changes to gh-pages..."
    cd "$TEMP_DIR"
    git add -A
    if git diff --cached --quiet; then
        echo "No changes to push"
    else
        git commit -m "Sync RPM repository ($REPO_DIR)"
        git push origin gh-pages
    fi
    cd -

    # Cleanup
    rm -rf "$TEMP_DIR"

    echo "6. Triggering repository sync pipeline..."
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    COMMIT_MSG="Trigger sync after repository update for $REPO_DIR"
    if [ "$PROD" = true ]; then
        COMMIT_MSG="[PROD_SYNC] $COMMIT_MSG"
    fi
    git commit --allow-empty -m "$COMMIT_MSG"
    git push github "$CURRENT_BRANCH" 2>/dev/null || git push origin "$CURRENT_BRANCH"
    echo "Pipeline triggered via push"
fi
