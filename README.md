# NixHomeServer

NixHomeServer is a reproducible NixOS home-server configuration for people who
want to run more of their digital life at home: photos, files, documents,
passwords, media, backups, and private app access.

What apps do you get?

- `immich`: photos and videos with private albums, person/group tools, and backup sync.
- `paperless`: document capture, OCR, and searchable filing for receipts, PDFs, and paperwork.
- `filestash`: web and SFTP file browser to work from browsers and remote devices.
- `jellyfin`: media server for home streaming to phones, TVs, and web players.
- `audiobookshelf`: organized audiobooks and podcast listening.
- `kavita`: ebook and comic library organization and reading.
- `kiwix`: local offline knowledge/reference collections.
- `vaultwarden`: private password manager replacement for hosted vaults.
- `mail-archive-ui`: searchable mailbox archive with attachments and document handoff.
- `sonarr`, `radarr`, `prowlarr`, `qbittorrent`: optional media automation stack for tracking and downloading.
- `youtube-downloader`: optional queue for downloading public audio/video for offline use.
- `offline-music`: optional home offline media sync workflows (typically built on folders and Syncthing).
- `groundwater-logger`: optional environmental telemetry and logging package.

## Stage 2: Check The Hardware First

Do this before creating accounts or editing config. If the hardware plan is
wrong, every later step becomes harder.

This repo supports `x86_64-linux` and `aarch64-linux` NixOS systems that boot
with UEFI. The current server profile remains an x86_64 ZFS-mirror home server,
while the portable profile is intended for simple repurposed laptops, mini PCs,
and ARM devices with one disk. Avoid locked-down consumer NAS appliances and
machines where replacing the operating system is a project by itself.

What you will need:

- 8 GB RAM minimum (16GB ideal).
- Wired Ethernet.
- One SSD or internal disk you are willing to erase.
- For `storage.profile = "zfs-mirror"`: at least three usable disk attachment
  points, one for the operating system and two or more for the mirrored ZFS pool.
- For `storage.profile = "single-disk-ext4"`: one disk is enough; system state
  and app data both live on that disk.

*If your PC motherboard only has two SATA ports, you can either use an NVME (if the motherboard has a slot for it) or buy a sata splitter.

The model names below are examples to help you search. Manufacturers change
configurations under the same product family, so confirm the exact CPU, RAM,
drive bays, M.2 slots, SATA ports, and network ports before buying.

Internal SATA bays are strongly preferred for the data disks. USB hard-drive
enclosures can be useful for backups, but they are a worse foundation for the
main mirrored pool because disconnects, flaky bridges, and inconsistent disk
identifiers make recovery harder.

### Good Server Shapes

NAS-style mini PC with internal bays:

- Best fit when you want a compact machine and do not want to build a desktop.
- Look for four 3.5-inch SATA bays, at least one NVMe slot for the system SSD,
  replaceable RAM, and Intel/AMD x86_64 CPU.
- Example: AOOSTAR WTR Pro 4-bay NAS mini PC. AOOSTAR lists WTR Pro models with
  four drive bays, dual 2.5GbE networking, and AMD Ryzen or Intel variants.
- Why it fits this repo: the data disks can live inside the same box, while the
  OS can live on an NVMe SSD.

Used business small-form-factor desktop:

- Best fit when you want good value and easy parts replacement.
- Look for "SFF", not "Tiny" or "Micro", if you want internal 3.5-inch disks.
  Tiny/Micro machines are excellent little computers but usually do not have
  room for mirrored 3.5-inch hard drives.
- Examples to search for: HP EliteDesk 800 G6 SFF, Dell OptiPlex 7080 SFF,
  Lenovo ThinkCentre M70s Gen 5 or M75s Gen 5 SFF.
- Why it fits this repo: these machines are normal UEFI x86 PCs, usually have
  wired Ethernet, standard RAM, one or more M.2 slots, and at least some
  internal drive expansion. Check the exact drive-bay layout before buying.

Small custom desktop:

- Best fit when you are comfortable choosing parts or want quiet cooling and
  more disk bays.
- Look for a case with at least two 3.5-inch bays, a motherboard with enough
  SATA ports, an NVMe slot, and a modest Intel or AMD CPU.
- Why it fits this repo: it is the easiest shape to repair and expand later.

Tiny mini PC:

- Use only if you deliberately want an SSD-only server or separate dedicated
  storage.
