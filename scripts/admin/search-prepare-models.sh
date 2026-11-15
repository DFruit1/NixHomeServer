#!/usr/bin/env bash
# Pinned Search inference weights. Safe to rerun; never replaces a verified file.
set -euo pipefail
models_dir=${SEARCH_MODELS_DIR:-/mnt/data/search/models}
mkdir -p "$models_dir"
exec 9>"$models_dir/.prepare.lock"
flock 9
prepare() {
  local file=$1 revision=$2 repository=$3 hash=$4 size=$5
  local dest="$models_dir/$file" partial="$models_dir/$file.part"
  if [[ -f "$dest" ]] && printf '%s  %s\n' "$hash" "$dest" | sha256sum --check --status; then
    echo "Verified $file"
    return
  fi
  if [[ -f "$partial" && $(stat -c %s "$partial") -ge "$size" ]]; then
    if [[ $(stat -c %s "$partial") == "$size" ]] && printf '%s  %s\n' "$hash" "$partial" | sha256sum --check --status; then
      chmod 0640 "$partial"
      mv -- "$partial" "$dest"
      return
    fi
    rm -f -- "$partial"
  fi
  curl --fail --location --retry 5 --retry-all-errors --connect-timeout 20 \
    --continue-at - --output "$partial" \
    "https://huggingface.co/$repository/resolve/$revision/$file?download=true"
  [[ $(stat -c %s "$partial") == "$size" ]]
  printf '%s  %s\n' "$hash" "$partial" | sha256sum --check --status
  chmod 0640 "$partial"
  mv -- "$partial" "$dest"
  echo "Installed and verified $file"
}
# Q8_0 rather than the f16 file: the same 2,560-dim vectors at half the size.
# The retired f16 weights are left on the data pool; restore the old entry and
# the previous VERSION in semantic.rs to roll back (the backfill then re-embeds
# the library again).
prepare Qwen3-Embedding-4B-Q8_0.gguf f4602530db1d980e16da9d7d3a70294cf5c190be \
  Qwen/Qwen3-Embedding-4B-GGUF b60ae5ce2dd6a0b77f82cadf21def1f310a3e10cde380ad0081b07a9d416949d 4279660224
prepare Qwen3-Reranker-0.6B.F16.gguf eb9ad47d4e53c2a6abd6158b505f1539d1c5650c \
  Voodisss/Qwen3-Reranker-0.6B-GGUF-llama_cpp fa726a72c1afafe42ae6ca6059c9a78a43f18db7389a8fa04f88bb7f37d0a8aa 1197634304
