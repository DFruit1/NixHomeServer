{ config, vars, ... }:

{
  security.acme = {
    acceptTerms = true;
    defaults = {
      email = vars.kanidmAdminEmail;
      dnsProvider = "cloudflare";
      credentialFiles.CF_DNS_API_TOKEN_FILE = config.age.secrets.cfAPIToken.path;
      dnsResolver = "9.9.9.9:53";
    };
    certs."${vars.domain}" = {
      extraDomainNames = [ "*.${vars.domain}" ];
      group = "caddy";
      reloadServices = [ "caddy.service" ];
    };
    certs."${vars.kanidmDomain}" = {
      group = "caddy";
      reloadServices = [ "caddy.service" "kanidm.service" ];
    };
  };

  systemd.services = {
    "acme-order-renew-${vars.domain}" = {
      wants = [ "unbound.service" ];
      after = [ "unbound.service" ];
    };
    "acme-order-renew-${vars.kanidmDomain}" = {
      wants = [ "unbound.service" ];
      after = [ "unbound.service" ];
    };
  };
}
