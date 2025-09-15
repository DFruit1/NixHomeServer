{ lib, vars, ... }:

let
  genProfile = name: paths:
    let
      allowPaths = (vars.appArmorCommonPaths or []) ++ paths;
      allowLines = lib.concatStringsSep "\n"
        (map (p: "  allow ${p} rwmix,") allowPaths);
    in
    ''
      profile ${name} / {
        #include <tunables/global>
${allowLines}
        deny /** rwklx,
      }
    '';

  generatedPolicies =
    lib.mapAttrs'
      (n: p:
        lib.nameValuePair ("generated-" + n) {
          profile = genProfile n p;
          state = "enforce";
        }
      )
      vars.appArmorDefaults;
in
{
  security.apparmor = {
    enable = true;
    policies = generatedPolicies;
  };
}
