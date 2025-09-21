{ lib, vars, ... }:

let
  userProfiles = vars.appArmorDefaults or { };

  baseProfiles = {
    "immich-server" = [
      "${vars.dataRoot}/immich/**"
      "/var/lib/immich/**"
      "/var/log/immich/**"
    ];
    "paperless-web" = [
      "${vars.dataRoot}/paperless/**"
      "/var/lib/paperless/**"
      "/var/log/paperless-ngx/**"
    ];
    audiobookshelf = [
      "${vars.dataRoot}/audiobookshelf/**"
      "/var/lib/audiobookshelf/**"
      "/var/log/audiobookshelf/**"
    ];
    copyparty = [
      "${vars.dataRoot}/copyparty/**"
      "/var/lib/copyparty/**"
      "/var/log/copyparty/**"
    ];
    vaultwarden = [
      "${vars.dataRoot}/vaultwarden/**"
      "/var/lib/vaultwarden/**"
      "/var/log/vaultwarden/**"
      "/etc/vaultwarden/**"
    ];
    "homepage-dashboard" = [
      "${vars.dataRoot}/homepage/**"
      "/var/lib/homepage-dashboard/**"
      "/var/cache/homepage-dashboard/**"
      "/var/log/homepage-dashboard/**"
    ];
    "cloudflared-tunnel-${vars.cloudflareTunnelName}" = [
      "/var/lib/cloudflared/**"
      "/var/log/cloudflared/**"
      "/etc/cloudflared/**"
    ];
    "netbird-main" = [
      "/var/lib/netbird-main/**"
      "/var/log/netbird-main/**"
      "/etc/netbird-main/**"
    ];
    "oauth2-proxy" = [
      "/var/lib/oauth2-proxy/**"
      "/var/log/oauth2-proxy/**"
      "/etc/oauth2-proxy/**"
    ];
    unbound = [
      "/var/lib/unbound/**"
      "/var/log/unbound/**"
      "/etc/unbound/**"
    ];
    "dnscrypt-proxy2" = [
      "/var/lib/dnscrypt-proxy/**"
      "/var/log/dnscrypt-proxy/**"
      "/etc/dnscrypt-proxy/**"
    ];
  };

  combinedProfiles =
    let
      keys = lib.attrNames (baseProfiles // userProfiles);
    in
    lib.genAttrs keys (name:
      lib.unique (
        (lib.attrByPath [ name ] [ ] baseProfiles)
        ++ (lib.attrByPath [ name ] [ ] userProfiles)
      )
    );

  genProfile = name: paths:
    let
      allowPaths = (vars.appArmorCommonPaths or []) ++ paths;
      allowLines = lib.concatStringsSep "\n"
        (map (p: "  allow ${p} rwmix,") allowPaths);
    in
    ''
      #include <tunables/global>

      profile ${name} flags=(attach_disconnected,mediate_deleted) {
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
      combinedProfiles;
in
{
  security.apparmor = {
    enable = true;
    policies = generatedPolicies;
  };
}
