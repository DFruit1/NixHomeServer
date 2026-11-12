{ config, lib, options, pkgs, vars, ... }:
let
  cfg = config.repo.paperlessGpt;
  dependenciesPresent = lib.all
    (name: lib.hasAttrByPath [ "repo" name ] options)
    [ "paperlessGpt" "paperless" "bonsai" ];
  owner = vars.localAdminUser;
  provision = pkgs.writeText "paperless-gpt-provision.py" ''
    import os
    from django.contrib.auth import get_user_model
    from django.contrib.auth.models import Permission
    from django.db.models import Q
    from documents.models import Document, Tag, Correspondent, DocumentType, CustomField, StoragePath
    from guardian.shortcuts import assign_perm, get_objects_for_user, remove_perm
    from rest_framework.authtoken.models import Token

    User = get_user_model()
    owner = User.objects.get(username=${builtins.toJSON owner}, is_active=True)
    user, created = User.objects.get_or_create(username="paperless-gpt-service")
    if created:
        user.set_unusable_password()
    user.is_staff = False
    user.is_superuser = False
    user.save()
    # Never inherit the owner's group permissions (which can include delete).
    user.groups.clear()
    # Metadata created through the service API must remain visible/editable in
    # the owner's ordinary Paperless UI, including markers created at startup.
    for model in (Tag, Correspondent):
        name = model._meta.model_name
        for obj in model.objects.filter(owner=user).iterator():
            assign_perm("documents.view_" + name, owner, obj)
            assign_perm("documents.change_" + name, owner, obj)
    Tag.objects.get_or_create(name="paperless-gpt", owner=owner)
    for model in (Document, Tag, Correspondent, DocumentType, StoragePath):
        name = model._meta.model_name
        view = "documents.view_" + name
        visible = get_objects_for_user(owner, view, klass=model, accept_global_perms=False)
        objects = model.objects.filter(Q(owner=owner) | Q(owner__isnull=True) | Q(pk__in=visible.values("pk")))
        previous = get_objects_for_user(user, view, klass=model, accept_global_perms=False)
        for obj in previous.exclude(pk__in=objects.values("pk")).iterator():
            remove_perm(view, user, obj)
            if model is Document:
                remove_perm("documents.change_document", user, obj)
        for obj in objects.iterator():
            assign_perm(view, user, obj)
            if model is Document:
                assign_perm("documents.change_document", user, obj)
    names = ["view_document", "change_document", "view_tag", "add_tag",
             "view_correspondent", "add_correspondent", "view_documenttype",
             "view_customfield", "view_storagepath"]
    user.user_permissions.set(Permission.objects.filter(content_type__app_label="documents", codename__in=names))
    token, _ = Token.objects.get_or_create(user=user)
    with open(os.environ["PAPERLESS_GPT_ENV_OUT"], "w") as f:
        f.write("PAPERLESS_API_TOKEN=" + token.key + "\n")
  '';
in
{
  config = lib.optionalAttrs dependenciesPresent (lib.mkIf cfg.enable {
    assertions = [{
      assertion = config.repo.bonsai.enable && config.repo.bonsai.gate.enable;
      message = "Paperless-GPT requires enabled Bonsai and its inference concurrency gate.";
    }];
    repo.paperless.additionalAllowedHosts = [ vars.networking.loopbackIPv4 ];
    virtualisation.oci-containers.containers.paperless-gpt.environment = {
      PAPERLESS_BASE_URL = "http://${vars.networking.loopbackIPv4}:${toString vars.networking.ports.paperless}";
      PAPERLESS_PUBLIC_URL = "https://paperless.${vars.domain}";
      OPENAI_BASE_URL = config.repo.bonsai.gate.gateBaseUrl;
      OPENAI_API_KEY = "local-loopback";
      LLM_MODEL = config.repo.bonsai.modelName;
    };
    systemd.services.paperless-gpt = {
      wants = [ "bonsai-gate.service" ];
      after = [ "bonsai-gate.service" ];
    };
    # Refresh object access for newly imported owner documents; revoke grants
    # when the owner loses access. No document content or metadata is changed.
    systemd.timers.paperless-gpt-provision = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = "3min"; OnUnitInactiveSec = "5min"; };
    };
    systemd.services.paperless-gpt-provision = {
      description = "Provision the approved Paperless-GPT service identity and runtime credential";
      wantedBy = [ "multi-user.target" ];
      requires = [ "paperless-web.service" ];
      after = [ "paperless-web.service" "paperless-permissions-bootstrap.service" ];
      path = [ pkgs.coreutils pkgs.util-linux pkgs.getent config.services.paperless.manage ];
      serviceConfig = {
        Type = "oneshot";
        Group = "paperless";
        RuntimeDirectoryPreserve = "yes";
        RuntimeDirectory = "paperless-gpt-credentials";
        RuntimeDirectoryMode = "0750";
        UMask = "0077";
        Nice = 15;
        CPUWeight = 10;
        IOWeight = 10;
        MemoryHigh = "512M";
        MemoryMax = "1G";
      };
      script = ''
        set -euo pipefail
        temp=$(mktemp /run/paperless-gpt-credentials/environment.XXXXXX)
        trap 'rm -f -- "$temp"' EXIT
        chown paperless:paperless "$temp"
        runuser -u paperless -- env PAPERLESS_GPT_ENV_OUT="$temp" \
          paperless-manage shell -c ${lib.escapeShellArg "exec(open('${provision}').read())"}
        uid=$(id -u paperless-gpt)
        gid=$(id -g paperless-gpt)
        printf 'PUID=%s\nPGID=%s\n' "$uid" "$gid" >> "$temp"
        install -m 0600 -o root -g root "$temp" /run/paperless-gpt-credentials/environment
      '';
    };
  });
}
