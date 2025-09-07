#!/usr/bin/env bash

# ------------------------------------------------------------------
# gen-all-secrets.sh  ▸  first-provision helper for NixOS + agenix
# ------------------------------------------------------------------
set -euo pipefail

top_dir="secrets/top" # clear-text staging dir
age_dir="secrets"     # encrypted files live here

mkdir -p "$top_dir" "$age_dir"

need() {
        command -v "$1" >/dev/null || {
                echo "❌ $1 not found" >&2
                exit 1
        }
}
need openssl
need age

# name                bytes
declare -A SPEC=(
        [kanidmAdminPass]=24
        [kanidmSysAdminPass]=24
        [immichClientSecret]=32
        [paperlessClientSecret]=32
        [absClientSecret]=32
        [copypartyClientSecret]=32
        [vaultwardenClientSecret]=32
        [vaultwardenAdminToken]=48
)

gen_secret() {
        local bytes=$1
        # RFC-4648 URL-safe base64 without trailing =
        openssl rand -base64 "$bytes" | tr -d '=+/[:cntrl:]' | head -c "$((bytes * 4 / 3))"
}

for name in "${!SPEC[@]}"; do
        clear_file="${top_dir}/${name}"
        age_file="${age_dir}/${name}.age"

        if [[ -f "$age_file" ]]; then
                echo "⏭  $name already encrypted – skipping"
                continue
        fi

        echo -n "🔐  Generating $name … "

        secret=$(gen_secret "${SPEC[$name]}")
        printf '%s\n' "$secret" >"$clear_file"
        chmod 0440 "$clear_file"

        age --encrypt \
                -r "$(cat secrets/pubkeys/age.pub)" \
                --output "$age_file" \
                "$clear_file"

        echo "done (→ $age_file)"
done

echo -e "\n✅ All missing secrets generated & encrypted."
echo "🔏 Clear-text copies are in $top_dir — delete or move them to a secure vault when you’re done."

manual_missing=()
for name in netbirdSetupKey cfHomeCreds; do
        [[ -f "${age_dir}/${name}.age" ]] || manual_missing+=("$name")

done

if (( ${#manual_missing[@]} )); then
        echo -e "\n⚠️  The following secrets must be created manually and encrypted:"
        for name in "${manual_missing[@]}"; do
                case "$name" in
                netbirdSetupKey)
                        echo "  - netbirdSetupKey: obtain a NetBird setup key, store it in secrets/top/netbirdSetupKey and encrypt to secrets/netbirdSetupKey.age"
                        ;;
                cfHomeCreds)
                        echo "  - cfHomeCreds: save your Cloudflare tunnel credentials JSON to secrets/top/cfHomeCreds and encrypt to secrets/cfHomeCreds.age"
                        ;;
                esac
        done
fi