- Examples: Beelink EQ14, GMKtec NucBox G3 Plus, Lenovo ThinkCentre M70q Tiny,
  Minisforum MS-01.
- Why to be cautious: most tiny PCs do not have room for two 3.5-inch data
  disks. They can run the services, but they do not match this repo's default
  "system SSD plus mirrored HDD data pool" storage shape unless you add a
  separate storage plan.

### System SSD

The system SSD is where NixOS, the Nix store, and persistent system state live.
This disk will be wiped during bootstrap.

Buy based on the slot your machine has:

- NVMe M.2 SSD if the machine has an M.2 NVMe slot.
- 2.5-inch SATA SSD if the machine only has SATA.

Practical size:

- 500 GB is workable.
- 1 TB is a better default.
- 2 TB is comfortable if you expect lots of Nix generations, logs, caches, or
  local build artifacts.

Example SSDs:

- Samsung 990 PRO NVMe: fast PCIe 4.0 option for machines with NVMe slots.
- WD Red SN700 NVMe: NAS-oriented NVMe option designed for always-on workloads.
- Crucial MX500 2.5-inch SATA: good option when the machine does not have NVMe.
- Samsung 870 EVO 2.5-inch SATA: another common SATA SSD option.

Do not spend extra on a very large system SSD if the data pool is where photos,
media, documents, and backups will live. The data disks matter more for capacity.

### Data HDDs

The data disks hold user files, photos, media, documents, app data, and backups
under `/mnt/data`. They will be wiped during bootstrap.

Use NAS-class 3.5-inch SATA hard drives where possible. NAS drives are designed
for always-on multi-disk systems. Buy at least two drives of the same capacity
for the first mirror.

Practical size:

- 4 TB mirror: fine for learning and light documents.
- 8 TB mirror: better starting point for photos and media.
- 12 TB to 20 TB mirror: better if you already have a large photo/video/media
  library.

Example HDD families:

- WD Red Plus.
- Seagate IronWolf.
- Toshiba N300.

Prefer CMR drives for ZFS mirrors. CMR is the conventional recording method and
behaves predictably for sustained writes and rebuilds. Avoid SMR drives for the
main data pool; SMR can be acceptable for some archive workloads but is a poor
default for a ZFS mirror that may need to resilver after a disk replacement.
Retail listings are not always clear, so check the manufacturer model details
before buying.

Buy one extra external USB hard drive, or plan another offsite backup target,
for backups. A mirror helps with disk failure. It does not protect you from
accidental deletion, fire, theft, or bad configuration.

### Hardware Checklist

Before proceeding, make sure you have:

- x86_64 or aarch64 target server with UEFI boot.
- Keyboard/monitor or another console method for the first installer boot.
- Wired network connection.
- One SSD or internal disk you are willing to erase for the system.
- For `zfs-mirror`, two or more data disks you are willing to erase for the ZFS mirror.
- For `single-disk-ext4`, no separate data disks are required.
- A separate backup of anything currently on those disks.

Do not continue with bootstrap if any selected disk contains data you still need
and have not copied somewhere else.

## Stage 3: Choose The Home-Network Shape

This is the first networking decision. You do not need to know everything about
DNS yet. You only need to choose how devices in your home will find the server.

The server can run in two modes:

- Split-DNS mode: best home experience, requires router DNS/DHCP configuration.
- NetBird-only mode: simpler router requirements, but only NetBird-enrolled
  devices get the private access experience.

### Option A: Split-DNS Home Network

Choose this if you want home devices to open normal names like
`photos.example.com` or `files.example.com` and reach the server directly on
your LAN.

In this mode, your server runs private DNS for your home. DNS is the phone book
that turns names into IP addresses. Split DNS means the same name can resolve
differently depending on where you are:

- At home, private app names can point directly to the server's LAN address.
- Away from home, private access can use NetBird.
- Public share names can still use Cloudflare Tunnel when appropriate.

Your router must be able to do two things:

- Give the server a stable address, either through a DHCP address reservation or
  by staying out of the way while the server uses the static LAN address from
  `vars.nix`.
- Tell home devices to use the server as their DNS resolver, or force/override
  client DNS to the server.

A GL.iNet Flint 2 is a reasonable example router for this shape. GL.iNet's
current router docs expose LAN DHCP settings and address reservation under
`NETWORK -> LAN`, and DNS settings such as custom DNS and client DNS override
under `NETWORK -> DNS`:

