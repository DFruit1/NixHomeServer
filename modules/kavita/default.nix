{ config, vars, pkgsUnstable, ... }:

{
  services.kavita = {
    enable = true;
    package = pkgsUnstable.kavita;
    dataDir = "${vars.dataRoot}/kavita";
    tokenKeyFile = config.age.secrets.kavitaTokenKey.path;
    settings = {
      Port = vars.kavitaPort;
      IpAddresses = "127.0.0.1,::1";
    };
  };
}
