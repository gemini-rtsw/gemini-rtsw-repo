# RPM Repository

RPM package repository stored as a Docker container on GitHub Container Registry (GHCR).

The container (`ghcr.io/gemini-rtsw/rpm-repo`) runs nginx and serves RPMs + repodata over HTTP on port 8080.

## Using the repository

Start the RPM repo container:

    docker run -d --name rpm-repo -p 8080:8080 ghcr.io/gemini-rtsw/rpm-repo:latest

Point dnf at it:

    echo -e "[rpm-repo]\nname=RPM Repository\nbaseurl=http://localhost:8080/rpm-repo/\nenabled=1\ngpgcheck=0" \
        > /etc/yum.repos.d/rpm-repo.repo
    dnf makecache --refresh
    dnf install PACKAGE_NAME

In a Dockerfile (with the repo container on a Docker network named `rpm-net`):

    ARG RPM_REPO_URL=http://rpm-repo:8080/rpm-repo/
    RUN echo -e "[rpm-repo]\nname=RPM Repo\nbaseurl=${RPM_REPO_URL}\nenabled=1\ngpgcheck=0" \
        > /etc/yum.repos.d/rpm-repo.repo

Use different tags for different environments:

    ghcr.io/gemini-rtsw/rpm-repo:latest   # development
    ghcr.io/gemini-rtsw/rpm-repo:prod     # production

## Scripts

| Script | Description |
|--------|-------------|
| `upload_rpm.sh` | Stage RPMs and trigger a pipeline to add them to the container |
| `sync_repo.sh` | Sync RPMs between local `rpms/` directory and the container |
| `list_rpms.sh` | List RPMs in the container |
| `sync_to_prod.sh` | Tag a container image as `prod` |
| `backup_repos.sh` | Download all RPMs from a container for backup |

### Upload RPMs

    ./upload_rpm.sh path/to/package.rpm
    ./upload_rpm.sh rpms/*.rpm
    ./upload_rpm.sh -n package.rpm    # stage only, don't trigger pipeline

### Sync repository

    ./sync_repo.sh              # sync with :latest
    ./sync_repo.sh some-tag     # sync with a specific tag

### List RPMs

    ./list_rpms.sh              # list :latest
    ./list_rpms.sh prod         # list :prod

### Promote to production

    ./sync_to_prod.sh           # tag :latest as :prod
    ./sync_to_prod.sh v1.2      # tag :v1.2 as :prod

### Backup

    ./backup_repos.sh           # backup :latest
    ./backup_repos.sh prod      # backup :prod

## How it works

1. RPMs are stored inside a Docker container at `/usr/share/nginx/html/rpm-repo/`
2. `createrepo_c` generates repodata during the container build
3. nginx serves everything over HTTP on port 8080
4. The GitHub Actions pipeline pulls the previous image, adds any new RPMs, rebuilds, and pushes

## Requirements

- Docker
- GHCR authentication (`docker login ghcr.io`)
