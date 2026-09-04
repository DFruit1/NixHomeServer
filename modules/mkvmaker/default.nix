{ lib, vars, ... }:

{
  imports = [
    ./networking.nix
    ./identity.nix
    ./filepaths.nix
    ./services.nix
    ./bootstrap.nix
    ./backups.nix
    ./distributed-workers.nix
  ];

  nixhomeserver.modules.mkvmaker = true;

  # Operator-facing toggle for the distributed-worker feature, driven from
  # vars.nix. distributed-workers.nix keeps its own default of true and is left
  # untouched so the feature can be redeveloped later.
  repo.mkvmaker.distributedWorkers.enable =
    lib.mkDefault ((vars.mkvmaker or { }).distributedWorkers.enable or true);
}
