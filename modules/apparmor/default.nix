{ lib, pkgs, vars, ... }:

let
  genProfile = name: paths:
    let
      allowLines = lib.concatStringsSep "\n"
        (map (p: "  allow ${p} rwmix,") paths);
    in ''
      profile ${name} / {
        #include <tunables/global>
${allowLines}

        deny /** rwklx,
      }
    '';

  generatedPolicies =
    lib.mapAttrs' (n: p:
      lib.nameValuePair ("generated-" + n) {
        profile = genProfile n p;   # inline profile text
        state   = "complain";        # or "complain"
      }
    ) vars.appArmorDefaults;

in
{
  ############  AppArmor on, load generated policies  ##################
  security.apparmor = {
    enable   = false;
    policies = generatedPolicies;   # attr-set, not a list
  };

  ############  helper CLI (unchanged)  ################################
  environment.systemPackages = [
    pkgs.nushell
    (pkgs.writeShellApplication {
      name          = "apparmor-violations";
      runtimeInputs = [ pkgs.nushell ];
      text = ''
        nu ${./dotfiles/apparmor_violations.nu}
      '';
    })
  ];
}
