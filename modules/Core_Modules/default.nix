{ ... }:

{
  imports = [
    ./age
    ./auth-gateway
    ./backups
    ./base-system
    ./caddy
    ./cloudflared
    ./data-disks
    ./impermanence
    ./kanidm
    ./kopia
    ./monitoring
    ./module-registry.nix
    ./netbird
    ./oauth2-proxy/identity.nix
    ./rclone
    ./storage
    ./storage-monitoring
    ./syncthing
    ./unbound
    ./validation
  ];
}
