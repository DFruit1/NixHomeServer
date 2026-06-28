{ lib, pkgs, ... }:

let
  patchedPaperlessFetchFromGitHubNativeBuildInputs = with pkgs; [
    jq
    perl
    python3
  ];
  patchedPaperlessFetchFromGitHub =
    args:
    pkgs.runCommand "${args.repo}-${lib.replaceStrings ["/"] ["-"] args.tag}-patched"
      {
        nativeBuildInputs = patchedPaperlessFetchFromGitHubNativeBuildInputs;
        src = pkgs.fetchFromGitHub args;
      }
      ''
                cp -a "$src" "$out"
                chmod -R +w "$out"
                jq 'del(.packageManager)' "$out/src-ui/package.json" > "$out/src-ui/package.json.tmp"
                mv "$out/src-ui/package.json.tmp" "$out/src-ui/package.json"
                substituteInPlace "$out/src/documents/templates/account/signup.html" \
                  --replace-fail '{% if not FIRST_INSTALL %}' '{% if True %}'
                PATCH_TARGET="$out/src/paperless/adapter.py" python3 - <<'PY'
        import os
        from pathlib import Path

        path = Path(os.environ["PATCH_TARGET"])
        text = path.read_text()

        text = text.replace(
            "from django.contrib.auth.models import Group\nfrom django.contrib.auth.models import User\n",
            "from django.contrib.auth.models import Group\nfrom django.contrib.auth.models import Permission\nfrom django.contrib.auth.models import User\n",
        )

        old = """    def save_user(self, request, sociallogin, form=None):
                \"\"\"
                Save the user instance. Default groups are assigned to the user, if
                specified in the settings.
                \"\"\"
                # save_user also calls account_adapter save_user which would set ACCOUNT_DEFAULT_GROUPS
                user: User = super().save_user(request, sociallogin, form)
                group_names: list[str] = settings.SOCIAL_ACCOUNT_DEFAULT_GROUPS
                if len(group_names) > 0:
                    groups = Group.objects.filter(name__in=group_names)
                    logger.debug(
                        f\"Adding default social groups to user `{user}`: {group_names}\",
                    )
                    user.groups.add(*groups)
                    user.save()
                handle_social_account_updated(None, request, sociallogin)
                return user
        """

        new = """    def _coerce_social_group_names(self, group_values):
                if isinstance(group_values, str):
                    return {group_values}
                if isinstance(group_values, (list, tuple, set)):
                    return {
                        group_name
                        for group_name in group_values
                        if isinstance(group_name, str) and len(group_name) > 0
                    }
                return set()

            def _get_social_group_names(self, sociallogin):
                extra_data = sociallogin.account.extra_data or {}
                claim_names = {
                    getattr(settings, \"SOCIAL_ACCOUNT_SYNC_GROUPS_CLAIM\", \"groups\"),
                    \"groups\",
                    \"groups_name\",
                }
                group_names = set()
                for claim_name in claim_names:
                    group_names.update(
                        self._coerce_social_group_names(extra_data.get(claim_name, [])),
                    )

                userinfo = extra_data.get(\"userinfo\", {})
                if isinstance(userinfo, dict):
                    for claim_name in claim_names:
                        group_names.update(
                            self._coerce_social_group_names(userinfo.get(claim_name, [])),
                        )
                return group_names

            def _ensure_paperless_admin_group(self):
                group, _ = Group.objects.get_or_create(name=\"app-admin\")
                group.permissions.set(Permission.objects.all())
                return group

            def _apply_kanidm_admin_role(self, user, sociallogin):
                if sociallogin.account.provider != \"kanidm\":
                    return
                is_admin = \"app-admin\" in self._get_social_group_names(sociallogin)
                logger.debug(
                    f\"Reconciling Paperless social admin role for `{user}`: {is_admin}\",
                )
                user.is_superuser = is_admin
                user.is_staff = is_admin
                if user.pk:
                    if is_admin:
                        user.groups.add(self._ensure_paperless_admin_group())
                    else:
                        admin_group = Group.objects.filter(name=\"app-admin\").first()
                        if admin_group is not None:
                            user.groups.remove(admin_group)

            def pre_social_login(self, request, sociallogin):
                self._apply_kanidm_admin_role(sociallogin.user, sociallogin)
                if sociallogin.user.pk:
                    sociallogin.user.save(update_fields=[\"is_superuser\", \"is_staff\"])
                return super().pre_social_login(request, sociallogin)

            def save_user(self, request, sociallogin, form=None):
                \"\"\"
                Save the user instance. Default groups are assigned to the user, if
                specified in the settings.
                \"\"\"
                user = sociallogin.user
                self._apply_kanidm_admin_role(user, sociallogin)
                if (
                    User.objects.exclude(username__in=[\"consumer\", \"AnonymousUser\"]).count()
                    == 0
                    and Document.global_objects.count() == 0
                ):
                    logger.debug(f\"Creating initial social superuser `{user}`\")
                    user.is_superuser = True
                    user.is_staff = True
                # save_user also calls account_adapter save_user which would set ACCOUNT_DEFAULT_GROUPS
                user: User = super().save_user(request, sociallogin, form)
                group_names: list[str] = settings.SOCIAL_ACCOUNT_DEFAULT_GROUPS
                if len(group_names) > 0:
                    groups = Group.objects.filter(name__in=group_names)
                    logger.debug(
                        f\"Adding default social groups to user `{user}`: {group_names}\",
                    )
                    user.groups.add(*groups)
                    user.save()
                self._apply_kanidm_admin_role(user, sociallogin)
                user.save(update_fields=[\"is_superuser\", \"is_staff\"])
                handle_social_account_updated(None, request, sociallogin)
                return user
        """

        if old not in text:
            raise SystemExit("expected CustomSocialAccountAdapter.save_user block not found")

        path.write_text(text.replace(old, new))
        PY
      '';

  paperlessPackage = pkgs.callPackage (pkgs.path + "/pkgs/by-name/pa/paperless-ngx/package.nix") {
    fetchFromGitHub = patchedPaperlessFetchFromGitHub;
    nodejs = pkgs.nodejs_24;
  };
in
{
  config = {
    services.paperless.package = paperlessPackage;
  };
}
