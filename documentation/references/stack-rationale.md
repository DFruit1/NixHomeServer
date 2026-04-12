# Stack Rationale

This explains why each major component exists in this repository.

## Decision priorities
- Reproducibility: same config rebuilds the same system state.
- Security boundaries: minimal public attack surface.
- Operational clarity: each service has a clear job and trust boundary.

## Component choices
| Component | Why it is used | What it solves |
|---|---|---|
| NixOS + flakes | Declarative and reproducible host config | Prevents configuration drift over time |
| agenix (`age`) | Encrypted secrets in repo workflow | Keeps secret material out of plaintext config |
| Caddy | Simple, auditable reverse-proxy boundary | Centralizes TLS and app routing policy |
| Cloudflare Tunnel | Publish specific endpoints without opening broad inbound ports | Protects home IP and limits internet exposure |
| Kanidm | Self-hosted identity provider with OIDC support | One source of truth for accounts and groups |
| OAuth2 Proxy | Auth gateway in front of apps without native OIDC boundary controls | Adds policy/auth layer for public file access |
| NetBird | WireGuard-based private mesh access | Reaches private apps securely from any network |
| Unbound (+ dnscrypt-proxy) | Local private DNS authority + controlled upstream recursion | Consistent private hostname behavior |
| Disko | Declarative disk partition/filesystem layout | Repeatable storage provisioning |
| mergerfs + SnapRAID | Flexible multi-disk storage with parity | Practical home-server storage resilience |

## Why only two public endpoints
Public internet is intentionally limited to:
- `id.<domain>` for identity/OIDC flow
- `files.<domain>` for controlled file sharing

Everything else remains private over NetBird to reduce external attack surface.

## Why group-based access in Kanidm
Group membership is easier to audit and maintain than per-app local users. It also centralizes access decisions:
- `users` for baseline identity only
- per-app `*-users` groups for actual application access
- per-app `*-admin` groups for intended application administrators
- `fileshare_users` for public files flow
- `idm_admins` for delegated identity admin
- `kavita-*` for app role sync
