# RPM Repository

RPM package repository stored as a Docker container on GitHub Container Registry (GHCR).

The container (`ghcr.io/gemini-rtsw/rpm-repo`) runs nginx and serves RPMs + repodata over HTTP on port 8080.

## Image tags

The repo is published as three tags (see [How it works](#how-it-works)):

| Tag | Contents | Size |
|-----|----------|------|
| `:latest-el8` | only `.el8` RPMs | ~half |
| `:latest-el9` | only `.el9` RPMs | ~half |
| `:latest` | combined (back-compat) | full |

**Use the per-EL tag matching your target** — it is ~half the size, so the pull
fits a CI runner / dev box without overflowing the disk. Use `:latest` only if
you genuinely need both ELs in one image.

## Using the repository

Start the RPM repo container (pick the tag for your EL):

    docker run -d --name rpm-repo -p 8080:8080 ghcr.io/gemini-rtsw/rpm-repo:latest-el8

Point dnf at it:

    echo -e "[rpm-repo]\nname=RPM Repository\nbaseurl=http://localhost:8080/rpm-repo/\nenabled=1\ngpgcheck=0" \
        > /etc/yum.repos.d/rpm-repo.repo
    dnf makecache --refresh
    dnf install PACKAGE_NAME

In a Dockerfile (with the repo container on a Docker network):

    ARG RPM_REPO_URL=http://rpm-repo:8080/rpm-repo/
    RUN echo -e "[rpm-repo]\nname=RPM Repo\nbaseurl=${RPM_REPO_URL}\nenabled=1\ngpgcheck=0" \
        > /etc/yum.repos.d/rpm-repo.repo

## Local package builds

Building a package locally (via `gemini-rtsw-ci/build_rpm.sh`) uses this repo to
resolve dependencies. The build scripts pull the **per-EL tag automatically**
based on `--el`:

    ./gemini-rtsw-ci/build_rpm.sh --el 8     # pulls :latest-el8
    ./gemini-rtsw-ci/build_rpm.sh --el 9     # pulls :latest-el9

- Keep the repo's `gemini-rtsw-ci` submodule current (an old submodule still
  pulls the full `:latest`).
- Override the image if needed:
  `RPM_REPO_IMAGE=ghcr.io/gemini-rtsw/rpm-repo:latest ./gemini-rtsw-ci/build_rpm.sh --el 8`

## Scripts

| Script | Description |
|--------|-------------|
| `upload-rpm.sh` | **Register a package.** Push RPM(s) as a per-package, per-EL scratch tag. With no flag, also publishes (calls `sync_repo.sh`). With `--tag-only`, pushes the tag and stops. |
| `sync_repo.sh` | **Publish `:latest`.** Pull EVERY `rpm-*` scratch tag + the previous `:latest`, rebuild, and push `:latest`. The single writer of `:latest`. Safe to run standalone to **heal** `:latest`. |
| `list_rpms.sh` | List RPMs in the `:latest` container |
| `download_from_gitlab.sh` | One-time migration: pull all RPMs out of the old GitLab registry into `rpms/` |

### Add a package manually

    ./upload-rpm.sh path/to/package.rpm [path/to/package-devel.rpm ...]

Pushes the package's scratch tag, then rebuilds and pushes `:latest`. For a
one-off manual upload this single command is fine.

If you instead want to register several packages and publish once at the end:

    ./upload-rpm.sh --tag-only pkgA.rpm pkgA-devel.rpm   # tag only, no publish
    ./upload-rpm.sh --tag-only pkgB.rpm                  # tag only, no publish
    ./sync_repo.sh                                       # publish :latest once

### Heal / force-rebuild `:latest`

If a package is present as a scratch tag but missing from `:latest` (e.g. two
matrix legs raced on the `:latest` rebuild and the loser got clobbered), just
republish — **no package rebuild needed**:

    ./sync_repo.sh

It pulls every `rpm-*` scratch tag and re-merges them, so the clobbered RPM
returns. Because `:latest` is ~6GB to pull and push, prefer running this on a
runner rather than a metered/slow connection: trigger the **`rebuild-latest`**
workflow from the GitHub UI (**Actions → rebuild-latest → Run workflow**),
which runs `sync_repo.sh` on a GitHub runner.

### List RPMs

    ./list_rpms.sh

## How it works

Each package's RPM(s) are stored as their own **tag** on the `rpm-repo` package:
`ghcr.io/gemini-rtsw/rpm-repo:rpm-<pkgname>` — a tiny `FROM scratch` image
containing just that package's `.rpm` files. The served yum repo lives in the
`:latest` tag.

Publishing is split into two responsibilities:

**1. Register (`upload-rpm.sh`).** Packs the given RPM(s) into a `FROM scratch`
image and pushes it as `rpm-repo:rpm-<pkgname>-el<N>`. The tag is keyed by
**package name + EL** (no version/hash), so re-publishing a package
**overwrites** its tag — one current RPM image per package per EL. The el8 and
el9 builds of the same package use different tags, so they never collide. This
step is race-free.

**2. Publish (`sync_repo.sh`).** The **single writer** of the served images. It:
- lists every `rpm-*` scratch tag, pulls each, and copies the RPMs into `./rpms`
  (so `./rpms` holds the latest of every package per EL);
- folds in the RPMs already in the previous images (**preserving
  older/manually-added versions** — we build against older versions too);
- runs `createrepo_c`, buckets the RPMs into stable layers, and pushes **three**
  images. nginx in each serves over HTTP on port 8080.

**Three published images (per-EL split):**

| Tag | Contents | Who pulls it |
|-----|----------|--------------|
| `:latest-el8` | only `.el8` RPMs (~half size) | EL8 builds (bumped consumers) |
| `:latest-el9` | only `.el9` RPMs (~half size) | EL9 builds (bumped consumers) |
| `:latest` | full combined set | back-compat for un-bumped consumers |

The per-EL images exist because each CI runner only builds one EL and pulling
the full ~6GB combined repo overflowed the runner disk (RTEMS cross-compiles
are large). A runner now pulls only its EL's image. `build_rpm.sh`/
`build_docker.sh` default to `:latest-el${EL_VERSION}` (override with the
`RPM_REPO_IMAGE` env var). `:latest` is kept until every consumer is on a per-EL
tag, then it can be dropped. Each image has its own anti-truncation guard.

Because `sync_repo.sh` rebuilds from the **full scratch-tag set**, running it at
any time reconstructs the complete repo — which is why it doubles as the heal
command above.

### The publish race, and how the split contains it

The scratch-tag push (step 1) is race-free. The `:latest` rebuild (step 2) is a
read-modify-write on one shared mutable tag, so two publishes running at once
can clobber each other (last writer wins).

- **Within one repo's el8/el9 matrix:** each build leg runs step 1 only
  (`--tag-only`), and step 2 runs **once** as a final `publish` job that
  `needs:` the whole matrix — so it fires after BOTH el8 and el9 finish. One
  writer, no race. This is the case that previously dropped RPMs (e.g. rtems
  el9); it is now fixed. (The publish shows up as the final job in the repo's
  Actions run.)
- **Across different repos publishing simultaneously:** still possible to race
  on `:latest`. **But no RPM is ever lost** — the loser's RPMs survive in their
  scratch tags, and the next `sync_repo.sh` (any publish, or a manual
  `rebuild-latest`) re-merges them. A clobbered RPM is at worst *briefly*
  absent from `:latest`.

Tags **add/overwrite but never remove**; the `:latest` merge + scratch tags are
what retain history.

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
