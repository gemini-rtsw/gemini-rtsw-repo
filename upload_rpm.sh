#!/bin/bash

# Uploads RPM files to the GHCR RPM repo container.
# Copies RPMs into the local rpms/ directory, then triggers the pipeline
# which rebuilds the container with the new RPMs included.

RPM_DIR="./rpms"

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

if [ $# -lt 1 ]; then
    echo "Usage: $0 [-n|--no-push] <path-to-rpm-file> [additional-rpm-files...]"
    echo "Options:"
    echo "  -n, --no-push    Skip triggering the repository sync pipeline"
    echo "Example: $0 ./my-package.rpm"
    echo "Example: $0 ./rpms/*.rpm"
    exit 1
fi

mkdir -p "$RPM_DIR"

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
    echo "Staging $BASENAME for upload..."
    cp "$RPM_FILE" "$RPM_DIR/$BASENAME"
    echo "Staged: $BASENAME"
    uploaded_files+=("$BASENAME")
done

if [ ${#uploaded_files[@]} -eq 0 ]; then
    echo "No valid RPM files were staged."
    exit 1
fi

if [ "$NO_PUSH" = false ]; then
    echo "Triggering repository sync pipeline via git push..."
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    if [ ${#uploaded_files[@]} -eq 1 ]; then
        COMMIT_MSG="Upload ${uploaded_files[0]}"
    else
        COMMIT_MSG="Upload ${#uploaded_files[@]} RPMs"
    fi
    git commit --allow-empty -m "$COMMIT_MSG"
    git push github "$CURRENT_BRANCH" 2>/dev/null || git push origin "$CURRENT_BRANCH"
    echo "Pipeline triggered via push"
else
    echo "Skipping pipeline trigger (--no-push specified)"
fi
