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
    ./netbird
    ./oauth2-proxy/identity.nix
    ./phone-backup
    ./storage
    ./storage-monitoring
    ./syncthing
    ./unbound
    ./validation
  ];
}
