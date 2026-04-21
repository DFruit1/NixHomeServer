{ lib, vars, copyparty, ... }:

let
  copypartyPort = 3923;
in

{
  imports = [ copyparty.nixosModules.default ];

  nixpkgs.overlays = [ copyparty.overlays.default ];

  services.copyparty = {
    enable = true;
    openFilesLimit = 8192;
    settings = {
      i = "127.0.0.1";
      p = copypartyPort;
      shr = "/shares";
      "shr-who" = "auth";
      "shr-site" = "https://${vars.filesDomain}";
      auth-ord = "idp";
      idp-h-usr = "x-forwarded-preferred-username";
      idp-h-grp = "x-forwarded-groups";
      idp-store = 3;
      idp-login = "/oauth2/start?rd={dst}";
      idp-login-t = "Continue with Kanidm";
      # This clears the proxy session and immediately starts the login flow again.
      idp-logout = "/oauth2/sign_out?rd=/oauth2/start?rd=%2F";
      no-bauth = true;
      rproxy = 1;
      xff-hdr = "x-forwarded-for";
      xff-src = "127.0.0.1/32";
      no-reload = true;
      "html-head-s" = "<script>document.addEventListener('DOMContentLoaded',()=>{if(document.documentElement.id!=='ht_spl')return;const user=document.getElementById('un')?.textContent?.trim();if(!user)return;const addAlias=(headingId,href,label)=>{const heading=document.getElementById(headingId);const list=heading?.nextElementSibling;if(!list||list.tagName!=='UL')return;for(const li of Array.from(list.querySelectorAll('li'))){const a=li.querySelector('a');if(a?.textContent?.trim()==='/my-files/'+user+'/')li.remove();}if(Array.from(list.querySelectorAll('a')).some(a=>a.textContent?.trim()===label))return;const li=document.createElement('li');const a=document.createElement('a');a.href=href;a.textContent=label;li.appendChild(a);list.prepend(li);};addAlias('f','/my-files/'+encodeURIComponent(user)+'/','/my-files/');addAlias('g','/my-files/'+encodeURIComponent(user)+'/','/my-files/');});</script>";
    };
    volumes = { };
    globalExtraConfig = ''
      [/my-files/''${u}]
      ${vars.usersWorkspaceRoot}/''${u}/files
      accs:
        rwmda: ''${u}
      flags:
        fk: 4
        e2d: true
        chmod_d: 770
        chmod_f: 660
        unlistcr: true
        unlistcw: true

      [/shared]
      ${vars.sharedPublicRoot}
      accs:
        rwmda: @acct
      flags:
        fk: 4
        e2d: true
        chmod_d: 775
        chmod_f: 664
        unlistcr: true
        unlistcw: true
    '';
  };

  users.users.copyparty.extraGroups = [ "users" ];

  systemd.services.copyparty = {
    wants = [ "fileshare-workspace-sync.service" ];
    after = [ "fileshare-workspace-sync.service" ];
    serviceConfig.BindPaths = lib.mkAfter [
      vars.usersWorkspaceRoot
      vars.sharedPublicRoot
    ];
  };
}
