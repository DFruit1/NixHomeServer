{ pkgs, lib, ... }:

let vars = import ../../vars.nix { inherit lib; };
in
{
  services.unbound = {
    enable = true;
    resolveLocalQueries = true;
    settings.server = {
      interface      = [ "0.0.0.0" "::0" ];
      access-control = [ "192.168.0.0/16 allow" "127.0.0.0/8 allow" ];
      local-zone     = [ "${vars.domain} static" ];
      local-data     = [
        "${vars.domain}                 A ${vars.lanIP}"
        "www.${vars.domain}             A ${vars.lanIP}"
        "immich.${vars.domain}          A ${vars.lanIP}"
        "paperless.${vars.domain}       A ${vars.lanIP}"
        "audiobookshelf.${vars.domain}  A ${vars.lanIP}"
        "id.${vars.domain}              A ${vars.lanIP}"
      ];
    };
  };
}
