{
  # Loopback port for the ntfy server. Caddy on the private host is the sole
  # ingress, so this port must never be opened by the firewall or the tunnel.
  ports.ntfy = 8099;
  homepage = _: [ ];
}