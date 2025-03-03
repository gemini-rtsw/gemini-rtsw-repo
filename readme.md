# RPM Repository Management

This repository serves as an RPM package repository using GitLab's Package Registry. It includes scripts for managing RPM packages and maintaining repository metadata.

## Repository Structure

- `upload_rpm.sh` - Script to upload a single RPM package
- `sync_repo.sh` - Script to sync multiple RPMs and update metadata
- `list_rpms.sh` - Script to list RPMs in the repository
- `sync_to_prod.sh` - Script to sync all RPMs from default to production repository
- `backup_repos.sh` - Script to download all RPMs from both repositories for backup
- `.gitlab-ci.yml` - CI configuration for repository maintenance
- `rpms/` - Directory containing RPM packages

## Usage

### 1. Uploading a Single RPM

To upload a single RPM package:

    ./upload_rpm.sh path/to/your/package.rpm

To upload to the production repository:

    ./upload_rpm.sh -p path/to/your/package.rpm
    # or
    ./upload_rpm.sh --prod path/to/your/package.rpm

This script will:
- Validate the RPM file
- Upload it to the GitLab Package Registry (default or production)
- Trigger a CI pipeline to update repository metadata

### 2. Syncing Multiple RPMs

For bulk operations, use the sync script:

    ./sync_repo.sh

To sync with the production repository:

    ./sync_repo.sh -p
    # or
    ./sync_repo.sh --prod

The sync script will:
- Compare local RPMs in `rpms/` with remote repository
- Download missing RPMs from remote
- Upload new local RPMs
- When run locally, it triggers a CI pipeline that will regenerate and upload repository metadata
- When run with the production flag (-p/--prod), it ensures the CI pipeline regenerates the production repository metadata

### 3. Listing RPMs

To list RPMs in the repository:

    ./list_rpms.sh

To list RPMs in the production repository:

    ./list_rpms.sh -p
    # or
    ./list_rpms.sh --prod

### 4. Promoting RPMs to Production

To promote all RPMs from the default repository to the production repository:

    ./sync_to_prod.sh

This script will:
- Download all RPMs from the default repository (rpm-repo/1.0)
- Upload them to the production repository (prod/1.0)
- Skip RPMs that already exist in production
- Trigger a CI pipeline to update repository metadata

To skip triggering the pipeline:

    ./sync_to_prod.sh -n
    # or
    ./sync_to_prod.sh --no-push

### 5. Backing Up Repositories

To create a backup of all RPMs from both default and production repositories:

    ./backup_repos.sh

This script will:
- Download all RPMs from the default repository
- Download all RPMs from the production repository
- Download repository metadata
- Create a manifest file with timestamp and counts
- Store everything in the `./rpm_backup` directory

To compress the backup into a tar.gz archive:

    ./backup_repos.sh -c
    # or
    ./backup_repos.sh --compress

The backup will be organized as follows:
- `./rpm_backup/default/` - Default repository RPMs and metadata
- `./rpm_backup/prod/` - Production repository RPMs and metadata
- `./rpm_backup/manifest.txt` - Backup information and statistics

### 6. Automatic Repository Maintenance

The repository is automatically maintained by GitLab CI:

- When an RPM is uploaded, a pipeline is triggered
- The pipeline downloads all RPMs
- Creates fresh repository metadata using createrepo_c
- Uploads the metadata back to GitLab

#### Triggering Repository Sync from GitLab Interface

You can manually trigger repository sync from the GitLab interface:

1. Go to the project's CI/CD > Pipelines section
2. Click "Run pipeline"
3. For the default repository, simply run the pipeline without variables
4. For the production repository, add a variable:
   - Key: `IS_PROD`
   - Value: `true`
5. Click "Run pipeline"

This will execute the sync job with the appropriate configuration based on the `IS_PROD` variable.

### 7. Using the Repository

To use this RPM repository in your system:

1. Create a new repository configuration file at `/etc/yum.repos.d/gitlab-rpm-repo.repo` with these contents:

    [gitlab-rpm-repo]
    name=GitLab RPM Repository
    baseurl=https://oauth2:YOUR_GITLAB_TOKEN@gitlab.com/api/v4/projects/66226575/packages/generic/rpm-repo/1.0/
    enabled=1
    gpgcheck=0

For the production repository:

    [gitlab-prod-repo]
    name=GitLab Production RPM Repository
    baseurl=https://oauth2:YOUR_GITLAB_TOKEN@gitlab.com/api/v4/projects/66226575/packages/generic/prod/1.0/
    enabled=1
    gpgcheck=0

2. Replace `YOUR_GITLAB_TOKEN` with your GitLab personal access token.

3. Update the package metadata and install packages using dnf:
   - Update metadata: `dnf makecache --refresh`
   - Install packages: `dnf install PACKAGE_NAME`

Note: If you need PowerTools and EPEL repositories, install and enable them before installing packages:
- Install EPEL: `dnf install epel-release`
- Install DNF plugins: `dnf install dnf-plugins-core`
- Enable PowerTools: `dnf config-manager --set-enabled powertools`

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
- Two separate repositories are available:
  - Default repository: `rpm-repo/1.0`
  - Production repository: `prod/1.0`
- **Important**: After creating a new repository, you must run `sync_repo.sh` manually once to initialize the repository data structure.
- When running `sync_repo.sh -p` locally, it will trigger a CI pipeline that regenerates the production repository metadata.
- If repository metadata is not being regenerated for production, ensure you're using the latest version of the scripts that include the [PROD_SYNC] tag in commit messages.

## Rebuilding Repository Data

If you need to rebuild repository data (for example, if metadata becomes corrupted or out of sync), follow these steps:

### Rebuilding Default Repository Data

1. Run the sync script locally:
   ```
   ./sync_repo.sh
   ```
   This will trigger a CI pipeline that regenerates the default repository metadata.

2. Alternatively, manually trigger a CI pipeline:
   - Go to GitLab > CI/CD > Pipelines
   - Click "Run pipeline"
   - Run without any additional variables

### Rebuilding Production Repository Data

1. Run the sync script with the production flag:
   ```
   ./sync_repo.sh -p
   ```
   or
   ```
   ./sync_repo.sh --prod
   ```
   This will trigger a CI pipeline that regenerates the production repository metadata.

2. Alternatively, manually trigger a CI pipeline with the IS_PROD variable:
   - Go to GitLab > CI/CD > Pipelines
   - Click "Run pipeline"
   - Add a variable:
     - Key: `IS_PROD`
     - Value: `true`
   - Click "Run pipeline"

The CI pipeline will download all RPMs, regenerate repository metadata using createrepo_c, and upload the metadata back to GitLab.


