{ inputs
, lib
, pkgs
, vars
, system
, appPackages
}:

let
  inherit (inputs) agenix filestashNix impermanence;
  hardwareModule =
    if builtins.elem vars.hardwareProfile [ "generated" "existing-server" ] then
      ../hardware-configuration.nix
    else if vars.hardwareProfile == "generic-uefi" then
      ../hardware/generic-uefi.nix
    else
      throw "Unsupported system.hardwareProfile '${vars.hardwareProfile}'. Supported values are generated, existing-server, and generic-uefi.";

  nixosHost = lib.nixosSystem {
    modules = [
      { nixpkgs.hostPlatform = system; }
      hardwareModule
      ../configuration.nix
      agenix.nixosModules.default
      impermanence.nixosModules.impermanence
    ];
    specialArgs = {
      inherit vars filestashNix appPackages;
      oauth2Proxy = import ../modules/Core_Modules/oauth2-proxy {
        inherit lib pkgs vars;
      };
    };
  };
  bootstrapHost = lib.nixosSystem {
    modules = [
      { nixpkgs.hostPlatform = system; }
      ({ lib, ... }: {
        # This output is primarily a Disko target, but it is exported as a
        # NixOS configuration and must pass ordinary flake checks as a complete
        # host too.
        networking.hostId = vars.hostId;
        system.stateVersion = "25.05";
        boot.loader.grub = {
          enable = true;
          efiSupport = true;
          efiInstallAsRemovable = true;
          device = "nodev";
        };
        boot.loader.systemd-boot.enable = lib.mkForce false;
        boot.loader.efi.canTouchEfiVariables = false;
        boot.zfs.forceImportRoot = false;
      })
      inputs.disko.nixosModules.disko
      ../bootstrap/disko-system.nix
      ../bootstrap/disko-data.nix
    ];
    specialArgs = { inherit vars; };
  };
in
{
  nixosConfigurations = {
    ${vars.hostname} = nixosHost;
  };

  # Kept separate from the deployable hostname so ordinary rebuilds never run
  # the disk layout module. The disko CLI targets this explicit suffix only.
  bootstrapConfigurations = {
    "${vars.hostname}-bootstrap" = bootstrapHost;
  };

  nixhomeserverSettings = {
    ${vars.hostname} = vars;
  };
}
