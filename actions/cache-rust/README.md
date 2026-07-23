# cache-rust

Point the Rust compiler at a shared **sccache** backed by the in-cluster
**MinIO** bucket `actions-cache`, using the `MINIO_*` credentials the ARC runners
already carry.

## Why sccache, not a target-dir cache

The runners are **ephemeral** Kubernetes pods — nothing persists on local disk.
Swatinem/rust-cache stores the whole `target/` in GitHub's Actions cache, which
**evicts under a 10 GB per-repo limit**; a Rust target dir is a few GB, so it
drops out and `clippy` compiles cold (~8 min) at random. Tarring `target/` to
object storage instead just trades that for moving multiple gigabytes every run —
slow, and it fills an ephemeral pod's small disk.

**sccache** caches individual compilation units in object storage and writes
through as the compiler runs. A warm build fetches only the objects it needs, so
there is no giant archive and no `target/` juggling. MinIO has no 10 GB ceiling
and lives in the cluster, so hits are local. It pairs with `CARGO_INCREMENTAL=0`
(already set on the runners), which sccache needs anyway.

## Usage

One call, before the build. Nothing to save afterwards — sccache writes through
as it compiles.

```yaml
- uses: actions/checkout@v4
- uses: dtolnay/rust-toolchain@stable
  with:
    components: rustfmt, clippy

- uses: peavers/.github/actions/cache-rust@main

- run: cargo clippy --workspace --all-targets -- -D warnings
- run: cargo test --workspace
```

## Inputs

| Input | Default | Meaning |
|-------|---------|---------|
| `version` | `0.8.2` | sccache release to install if the runner image doesn't ship it. |
| `key-prefix` | `sccache/<repo>` | Namespaces this repo's objects in the bucket, so projects don't collide or evict each other. |

## Behaviour

- **Installs sccache** (static musl build, ~10 MB) only if absent, then exports
  `RUSTC_WRAPPER=sccache` and the MinIO S3 config to `$GITHUB_ENV` for every
  later step in the job.
- **Never fails the build.** No credentials, no sccache download, or a server
  that won't start all degrade to a normal (uncached) compile, never an error.
- **No save step.** sccache is write-through; there is nothing to upload at the
  end and no post-step to register.

## Requirements

`MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY`, `MINIO_ENDPOINT`, `MINIO_PORT`,
`MINIO_BUCKET` in the runner environment (the arc-runners
`minio-cache-credentials` secret), and `curl`. Both are present on the peavers
runner image. Baking the sccache binary into that image would save the one-time
download; until then it is fetched per job.
