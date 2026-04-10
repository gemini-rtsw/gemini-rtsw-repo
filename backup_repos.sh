#!/bin/bash

# Downloads all RPMs from both default and production repositories on gh-pages for backup

DEFAULT_REPO="rpm-repo"
PROD_REPO="prod"
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

# Clone gh-pages into temp directory
TEMP_DIR=$(mktemp -d)
REPO_URL=$(git remote get-url github 2>/dev/null || git remote get-url origin)

echo "Starting repository backup at $TIMESTAMP"

echo "1. Cloning gh-pages branch..."
if ! git clone --branch gh-pages --single-branch "$REPO_URL" "$TEMP_DIR" 2>/dev/null; then
    echo "No gh-pages branch found - nothing to backup"
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Create backup directories
mkdir -p "$DEFAULT_BACKUP_DIR"
mkdir -p "$PROD_BACKUP_DIR"

# Function to backup a repository
backup_repository() {
    local repo_name=$1
    local repo_dir=$2
    local backup_dir=$3

    echo "Backing up $repo_name repository..."

    local files
    files=$(find "$TEMP_DIR/$repo_dir" -maxdepth 1 -type f -name "*.rpm" 2>/dev/null)

    if [ -z "$files" ]; then
        echo "No RPMs found in $repo_name repository - nothing to backup"
        return
    fi

    local count
    count=$(echo "$files" | wc -l | tr -d ' ')
    echo "Found $count RPMs in $repo_name repository"

    echo "Downloading RPMs from $repo_name repository..."
    for rpm_file in $files; do
        BASENAME=$(basename "$rpm_file")
        cp "$rpm_file" "$backup_dir/$BASENAME"
        echo "Backed up: $BASENAME"
    done

    # Also backup repodata if it exists
    if [ -d "$TEMP_DIR/$repo_dir/repodata" ]; then
        echo "Backing up repository metadata..."
        cp -r "$TEMP_DIR/$repo_dir/repodata" "$backup_dir/repodata"
    fi

    echo "$repo_name repository backup complete"
}

# Download default repository
backup_repository "default" "$DEFAULT_REPO" "$DEFAULT_BACKUP_DIR"

# Download production repository
backup_repository "production" "$PROD_REPO" "$PROD_BACKUP_DIR"

# Cleanup temp dir
rm -rf "$TEMP_DIR"

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
