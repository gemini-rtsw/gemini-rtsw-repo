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

In a Dockerfile (with the repo container on a Docker network):

    ARG RPM_REPO_URL=http://rpm-repo:8080/rpm-repo/
    RUN echo -e "[rpm-repo]\nname=RPM Repo\nbaseurl=${RPM_REPO_URL}\nenabled=1\ngpgcheck=0" \
        > /etc/yum.repos.d/rpm-repo.repo

## Scripts

| Script | Description |
|--------|-------------|
| `sync_repo.sh` | Sync local `rpms/` into the container, rebuild, and push |
| `list_rpms.sh` | List RPMs in the container |

### Add RPMs

    cp path/to/package.rpm rpms/
    ./sync_repo.sh

### List RPMs

    ./list_rpms.sh

## How it works

1. RPMs are stored inside a Docker container at `/usr/share/nginx/html/rpm-repo/`
2. `createrepo_c` generates repodata during the container build
3. nginx serves everything over HTTP on port 8080
4. `sync_repo.sh` pulls the previous image, adds new RPMs, rebuilds, and pushes

## Requirements

- Docker
- GHCR authentication (`docker login ghcr.io`)

## GitHub package access

For other repos in the org to pull the `ghcr.io/gemini-rtsw/rpm-repo` container (e.g. in their CI), the package must be configured to allow access:

1. Go to the package settings: **github.com/orgs/gemini-rtsw/packages/container/rpm-repo/settings**
2. Under **Manage Actions access**, add each repo that needs access
3. Set the role to **Read** for repos that only pull, or **Write** for repos whose CI pushes new RPMs via `sync_repo.sh`
