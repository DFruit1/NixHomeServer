{ config, pkgs, vars, ... }:

{
  ########################################################
  ## Bootloader suitable for your GPT + EFI /boot
  ########################################################
  boot.loader.systemd-boot.enable      = true;
  boot.loader.efi.canTouchEfiVariables = true;

  ########################################################
  ## Minimal networking: DHCP on every interface
  ########################################################
  networking.useDHCP = true;   # enables dhcpcd for all NICs

  ########################################################
  ## SSH so you can log in after Stage-1 install
  ########################################################
  services.openssh = {
    enable                 = true;
    settings = {
      PasswordAuthentication = false;             # capital “P”
      PermitRootLogin        = "prohibit-password";
    };
  };

  users.users.root.openssh.authorizedKeys.keys = [
    vars.serverSSHPubKey           # pulled from vars.nix
  ];

  ########################################################
  ## Essential tools to fetch / update your flake
  ########################################################
  environment.systemPackages = with pkgs; [
    git
  ];

  ########################################################
  ## Nix features & compatibility
  ########################################################
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  ########################################################
  ## Required for new installs
  ########################################################
  system.stateVersion = "25.05";
}

