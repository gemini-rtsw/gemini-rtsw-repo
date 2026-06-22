# RPM Repository

RPM package repository stored as a Docker container on GitHub Container Registry (GHCR).

The container (`ghcr.io/gemini-rtsw/rpm-repo`) runs nginx and serves RPMs + repodata over HTTP on port 8080.

## Image tags

The repo is published as two per-EL tags (see [How it works](#how-it-works)):

| Tag | Contents | Size |
|-----|----------|------|
| `:latest-el8` | only `.el8` RPMs | ~half |
| `:latest-el9` | only `.el9` RPMs | ~half |

**Use the per-EL tag matching your target.** Each is ~half the size, so the pull
fits a CI runner / dev box without overflowing the disk.

> The old combined `:latest` tag is **no longer maintained** — `sync_repo.sh`
> stopped rebuilding it (it wasted time/space on a ~6GB image once all consumers
> moved to per-EL). The stale tag may still exist in GHCR but is frozen; do not
> use it. Pull a per-EL tag instead.

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
  pulls the now-frozen `:latest`).
- Override the image if needed (e.g. to test a specific tag):
  `RPM_REPO_IMAGE=ghcr.io/gemini-rtsw/rpm-repo:latest-el8 ./gemini-rtsw-ci/build_rpm.sh --el 8`

## Scripts

| Script | Description |
|--------|-------------|
| `upload-rpm.sh` | **Register RPM(s).** Push EACH RPM as its own per-NVRA scratch tag `rpm-<NVRA>`. With no flag, also publishes (calls `sync_repo.sh`). With `--tag-only`, pushes tags and stops. |
| `sync_repo.sh` | **Publish.** Rebuild `:latest-el8` / `:latest-el9` **purely from the `rpm-*` tags** (no merge-pull of the old image). Safe to run standalone to **heal**. |
| `backfill-tags.sh` | **One-time migration.** Enumerate every RPM in the current images (incl. grandfathered) and push each as a per-NVRA tag, so the tags become the complete source of truth. |
| `repo-usage.sh` | **Space report.** Sum scratch-tag sizes per package, biggest first, so you can spot heavy packages (e.g. epics-base) to prune. |
| `prune-pkg.sh` | **Targeted prune.** For ONE package, keep the newest build per NVR-group and interactively delete older git-hash builds (preview + per-RPM confirm), then rebuild `:latest`. |
| `tag-lib.sh` | Shared helpers: `rpm_tag_for`, tag listing, push-retry, GHCR tag delete. |
| `list_rpms.sh` | List RPMs in an image |
| `download_from_gitlab.sh` | One-time migration: pull all RPMs out of the old GitLab registry into `rpms/` |

### Add a package manually

    ./upload-rpm.sh path/to/package.rpm [path/to/package-devel.rpm ...]

Pushes each RPM's scratch tag, then rebuilds and pushes the per-EL images. For a
one-off manual upload this single command is fine.

If you instead want to register several packages and publish once at the end:

    ./upload-rpm.sh --tag-only pkgA.rpm pkgA-devel.rpm   # tags only, no publish
    ./upload-rpm.sh --tag-only pkgB.rpm                  # tags only, no publish
    ./sync_repo.sh                                       # rebuild images once

### Heal / force-rebuild the images

If an RPM is present as a scratch tag but missing from a served image, just
republish — **no package rebuild needed**:

    ./sync_repo.sh

It rebuilds the per-EL images purely from the `rpm-*` tags, so any RPM that was
missing from an image returns. Prefer running it on a runner: trigger the
**`rebuild-latest`** workflow from the GitHub UI (**Actions → rebuild-latest →
Run workflow**), which runs `sync_repo.sh` on a GitHub runner.

### Reclaiming space: usage report + targeted prune

The scratch tags accumulate every git-hash build forever, so the repo grows and
eventually strains runner disk. To reclaim space:

**1. See who's big:**

    ./repo-usage.sh

Lists each package's tag count + total size, biggest first (e.g. epics-base and
rtems are the heavy ones).

**2. Prune old builds of a heavy package:**

    ./prune-pkg.sh epics-base

For that one package it keeps the **newest build per NVR-group** (by GHCR
creation time) and offers the **older git-hashes** as prune candidates. It shows
a preview, then asks **per RPM** (default = keep); after you confirm, it deletes
the chosen scratch tags and rebuilds the served images.

