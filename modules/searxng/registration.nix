{
  # No homepage tile and no gateway host: SearXNG is loopback-only and is
  # reached through ai-tools or the Search backend. Only the loopback port
  # is registered here; exposing the host would break the invariant asserted in
  # networking.nix.
  ports.searxng = 8098;
  homepage = _: [ ];
}
