#!/bin/bash

# Downloads all RPMs from both default and production GHCR containers for backup

RPM_REPO_IMAGE="ghcr.io/gemini-rtsw/rpm-repo"
BACKUP_DIR="./rpm_backup"
DEFAULT_BACKUP_DIR="$BACKUP_DIR/default"
PROD_BACKUP_DIR="$BACKUP_DIR/prod"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Parse command line options
COMPRESS=false
while getopts "c-:" opt; do
    case $opt in
        c) COMPRESS=true ;;
        -)
            case "${OPTARG}" in
                compress) COMPRESS=true ;;
                *) echo "Invalid option: --${OPTARG}" >&2; exit 1 ;;
            esac ;;
        ?) echo "Invalid option: -${OPTARG}" >&2; exit 1 ;;
    esac
done
shift $((OPTIND-1))

# Create backup directories
mkdir -p "$DEFAULT_BACKUP_DIR"
mkdir -p "$PROD_BACKUP_DIR"

echo "Starting repository backup at $TIMESTAMP"

# Function to backup a repository
backup_repository() {
    local repo_name=$1
    local tag=$2
    local backup_dir=$3

    echo "Backing up $repo_name repository..."

    if ! docker pull "$RPM_REPO_IMAGE:$tag" 2>/dev/null; then
        echo "No $repo_name repository found - nothing to backup"
        return
    fi

    CID=$(docker create "$RPM_REPO_IMAGE:$tag")
    docker cp "$CID:/rpm-repo/." "$backup_dir/" 2>/dev/null || true
    docker rm "$CID" > /dev/null

    local count
    count=$(find "$backup_dir" -maxdepth 1 -name "*.rpm" 2>/dev/null | wc -l | tr -d ' ')
    echo "Backed up $count RPMs from $repo_name repository"

    echo "$repo_name repository backup complete"
}

# Download default repository
backup_repository "default" "latest" "$DEFAULT_BACKUP_DIR"

# Download production repository
backup_repository "production" "prod" "$PROD_BACKUP_DIR"

# Create a manifest file with timestamp and counts
echo "Creating backup manifest..."
echo "Backup created: $TIMESTAMP" > "$BACKUP_DIR/manifest.txt"
echo "Default repository RPMs: $(find "$DEFAULT_BACKUP_DIR" -maxdepth 1 -name "*.rpm" 2>/dev/null | wc -l)" >> "$BACKUP_DIR/manifest.txt"
echo "Production repository RPMs: $(find "$PROD_BACKUP_DIR" -maxdepth 1 -name "*.rpm" 2>/dev/null | wc -l)" >> "$BACKUP_DIR/manifest.txt"

# Compress the backup if requested
if [ "$COMPRESS" = true ]; then
    echo "Compressing backup..."
    ARCHIVE_NAME="rpm_backup_${TIMESTAMP}.tar.gz"
    tar -czf "$ARCHIVE_NAME" "$BACKUP_DIR"
    echo "Backup compressed to $ARCHIVE_NAME"
    echo "Compressed archive: $ARCHIVE_NAME" >> "$BACKUP_DIR/manifest.txt"
fi

echo "Backup complete!"
echo "Backup location: $BACKUP_DIR"
echo "Backup manifest: $BACKUP_DIR/manifest.txt"
