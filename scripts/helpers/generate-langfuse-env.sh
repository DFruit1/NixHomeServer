#!/usr/bin/env bash
# Headless project initialization: https://langfuse.com/self-hosting/administration/headless-initialization
set -euo pipefail
for name in POSTGRES_PASSWORD REDIS_AUTH CLICKHOUSE_PASSWORD MINIO_ROOT_PASSWORD \
  SALT ENCRYPTION_KEY NEXTAUTH_SECRET LANGFUSE_INIT_USER_PASSWORD; do
  printf '%s=%s\n' "$name" "$(openssl rand -hex 32)"
done
printf 'LANGFUSE_INIT_PROJECT_PUBLIC_KEY=pk-lf-%s\n' "$(openssl rand -hex 32)"
printf 'LANGFUSE_INIT_PROJECT_SECRET_KEY=sk-lf-%s\n' "$(openssl rand -hex 32)"
