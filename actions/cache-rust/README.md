# cache-rust

Restore and save the Cargo build cache to the in-cluster **MinIO** bucket
`actions-cache`, using the `MINIO_*` credentials the ARC runners already carry.

## Why this exists

Swatinem/rust-cache stores the Rust `target/` directory in GitHub's hosted
Actions cache, which has a hard **10 GB per-repo limit** and evicts
least-recently-used. A Rust `target/` is a few gigabytes, so a couple of
branches in flight push the repo over the limit and the next build restores
nothing — a cold eight-minute `clippy` at random. The runners are also
**ephemeral** (Kubernetes/ARC pods), so nothing persists on local disk.

MinIO has no such ceiling and lives inside the cluster, so the transfer is local
rather than a round trip to GitHub. The `actions-cache` bucket and a scoped
`runners-cache` user were already provisioned for this (`minio-cache-credentials`
in `arc-runners`); this action is the piece that uses them.

## Usage

Call it twice — once to restore before the build, once to save after, with
`if: always()` so a failed build still seeds the cache for the next one. A
composite action cannot register a post step, which is why it is two calls
rather than one.

```yaml
- uses: actions/checkout@v4
- uses: dtolnay/rust-toolchain@stable
  with:
    components: rustfmt, clippy

- uses: peavers/.github/actions/cache-rust@main
  with:
    phase: restore
    key: verify        # jobs that compile the same way share a key

- run: cargo clippy --workspace --all-targets -- -D warnings
- run: cargo test --workspace

- uses: peavers/.github/actions/cache-rust@main
  if: always()
  with:
    phase: save
    key: verify
```

## Inputs

| Input | Required | Default | Meaning |
|-------|----------|---------|---------|
| `phase` | yes | — | `restore` before the build, `save` after. |
| `key` | no | `default` | Names the cache slot. Jobs that compile the same way (the clippy + test verify jobs) should share one; a release build that differs should not, so it does not restore a test-profile `target/` over its own. |

## Behaviour

- **One moving object per `(repo, key, OS)`**, deliberately *not* keyed on the
  lockfile. Restoring the previous run's `target/` even when a dependency
  changed is the point — cargo recompiles what differs and reuses the rest. A
  lockfile-keyed cache would go cold on every dependency bump, which is exactly
  when a build is slowest.
- **Never fails the build.** A missing or corrupt cache, or a runner set with no
  `MINIO_*` wired, degrades to a cold build, never an error.
- **zstd** compression when available (fast on a multi-GB tree), gzip otherwise.

## Requirements

The runner must have `MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY`, `MINIO_ENDPOINT`,
`MINIO_PORT`, `MINIO_BUCKET` in its environment (the arc-runners
`minio-cache-credentials` secret) and the `aws` CLI on `PATH`. Both are already
present on the peavers runner image.
