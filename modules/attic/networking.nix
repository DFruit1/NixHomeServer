{ ... }:

{
  # The cache is intentionally loopback-only. It is consumed by the server's
  # Nix daemon and is not registered with Caddy, Unbound, or the firewall.
}
