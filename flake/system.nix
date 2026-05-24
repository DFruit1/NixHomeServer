{ inputs
, lib
, pkgs
, pkgsUnstable
, vars
, system
, appPackages
}:

let
  inherit (inputs) agenix filestashNix impermanence;

  nixosHost = lib.nixosSystem {
    modules = [
      { nixpkgs.hostPlatform = system; }
      ../configuration.nix
      agenix.nixosModules.default
      impermanence.nixosModules.impermanence
    ];
    specialArgs = {
      inherit vars filestashNix pkgsUnstable appPackages;
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