- GL.iNet LAN docs: <https://docs.gl-inet.com/router/en/4/interface_guide/lan/>
- GL.iNet DNS docs: <https://docs.gl-inet.com/router/en/4/interface_guide/dns/>

You do not configure the router first during bootstrap because the server DNS
does not exist yet. You choose this path now, install the server, then point the
router's LAN DNS behavior at the server after the server is healthy.

Use this repo setting:

```nix
dnsSettings.mode = "split-horizon";
```

Tradeoff: this is the nicest daily experience at home, but DNS becomes part of
your home infrastructure. If the server is down and your router hands out only
the server as DNS, ordinary browsing on home devices may lose name resolution
until you change router DNS or bring the server back.

### Option B: NetBird-Only Network

Choose this if you do not want to change router DNS behavior, cannot replace
your router, or want the simplest first install.

NetBird is the private road back to the server. Devices that join your NetBird
network can reach private services through that private network. Devices that
are not enrolled in NetBird do not get the same private-name experience.

In this mode, your router does not need to point household DNS to the server.
The server still needs a sane LAN address for administration and local network
stability, but the router does not need special split-DNS behavior.

Use this repo setting:

```nix
dnsSettings.mode = "netbird-only";
```

Tradeoff: this is easier to set up, but every laptop or phone that needs private
services must be enrolled in NetBird. Devices that cannot run NetBird, such as
some TVs or appliances, may not be able to use private app hostnames directly.

### Values To Record Now

Whichever option you choose, write down:

- Server hostname, for example `home-server`.
- Domain name, for example `example.com`.
- LAN IP you want the server to use, for example `192.168.8.10`.
- LAN prefix length, often `24` on home networks.
- Gateway/router IP, for example `192.168.8.1`.
- Whether `dnsSettings.mode` will be `split-horizon` or `netbird-only`.

The network interface name, such as `eth0` or `enp3s0`, must be confirmed on
the real server during the installer stage. Do not guess it from your laptop.

## Stage 4: Gather External Accounts And Secrets

Before you start editing `vars.nix`, create the required external accounts in a practical order. The order matters because each step depends on the previous one.

```mermaid
flowchart LR
  A["Create/confirm domain source"] --> B["Cloudflare account + domain DNS setup"]
  B --> C["Cloudflare API token + Tunnel credentials"]
  C --> D["NetBird account + default network"]
  D --> E["MEGA account (offsite backup target)"]
  E --> F["SSH admin key + local admin plan"]
  F --> G["vars.nix + secret files"]
  G --> H["bootstrap"]
```

### Step 1: Set the ownership model and account plan

Pick one person as the server bootstrap operator.

1. Confirm where the domain will be managed:
   - If you already own a domain, decide whether to move DNS to Cloudflare.
   - If you need a new domain, buy it first before the bootstrap session.
2. Decide which email/MFA method you will use across Cloudflare, NetBird, and
   MEGA.
   - Use a second secure email provider (for example Tuta, Proton, or Fastmail) as
     a recovery and admin-contact address, separate from your primary mailbox.
   - Use one password manager from today forward; the bootstrap depends on you being
     able to recover these accounts.
3. Decide the names you want now:
   - `identity.adminUser` (SSO admin account label, not a shell user yet)
   - `identity.localAdminUser` (server SSH admin Unix user)
   - `network.hostname` and your chosen base domain

### Step 2: Register or confirm a domain

You can use any registrar. The only hard requirement is that DNS for the domain
can be managed by Cloudflare for tunnel DNS and certificate automation.

If buying a new domain:

1. Register a new domain on your chosen registrar.
2. Add it to Cloudflare as a new site.
3. At your registrar, update nameservers to the values Cloudflare gives you.
4. Wait for DNS propagation before continuing.

If you already own a domain:

1. Verify you can edit DNS records for that domain.
2. Point the domain to Cloudflare nameservers (or add Cloudflare as a DNS provider
   in a supported integration mode).
3. Verify Cloudflare shows the domain as active in the dashboard.

### Step 3: Create Cloudflare account details

The repo uses Cloudflare in two ways:

- HTTPS certificate automation (DNS challenge).
- Public traffic for selected hostnames through Cloudflare Tunnel.

In the Cloudflare dashboard:

1. Open the domain/site and confirm it is active.
2. Create an API token for DNS writes only (least privilege):
   - Zone read is typically required.
   - DNS edit is typically required for certificate automation and host checks.
