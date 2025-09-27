{ lib, vars, ... }:

let
  userProfiles = vars.appArmorDefaults or { };
  userCapabilities = vars.appArmorCapabilities or { };

  defaultCommonPaths = [
    "/nix/store/**"
    "/usr/**"
    "/lib/**"
    "/lib64/**"
    "/bin/**"
    "/sbin/**"
    "/run/**"
    "/etc/ssl/**"
    "/etc/machine-id"
    "/dev/null"
    "/dev/urandom"
    "/proc/**"
    "/sys/**"
  ];

  readOnlyPaths = lib.unique (defaultCommonPaths ++ (vars.appArmorCommonPaths or [ ]));

  baseProfiles = {
    caddy = [
      "/var/lib/caddy/**"
      "/var/log/caddy/**"
      "/etc/caddy/**"
      "/var/lib/acme/${vars.kanidmDomain}/**"
      "/run/caddy/**"
    ];
    "immich-server" = [
      "${vars.dataRoot}/immich/**"
      "/var/lib/immich/**"
      "/var/log/immich/**"
      "/run/immich/**"
    ];
    "immich-machine-learning" = [
      "${vars.dataRoot}/immich/**"
      "/var/cache/immich/**"
      "/var/lib/immich/**"
      "/var/log/immich/**"
      "/run/immich/**"
    ];
    "paperless-web" = [
      "${vars.dataRoot}/paperless/**"
      "/var/lib/paperless/**"
      "/var/log/paperless-ngx/**"
      "/run/paperless/**"
    ];
    audiobookshelf = [
      "${vars.dataRoot}/audiobookshelf/**"
      "/var/lib/audiobookshelf/**"
      "/var/log/audiobookshelf/**"
      "/run/audiobookshelf/**"
    ];
    copyparty = [
      "${vars.dataRoot}/copyparty/**"
      "/var/lib/copyparty/**"
      "/var/log/copyparty/**"
      "/run/copyparty/**"
    ];
    vaultwarden = [
      "${vars.dataRoot}/vaultwarden/**"
      "/var/lib/vaultwarden/**"
      "/var/log/vaultwarden/**"
      "/etc/vaultwarden/**"
      "/run/vaultwarden/**"
    ];
    "homepage-dashboard" = [
      "${vars.dataRoot}/homepage/**"
      "/var/lib/homepage-dashboard/**"
      "/var/cache/homepage-dashboard/**"
      "/var/log/homepage-dashboard/**"
      "/run/homepage-dashboard/**"
    ];
    "cloudflared-tunnel-${vars.cloudflareTunnelName}" = [
      "/var/lib/cloudflared/**"
      "/var/log/cloudflared/**"
      "/etc/cloudflared/**"
      "/run/cloudflared/**"
    ];
    "netbird-main" = [
      "/var/lib/netbird-main/**"
      "/var/log/netbird-main/**"
      "/etc/netbird-main/**"
      "/run/netbird-main/**"
    ];
    "oauth2-proxy" = [
      "/var/lib/oauth2-proxy/**"
      "/var/log/oauth2-proxy/**"
      "/etc/oauth2-proxy/**"
      "/run/oauth2-proxy/**"
    ];
    unbound = [
      "/var/lib/unbound/**"
      "/var/log/unbound/**"
      "/etc/unbound/**"
      "/run/unbound/**"
    ];
    "dnscrypt-proxy2" = [
      "/var/lib/dnscrypt-proxy/**"
      "/var/log/dnscrypt-proxy/**"
      "/etc/dnscrypt-proxy/**"
      "/run/dnscrypt-proxy/**"
    ];
    kanidm = [
      "/var/lib/kanidm/**"
      "/var/log/kanidm/**"
      "/etc/kanidm/**"
      "/var/lib/acme/${vars.kanidmDomain}/**"
      "/run/kanidm/**"
    ];
  };

  baseCapabilities = {
    caddy = [ "net_bind_service" ];
    unbound = [ "net_bind_service" ];
    "dnscrypt-proxy2" = [ "net_bind_service" ];
  };

  combineListAttrs = a: b:
    let
      keys = lib.unique (lib.attrNames a ++ lib.attrNames b);
    in
    lib.genAttrs keys (name:
      (lib.attrByPath [ name ] [ ] a)
      ++ (lib.attrByPath [ name ] [ ] b)
    );

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

  combinedCapabilities = combineListAttrs baseCapabilities userCapabilities;

  genProfile = name: paths:
    let
      rwPaths = lib.unique paths;
      allowReadOnly =
        lib.concatMapStrings (p: "      ${p} mr,\n      ${p} ix,\n") readOnlyPaths;
      allowReadWrite = lib.concatMapStrings (p: "      ${p} mrwkix,\n") rwPaths;
      capabilityLines =
        lib.concatMapStrings (c: "      capability ${c},\n")
          (lib.attrByPath [ name ] [ ] combinedCapabilities);
    in
    ''
                  #include <tunables/global>

                  profile ${name} flags=(attach_disconnected,mediate_deleted) {
                    #include <abstractions/base>
                    #include <abstractions/nameservice>
                    #include <abstractions/ssl_certs>

      ${allowReadOnly}${allowReadWrite}${capabilityLines}
                  }
    '';

  generatedPolicies =
    lib.mapAttrs'
      (n: p:
        lib.nameValuePair ("generated-" + n) {
          profile = genProfile n p;
          state = "complain";
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
