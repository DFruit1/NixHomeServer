#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
ensure_tools bash openssl python3
bash "$TESTS_REPO_ROOT/scripts/helpers/generate-langfuse-env.sh" | python3 -c '
import sys,re
values=dict(line.rstrip("\n").split("=",1) for line in sys.stdin)
expected={"POSTGRES_PASSWORD","REDIS_AUTH","CLICKHOUSE_PASSWORD","MINIO_ROOT_PASSWORD","SALT","ENCRYPTION_KEY","NEXTAUTH_SECRET","LANGFUSE_INIT_USER_PASSWORD","LANGFUSE_INIT_PROJECT_PUBLIC_KEY","LANGFUSE_INIT_PROJECT_SECRET_KEY"}
assert set(values)==expected
for name,value in values.items():
    pattern="pk-lf-[a-f0-9]{64}" if name.endswith("PUBLIC_KEY") else "sk-lf-[a-f0-9]{64}" if name.endswith("SECRET_KEY") else "[a-f0-9]{64}"
    assert re.fullmatch(pattern,value),name
assert len(set(values.values()))==len(values)
print("Langfuse bootstrap credentials have valid formats and distinct values.")'
