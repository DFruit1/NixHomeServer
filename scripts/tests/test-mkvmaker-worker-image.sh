#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix

cmdline_normalizer="$TESTS_REPO_ROOT/scripts/helpers/normalize-ventoy-kernel-cmdline.sh"
[[ -x "$cmdline_normalizer" ]] || {
  echo "❌ Ventoy kernel-command-line normalizer is missing or not executable." >&2
  exit 1
}

ventoy_cmdline='BOOT_IMAGE=/boot/bzImage vtinit=/nix/store/test-system/init rdinit=/vtoy/vtoy'
expected_cmdline='BOOT_IMAGE=/boot/bzImage init=/nix/store/test-system/init rdinit=/vtoy/vtoy'
require_json_equal \
  "$(printf '%s\n' "$ventoy_cmdline" | "$cmdline_normalizer")" \
  "$expected_cmdline" \
  "Ventoy GRUB2 vtinit parameter must be restored for the NixOS initrd"

native_cmdline='BOOT_IMAGE=/boot/bzImage init=/nix/store/test-system/init quiet'
require_json_equal \
  "$(printf '%s\n' "$native_cmdline" | "$cmdline_normalizer")" \
  "$native_cmdline" \
  "native NixOS init parameters must remain unchanged"

unrelated_cmdline='BOOT_IMAGE=/boot/bzImage foo=vtinit=/not-a-kernel-parameter quiet'
require_json_equal \
  "$(printf '%s\n' "$unrelated_cmdline" | "$cmdline_normalizer")" \
  "$unrelated_cmdline" \
  "vtinit text inside another parameter must remain unchanged"

worker_surface="$(nix eval --json '.#lib.mkvmakerWorkerConfigurations.server' --apply 'cfg: {
  hostName = cfg.networking.hostName;
  platform = cfg.nixpkgs.hostPlatform.system;
  networkManager = cfg.networking.networkmanager.enable;
  inboxMount = cfg.fileSystems."/mnt/data/shared/_ISO/_DVDs";
  moviesMount = cfg.fileSystems."/mnt/data/shared/_Videos/_Movies";
  stateMount = cfg.fileSystems."/var/lib/mkvmaker";
  configMount = cfg.fileSystems."/var/lib/mkvmaker-worker-config";
  service = cfg.systemd.services.mkvmaker-worker.serviceConfig;
  serviceUnit = cfg.systemd.services.mkvmaker-worker.unitConfig;
  timer = cfg.systemd.timers.mkvmaker-worker.timerConfig;
  ventoyCompat = {
    before = cfg.boot.initrd.systemd.services.mkvmaker-ventoy-init-compat.before;
    requiredBy = cfg.boot.initrd.systemd.services.mkvmaker-ventoy-init-compat.requiredBy;
    script = cfg.boot.initrd.systemd.services.mkvmaker-ventoy-init-compat.script;
    type = cfg.boot.initrd.systemd.services.mkvmaker-ventoy-init-compat.serviceConfig.Type;
  };
  usbBootable = cfg.isoImage.makeUsbBootable;
  efiBootable = cfg.isoImage.makeEfiBootable;
  volumeId = cfg.isoImage.volumeID;
}')"

jq -e '
  (.hostName == "mkvmaker-worker")
  and (.platform == "x86_64-linux")
  and (.networkManager == true)
  and (.inboxMount.device == "192.168.8.12:/mnt/data/shared/_ISO/_DVDs")
  and (.inboxMount.fsType == "nfs")
  and (.inboxMount.options | index("nfsvers=4.2") != null)
  and (.inboxMount.options | index("x-systemd.automount") != null)
  and (.moviesMount.device == "192.168.8.12:/mnt/data/shared/_Videos/_Movies")
  and (.stateMount.device == "192.168.8.12:/var/lib/mkvmaker")
  and (.stateMount.fsType == "nfs")
  and (.configMount.device == "192.168.8.12:/var/lib/mkvmaker-worker-config")
  and (.configMount.options | index("ro") != null)
  and (.service.Type == "simple")
  and (.service.User == "mkvmaker-worker")
  and (.service.Group == "mkvmaker-worker")
  and (.service.PrivateDevices == true)
  and (.service.CapabilityBoundingSet == "")
  and (.service.Restart == "on-failure")
  and (.service.KillMode == "control-group")
  and (.serviceUnit.RequiresMountsFor | index("/mnt/data/shared/_ISO/_DVDs") != null)
  and (.serviceUnit.RequiresMountsFor | index("/var/lib/mkvmaker") != null)
  and (.serviceUnit.RequiresMountsFor | index("/var/lib/mkvmaker-worker-config") != null)
  and (.timer.OnBootSec == "30s")
  and (.timer.OnUnitInactiveSec == "1min")
  and (.ventoyCompat.before | index("initrd-find-nixos-closure.service") != null)
  and (.ventoyCompat.requiredBy | index("initrd-find-nixos-closure.service") != null)
  and (.ventoyCompat.script | contains("normalize-ventoy-kernel-cmdline"))
  and (.ventoyCompat.script | contains("mount --bind"))
  and (.ventoyCompat.type == "oneshot")
  and (.usbBootable == true)
  and (.efiBootable == true)
  and (.volumeId == "MKVMAKER_WORKER")
