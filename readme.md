# RPM Repository

RPM package repository for the Gemini RTSW stack, stored on GitHub Container
Registry (GHCR). Two layers:

1. **Per-RPM scratch tags** — every RPM is its own tiny `FROM scratch` image
   tag `rpm-<NVRA>`. These are the **durable source of truth**.
2. **The served image** `ghcr.io/gemini-rtsw/rpm-repo:latest` — an nginx
   container serving all RPMs + repodata over HTTP on port 8080, rebuilt from
   the scratch tags.

## Using the repository

Start the repo container and point dnf at it:

    docker run -d --name rpm-repo -p 8080:8080 ghcr.io/gemini-rtsw/rpm-repo:latest

    echo -e "[rpm-repo]\nname=RPM Repository\nbaseurl=http://localhost:8080/rpm-repo/\nenabled=1\ngpgcheck=0" \
        > /etc/yum.repos.d/rpm-repo.repo
    dnf makecache --refresh
    dnf install PACKAGE_NAME

In a Dockerfile (with the repo container on a Docker network):

    ARG RPM_REPO_URL=http://rpm-repo:8080/rpm-repo/
    RUN echo -e "[rpm-repo]\nname=RPM Repo\nbaseurl=${RPM_REPO_URL}\nenabled=1\ngpgcheck=0" \
        > /etc/yum.repos.d/rpm-repo.repo

Local package builds (via `gemini-rtsw-ci/build_rpm.sh`) pull `:latest`
automatically to resolve dependencies — no manual setup.

> **Note on `:latest-el8` / `:latest-el9`.** An earlier design split the repo
> into per-EL images. That was **shelved** — at this migration stage almost
> every package is el8-only, so the split duplicated nearly everything into both
> images (no size win) and doubled build cost. The current model is a **single
> combined `:latest`**. The split code still lives in `sync_repo.sh` (dormant,
> `build_one` with an EL filter) to revisit once el9 has real package coverage.
> Any leftover `:latest-el8`/`:latest-el9` tags in GHCR are stale; ignore them.

## Scripts

| Script | Purpose |
|--------|---------|
| `upload-rpm.sh` | **Register RPM(s).** Push each RPM as its own `rpm-<NVRA>` scratch tag. No flag → also publishes (calls `sync_repo.sh`). `--tag-only` → push tags, skip publish (CI build legs use this). |
| `sync_repo.sh` | **Publish `:latest`.** Rebuild the served image **purely from the `rpm-*` scratch tags**. Single writer; safe to run standalone to **heal**. |
| `repo-usage.sh` | **Space report.** Per-package tag count + total size, biggest first — find what to prune. |
| `prune-pkg.sh` | **Targeted prune.** For ONE package: list builds, interactively exclude, verify, then **dispatch the CI `prune` workflow** to delete tags + rebuild (runs on a runner, not locally). |
| `backfill-tags.sh` | **One-time migration.** Push every RPM in the served image(s) — including grandfathered ones — as a per-NVRA scratch tag, so the tags become the complete source of truth. Already run. |
| `tag-lib.sh` | Shared helpers: credential resolution, tag listing, push-retry, tag delete. Sourced by the others. |
| `list_rpms.sh` | List RPMs in an image. |
| `download_from_gitlab.sh` | One-time: pull RPMs out of the old GitLab registry. Historical. |

## Workflows (`.github/workflows/`)

Run from the GitHub UI (**Actions → … → Run workflow**). They run on a runner
with the ambient `GITHUB_TOKEN`, so no local token or bandwidth is needed.

| Workflow | What it does |
|----------|--------------|
| `rebuild-latest` | Rebuild + push `:latest` from all scratch tags (heal / force-rebuild). Optional `allow_shrink` input for prune-aware rebuilds. |
| `prune` | Delete a given set of tags, then rebuild `:latest`. Dispatched by `prune-pkg.sh` (or run manually, pasting the tag list). |
| `backfill-tags` | One-time backfill (see above). |
| `repo-usage` | Print the space report on a runner. |

## Common tasks

### Add / update a package manually

    ./upload-rpm.sh path/to/foo.rpm [path/to/foo-devel.rpm ...]

Pushes each RPM's scratch tag, then rebuilds `:latest`. For one upload this is
fine. To stage several and publish once:

    ./upload-rpm.sh --tag-only a.rpm a-devel.rpm
    ./upload-rpm.sh --tag-only b.rpm
    ./sync_repo.sh                 # rebuild :latest once

(Normally CI does this: build legs push tags with `--tag-only`, and a final
publish job runs `sync_repo.sh` once.)

### Heal / force-rebuild `:latest`

If an RPM is in a scratch tag but missing from `:latest`, just republish — no
package rebuild needed. Prefer the runner (the image is multi-GB):

**Actions → rebuild-latest → Run workflow.** (Or `./sync_repo.sh` locally if
your machine can handle the image.)

