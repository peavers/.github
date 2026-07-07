# peavers/.github — shared GitHub Actions

The org's central library of **composite actions**, **reusable workflows**, and
**org workflow templates**. Reference these from any repo in any of the peavers
orgs (this repo is public, so cross-org references need no extra config).

## Layout

```
actions/                 composite actions  ->  uses: peavers/.github/actions/<name>@main
  gh-app-token/          mint a GitHub App token via Vault OIDC (PAT replacement)
  compute-version/       derive an immutable image tag (semver / 7-char SHA)
.github/
  workflows/             reusable workflows ->  uses: peavers/.github/.github/workflows/<file>@main
    gradle-jib-publish        build a Spring Boot service with Jib -> Harbor
    dockerfile-buildx-publish build a Dockerfile image with Buildx -> Harbor
    k8s-deploy                kubectl set image + rollout for N deployments
    sonarqube                 Gradle + optional Node coverage -> SonarQube scan
    mkdocs-pages              build MkDocs -> deploy to GitHub Pages
    cdk-deploy                deploy an AWS CDK app (+ optional Cloudflare DNS)
    static-site-deploy        build a static site -> S3 + CloudFront
workflow-templates/      org "New workflow" gallery (peavers org repos)
```

> Pin to a tag/SHA (`@v1`) rather than `@main` for anything you don't want moving
> under you. `@main` is fine while this library is young.

## Actions

### `actions/gh-app-token` — App token instead of a PAT

Mints a short-lived (~1h) GitHub App installation token by exchanging the
workflow's GitHub OIDC JWT at Vault (`jwt-github/ci`) for the App private key,
then calling `actions/create-github-app-token`. **Nothing long-lived is stored in
GitHub.** This mirrors the cluster's AWS-OIDC bridge.

**Requirements**
- Runs on the **in-cluster self-hosted runners** — Vault is internal-only.
- Caller job sets `permissions: { id-token: write, contents: read }`.
- One-time cluster setup: `kubernetes/vault/github-app-setup.sh <APP_ID> <key.pem>`
  in the `kubernetes-cluster` repo (creates the KV entry + `jwt-github/ci` role).

**Usage**

```yaml
jobs:
  release:
    runs-on: [self-hosted]
    permissions:
      id-token: write        # request the OIDC JWT
      contents: read
    steps:
      - uses: peavers/.github/actions/gh-app-token@main
        id: ghtoken

      - uses: actions/checkout@v4
        with:
          token: ${{ steps.ghtoken.outputs.token }}   # checkout/push as the App

      - name: commit & push as the bot
        run: |
          git config user.name  "valhalla-ci[bot]"
          git config user.email "<APP_ID>+valhalla-ci[bot]@users.noreply.github.com"
          git commit --allow-empty -m "release: bump"
          git push
```

Notes:
- App-token pushes **do** trigger downstream workflows (a `GITHUB_TOKEN` push does
  not) — usually the whole reason a PAT was there.
- Need `packages:write` / `pull-requests:write` etc.? Grant it on the **GitHub
  App**; the installation token inherits the App's permissions.

### `actions/compute-version` — immutable image tag

Outputs `version` (the semver from a `v*` tag with the leading `v` stripped,
otherwise the 7-char commit SHA) and `tags` (`latest,<version>`). Used by the
build workflows below so every push gets a unique, reproducible tag.

## Reusable workflows — JVM services (Harbor + K8s)

The Gradle/Spring Boot service pipeline. All build/deploy jobs pull Harbor and
SonarQube creds from in-cluster Vault, so they **MUST run on the self-hosted
in-cluster runners** (`warcraft-runners` by default; pass `runner:` to override,
e.g. `peavers-code-runners`). The calling job must set
`permissions: { id-token: write, contents: read }` for the Vault OIDC exchange.

- `gradle-jib-publish.yml` — `./gradlew jib` -> Harbor. Inputs: `working-directory`,
  `image`, `java-version` (25), `runner`, `registry`. Outputs `version`/`tags`.
- `dockerfile-buildx-publish.yml` — Buildx build -> Harbor. Inputs: `context`,
  `image`, `platforms`, `file`, `runner`, `registry`. Outputs `version`/`tags`.
- `k8s-deploy.yml` — `kubectl set image` + `rollout status`. Inputs: `namespace`,
  `version`, `targets` (JSON array of `{deployment, container, image, timeout}`),
  `runner`.
- `sonarqube.yml` — Gradle build/test + JaCoCo (postgres + redis service
  containers) and an optional Node build, then a Sonar scan + quality gate.
  Inputs: `gradle-directory`, `node-enabled`, `node-directory`, `java-version`,
  `runner`.
- `mkdocs-pages.yml` — `mkdocs build` -> GitHub Pages (runs on `ubuntu-latest`;
  no Vault). Caller keeps `pages: write` / `id-token: write` and
  `concurrency: { group: pages }`.

**Vault prerequisites** (KV under `kv/data/cluster/_shared/`): `harbor`
(`username`, `password`) and `sonarqube` (`token`, `host_url`).

## Conventions

- One directory per composite action under `actions/<name>/action.yml`.
- Reusable workflows go in `.github/workflows/` and use `on: workflow_call`.
- Keep secrets out of here — auth flows through Vault/OIDC, never stored keys.