3. Create a Cloudflare Tunnel:
   - In Cloudflare Zero Trust, add a tunnel and download the `cfHomeCreds` JSON
     file from the generated connector.
   - Give the tunnel a stable name (you will store this exact string in
     `edge.cloudflareTunnelName`).
   - Do not publish token text anywhere else.

You will need these values later:

- `cfHomeCreds`: JSON credentials content from the tunnel connector.
- `cfAPIToken`: API token for DNS automation.

### Step 4: Set up NetBird

1. Create or sign in to NetBird.
2. Create the self-hosted network profile.
3. Generate one setup key for the server:
   - Keep TTL as needed for bootstrap.
4. Generate at least one setup key for admin devices (you can rotate later).
5. Record:
   - Your NetBird network CIDR.
   - The server private NetBird IP to use in `network.netbirdIp`.
   - The setup key in `secrets/unencrypted/netbirdSetupKey`.

### Step 5: Prepare MEGA for backup destination

MEGA is used as an optional offsite target via `rclone`.

1. Create a MEGA account.
2. Enable MFA if available.
3. Confirm your quota and choose folder names for backups.
4. Create a strong MEGA password and store it safely while staging
   `rcloneMegaPassword`.

Do this even if you only enable offsite backups later; the repo’s current secret
manifest expects the value during bootstrap.

### Step 6: Prepare deployment administrator credentials

Before writing `vars.nix`, gather these local operator credentials:

1. `identity.adminUser`: logical admin name for the future Kanidm super-user.
2. `identity.localAdminUser`: Linux user for SSH and initial system administration.
3. SSH public key:
   - If needed, create one:

   ```bash
   ssh-keygen -t ed25519 -C "nixhomeserver-admin"
   cat ~/.ssh/id_ed25519.pub
   ```

   The command output from `cat` is what goes in `identity.sshPublicKey`.

Now gather the values that cannot be invented by the repo.

You need Git access to this repository or to your fork. Git is where the server
configuration lives. The server is rebuilt from the files in the repo, so your
customized copy is the source of truth.

You need a domain name if you want friendly service names and public sharing.
The repo derives app hostnames from `vars.nix`, such as photos, files, identity,
monitoring, and backups hostnames under your domain.

Cloudflare has two roles in this repository:

- DNS-01 certificate validation so HTTPS can be issued automatically.
- Cloudflare Tunnel for controlled public ingress without exposed inbound ports.

You need a NetBird setup key:

- `netbirdSetupKey`: enrolls the server into your private NetBird network.

You need a storage alert destination:

- `storageAlertWebhookUrl`: a webhook URL where disk-health alerts can be sent.

The default secret generator also expects:

- `rcloneMegaPassword`: MEGA account password for the default Rclone offsite
  Kopia integration, even if that sync is left disabled initially.

You need an SSH key for server administration. SSH is the secure remote command
line. The public key goes into `vars.nix`; the private key stays on your admin
workstation. If you do not already have one:

```bash
ssh-keygen -t ed25519 -C "nixhomeserver-admin"
cat ~/.ssh/id_ed25519.pub
```

Keep the private key private. The public key printed by `cat` is the value you
will place in `identity.sshPublicKey`.

## Stage 5: Prepare The Repository

Clone your fork or working copy on a machine with Nix available. This can be
your normal workstation or the NixOS installer environment.

Create your local settings file:

```bash
cp vars.example.nix vars.nix
$EDITOR vars.nix
```

`vars.nix` is the answer sheet for your home. It tells the repo who the admin
is, what domain to use, what network mode you chose, which disks may be wiped,
and where the data pool should live.

Set these first:

- `identity.adminUser`: the Kanidm admin account.

  Kanidm is the private identity system. This user manages app users and access
  groups. Keep it separate from the Unix SSH admin account.

- `identity.localAdminUser`: the Unix admin account.

  This is the account you SSH into for server administration.

- `identity.sshPublicKey`: the public SSH key from Stage 4.

- `network.hostname`: the server's hostname.

- `network.domain`: your domain.

- `network.lanIp`, `network.lanPrefixLength`, and `network.lanGateway`: the LAN
  values from Stage 3.

- `network.netbirdIp` and `network.netbirdCidr`: the server's private NetBird
  address and the NetBird network range.

- `dnsSettings.mode`: either `"split-horizon"` or `"netbird-only"`.

- `system.timeZone`: your local IANA time zone.

- `system.hostId`: a stable 8-character lowercase hexadecimal value.

