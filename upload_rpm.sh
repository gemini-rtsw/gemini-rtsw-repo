#!/bin/bash

# Variables
TOKEN="glpat-eX-vwr3j7nPZmtYohnXF" # Replace this with your token
PROJECT_ID="66226575" # GitLab project ID

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

# Check if an RPM file was provided as an argument
if [ $# -ne 1 ]; then
    echo "Usage: $0 [-n|--no-push] <path-to-rpm-file>"
    echo "Options:"
    echo "  -n, --no-push    Skip triggering the repository sync pipeline"
    echo "Example: $0 ./my-package.rpm"
    exit 1
fi

RPM_FILE="$1"

# Check if the file exists and is a regular file
if [ ! -f "$RPM_FILE" ]; then
    echo "Error: File '$RPM_FILE' does not exist or is not a regular file"
    exit 1
fi

# Check if the file has .rpm extension
if [[ ! "$RPM_FILE" =~ \.rpm$ ]]; then
    echo "Error: File '$RPM_FILE' is not an RPM file (must have .rpm extension)"
    exit 1
fi

# Upload the RPM
echo "Uploading $RPM_FILE..."
curl --header "PRIVATE-TOKEN: $TOKEN" \
     --upload-file "$RPM_FILE" \
     "https://gitlab.com/api/v4/projects/$PROJECT_ID/packages/generic/rpm-repo/1.0/$(basename "$RPM_FILE")"

echo "Upload complete: $RPM_FILE"

# Trigger pipeline via git push unless --no-push was specified
if [ "$NO_PUSH" = false ]; then
    echo "Triggering repository sync pipeline via git push..."
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    git commit --allow-empty -m "Trigger sync after uploading $(basename "$RPM_FILE")"
    git push origin $CURRENT_BRANCH
    echo "Pipeline triggered via push"
else
    echo "Skipping repository sync pipeline trigger (--no-push specified)"
fi

