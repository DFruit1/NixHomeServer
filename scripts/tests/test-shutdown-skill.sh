#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"

# Regression guard: the guarded shutdown skill is an active project skill.
# It was archived once during the 2026-10-28 consolidation and must not
# disappear again. This test fails if the skill files, their git tracking,
# or their documentation references are removed.
skill_dir=".agents/skills/nixhomeserver-shutdown-guard"
skill_file="$skill_dir/SKILL.md"
openai_file="$skill_dir/agents/openai.yaml"

test -f "$skill_file" || { echo "❌ Missing $skill_file" >&2; exit 1; }
test -f "$openai_file" || { echo "❌ Missing $openai_file" >&2; exit 1; }

# The skill must be tracked in git, not just present in the working tree.
git ls-files --error-unmatch "$skill_file" >/dev/null 2>&1 || {
  echo "❌ $skill_file is not tracked in git" >&2
  exit 1
}
git ls-files --error-unmatch "$openai_file" >/dev/null 2>&1 || {
  echo "❌ $openai_file is not tracked in git" >&2
  exit 1
}

# Frontmatter must declare the expected skill name.
require_fixed "$skill_file" "name: nixhomeserver-shutdown-guard" \
  "Shutdown skill frontmatter must declare its name."

# Active documentation must reference the skill as an entrypoint.
require_fixed "AGENTS.md" ".agents/skills/nixhomeserver-shutdown-guard/SKILL.md" \
  "AGENTS.md must route to the shutdown skill."
require_fixed "documentation/agent-skills.md" "nixhomeserver-shutdown-guard/SKILL.md" \
  "agent-skills.md must list the shutdown skill."

# The skill must not have been re-archived.
if [[ -e "documentation/archive/skills/retired/nixhomeserver-shutdown-guard/SKILL.md" || \
      -e "documentation/archive/skills/retired/nixhomeserver-shutdown-guard/REFERENCE.md" ]]; then
  echo "❌ Shutdown skill is archived again; restore it to .agents/skills." >&2
  exit 1
fi

echo "✅ Guarded shutdown skill is present, tracked, and documented."