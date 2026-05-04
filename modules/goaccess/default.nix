{ config, lib, pkgs, ... }:

let
  cfg = config.services.goaccessDashboard;
  user = "goaccess";
  stateDirDefault = "/var/lib/goaccess";
  reportDirDefault = "${stateDirDefault}/report";
  dbDirDefault = "${stateDirDefault}/db";
  logFileDefault = "/var/log/caddy/access.log";
  generateReportScript = pkgs.writeShellScript "goaccess-generate-report" ''
    set -euo pipefail

    log_file=${lib.escapeShellArg cfg.logFile}
    report_file=${lib.escapeShellArg cfg.reportFile}
    db_path=${lib.escapeShellArg cfg.dbDir}
    tmp_report="$(${pkgs.coreutils}/bin/mktemp "${cfg.reportDir}/index.XXXXXX.html")"
    trap 'rm -f "$tmp_report"' EXIT

    cmd=(
      ${lib.escapeShellArg "${cfg.package}/bin/goaccess"}
      "$log_file"
      --log-format=CADDY
      --output="$tmp_report"
      --persist
      --db-path="$db_path"
      --no-global-config
    )

    if ${pkgs.findutils}/bin/find "$db_path" -mindepth 1 -print -quit | ${pkgs.gnugrep}/bin/grep -q .; then
      cmd+=(--restore)
    fi

    "''${cmd[@]}"
    ${pkgs.coreutils}/bin/mv "$tmp_report" "$report_file"
    ${pkgs.coreutils}/bin/chmod 0640 "$report_file"
  '';
  refreshLoopScript = pkgs.writeShellScript "goaccess-refresh-loop" ''
    set -euo pipefail

    log_file=${lib.escapeShellArg cfg.logFile}
    report_file=${lib.escapeShellArg cfg.reportFile}

    while true; do
      if [[ -s "$log_file" ]]; then
        if ! ${generateReportScript}; then
          echo "goaccess report generation failed; retrying shortly" >&2
          sleep 5
          continue
        fi
      elif [[ ! -e "$report_file" ]]; then
        sleep 1
        continue
      fi

      sleep ${toString cfg.refreshIntervalSeconds}
    done
  '';
in
{
  options.services.goaccessDashboard = {
    enable = lib.mkEnableOption "the private GoAccess traffic dashboard";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.goaccess;
      description = "Package providing the GoAccess binary.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = stateDirDefault;
      description = "Writable state root for GoAccess report and persisted database data.";
    };

    reportDir = lib.mkOption {
      type = lib.types.str;
      default = reportDirDefault;
      description = "Directory containing the generated HTML dashboard.";
    };

    reportFile = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.reportDir}/index.html";
      description = "Generated GoAccess HTML report path.";
    };

    dbDir = lib.mkOption {
      type = lib.types.str;
      default = dbDirDefault;
      description = "Directory holding the persisted GoAccess database.";
    };

    logFile = lib.mkOption {
      type = lib.types.str;
      default = logFileDefault;
      description = "Caddy access log file to analyze.";
    };

    refreshIntervalSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
      description = "Seconds between GoAccess report refreshes.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${user} = {
      isSystemUser = true;
      group = "caddy";
      home = cfg.stateDir;
      createHome = false;
    };

    systemd.tmpfiles.rules = [
      "d /var/log/caddy 0750 caddy caddy -"
      "d ${cfg.stateDir} 0750 ${user} caddy -"
      "d ${cfg.reportDir} 0750 ${user} caddy -"
      "d ${cfg.dbDir} 0750 ${user} caddy -"
    ];

    systemd.services.goaccess-report = {
      description = "Generate and refresh the GoAccess traffic dashboard";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "caddy.service"
        "local-fs.target"
      ];
      after = [
        "caddy.service"
        "local-fs.target"
      ];
      serviceConfig = {
        Type = "simple";
        User = user;
        Group = "caddy";
        ExecStart = refreshLoopScript;
        Restart = "on-failure";
        UMask = "0007";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        ReadOnlyPaths = [ cfg.logFile ];
        ReadWritePaths = [
          cfg.stateDir
          cfg.reportDir
          cfg.dbDir
        ];
      };
    };
  };
}
