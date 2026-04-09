#!/bin/bash

# Variables
#TOKEN="glpat-eX-vwr3j7nPZmtYohnXF" # Replace this with your token
TOKEN=$REGISTRY_TOKEN
PROJECT_ID="66226575" # GitLab project ID

# Parse command line options
NO_PUSH=false
PROD=false
REPO_PATH="rpm-repo/1.0"

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

# Set repository path based on prod flag
if [ "$PROD" = true ]; then
    REPO_PATH="prod/1.0"
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

uploaded_files=()

for RPM_FILE in "$@"; do
    # Check if the file exists and is a regular file
    if [ ! -f "$RPM_FILE" ]; then
        echo "Error: File '$RPM_FILE' does not exist or is not a regular file, skipping"
        continue
    fi

    # Check if the file has .rpm extension
    if [[ ! "$RPM_FILE" =~ \.rpm$ ]]; then
        echo "Error: File '$RPM_FILE' is not an RPM file (must have .rpm extension), skipping"
        continue
    fi

    # Upload the RPM
    echo "Uploading $RPM_FILE to $REPO_PATH repository..."
    curl --header "PRIVATE-TOKEN: $TOKEN" \
         --upload-file "$RPM_FILE" \
         "https://gitlab.com/api/v4/projects/$PROJECT_ID/packages/generic/$REPO_PATH/$(basename "$RPM_FILE")"

    echo "Upload complete: $RPM_FILE"
    uploaded_files+=("$(basename "$RPM_FILE")")
done

if [ ${#uploaded_files[@]} -eq 0 ]; then
    echo "No valid RPM files were uploaded."
    exit 1
fi

# Trigger pipeline via git push unless --no-push was specified
if [ "$NO_PUSH" = false ]; then
    echo "Triggering repository sync pipeline via git push..."
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    if [ ${#uploaded_files[@]} -eq 1 ]; then
        COMMIT_MSG="Trigger sync after uploading ${uploaded_files[0]} to $REPO_PATH"
    else
        COMMIT_MSG="Trigger sync after uploading ${#uploaded_files[@]} RPMs to $REPO_PATH"
    fi
    git commit --allow-empty -m "$COMMIT_MSG"
    git push origin $CURRENT_BRANCH
    echo "Pipeline triggered via push"
else
    echo "Skipping repository sync pipeline trigger (--no-push specified)"
fi

