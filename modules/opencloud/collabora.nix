{ vars, ... }:

let
  cloudHost = "cloud.${vars.domain}";
  officeHost = "office.${vars.domain}";
in
{
  services.collabora-online = {
    enable = true;
    port = vars.networking.ports.collaboraOnline;
    aliasGroups = [
      {
        host = "https://${officeHost}";
        aliases = [ "https://${cloudHost}" ];
      }
    ];
    settings = {
      # Allow WOPI traffic and serve plain HTTP to Caddy, which is the only
      # TLS terminator in front of coolwsd.
      storage.wopi."@allow" = true;
      ssl.enable = false;
      ssl.termination = true;
      ssl.ssl_verification = true;

      # Bind loopback only: Caddy and the in-process OpenCloud collaboration
      # service both reach coolwsd over 127.0.0.1. Force IPv4 so the socket is
      # reachable on the loopback address Caddy proxies to.
      net.listen = "loopback";
      net.proto = "IPv4";

      # Only loopback clients may issue POST/REST requests, which confines the
      # convert-to and WOPI endpoints to the reverse proxy and OpenCloud.
      net.post_allow.host = [
        "127.0.0.1/32"
        "::1/128"
      ];

      # Documents may only fetch external data from loopback. This blocks SSRF
      # from untrusted documents via =WEBSERVICE(), linked images, and external
      # references while leaving WOPI storage access intact.
      net.lok_allow.host = [
        "127.0.0.1/32"
        "::1/128"
        "localhost"
      ];

      # Macros stay fully disabled; the security level is inert while execution
      # is off but pins intent against future defaults.
      security.enable_macros_execution = false;
      security.macro_security_level = 1;
      security.seccomp = true;
      security.capabilities = true;
      security.server_signature = false;
      security.enable_metrics_unauthenticated = false;

      # The office host is LAN/NetBird only and no console credentials are
      # provisioned, so keep the admin console and metrics endpoint closed.
      admin_console.enable = false;

      # Do not advertise available updates in the editor or phone home for a
      # version-popup the user cannot action.
      allow_update_popup = false;

      # Unload idle documents after 30 minutes rather than the 1 hour default.
      per_document.idle_timeout_secs = 1800;

      # Per-process ceilings so one document cannot exhaust the home server.
      per_document.max_concurrency = 2;
      per_document.limit_virt_mem_mb = 2048;
      per_document.limit_stack_mem_kb = 8192;
      per_document.limit_num_open_files = 4096;
      per_document.limit_file_size_mb = 512;
      per_document.cleanup.limit_dirty_mem_mb = 2048;

      # Global guard rails: begin reclaiming idle documents at half of memory
      # and keep only one warm child and one idle subforkit.
      memproportion = 50.0;
      num_prespawn_children = 1;
      serverside_config.idle_timeout_secs = 1800;
      serverside_config.max_idle_subforkits = 1;

      # Reject documents larger than 100 MiB before loading them.
      storage.wopi.max_file_size = 104857600;
    };
  };

  systemd.services.coolwsd.after = [ "opencloud-storage-layout-v1.service" ];
}