- `edge.cloudflareTunnelName`: the tunnel name from Cloudflare.

- `storage.systemDisk`: placeholder until confirmed on the installer.

- `storage.dataPool.mirrorPairs`: placeholders until confirmed on the installer.

Generate a host ID if you do not already have one:

```bash
head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n'
printf '\n'
```

Run the non-destructive readiness helpers:

```bash
nix run .#validate-config-readiness
nix run .#show-config-summary
nix run .#export-inventory -- --format text
```

These commands do not wipe disks or deploy the server. They check whether the
configuration is internally coherent and print a readable summary. Disk and
interface warnings are expected before you verify the real target hardware.

Application selection is controlled by explicit imports in
[`configuration.nix`](./configuration.nix). The fixed platform layer is
[`modules/Core_Modules`](./modules/Core_Modules/README.md). Optional app modules
can be removed from the import list, and cross-service bindings should be kept
as explicit imports from [`modules/Integrations`](./modules/Integrations/README.md).

## Core Modules: Why They Are the Foundation

Core modules are the services that make every optional app usable and manageable.
Treat this layer as non-negotiable; app modules are written to run on top of it.

Core modules included by default are:

- `age`: centralized secret materialization for non-secret storage in Nix and encrypted secret files at deploy-time.
- `backups`: shared backup policy and lifecycle for stateful services.
- `base-system`: baseline OS settings, kernel/service defaults, and host-level behavior.
- `caddy`: the web entrypoint that routes hostnames to app endpoints.
- `cloudflared`: outbound-only tunnel path so private services can be reached without public port exposure.
- `data-disks`: mirrored pool layout and resilient data-device handling.
- `impermanence`: controlled persistence for `/persist`, `/var` state, and application data expectations across rebuilds.
- `kanidm`: identity, groups, and SSO provider so one account model secures services.
- `kopia`: scheduled and operational backup orchestration hooks.
- `monitoring`: health visibility and health-driven troubleshooting surface.
- `netbird`: private overlay network for remote access with predictable identity-aware routing.
- `oauth2-proxy`: central OIDC-to-HTTP auth gateway used by apps that do not do native OIDC.
- `phone-backup`: first-class mobile backup entrypoint wiring.
- `rclone`: backup destination sync paths and automation.
- `storage`: mount points and shared storage policy contract for apps.
- `storage-monitoring`: scheduled SMART short/long self-test sweeps for physical disks.
- `syncthing`: optional peer-to-peer sync for personal and offline media workflows.
- `unbound`: DNS for private hostnames and internal name routing rules.
- `validation`: pre- and post-merge checks to prevent bad config from reaching runtime.

`storage-monitoring` is not replaced by Beszel.
It remains useful because it schedules explicit SMART health tests in the background,
while Beszel provides service and resource observability dashboards.

If one of these is removed, the dependent pieces usually fail in non-obvious ways:
no authentication, broken name resolution, no web ingress, missing persistence, or
no protected remote access.

This helps explain the bootstrap shape: first set the platform base (network,
identity, DNS, storage, secrets), then enable application modules for features.

## Stage 6: Create The Secret Key

Secrets are values that should not be readable in Git: passwords, API tokens,
tunnel credentials, cookie signing keys, and generated app secrets.

This repo uses agenix. It works like a lock and key:

- The public age recipient goes in `secrets/pubkeys/age.pub` and can be
  committed.
- The private age key goes on the server at `/etc/agenix/age.key` and must not
  be committed.

Create a new age identity:

```bash
install -d -m 0700 /tmp/nixhomeserver-age
age-keygen -o /tmp/nixhomeserver-age/age.key
install -d -m 0755 secrets/pubkeys
age-keygen -y /tmp/nixhomeserver-age/age.key > secrets/pubkeys/age.pub
```

Or derive the public recipient from an existing age key:

```bash
install -d -m 0755 secrets/pubkeys
age-keygen -y /path/to/age.key > secrets/pubkeys/age.pub
```

Track `secrets/pubkeys/age.pub`. Never commit the private age key.

## Stage 7: Stage And Encrypt Secrets

Create the temporary plaintext staging directory:

```bash
install -d -m 0700 secrets/unencrypted
```

Place these files in it:

- `secrets/unencrypted/netbirdSetupKey`
- `secrets/unencrypted/cfHomeCreds`
- `secrets/unencrypted/cfAPIToken`
- `secrets/unencrypted/storageAlertWebhookUrl`
- `secrets/unencrypted/rcloneMegaPassword`

