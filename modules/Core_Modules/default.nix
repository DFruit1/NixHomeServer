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
    ./storage
    ./storage-monitoring
    ./unbound
    ./validation
  ];
}
