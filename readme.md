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
| `upload-rpm.sh` | **Primary entry point.** Publish RPM(s): push as a per-package tag, then rebuild `:latest` from all tags. Used by CI and humans. |
| `sync_repo.sh` | Rebuild `:latest` from whatever is in `./rpms` (plus the previous `:latest`). Called by `upload-rpm.sh`; rarely run directly. |
| `list_rpms.sh` | List RPMs in the `:latest` container |
| `download_from_gitlab.sh` | One-time migration: pull all RPMs out of the old GitLab registry into `rpms/` |

### Add RPMs (CI and manual — same path)

    ./upload-rpm.sh path/to/package.rpm [path/to/package-devel.rpm ...]

This is what `gemini-rtsw-ci` calls for every build, and what you run by hand
to add a package manually. No need to touch `rpms/` or `sync_repo.sh` yourself.

### List RPMs

    ./list_rpms.sh

## How it works

Each package's RPM(s) are stored as their own **tag** on the `rpm-repo` package:
`ghcr.io/gemini-rtsw/rpm-repo:rpm-<pkgname>` — a tiny `FROM scratch` image
containing just that package's `.rpm` files. The served yum repo lives in the
`:latest` tag.

`upload-rpm.sh` does the publish:

1. Packs the given RPM(s) into a `FROM scratch` image and pushes it as
   `rpm-repo:rpm-<pkgname>`. The tag is keyed by **package name only** (no
   version/hash), so re-publishing a package **overwrites** its tag — one
   current RPM image per package.
2. Lists every `rpm-*` tag, pulls each, and copies the RPMs into `./rpms`, so
   `./rpms` holds the latest of every package.
3. Hands off to `sync_repo.sh`, which additionally pulls the previous `:latest`
   and merges its RPMs in (**preserving older/manually-added versions** — we
   build against older versions too), runs `createrepo_c`, and pushes
   `:latest`. nginx in that image serves everything over HTTP on port 8080.

### Why this avoids a publish race

The `rpm-*` tags are distinct per package, so concurrent builds never clobber
each other's RPMs. `:latest` is rebuilt from the **full tag set** (plus the
previous `:latest`) every time, so two builds racing to push `:latest` converge
to the same complete result — no cross-repo lock needed. Tags **add/overwrite
but never remove**; the `:latest` merge is what retains history.

## Requirements

- Docker
- GHCR authentication (`docker login ghcr.io`)

## GitHub package access

For other repos in the org to pull the `ghcr.io/gemini-rtsw/rpm-repo` container (e.g. in their CI), the package must be configured to allow access:

1. Go to the package settings: **github.com/orgs/gemini-rtsw/packages/container/rpm-repo/settings**
2. Under **Manage Actions access**, add each repo that needs access
3. Set the role to:
   - **Read** for repos that only pull `:latest` (consume the yum repo), or
   - **Write** for project repos whose CI publishes via `upload-rpm.sh` (they
     push their `rpm-*` tag and rebuild `:latest`)

Tag listing and pulling use the workflow's `GITHUB_TOKEN` — no PAT is required.
