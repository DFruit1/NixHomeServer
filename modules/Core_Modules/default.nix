{ ... }:

{
  imports = [
    ./age
    ./backups
    ./base-system
    ./caddy
    ./cloudflared
    ./data-disks
    ./impermanence
    ./kanidm
    ./kopia
    ./monitoring
    ./netbird
    ./oauth2-proxy/identity.nix
    ./phone-backup
    ./rclone
    ./storage
    ./storage-monitoring
    ./syncthing
    ./unbound
    ./validation
  ];
}
