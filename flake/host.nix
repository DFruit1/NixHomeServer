{ inputs
, self
, lib
, pkgs
, pkgsUnstable
, vars
, system
}:

let
  inherit (inputs) agenix copyparty filestashNix impermanence;

  nixosHost = lib.nixosSystem {
    modules = [
      { nixpkgs.hostPlatform = system; }
      ../configuration.nix
      agenix.nixosModules.default
      impermanence.nixosModules.impermanence
    ];
    specialArgs = {
      inherit self vars copyparty filestashNix pkgsUnstable;
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
