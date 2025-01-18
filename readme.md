# RPM Repository Management

This repository serves as an RPM package repository using GitLab's Package Registry. It includes scripts for managing RPM packages and maintaining repository metadata.

## Repository Structure

- `upload_rpm.sh` - Script to upload a single RPM package
- `sync_repo.sh` - Script to sync multiple RPMs and update metadata
- `.gitlab-ci.yml` - CI configuration for repository maintenance
- `rpms/` - Directory containing RPM packages

## Usage

### 1. Uploading a Single RPM

To upload a single RPM package:

    ./upload_rpm.sh path/to/your/package.rpm

This script will:
- Validate the RPM file
- Upload it to the GitLab Package Registry
- Trigger a CI pipeline to update repository metadata

### 2. Syncing Multiple RPMs

For bulk operations, use the sync script:

    ./sync_repo.sh

The sync script will:
- Compare local RPMs in `rpms/` with remote repository
- Download missing RPMs from remote
- Upload new local RPMs
- Generate and upload repository metadata
- Trigger a CI pipeline if not running in CI

### 3. Automatic Repository Maintenance

The repository is automatically maintained by GitLab CI:

- When an RPM is uploaded, a pipeline is triggered
- The pipeline downloads all RPMs
- Creates fresh repository metadata using createrepo_c
- Uploads the metadata back to GitLab

### 4. Using the Repository

To use this RPM repository in your system:

1. Add the repository:

    dnf config-manager --add-repo https://gitlab.com/api/v4/projects/66226575/packages/rpm/generic/

2. Configure repository settings:

    dnf config-manager --save \
        --setopt=gitlab*.gpgcheck=0 \
        --setopt=gitlab*.repo_gpgcheck=0 \
        --setopt=gitlab*.sslverify=1

## Requirements

- bash
- curl
- git
- Docker (for CI runner)
- GitLab access token (for local operations)

## Notes

- The repository uses GitLab's Package Registry for storage
- Repository metadata is automatically updated after changes
- CI pipelines ensure consistency between local and remote packages
- Authentication is handled via GitLab tokens


