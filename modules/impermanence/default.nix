{ config, impermanence, lib, vars, ... }:
{
  imports = [ impermanence.nixosModules.impermanence ];

  fileSystems."/persist" = lib.mkForce {
    device = "/dev/disk/by-id/${vars.mainDisk}";
    fsType = "btrfs";
    options = [ "subvol=persist" "compress=zstd" "noatime" ];
    neededForBoot = true;
  };

  environment.persistence."/persist" = {
    directories = [
      { directory = "/var/lib/caddy"; user = "caddy"; group = "caddy"; mode = "0750"; }
      { directory = "/var/log/caddy"; user = "caddy"; group = "caddy"; mode = "0750"; }
      { directory = "/var/lib/kanidm"; user = "kanidm"; group = "kanidm"; mode = "0700"; }
      { directory = "/var/log/kanidm"; user = "kanidm"; group = "kanidm"; mode = "0700"; }
      { directory = "/var/lib/immich"; user = "immich"; group = "immich"; mode = "0750"; }
      { directory = "/var/log/immich"; user = "immich"; group = "immich"; mode = "0750"; }
      { directory = "/var/lib/paperless"; user = "paperless"; group = "paperless"; mode = "0750"; }
      { directory = "/var/log/paperless-ngx"; user = "paperless"; group = "paperless"; mode = "0750"; }
      { directory = "/var/lib/audiobookshelf"; user = "audiobookshelf"; group = "audiobookshelf"; mode = "0750"; }
      { directory = "/var/log/audiobookshelf"; user = "audiobookshelf"; group = "audiobookshelf"; mode = "0750"; }
      { directory = "/var/lib/copyparty"; user = "copyparty"; group = "copyparty"; mode = "0750"; }
      { directory = "/var/log/copyparty"; user = "copyparty"; group = "copyparty"; mode = "0750"; }
      { directory = "/var/lib/vaultwarden"; user = "vaultwarden"; group = "vaultwarden"; mode = "0700"; }
      { directory = "/var/log/vaultwarden"; user = "vaultwarden"; group = "vaultwarden"; mode = "0750"; }
      { directory = "/var/lib/homepage-dashboard"; user = "root"; group = "root"; mode = "0755"; }
      { directory = "/var/cache/homepage-dashboard"; user = "root"; group = "root"; mode = "0755"; }
      { directory = "/var/log/homepage-dashboard"; user = "root"; group = "root"; mode = "0755"; }
      { directory = "/var/lib/cloudflared"; user = "cloudflared"; group = "cloudflared"; mode = "0750"; }
      { directory = "/var/log/cloudflared"; user = "cloudflared"; group = "cloudflared"; mode = "0750"; }
      { directory = "/var/lib/oauth2-proxy"; user = "oauth2-proxy"; group = "oauth2-proxy"; mode = "0750"; }
      { directory = "/var/log/oauth2-proxy"; user = "oauth2-proxy"; group = "oauth2-proxy"; mode = "0750"; }
      { directory = "/var/lib/unbound"; user = "unbound"; group = "unbound"; mode = "0750"; }
      { directory = "/var/log/unbound"; user = "unbound"; group = "unbound"; mode = "0750"; }
      { directory = "/var/lib/dnscrypt-proxy"; user = "root"; group = "root"; mode = "0755"; }
      { directory = "/var/log/dnscrypt-proxy"; user = "root"; group = "root"; mode = "0755"; }
      { directory = "/var/lib/netbird-main"; user = "netbird-main"; group = "netbird-main"; mode = "0700"; }
      { directory = "/var/log/netbird-main"; user = "netbird-main"; group = "netbird-main"; mode = "0700"; }
    ];
    files = [ "/etc/machine-id" ];
  };
}