> **Safety — you are the safety net.** There is NO automated "is this pinned?"
> check: pins live across many branches/release tags and even in repos OUTSIDE
> this GitHub org, so it's impossible to know for certain. Review the preview
> and keep anything a release or external consumer might still need. Nothing is
> deleted without per-RPM confirmation. Grandfathered/clean RPMs (no `.git.`
> hash in the release) are never offered as candidates.

### List RPMs

    ./list_rpms.sh

## How it works

**Every RPM is stored as its own tag** on the `rpm-repo` package:
`ghcr.io/gemini-rtsw/rpm-repo:rpm-<NVRA>` — a tiny `FROM scratch` image holding
exactly that one `.rpm`. The tag key is the RPM's full identity (Name-Version-
Release-Arch, i.e. its filename), so a new version is a **new** tag: tags ADD and
never overwrite. The scratch tags are the **single, durable source of truth** —
for built RPMs and for irreplaceable grandfathered ones alike.

The served yum images are pure derived artifacts, rebuilt from the tags:

| Tag | Contents | Who pulls it |
|-----|----------|--------------|
| `:latest-el8` | only `.el8` RPMs (~half size) | EL8 builds |
| `:latest-el9` | only `.el9` RPMs (~half size) | EL9 builds |

Publishing is two responsibilities:

**1. Register (`upload-rpm.sh`).** Each given RPM is packed into a `FROM scratch`
image and pushed as `rpm-<NVRA>`. Unique key per artifact → no overwrite, no EL
collision, no race. (`--tag-only` stops here; the publish runs separately.)

**2. Publish (`sync_repo.sh`).** Lists every `rpm-*` tag, pulls each (in
parallel), sorts by EL, runs `createrepo_c`, buckets into stable layers, and
pushes `:latest-el8` / `:latest-el9`. It does **not** pull the existing images
to merge into — it rebuilds them **purely from the tag set**. nginx serves each
over HTTP on port 8080.

### Why pure-from-tags

- **No 6GB base pull** at publish — only the tiny per-RPM tags. Faster, and it
  fits the runner disk.
- **No read-modify-write, so no race.** A rebuild deterministically reconstructs
  the full repo from the tags; two concurrent publishes converge to the same
  result. (The old model merged into a shared mutable image, which could clobber.)
- **Any single RPM is retrievable** without pulling the whole repo — just pull
  its `rpm-<NVRA>` tag.

### Safety: never lose an RPM

The tags are the *only* source, so a missing tag would mean a missing RPM. Two
guards protect the irreplaceable grandfathered RPMs:

1. **Tag-pull completeness.** Each tag holds one RPM, so the number of RPMs
   extracted must equal the number of tags. A shortfall (a failed pull) aborts
   the publish — it never ships an incomplete repo.
2. **Anti-truncation.** Each publish records its per-EL RPM count in a tiny
   `rpm-count-el<N>` marker tag. The next publish refuses to push an image with
   **fewer** RPMs than that — a shrink fails loudly instead of silently dropping
   RPMs.

GHCR has no practical total-size cap, so accumulating tags is fine; old NVRs
stay retrievable. (Tag-count growth is unbounded by design; a retention policy
can prune unreferenced dev NVRs later — release pins protect what matters.)

### One-time migration

`backfill-tags.sh` seeds the model: it reads every RPM out of the current
`:latest-el8` / `:latest-el9` images (including grandfathered ones) and pushes
each as a per-NVRA tag, then verifies the tag count matches. Run once; after
that the tags are complete and `sync_repo.sh` is safe to run pure-from-tags.

## Requirements

- Docker
- GHCR authentication (`docker login ghcr.io`)

## GitHub package access

For other repos in the org to pull the `ghcr.io/gemini-rtsw/rpm-repo` container (e.g. in their CI), the package must be configured to allow access:

1. Go to the package settings: **github.com/orgs/gemini-rtsw/packages/container/rpm-repo/settings**
2. Under **Manage Actions access**, add each repo that needs access
3. Set the role to:
   - **Read** for repos that only pull `:latest-el8`/`:latest-el9` (consume the
     yum repo), or
   - **Write** for project repos whose CI publishes via `upload-rpm.sh` (they
     push their `rpm-<NVRA>` tags and rebuild the per-EL images)

Tag listing and pulling use the workflow's `GITHUB_TOKEN` — no PAT is required.