Then generate all repo-managed secrets and encrypt the staged values:

```bash
./scripts/generate-all-secrets.sh
```

Expected result:

- Encrypted `secrets/*.age` files exist.
- `secrets/pubkeys/age.pub` matches the private key you will install on the
  server.
- No error reports a missing or invalid staged secret.

Track the encrypted files and public key. Keep `secrets/unencrypted/` and the
private age key untracked. After encryption, move the plaintext copies into a
password manager or secure offline location, or delete them after confirming the
encrypted files exist.

## Stage 8: Boot The Installer And Confirm Real Hardware Names

Now move to the target server.

Boot a recent NixOS installer ISO, get network access, then clone the repo:

```bash
mkdir -p /mnt/src
git clone <your-fork-or-origin-url> /mnt/src
cd /mnt/src
```

Inspect disks and network interfaces:

```bash
lsblk -o NAME,PATH,TYPE,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINTS
ls -l /dev/disk/by-id/
ip link
```

Why this matters:

- `lsblk` shows disk size, model, current filesystem, and mount points.
- `/dev/disk/by-id/` shows stable disk identifiers. Use these in `vars.nix`, not
  `/dev/sda` names.
- `ip link` shows the real network interface name for this server.

Print the repo's read-only storage plan:

```bash
nix run .#bootstrap-storage-plan
```

Update `vars.nix` with the real values:

- `network.lanInterface`
- `storage.systemDisk`
- `storage.dataPool.mirrorPairs`

Stop if any selected disk contains data you intend to keep.

## Stage 9: Provision Blank Disks

This stage wipes disks. Read it twice before running any destructive disk tool.

The selected `storage.profile` controls the destructive layout:

- `zfs-mirror`: system SSD with UEFI boot plus Btrfs subvolumes for `/`, `/nix`,
  and `/persist`; data disks form a mirrored ZFS pool mounted under `/mnt/data`.
- `single-disk-ext4`: one disk with UEFI boot plus a single ext4 root filesystem;
  `/persist` and `/mnt/data` are normal directories on that disk.

The layout references are:

- [`bootstrap/disko-system.nix`](./bootstrap/disko-system.nix)
- [`bootstrap/disko-data.nix`](./bootstrap/disko-data.nix)

This repository intentionally does not hide disk wiping behind a convenience
wrapper. Review the plan, run your chosen disko or equivalent provisioning
process, then mount the installed layout under `/mnt`.

Before installing, verify the mounts:

```bash
findmnt /mnt
findmnt /mnt/boot
findmnt /mnt/nix
findmnt /mnt/persist
zpool status
```

Do not use disko for routine rebuilds, existing-server app changes, or in-place
storage repair. Existing storage maintenance belongs in
[`documentation/restore-and-recovery.md`](./documentation/restore-and-recovery.md).

## Stage 10: Install NixOS

Copy the complete repository into the target system:

```bash
mkdir -p /mnt/etc/nixos
cp -a /mnt/src/. /mnt/etc/nixos/
```

Generate and review hardware configuration:

```bash
nixos-generate-config --root /mnt
$EDITOR /mnt/etc/nixos/hardware-configuration.nix
```

`hardware-configuration.nix` records what NixOS discovered about this specific
machine. It is the bridge between the generic repo and the real hardware.

Install the private agenix key:

```bash
install -d -m 0700 /mnt/etc/agenix
install -m 0400 /path/to/age.key /mnt/etc/agenix/age.key
```

Install the flake host, replacing `<vars.hostname>` with the hostname from
`vars.nix`:

```bash
nixos-install --flake /mnt/etc/nixos#<vars.hostname>
reboot
```

## Stage 11: First Boot And First Deploy

After reboot, SSH in as the local admin user:

```bash
ssh <local-admin-user>@<vars.hostname>
```

If that works, the server is on the network and your SSH key is accepted.

Check the basics on the server:

```bash
sudo systemctl --failed --no-pager
findmnt /persist
test -d /mnt/data
```

These checks answer:

- Are any system services already failed?
- Is persistent system state available?
- Is the data root present where apps expect it?

For `zfs-mirror`, also check:

```bash
zpool status
findmnt /mnt/data
```

From your admin workstation repo, run the full guarded test deploy:

```bash
./scripts/deploy.sh --debug --action test
```

