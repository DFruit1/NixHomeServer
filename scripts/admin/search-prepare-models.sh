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
# 4B Q8_0 reranker from the same converter as the retired 0.6B, whose GGUFs
# carry the yes/no classifier head llama.cpp's --reranking needs. Scores are
# computed per query, so nothing is re-indexed. Retired files stay on the data
# pool; to roll back, restore one entry and the path in
# modules/search/semantic.nix:
#   Qwen3-Reranker-0.6B.Q8_0.gguf, Voodisss/Qwen3-Reranker-0.6B-GGUF-llama_cpp
#   revision eb9ad47d4e53c2a6abd6158b505f1539d1c5650c, 639153344 bytes, sha256
#   6ddab39a36c6c87fdb76f0e5f05657012d5dbc97034c0983c157f17ef9f34d55
#   Qwen3-Reranker-0.6B.F16.gguf, 1197634304 bytes, sha256
#   fa726a72c1afafe42ae6ca6059c9a78a43f18db7389a8fa04f88bb7f37d0a8aa
prepare Qwen3-Reranker-4B.Q8_0.gguf 1b452c803342e73ac3644551b727dfd51a09fd5b \
  Voodisss/Qwen3-Reranker-4B-GGUF-llama_cpp 102ac400d68f02877c2fdfecf0732872652298448352b6faf28ec7f8dca8c913 4279678912
