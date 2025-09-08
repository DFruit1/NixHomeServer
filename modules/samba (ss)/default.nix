{ lib, pkgs }:

let
  vars = import ../../vars.nix { inherit lib; };
in
{
  #############################################
  # Samba – per-user "homes" share (Kanidm ADS)
  #############################################
  services.samba = {
    enable = true;

    # Open only LAN interface
    openFirewall = false;                         # we handle ports below

    winbind = {                                   # proper nesting
      enable = true;
    };

    # DON’T set securityType here – we define security in extraConfig
    shares.homes = {
      path           = "${vars.dataRoot}/home/%S";
      browseable     = "no";
      comment        = "Home Directories";
      "read only"    = "no";
      "create mask"  = "0644";
      "directory mask" = "0755";
    };

    extraConfig = ''
      # --- Active Directory / Kanidm ADS join ---
      security   = ADS
      workgroup  = WORKGROUP                # NetBIOS name (upper-case optional)
      realm      = ${lib.strings.toUpper vars.domain}

      # id-mapping (simple, local tdb)
      idmap config * : backend = tdb
      idmap config * : range   = 3000-7999

      winbind use default domain = yes

      obey pam restrictions = yes
      pam password change   = yes
    '';
  };

  ########################
  # tmpfiles – create root
  ########################
  systemd.tmpfiles.rules = [
    "d ${vars.dataRoot}/home 0755 root root - -"
  ];

  ########################
  # Firewall – LAN only
  ########################
  networking.firewall = {
    interfaces.enp34s0.allowedTCPPorts = [ 139 445 ];
    interfaces.enp34s0.allowedUDPPorts = [ 137 138 ];
  };
}
