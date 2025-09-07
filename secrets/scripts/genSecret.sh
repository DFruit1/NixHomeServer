#!/usr/bin/env bash
# gen-secrets.sh ▸ Generate age-encrypted secrets for NixOS home-server
set -euo pipefail

########################################
# Prerequisites
########################################
need() { command -v "$1" >/dev/null 2>&1 || {
	echo "❌ $1 not found" >&2
	exit 1
}; }
need agenix
need openssl
need jq

########################################
# Configuration
########################################
secret_dir="./secrets"
mkdir -p "$secret_dir"

secrets=(
	kanidmAdminPass
	ncAdminPass
	ncOIDCClientSecret
	immichClientSecret
	paperlessClientSecret
	absClientSecret
	vaultwardenClientSecret
	vaultwardenAdminToken
)

########################################
# Helper: generate one secret
########################################
gen_secret() {
	local name=$1 secret

	case "$name" in
	netbirdSetupKey)
		# 44-char URL-safe base64 (NetBird’s format)
		secret=$(openssl rand -base64 32 | tr '+/' '-_' | head -c 44)
		;;
	cfHomeCreds)
		# Dummy JSON. Replace with the real tunnel credentials later.
		secret=$(jq -n \
			--arg acct "$(openssl rand -hex 8)" \
			--arg tsecret "$(openssl rand -base64 32)" \
			'{AccountTag:$acct, TunnelSecret:$tsecret, TunnelID:"REPLACE-ME", TunnelName:"REPLACE-ME"}')
		;;
	*)
		# 32-byte random string for passwords / tokens
		secret=$(openssl rand -base64 32)
		;;
	esac

	printf %s "$secret"
}

########################################
# Main loop
########################################
for name in "${secrets[@]}"; do
	target="${secret_dir}/${name}.age"

	if [[ -e "$target" ]]; then
		echo "⏭  $name already exists – skipping"
		continue
	fi

	echo -n "🔐  Generating $name … "
	gen_secret "$name" | agenix -e -i "$target"
	chmod 0400 "$target"
	echo "done ⇒ $target"
done

echo "✅ All missing secrets generated. Edit cfHomeCreds.age and netbirdSetupKey.age with real values when ready."
