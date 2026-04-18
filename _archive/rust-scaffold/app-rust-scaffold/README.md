# Rust Scaffold

This is the first repo-local Rust app in this server configuration.

It exists to prove the full workflow:

- edit Rust code directly in this repository
- edit local assets like [`static/custom.css`](./static/custom.css)
- rebuild with Nix
- run locally with `nix run`
- later deploy through a dedicated NixOS module

## Common commands

From repo root:

```bash
nix develop .#rust-scaffold
cargo fmt
cargo clippy --all-targets -- -D warnings
cargo nextest run
cargo run
```

Or use the flake outputs directly:

```bash
nix build .#rust-scaffold
nix run .#rust-scaffold
```

The app exposes:

- `GET /`
- `GET /healthz`
- `GET /static/custom.css`
