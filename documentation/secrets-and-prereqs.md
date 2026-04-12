# Secrets and Prerequisites

This stack depends on external systems before first deploy.

## External prerequisites
- Cloudflare account with zone for `<domain>`.
- Cloudflare Tunnel created for this host.
- NetBird management account and reusable setup key for server enrollment.
- Nix-enabled admin workstation with `age`, `jq`, and `openssl`.

## Required staged files in `secrets/top/`
Before rerunning `./scripts/gen-all-secrets.sh`, ensure these files exist:
- `secrets/top/netbirdSetupKey`
- `secrets/top/cfHomeCreds`
- `secrets/top/cfAPIToken`

`gen-all-secrets.sh` validates and encrypts these into `.age` files.

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

Generated app/auth secrets include Kanidm admin credentials, OIDC client secrets, OAuth2 Proxy secrets, and app bootstrap secrets.

After successful encryption, remove cleartext staged files from `secrets/top/`.
