{ lib, hostName, settings }:

let
  catalog = import ../modules/catalog.nix;
  availableApps = builtins.attrNames catalog.apps;
  isStringList = value: builtins.isList value && lib.all builtins.isString value;
  checks = [
    {
      valid = builtins.isAttrs settings;
      message = "host settings must be an attribute set";
    }
    {
      valid = isStringList (settings.enabledApps or null);
      message = "applications.enabled must be an explicit list of application names";
    }
    {
      valid = builtins.length (settings.enabledApps or [ ])
        == builtins.length (lib.unique (settings.enabledApps or [ ]));
      message = "applications.enabled must not contain duplicate application names";
    }
    {
      valid = lib.all (name: builtins.elem name availableApps) (settings.enabledApps or [ ]);
      message = "applications.enabled contains an unknown application; valid names are: ${lib.concatStringsSep ", " availableApps}";
    }
    {
      valid = builtins.isString settings.hostname && settings.hostname == hostName;
      message = "network.hostname must match its hosts.nix key '${hostName}'";
    }
    {
      valid = builtins.elem settings.hostPlatform [ "x86_64-linux" "aarch64-linux" ];
      message = "system.hostPlatform must be x86_64-linux or aarch64-linux";
    }
    {
      valid = builtins.elem settings.hardwareProfile [ "generated" "existing-server" "generic-uefi" ];
      message = "system.hardwareProfile is unsupported";
    }
    {
      valid = builtins.elem settings.buildMode [ "local" "remote" "balanced" "maximum-effort" ];
      message = "system.buildMode must be local, remote, balanced, or maximum-effort";
    }
    {
      valid = builtins.isInt settings.nixStoreMaxSizeGiB
        && settings.nixStoreMaxSizeGiB >= 1
        && settings.nixStoreMaxSizeGiB <= 1048576;
      message = "system.nixStoreMaxSizeGiB must be an integer from 1 through 1048576";
    }
    {
      valid = builtins.isInt settings.nixGcRetentionDays
        && settings.nixGcRetentionDays >= 1
        && settings.nixGcRetentionDays <= 36500;
      message = "system.nixGcRetentionDays must be an integer from 1 through 36500";
    }
    {
      valid = builtins.isBool settings.localNixGC;
      message = "system.localNixGC must be a boolean";
    }
    {
      valid = builtins.elem settings.storageProfile [ "zfs-mirror" "single-disk-ext4" ];
      message = "storage.profile must be zfs-mirror or single-disk-ext4";
    }
    {
      valid = builtins.isString settings.domain && settings.domain != "";
      message = "network.domain must be a non-empty string";
    }
    {
      valid = builtins.isString settings.mainDisk && settings.mainDisk != "";
      message = "storage.systemDisk must be a non-empty disk-by-id basename";
    }
    {
      valid = isStringList settings.kanidmAppUsers && isStringList settings.kanidmAppAdminUsers;
      message = "identity app user lists must contain only strings";
    }
    {
      valid = builtins.isInt settings.backupStorageGid;
      message = "backupAccess.storageGid must be an integer";
    }
    {
      valid = builtins.isAttrs settings.networking.ports
        && lib.all builtins.isInt (builtins.attrValues settings.networking.ports);
      message = "advanced.ports must contain only integer port values";
    }
  ];
  failures = map (check: check.message) (builtins.filter (check: !check.valid) checks);
in
if failures == [ ] then
  settings
else
  throw "Invalid settings for host '${hostName}': ${lib.concatStringsSep "; " failures}"
