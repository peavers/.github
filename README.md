# peavers/.github — shared GitHub Actions

The org's central library of **composite actions**, **reusable workflows**, and
**org workflow templates**. Reference these from any repo in any of the peavers
orgs (this repo is public, so cross-org references need no extra config).

## Layout

```
actions/                 composite actions  ->  uses: peavers/.github/actions/<name>@main
  gh-app-token/          mint a GitHub App token via Vault OIDC (PAT replacement)
  valhalla-auth/         fetch Harbor / Nexus credentials from Vault at run time
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

### `actions/valhalla-auth` — home-lab credentials, at run time

The self-hosted runner pods used to mount `~/.docker/config.json`,
`~/.m2/settings.xml` + `NEXUS_PASSWORD` and `~/.kube/config` into every job.
Workflows used them without declaring them, so no repo recorded the dependency
and no job could run anywhere but in-cluster.

This fetches only what a job asks for, through the same OIDC exchange
`gh-app-token` uses. The `with:` block becomes an accurate statement of what the
job can reach.

```yaml
permissions:
  id-token: write          # required - the OIDC token is the only credential
  contents: read

steps:
  - uses: peavers/.github/actions/valhalla-auth@main
    with:
      harbor: true         # docker login docker.valhalla.life
      cargo: true          # CARGO_REGISTRIES_VALHALLA_TOKEN
      maven: true          # ~/.m2/settings.xml + NEXUS_USERNAME/PASSWORD
      npm: true            # ~/.npmrc for the @parses scope
```

`strict` defaults to **true** and deletes the runner-mounted copies first. While
the pods still mount them a broken call here would be invisible - the old file is
still on disk and the build still passes. A job green under `strict` is proven not
to need the mounts.

**It finds Vault by itself.** The action probes the in-cluster service and falls
back to the tunnel hostname when there is no route to it, so the same workflow
works on an in-cluster runner and on an external one with no configuration.

TLS verification is *derived* from which one answered - private CA in-cluster,
publicly trusted certificate through the tunnel. That is deliberate: it removes
the failure where somebody repoints the URL and leaves verification off against a
public endpoint, which nothing anywhere would report.

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

## Moving a repo's jobs off the cluster

Every reusable workflow here except `k8s-deploy` resolves its runner as:

```yaml
runs-on: ${{ vars.RUNNER_LABEL || inputs.runner }}
```

`vars` in a reusable workflow is read from the **calling** repository, so one
variable moves that repo's jobs with no commit anywhere:

```sh
gh variable set RUNNER_LABEL -R <owner>/<repo> -b blacksmith-4vcpu-ubuntu-2404
gh variable delete RUNNER_LABEL -R <owner>/<repo>     # and back
```

Unset falls through to `inputs.runner`, which is today's behaviour, so this
changes nothing until a variable is set. It is a switch rather than a commit so
one repo can be moved, watched for a week, and reverted without a PR.

**Before setting it, check the repo reaches nothing in-cluster.** Vault
(`vault.vault.svc.cluster.local`) has no route from outside, so anything using
`valhalla-auth`, `gh-app-token` or its own `vault-action` still has to run
in-cluster. `k8s-deploy` is deliberately excluded - it runs `kubectl`.

A caller with a mix - one job portable, one not - pins the literal in its own
workflow for the job that must stay, rather than setting the variable.

## Conventions

- One directory per composite action under `actions/<name>/action.yml`.
- Reusable workflows go in `.github/workflows/` and use `on: workflow_call`.
- Keep secrets out of here — auth flows through Vault/OIDC, never stored keys.