### Reclaim space: usage report + prune

The scratch tags accumulate every build forever, so the served image grows and
eventually strains runner disk.

**1. See what's big:**

    ./repo-usage.sh

**2. Prune old builds of a heavy package (e.g. epics-base, rtems):**

    ./prune-pkg.sh epics-base

It lists the package's builds grouped by NVR, **keeps the newest build per NVR**
(by container upload time, consistent across ELs) plus all grandfathered/clean
(no-`.git.`) RPMs, and offers the older builds for deletion. You:

  - scroll the **numbered DELETE list** (newest first),
  - type the **numbers to EXCLUDE** (rescue any you still need),
  - review the **final verify screen** (KEEP + DELETE),
  - type **`DELETE`** to confirm.

The local script only *picks* the list — it then **dispatches the `prune` CI
workflow**, which deletes the tags and rebuilds `:latest` **on a runner**. The
local machine never deletes or pushes the big image. If the list is too large
for a workflow input, it aborts with a warning (prune in smaller batches).

> **Safety — you are the safety net.** There is no automated "is this pinned?"
> check: pins live across branches, release tags, and even repos OUTSIDE this
> org, so it can't be known for certain. Review the lists; keep anything a
> release or external consumer might still need. Nothing is deleted without your
> explicit `DELETE` confirmation, and grandfathered/clean RPMs are never offered.
>
> **On "newest":** ordering is by **container upload time**. The one-time
> backfill pushed many old RPMs in a single window, so their upload times don't
> reflect real build order — a backfilled tag can look "newest." This only
> affects the pre-existing backfilled set (the old ones you're pruning anyway);
> builds going forward upload in true order. When in doubt, exclude and keep.

### List RPMs in the served image

    ./list_rpms.sh

## How it works

**Every RPM is its own tag:** `ghcr.io/gemini-rtsw/rpm-repo:rpm-<NVRA>`, a tiny
`FROM scratch` image holding one `.rpm`. The tag key is the RPM's full identity
(Name-Version-Release-Arch = its filename), so a new version is a **new** tag —
tags ADD, never overwrite. These scratch tags are the single durable source of
truth for built and grandfathered RPMs alike.

`:latest` (the served nginx image) is a pure derived artifact, rebuilt from the
tags.

**Publishing is two steps:**

1. **Register (`upload-rpm.sh`)** — pack each RPM into a scratch image, push as
   `rpm-<NVRA>`. Unique key per artifact → no overwrite, no race. `--tag-only`
   stops here.
2. **Publish (`sync_repo.sh`)** — list every `rpm-*` tag, pull each (parallel),
   `createrepo_c`, bucket into stable layers, push `:latest`. It rebuilds
   **purely from the tag set** — no merge-pull of the old image, so no
   read-modify-write race; concurrent publishes converge.

### Why pure-from-tags

- **Any single RPM is retrievable** by pulling its `rpm-<NVRA>` tag — no need to
  pull the whole multi-GB image.
- **No read-modify-write, so no clobbering race** between concurrent publishes.
- The served image is reproducible at any time from the tags (which is why
  `sync_repo.sh` doubles as the heal command).

### Safety: never lose an RPM

The tags are the only source, so a missing tag means a missing RPM. Guards:

1. **Tag-pull completeness** — extracted RPM count is checked against the tag
   count; a failed pull aborts the publish rather than shipping an incomplete
   repo.
2. **Anti-truncation** — each publish records its RPM count in a tiny
   `rpm-count-*` marker tag; the next publish refuses to push a **smaller** repo
   unless `PRUNE_REBUILD=1` (set by the prune path for an intentional shrink).

### Bucketing

RPMs are distributed into a fixed number of buckets (`NUM_BUCKETS` in
`sync_repo.sh`, matching the `COPY` lines in `Dockerfile.rpm-repo`) so the image
stores them across many stable layers — unchanged buckets stay cached on
push/pull instead of moving one monolithic layer.

## Requirements

- **Docker** + **GHCR login** (`docker login ghcr.io`). The utility scripts
  auto-resolve a token from the environment, the `gh` CLI, or the Docker login,
  so they work locally without extra setup.
- For **pruning**, the dispatching token also needs `workflow` scope (to fire
  the `prune` workflow); the actual delete + rebuild use the runner's
  `GITHUB_TOKEN`.

## GitHub package access

For other org repos to pull `ghcr.io/gemini-rtsw/rpm-repo` (e.g. in CI), grant
access at **github.com/orgs/gemini-rtsw/packages/container/rpm-repo/settings** →
**Manage Actions access**:

- **Read** — repos that only consume the served repo (`:latest`).
- **Write** — project repos whose CI publishes via `upload-rpm.sh` (push their
  `rpm-<NVRA>` tags and rebuild `:latest`).

Tag listing/pulling uses the workflow `GITHUB_TOKEN` — no PAT required in CI.
