# Secrets and Prerequisites

This stack depends on external systems before first deploy.

## External prerequisites
- Cloudflare account with zone for `<domain>`.
- Cloudflare Tunnel created for this host.
- NetBird management account and reusable setup key for server enrollment.
- Nix-enabled admin workstation with `age`, `jq`, and `openssl`.

## Required staged files in `secrets/top/`
Before running the staged-secret encryptor, ensure these files exist:
- `secrets/top/netbirdSetupKey`
- `secrets/top/cfHomeCreds`
- `secrets/top/cfAPIToken`
- `secrets/top/storageAlertWebhookUrl`

`scripts/gen-all-secrets.sh` is the only documented operator entrypoint. It validates staged inputs, generates repo-managed secrets, and writes the encrypted `.age` files.

## Expected formats
### `netbirdSetupKey`
Plain token string from NetBird setup key (no extra whitespace/newlines).

### `cfHomeCreds`
Cloudflared credentials JSON containing at least:
- `AccountTag`
- `TunnelID`
- `TunnelSecret`

### `cfAPIToken`
Either form is accepted:
```bash
CLOUDFLARE_DNS_API_TOKEN=<token>
```
or
```bash
CLOUDFLARE_ZONE_API_TOKEN=<token>
```

The script normalizes this secret so both token variable names are exported for ACME.

### `storageAlertWebhookUrl`
Single webhook URL for storage alerts:
```bash
https://ntfy.example.test/storage
```

Use one `http://...` or `https://...` URL with no extra whitespace or newlines.

## Age key handling
Generate key pair on workstation:
```bash
mkdir -p ~/.age
age-keygen -o ~/.age/agenix.key
mkdir -p secrets/pubkeys
age-keygen -y ~/.age/agenix.key > secrets/pubkeys/age.pub
```

Install private key on host:
```bash
install -d -m 0700 /etc/agenix
install -m 0400 /path/to/agenix.key /etc/agenix/age.key
```

If repository already contains encrypted secrets, reuse the matching private key for the existing public recipient set. Do not generate a new key unless you plan a full recipient rotation.

## Generate encrypted secrets
```bash
./scripts/gen-all-secrets.sh
```

Generated app/auth secrets include:

- Kanidm admin credentials
- OIDC client secrets
- OAuth2 Proxy secrets
- app bootstrap secrets

Mail archive credentials are intentionally different:

- do not add mailbox app passwords or provider tokens to agenix in this phase
- the app stores them encrypted at rest under `/mnt/data/appdata/mail-archive-ui`
- temporary sync material is written only under `/run/mail-archive-ui`
- downloaded Maildir content lives under `/mnt/data/mail-archive`

`storageAlertWebhookUrl` is a required staged external secret. The repo may
carry a placeholder encrypted value so config evaluation still works before the
real webhook is staged, but production alerts stay disabled until you replace
that placeholder with a real staged webhook URL and rerun
`./scripts/gen-all-secrets.sh`.

Internal helpers such as `generate-managed-secrets.sh`,
`encrypt-staged-secrets.sh`, and `lib-secrets.sh` remain in-tree, but they are
implementation details rather than part of the public operator workflow.

After successful encryption, remove cleartext staged files from `secrets/top/`.
