# cdk-deploy

Composite action that deploys an AWS CDK app via OIDC (shared
`github-actions-ci` role — no stored AWS keys), and optionally **fully automates
Cloudflare DNS** for an ACM-backed CloudFront site.

## Plain CDK deploy

```yaml
- uses: peavers/.github/actions/cdk-deploy@main
  with:
    working-directory: infra
```

## With Cloudflare DNS automation

Pass `domain` + `cloudflare-zone` (+ `distribution-id-param`) and the action:

1. publishes the **ACM validation CNAME** to Cloudflare *during* `cdk deploy`, so
   the certificate issues with no manual step (no waiting on `cdk deploy`);
2. after deploy, upserts the **site CNAME → CloudFront** (DNS-only by default —
   CloudFront/ACM own TLS).

```yaml
- uses: peavers/.github/actions/cdk-deploy@main
  with:
    working-directory: infra
    domain: peavers.io
    cloudflare-zone: peavers.io
    distribution-id-param: /peavers/landing/distribution-id
```

### Required one-time setup (Vault)

The Cloudflare path needs an API token in Vault, fetched the same way as
`gh-app-token` (GitHub OIDC → `jwt-github/ci`), so it MUST run on the in-cluster
self-hosted runners.

1. Create a Cloudflare API token scoped to **Zone → DNS → Edit** on the
   `peavers.io` zone (and **Zone → Read**).
2. Store it in Vault:

   ```bash
   vault kv put kv/cluster/_shared/cloudflare-dns api_token=<token>
   ```

3. Ensure the `jwt-github/ci` role's policy can read
   `kv/data/cluster/_shared/cloudflare-dns` (same policy that grants the GitHub
   App key).

### Runner requirements

`aws` CLI, `curl`, and `jq` must be on the runner image (aws + curl already are;
add `jq` if missing).
