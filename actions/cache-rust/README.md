# cache-rust

Points `rustc` at [sccache](https://github.com/mozilla/sccache) backed by the
**GitHub Actions cache**. sccache caches individual compilation units, so a warm
build recompiles only what changed, across branches and runs, with no `target/`
archive to save or restore.

```yaml
- uses: peavers/.github/actions/cache-rust@main
- run: cargo build --locked
```

| input | default | |
|---|---|---|
| `version` | `0.19.0` | sccache release to install |
| `required` | `true` | fail if sccache cannot start, instead of compiling cold |
| `key-prefix` | `""` | separates jobs within the repo's cache (`SCCACHE_GHA_VERSION`) |

It installs sccache with `mozilla-actions/sccache-action` (which also exports the
Actions runtime token sccache's GHA backend needs) and writes `RUSTC_WRAPPER`,
`SCCACHE_GHA_ENABLED` and `CARGO_INCREMENTAL=0` to `$GITHUB_ENV`.

History: until 2026-11-21 this used a shared bucket in the cluster's MinIO,
reached from outside through the `cache-ci` tunnel with credentials from Vault.
MinIO was retired when its images stopped being published.