This stages the current repo on the server, validates it there, builds the NixOS
configuration, activates it in test mode, and checks for failed units.

Only switch after the guarded test path passes:

```bash
./scripts/deploy.sh --action switch
```

The deploy helper defaults to `vars.localAdminUser@vars.hostname`, where
`vars.localAdminUser` is derived from `identity.localAdminUser`. It builds on
the remote server and starts with `--action test` unless told otherwise. Use
`./scripts/deploy.sh --help` for supported flags.

## Stage 12: Finish Router Setup

If you chose NetBird-only mode, enroll your admin devices in NetBird and use the
private NetBird path for private services. Your router should not need special
DNS configuration for this repo.

If you chose split-DNS mode, configure your router after the server is healthy:

1. Reserve the server's LAN IP for the server, or confirm the server's static
   address will not conflict with your router's DHCP pool.
2. Configure LAN clients to use the server's LAN IP as DNS, or enable the
   router's client DNS override behavior if that is how your router works.
3. Renew DHCP leases or reconnect a test device.
4. Confirm a private hostname resolves to the server while at home.

On a Flint 2, the relevant places in the GL.iNet web UI are documented as
`NETWORK -> LAN` for DHCP/address reservation and `NETWORK -> DNS` for DNS
behavior. Exact UI labels can vary by firmware version, so use the GL.iNet docs
linked in Stage 3 as the source of truth.

## How Traffic Moves Through The Server

Use this as a map, then revisit the setup steps in order:

```mermaid
flowchart LR
    A["Browser opens a hostname such as photos.example.com"] --> B{"DNS lookup for that hostname"}
    B --> C{"Is this a private home hostname?"}
    C -->|Yes| D["Home router sends DNS to server Unbound"]
    C -->|No| E{"Is this a public internet hostname?"}
    E -->|Yes| F["Cloudflare DNS and Tunnel"]
    E -->|No| G["Name may need manual fix in browser"]
    D --> H{"Request path"}
    H -->|Home device| I["Private traffic on LAN to server LAN IP"]
    H -->|Remote trusted device| J["NetBird path to server NetBird IP"]
    I --> K["Caddy on server"]
    J --> K
    F --> L["Cloudflare edge"]
    L --> M["cloudflared tunnel connector"]
    M --> K
    K --> N["Application service"]
    N --> O["Persistent app data in /persist and /mnt/data"]
    N --> P["Internet response"]
    G --> Q["DNS and hostname correction"]
```

```mermaid
flowchart TD
    A["Home LAN device with NetBird"] --> B["DNS query goes to NetBird nameservice"]
    C["Remote device with NetBird"] --> B
    B --> D["Private hostname resolves to server NetBird IP"]
    D --> E["Caddy"]
    E --> F["Private app service"]
    G["Home LAN device without NetBird"] --> H["Router uses normal public DNS"]
    H --> I{"Is hostname mapped publicly?"}
    I -->|Yes| J["Cloudflare DNS and Tunnel path"]
    I -->|No| K["Use direct LAN IP or install NetBird"]
    J --> L["cloudflared"]
    L --> E
```

In plain terms:

1. DNS first decides where a hostname should point.
2. In NetBird-only mode, private names are resolved through NetBird for enrolled devices; home clients without NetBird keep normal router/public DNS.
3. Public requests are routed through Cloudflare Tunnel so you avoid exposing inbound ports.
4. Caddy routes the request to the matching app.
5. The app uses local disks for data.

## NetBird, Cloudflare Tunnel, and MEGA in This Stack

### NetBird

NetBird creates a private encrypted overlay for your own devices. Think of it as a private
virtual network that exists only for users you add, with strict routing rules.
It is used because it gives you fast, private remote access without opening inbound
services to the internet.

```mermaid
flowchart LR
    A["Device at Home (trusted)"] --> B["Server LAN"]
    C["Device Away (trusted)"] --> D["NetBird Client"]
    D --> E["NetBird Control Plane"]
    E --> F["Server NetBird Agent"]
    F --> G["Caddy on Server"]
    B --> G
    G --> H["Private App"]
    C -->|No inbound port needed| H
```

In this guide, NetBird does one key job:

- Remote and trusted devices still reach private apps as if they were on a direct secure network.
- The server and clients keep normal LAN behavior at home.
- You can avoid broad firewall exposure for internal access patterns.

### Cloudflare Tunnel

