# Glossary

## NixOS
Linux distribution where the whole system is defined by configuration files.

## Flake
Nix packaging/config format that locks dependencies and standardizes outputs.

## agenix / age
Tooling for storing encrypted secrets in the repository and decrypting on host at runtime.

## Caddy
Reverse proxy that routes incoming HTTPS requests to local services.

## Cloudflare Tunnel
Outbound tunnel from your server to Cloudflare so selected hostnames are reachable publicly without opening broad inbound ports.

## Kanidm
Identity provider (IdP) that handles user accounts, groups, and OIDC login.

## OIDC (OpenID Connect)
Standard login protocol apps use to authenticate through an identity provider.

## OAuth2 Proxy
Auth gateway that sits in front of an app and requires OIDC login before passing traffic.

## NetBird
WireGuard-based private mesh network for secure remote access.

## Unbound
DNS resolver/authority used here for private hostname answers on NetBird.

## DNS-01 ACME
Certificate challenge method based on DNS records rather than direct inbound web traffic.

## Disko
Declarative disk partition/filesystem layout for NixOS.

## mergerfs
Virtual filesystem that merges multiple data disks into one view.

## SnapRAID
Parity-based protection for data disks (helps recover from disk failure, not a full backup).
