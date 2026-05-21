# Quickstart

Use this guide for bootstrap only:
- workstation prerequisites
- machine-specific [`vars.nix`](../vars.nix) setup
- secrets staging
- the initial agenix key install on a target host
- blank-machine bootstrap up to the first deploy

This guide is intentionally the exception path. Normal day-2 operations now use
the remote archive workflow from [Operations](./operations.md), so the desktop
does not need local Nix for validation or deploys once the server already
exists.

## Generate And Stage Secrets

Before generating secrets, configure the main install in [`vars.nix`](../vars.nix).
For a new one-host install, start from [`vars.example.nix`](../vars.example.nix):

```bash
cp vars.example.nix vars.nix
$EDITOR vars.nix
```

For a reusable template copy, inspect [`hosts/example/settings.nix`](../hosts/example/settings.nix)
or create a new site with:

```bash
nix run .#init-site -- --site my-home
```

Run the non-destructive config readiness check before any deploy or blank-machine work:

```bash
nix run .#validate-config-readiness -- --host dsaw
nix run .#show-config-summary -- --host dsaw
```

Generate repo-managed secrets and encrypt the staged inputs with the single documented secrets entrypoint:

```bash
./scripts/generate-all-secrets.sh
```

Expected result:
- encrypted secrets under `secrets/` update without leaving cleartext material outside `secrets/top/`
- no error reports a missing staged input or invalid JSON for `cfHomeCreds`
- `secrets/pubkeys/age.pub` matches the private key you plan to install on the target host

For normal day-2 operations, you can instead sync the repo to the running
server and execute the same entrypoint there:

```bash
ssh <admin>@<hostname> 'cd /path/to/repo && ./scripts/generate-all-secrets.sh'
```

## Blank-Machine Bootstrap

Boot a recent NixOS installer ISO, get network access, then clone the repo.

```bash
mkdir -p /mnt/src
git clone <your-fork-or-origin-url> /mnt/src
cd /mnt/src
```

This repo no longer maintains destructive disk-wrapper helpers. Treat [`bootstrap/disko-system.nix`](../bootstrap/disko-system.nix) and [`bootstrap/disko-data.nix`](../bootstrap/disko-data.nix) as blank-machine bootstrap references only. If the machine is blank, provision the system SSD and data pool with those declarations or with your own equivalent process before continuing with install-time mounting. Do not use `disko` to manage an already-installed server or an in-place storage migration.

Once the target filesystem layout is mounted under `/mnt`, copy the repo into the installed system, install the agenix key, and install the OS.

```bash
cp -r /mnt/src/* /mnt/etc/nixos
nixos-generate-config --root /mnt
install -d -m 0700 /mnt/etc/agenix
install -m 0400 /path/to/agenix.key /mnt/etc/agenix/age.key
nixos-install --flake /mnt/etc/nixos#server
reboot
```
