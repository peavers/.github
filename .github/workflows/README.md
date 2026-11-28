# Reusable workflows (on: workflow_call)

## The golden path (v1)

Every repo builds the same few ways, so its own workflow should be a few
lines that call these. Pin to `@v1`: the tag only moves once a change has
passed in a canary repo, and a breaking change becomes `@v2`.

| Workflow | What it does |
| --- | --- |
| `rust.yml` | `cargo fmt --check`, `clippy -D warnings`, `test`; optional Postgres service, Nexus cargo registry |
| `node.yml` | `npm install`, then `npm run <script>` for each of `scripts` (default `lint test build`) |
| `gradle.yml` | `./gradlew build` with Java 25; optional Postgres service, Nexus maven |
| `image.yml` | Build a Dockerfile or Jib image and push it to ECR, tagged with the semver or 7-char SHA |
| `deploy.yml` | Record new image tags in the deploy repo's manifests and commit; Argo CD applies the commit |

Nothing here holds cluster credentials: a deploy is a commit to
`peavers-code/kubernetes-cluster` (or another deploy repo), Argo CD applies it
and posts `argocd/<app>` on that commit.

A whole service, CI and deploy:

```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:
permissions:
  contents: read
  id-token: write   # Vault (Nexus, the deploy commit) and AWS (ECR), all OIDC
jobs:
  ci:
    uses: peavers/.github/.github/workflows/node.yml@v1
  image:
    needs: ci
    if: github.ref == 'refs/heads/main'
    uses: peavers/.github/.github/workflows/image.yml@v1
    with:
      image: peavers/addonsentry-admin
  deploy:
    needs: image
    uses: peavers/.github/.github/workflows/deploy.yml@v1
    with:
      path: kubernetes/addonsentry-admin
      images: peavers/addonsentry-admin=${{ needs.image.outputs.version }}
```

Repo-specific checks stay as their own job beside `ci`. Older workflows below
(`gradle-jib-publish`, `dockerfile-buildx-publish`, `k8s-deploy`) predate this
and are on their way out: `k8s-deploy` needs the in-cluster runners, which no
longer exist.

## Everything else

. Reference as:
#   uses: peavers/.github/.github/workflows/<file>@main