Cloudflare Tunnel is used for public entry points when you want safe internet access
to one or more app hostnames without requesting a public IP on your home internet
connection. The connector runs outbound from the server, then Cloudflare forwards
allowed traffic to it over an encrypted control channel.

```mermaid
flowchart LR
    A["Remote Browser"] --> B["Public DNS for app.example.com"]
    B --> C["Cloudflare Edge"]
    D["Server Connector: cloudflared"] --> E["Tunnel route map"]
    C -->|Allowed public hostnames only| D
    D --> F["Caddy"]
    F --> G["App Service"]
```

In practical terms:

- You can use one or two public hostnames without opening inbound ports on your router.
- Traffic is limited to hostnames configured in the tunnel config.
- This keeps the public boundary smaller than a traditional port-forward design.

### MEGA + rclone

MEGA is used as an offsite backup destination and simple, low-friction secondary store.
In this repo, it is consumed via `rclone` for backup workflows.

```mermaid
flowchart TD
    A["App data under /mnt/data"] --> B["Backup jobs on server"]
    B --> C["rclone task"]
    C --> D["MEGA remote"]
    D --> E["Optional restore path"]
```

Why it is useful:

- Keeps an extra copy of important data outside the home server.
- Supports an easy offsite strategy for backups that complements local ZFS redundancy.
- Provides a free quota baseline (about 20 GB), useful for smaller/critical sets or secondary copies.

```mermaid
flowchart TD
    A["Private request reaches Caddy"] --> B{"App requires login?"}
    B -->|No| C["App serves directly"]
    B -->|Yes| D["OAuth2 Proxy and IdP-aware proxy path"]
    D --> E["Kanidm identity provider"]
    E --> F["Credentials and policy check"]
    F -->|Allowed| G["Kanidm returns identity claim"]
    F -->|Denied| H["Access denied"]
    G --> I["OAuth2 Proxy returns signed session"]
    I --> C
    C --> J["App accepts user"]
```

This is why bootstrap asks for network mode, DNS settings, Cloudflare credentials,
NetBird enrollment, identity admin details, and disk layout up front. Those values
decide how each request reaches the right app and who is allowed through.

## Native OIDC vs OAuth2 Proxy

You asked how authentication is handled in this repo because it affects where you
trust identity and where you expose each app.

In this setup:

- Native OIDC means the app talks directly to Kanidm as an OIDC client.
- OAuth2 Proxy means a separate service performs OIDC login and then forwards
  the trusted request to the app.

Why the repo uses both:

- Some apps have good native OIDC support and cleaner direct integration.
- Some apps only expose weak or inconsistent OIDC options, so the proxy is used to
  keep access policy consistent.
- A single proxy pattern also lets the team enforce login boundaries and headers
  in one place for apps that are mostly "just web apps."

Decision guide for this repo:

- If an app has a reliable native OIDC configuration and good group/role
  mapping, it can connect directly to Kanidm.
- If an app has weak OIDC support or requires complex headers/cookies/legacy login
  behavior, it is wrapped with `oauth2-proxy`.
- The result is intentional: security is still central in Kanidm either way, while
  implementation is practical for each app.

For users: both methods still use one identity provider and one set of user accounts.
The visible difference is who performs the login handshake: the app, or a trusted
proxy service placed in front of it.

## Day-2 Operations

Once the first guarded deploy succeeds, use these entry points for ongoing work:

- [`documentation/operations.md`](./documentation/operations.md): guarded
  deploys, validation, rollback, service health, DNS, storage checks, and app
  hostnames.
- [`documentation/kanidm.md`](./documentation/kanidm.md): identity operations.
- [`documentation/vaultwarden.md`](./documentation/vaultwarden.md): private
  password-manager workflow.
- [`documentation/restore-and-recovery.md`](./documentation/restore-and-recovery.md):
  mirrored-pool repair and backup-backed restore work.
- [`custom_apps/rust/apps/mail-archive-ui/README.md`](./custom_apps/rust/apps/mail-archive-ui/README.md):
  mail archive UI, sync flow, and storage model.

Common commands:

```bash
nix run .#show-config-summary
./scripts/deploy.sh --action test
./scripts/deploy.sh --action switch
./scripts/deploy.sh --debug --action test
sudo systemctl --failed --no-pager
```

Keep new repository files tracked unless they are ignored, huge, generated cache
artifacts, plaintext secrets, or private keys. Nix rebuilds operate from the
tracked repository state, so untracked config files can be invisible at exactly
the wrong time.
