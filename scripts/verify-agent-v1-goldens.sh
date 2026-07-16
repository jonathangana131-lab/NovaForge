#!/bin/zsh

set -euo pipefail

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
fixture_dir="$repo_root/AgentPadTests/Fixtures/AgentHarnessV1"
ledger="$fixture_dir/SHA256SUMS"

if [[ ! -f "$ledger" ]]; then
  print -u2 "Missing V1 fixture checksum ledger: $ledger"
  exit 1
fi

cd "$fixture_dir"
LC_ALL=C shasum -a 256 -c SHA256SUMS

store="$fixture_dir/NovaForgeV1.store"
if [[ ! -f "$store" ]]; then
  print -u2 "Missing captured NovaForgeSchemaV1 store: $store"
  exit 1
fi
if [[ -e "$store-wal" || -e "$store-shm" ]]; then
  print -u2 "Captured store must be a self-contained SQLite backup without live WAL sidecars."
  exit 1
fi
quick_check="$(sqlite3 "file:$store?immutable=1" 'PRAGMA quick_check;')"
if [[ "$quick_check" != "ok" ]]; then
  print -u2 "Captured V1 store failed SQLite quick_check: $quick_check"
  exit 1
fi

print "AgentHarnessV1 fixture hashes and captured V1 store verified."
