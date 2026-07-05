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
    if vars.hardwareProfile == "existing-server" then
      ../hardware-configuration.nix
    else if vars.hardwareProfile == "generic-uefi" then
      ../hardware/generic-uefi.nix
    else
      throw "Unsupported system.hardwareProfile '${vars.hardwareProfile}'. Supported values are existing-server and generic-uefi.";

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
in
{
  nixosConfigurations = {
    ${vars.hostname} = nixosHost;
  };

  nixhomeserverSettings = {
    ${vars.hostname} = vars;
  };
}