' <<<"$worker_surface" >/dev/null || {
  echo "❌ Mkvmaker worker ISO configuration is invalid." >&2
  jq . <<<"$worker_surface" >&2
  exit 1
}

iso_name="$(nix eval --raw '.#packages.x86_64-linux.mkvmaker-worker-iso.name')"
[[ "$iso_name" == *iso* ]] || {
  echo "❌ Mkvmaker worker package is not an ISO derivation: $iso_name" >&2
  exit 1
}

server_surface="$(nix eval --json '.#nixosConfigurations.server.config' --apply 'cfg: {
  distributed = cfg.repo.mkvmaker.distributedWorkers;
  paths = cfg.repo.mkvmaker.paths;
  nfs = cfg.services.nfs.server;
  nfsSettings = cfg.services.nfs.settings;
  lanFirewall = cfg.networking.firewall.interfaces.enp34s0.allowedTCPPorts;
  guarded = cfg.repo.storage.dataPool.guardedServices;
  storageLayout = cfg.systemd.services.mkvmaker-storage-layout-v1.script;
  configWriter = cfg.systemd.services.mkvmaker-worker-config.script;
  publisher = cfg.systemd.services.mkvmaker-worker-image-publish.script;
  publisherService = cfg.systemd.services.mkvmaker-worker-image-publish.serviceConfig;
}')"

jq -e '
  (.distributed.enable == true)
  and (.distributed.leaseSeconds == 120)
  and (.distributed.nfsClientCidr == "192.168.8.0/24")
  and (.paths.workerImageOutput == "/mnt/data/users/admindsaw/_ISO/_SystemOSes")
  and (.nfs.enable == true)
  and (.nfs.hostName == "192.168.8.12")
  and (.nfsSettings.nfsd.vers3 == false)
  and (.nfsSettings.nfsd.vers4 == true)
  and (.nfs.exports | contains("/mnt/data/shared/_ISO/_DVDs 192.168.8.0/24"))
  and (.nfs.exports | contains("/mnt/data/shared/_Videos/_Movies 192.168.8.0/24"))
  and (.nfs.exports | contains("/mnt/data/shared/_Videos/_Shows 192.168.8.0/24"))
  and (.nfs.exports | contains("/mnt/data/shared/.mkvmaker-staging 192.168.8.0/24"))
  and (.nfs.exports | contains("/var/lib/mkvmaker 192.168.8.0/24"))
  and (.nfs.exports | contains("/var/lib/mkvmaker-worker-config 192.168.8.0/24(ro,"))
  and (.nfs.exports | contains("/mnt/data/shared 192.168.8.0/24") | not)
  and (.lanFirewall | index(2049) != null)
  and (.guarded | index("mkvmaker-worker-config") != null)
  and (.guarded | index("mkvmaker-worker-image-publish") != null)
  and (.storageLayout | contains("u:nobody:r-X"))
  and (.configWriter | contains("worker-config.json"))
  and (.configWriter | contains("/var/lib/mkvmaker-worker-config"))
  and (.configWriter | contains("rm -f /var/lib/mkvmaker/worker-config.json"))
  and (.configWriter | contains("d:g:mkvmaker:rwx"))
  and (.configWriter | contains("install -d -m 2770"))
  and (.publisher | contains("/mnt/data/users/admindsaw/_ISO/_SystemOSes"))
  and (.publisher | contains(".sha256"))
  and (.publisher | contains(".mkvmaker-worker-releases"))
  and (.publisher | contains("MKVMaker-Worker"))
  and (.publisher | contains("mv -Tf --"))
  and (.publisher | contains("sha256sum --check"))
  and (.publisherService.Type == "oneshot")
  and (.publisherService.RemainAfterExit == true)
' <<<"$server_surface" >/dev/null || {
  echo "❌ Server-side Mkvmaker worker export or ISO publication is invalid." >&2
  jq . <<<"$server_surface" >&2
  exit 1
}

require_fixed flake/mkvmaker-worker-iso.nix 'installation-cd-minimal.nix' \
  "worker image must extend the official minimal NixOS live image"
require_fixed flake/mkvmaker-worker-iso.nix 'worker-config.json' \
  "worker image must consume server-published conversion settings"
require_fixed flake/mkvmaker-worker-iso.nix 'MKVMAKER_WORKER_ID' \
  "worker image must derive a distinct queue worker identity"

if rg -n '(age\.secrets|netbirdSetupKey|privateKey|passwordFile)' flake/mkvmaker-worker-iso.nix; then
  echo "❌ Stateless worker image references persistent server credentials." >&2
  exit 1
fi

echo "✅ Mkvmaker exposes a stateless, USB-bootable NixOS worker image."
