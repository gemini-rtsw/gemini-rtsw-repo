#!/bin/bash

# Lists RPMs in the gh-pages branch RPM repository

REPO_DIR="rpm-repo"

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
    echo "Listing production repository packages"
fi

# Detect CI vs local
if [ -n "$GITHUB_ACTIONS" ]; then
    # In CI, gh-pages is checked out at ./gh-pages
    GH_PAGES_DIR="./gh-pages"
else
    # Locally, clone gh-pages into temp dir
    GH_PAGES_DIR=$(mktemp -d)
    REPO_URL=$(git remote get-url github 2>/dev/null || git remote get-url origin)

    echo "1. Fetching gh-pages branch..."
    if ! git clone --branch gh-pages --single-branch "$REPO_URL" "$GH_PAGES_DIR" 2>/dev/null; then
        echo "No gh-pages branch found - no packages to list"
        rm -rf "$GH_PAGES_DIR"
        exit 0
    fi
fi

echo "2. Getting list of remote RPMs..."
remote_files=$(find "$GH_PAGES_DIR/$REPO_DIR" -maxdepth 1 -type f -name "*.rpm" -exec basename {} \; 2>/dev/null | sort -u)

if [ -z "$remote_files" ]; then
    echo "No RPMs found in $REPO_DIR repository"
else
    echo "Found remote RPMs:"
    echo "$remote_files"
fi

# Cleanup temp dir if running locally
if [ -z "$GITHUB_ACTIONS" ]; then
    rm -rf "$GH_PAGES_DIR"
fi
