#!/bin/bash

# Uploads RPM files to the gh-pages branch RPM repository

REPO_DIR="rpm-repo"

# Parse command line options
NO_PUSH=false
PROD=false

while getopts "np-:" opt; do
    case $opt in
        n) NO_PUSH=true ;;
        p) PROD=true ;;
        -)
            case "${OPTARG}" in
                no-push) NO_PUSH=true ;;
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

# Check if at least one RPM file was provided as an argument
if [ $# -lt 1 ]; then
    echo "Usage: $0 [-n|--no-push] [-p|--prod] <path-to-rpm-file> [additional-rpm-files...]"
    echo "Options:"
    echo "  -n, --no-push    Skip triggering the repository sync pipeline"
    echo "  -p, --prod       Upload to production repository instead of default"
    echo "Example: $0 -p ./my-package.rpm"
    echo "Example: $0 ./rpms/*.rpm"
    exit 1
fi

# Clone gh-pages into temp directory
TEMP_DIR=$(mktemp -d)
REPO_URL=$(git remote get-url github 2>/dev/null || git remote get-url origin)

echo "Cloning gh-pages branch..."
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

uploaded_files=()

for RPM_FILE in "$@"; do
    if [ ! -f "$RPM_FILE" ]; then
        echo "Error: File '$RPM_FILE' does not exist or is not a regular file, skipping"
        continue
    fi

    if [[ ! "$RPM_FILE" =~ \.rpm$ ]]; then
        echo "Error: File '$RPM_FILE' is not an RPM file (must have .rpm extension), skipping"
        continue
    fi

    BASENAME=$(basename "$RPM_FILE")
    echo "Uploading $BASENAME to $REPO_DIR repository..."
    cp "$RPM_FILE" "$TEMP_DIR/$REPO_DIR/$BASENAME"
    echo "Upload complete: $BASENAME"
    uploaded_files+=("$BASENAME")
done

if [ ${#uploaded_files[@]} -eq 0 ]; then
    echo "No valid RPM files were uploaded."
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Push to gh-pages
echo "Pushing to gh-pages..."
cd "$TEMP_DIR"
git add -A
git commit -m "Upload ${#uploaded_files[@]} RPM(s) to $REPO_DIR"
git push origin gh-pages
cd -

# Cleanup
rm -rf "$TEMP_DIR"

# Trigger pipeline via git push unless --no-push was specified
if [ "$NO_PUSH" = false ]; then
    echo "Triggering repository sync pipeline via git push..."
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    if [ ${#uploaded_files[@]} -eq 1 ]; then
        COMMIT_MSG="Trigger sync after uploading ${uploaded_files[0]} to $REPO_DIR"
    else
        COMMIT_MSG="Trigger sync after uploading ${#uploaded_files[@]} RPMs to $REPO_DIR"
    fi
    git commit --allow-empty -m "$COMMIT_MSG"
    git push github "$CURRENT_BRANCH" 2>/dev/null || git push origin "$CURRENT_BRANCH"
    echo "Pipeline triggered via push"
else
    echo "Skipping repository sync pipeline trigger (--no-push specified)"
fi
