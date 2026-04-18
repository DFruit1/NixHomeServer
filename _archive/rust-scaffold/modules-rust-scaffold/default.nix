{ config, lib, pkgs, self, vars, ... }:

let
  cfg = config.services.rust-scaffold;
  user = "rust-scaffold";
  group = "rust-scaffold";
  environmentEntries =
    [
      "RUST_SCAFFOLD_ADDRESS=${cfg.address}"
      "RUST_SCAFFOLD_PORT=${toString cfg.port}"
      "RUST_SCAFFOLD_DATA_DIR=${cfg.dataDir}"
    ]
    ++ lib.mapAttrsToList (name: value: "${name}=${value}") cfg.environment;
in
{
  options.services.rust-scaffold = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Run the example Rust scaffold application as a local systemd service.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.system}.rust-scaffold;
      description = "Package to run for the Rust scaffold service.";
    };

    address = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address the Rust scaffold listens on.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = vars.rustScaffoldPort;
      description = "Port the Rust scaffold listens on.";
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra environment variables passed to the Rust scaffold service.";
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Optional environment file loaded by the Rust scaffold service.";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = vars.rustScaffoldDataDir;
      description = "Writable data directory reserved for the Rust scaffold service.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${user} = {
      isSystemUser = true;
      group = group;
      home = cfg.dataDir;
      createHome = false;
    };

    users.groups.${group} = { };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 ${user} ${group} -"
    ];

    systemd.services.rust-scaffold = {
      description = "Rust scaffold application";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "simple";
        User = user;
        Group = group;
        WorkingDirectory = cfg.dataDir;
        ExecStart = "${cfg.package}/bin/rust-scaffold";
        Environment = environmentEntries;
        EnvironmentFile = lib.optional (cfg.environmentFile != null) cfg.environmentFile;
        Restart = "on-failure";
        DynamicUser = false;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
        ReadWritePaths = [ cfg.dataDir ];
      };
    };
  };
}
