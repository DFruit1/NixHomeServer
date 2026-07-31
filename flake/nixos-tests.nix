{ lib, pkgs }:

{
  failure-alert = pkgs.testers.runNixOSTest {
    name = "nixhomeserver-failure-alert";

    nodes.machine = { config, ... }: {
      imports = [ ../modules/Core_Modules/monitoring/alerts.nix ];

      options.age.secrets = lib.mkOption {
        type = lib.types.attrs;
        default = { };
      };

      config = {
        _module.args.vars = {
          hostname = "alert-test-host";
        };

        systemd.services.deliberate-failure = {
          description = "Deliberate failure used by the VM test";
          unitConfig = {
            OnFailure = [ config.repo.monitoring.failureAlerts.targetUnit ];
            OnFailureJobMode = "replace-irreversibly";
          };
          serviceConfig.Type = "oneshot";
          script = ''
            echo "deliberate VM-test failure" >&2
            exit 42
          '';
        };
      };
    };

    testScript = ''
      machine.start()
      machine.wait_for_unit("multi-user.target")
      machine.fail("systemctl start deliberate-failure.service")
      machine.wait_until_succeeds(
          "journalctl --no-pager -t nixhomeserver-failure-alert "
          "| grep -F 'NixHomeServer unit failed: deliberate-failure.service on alert-test-host'"
      )
      machine.succeed(
          "systemctl show -p Result --value "
          "nixhomeserver-failure-alert@deliberate-failure.service.service | grep -Fx success"
      )
    '';
  };

  jellyfin-oidc = pkgs.testers.runNixOSTest {
    name = "nixhomeserver-jellyfin-oidc";

    nodes = {
      server = { jellyfinOidcPlugin, lib, pkgs, ... }:
      let
        pluginDir = "/var/lib/jellyfin/plugins/OIDC RBAC_1.0.8.0";
        pluginSource = "${jellyfinOidcPlugin}/lib/jellyfin-plugin-oidc";
        pluginRuntimeDir = "/run/jellyfin-oidc-plugin";
        pluginAssemblies = [
          "IdentityModel.dll"
          "Jellyfin.Plugin.OIDC.dll"
          "Microsoft.IdentityModel.Abstractions.dll"
          "Microsoft.IdentityModel.JsonWebTokens.dll"
          "Microsoft.IdentityModel.Logging.dll"
          "Microsoft.IdentityModel.Protocols.OpenIdConnect.dll"
          "Microsoft.IdentityModel.Protocols.dll"
          "Microsoft.IdentityModel.Tokens.dll"
          "System.IdentityModel.Tokens.Jwt.dll"
        ];
        installManifest = pkgs.writeShellScript "jellyfin-oidc-vm-manifest-install" ''
          set -euo pipefail
          install -m 0644 ${pluginSource}/meta.json ${lib.escapeShellArg "${pluginDir}/meta.json"}
          ${lib.concatMapStringsSep "\n" (assembly: ''
            ln -sfn ${pluginRuntimeDir}/${assembly} ${lib.escapeShellArg "${pluginDir}/${assembly}"}
          '') pluginAssemblies}
        '';
      in {
        imports = [ ../modules/jellyfin/package.nix ];

        services.jellyfin = {
          enable = true;
          openFirewall = false;
        };

        systemd.tmpfiles.settings.jellyfinOidcDirs = {
          "/var/lib/jellyfin/plugins".d = {
            mode = "0700";
            user = "jellyfin";
            group = "jellyfin";
          };
          "${pluginDir}".d = {
            mode = "0750";
            user = "jellyfin";
            group = "jellyfin";
          };
          "${pluginRuntimeDir}".d = {
            mode = "0750";
            user = "jellyfin";
            group = "jellyfin";
          };
        };
        systemd.services.jellyfin.serviceConfig = {
          ExecStartPre = [ installManifest ];
          BindReadOnlyPaths = [ "${pluginSource}:${pluginRuntimeDir}" ];
        };
        environment.etc."jellyfin-oidc-plugin-source".text = pluginSource;

        networking.firewall.allowedTCPPorts = [ 8096 ];
        networking.firewall.allowedUDPPorts = [ 7359 ];
        environment.systemPackages = with pkgs; [ curl jq netcat-openbsd util-linux ];
        virtualisation = {
          memorySize = 2048;
          diskSize = 4096;
        };
      };

      client = { pkgs, ... }: {
        networking.firewall.allowedUDPPorts = [ 7358 ];
        environment.systemPackages = with pkgs; [ curl jq python3 ];
      };
    };

    testScript = ''
      import json

      start_all()
      server.wait_for_unit("jellyfin.service")
      server.wait_for_open_port(8096)

      server.wait_until_succeeds(
          "curl -fsS http://127.0.0.1:8096/System/Info/Public | jq -e '.ServerName'"
      )
      server.succeed(
          "curl -fsS http://127.0.0.1:8096/web/index.html "
          "| grep -F '<script defer=\"defer\" src=\"/sso/OIDC/LoginButtons\"></script>'"
      )
      server.succeed(
          """curl -fsS -X POST -H 'Content-Type: application/json' \
          --data '{"UICulture":"en-US","MetadataCountryCode":"AU","PreferredMetadataLanguage":"en"}' \
          http://127.0.0.1:8096/Startup/Configuration"""
      )
      # Jellyfin 10.11 creates its initial user lazily when this endpoint is
      # first read; initialize it before assigning the test credentials.
      server.succeed("curl -fsS http://127.0.0.1:8096/Startup/User")
      server.succeed(
          """curl -fsS -X POST -H 'Content-Type: application/json' \
          --data '{"Name":"vm-admin","Password":"vm-native-password"}' \
          http://127.0.0.1:8096/Startup/User"""
      )
      server.succeed(
          """curl -fsS -X POST -H 'Content-Type: application/json' \
          --data '{"EnableRemoteAccess":false,"EnableAutomaticPortMapping":false}' \
          http://127.0.0.1:8096/Startup/RemoteAccess"""
      )
      server.succeed("curl -fsS -X POST http://127.0.0.1:8096/Startup/Complete")

      auth = json.loads(server.succeed(
          """curl -fsS -X POST -H 'Content-Type: application/json' \
          -H 'Authorization: MediaBrowser Client="VM Test", Device="NixOS", DeviceId="vm-test", Version="1.0"' \
          --data '{"Username":"vm-admin","Pw":"vm-native-password"}' \
          http://127.0.0.1:8096/Users/AuthenticateByName"""
      ))
      token = auth["AccessToken"]
      assert auth["User"]["Name"] == "vm-admin"

      server.succeed(
          "source=$(cat /etc/jellyfin-oidc-plugin-source); "
          "pid=$(systemctl show --property MainPID --value jellyfin.service); "
          "nsenter --target \"$pid\" --mount -- "
          "cmp \"$source/Jellyfin.Plugin.OIDC.dll\" "
          "'/var/lib/jellyfin/plugins/OIDC RBAC_1.0.8.0/Jellyfin.Plugin.OIDC.dll'"
      )
      server.fail(
          "pid=$(systemctl show --property MainPID --value jellyfin.service); "
          "nsenter --target \"$pid\" --mount -- sh -c "
          "\"printf changed >> '/var/lib/jellyfin/plugins/OIDC RBAC_1.0.8.0/Jellyfin.Plugin.OIDC.dll'\""
      )
      server.succeed(
          "journalctl --unit jellyfin.service --no-pager "
          "| grep -F 'Loaded plugin: OIDC RBAC 1.0.8.0'"
      )
      server.succeed(
          "curl -fsS http://127.0.0.1:8096/sso/OIDC/Providers | jq -e 'type == \"array\"'"
      )
      server.succeed(
          "curl -fsS http://127.0.0.1:8096/QuickConnect/Enabled | grep -Fx true"
      )
      server.succeed(
          """curl -fsS -X POST \
          -H 'Authorization: MediaBrowser Client="VM TV", Device="TV", DeviceId="vm-tv", Version="1.0"' \
          http://127.0.0.1:8096/QuickConnect/Initiate \
          | jq -e '.Code | test("^[0-9]{6}$")'"""
      )

      discovery = client.succeed(
          """python3 -c 'import socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1); s.bind(("0.0.0.0", 7358)); s.settimeout(5); s.sendto(b"who is JellyfinServer?", ("255.255.255.255", 7359)); print(s.recv(4096).decode())'"""
      )
      discovered = json.loads(discovery)
      assert discovered["Address"].startswith("http://")
      client.succeed(
          "curl -fsS '%s/System/Info/Public' | jq -e '.ServerName'" % discovered["Address"]
      )
    '';
  };
}
