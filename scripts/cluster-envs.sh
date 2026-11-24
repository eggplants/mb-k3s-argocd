#!/usr/bin/env bash
# Prints every config environment under cluster/ (server,agent,pi01,...), for mise fmt -C cluster -E.
set -euo pipefail
cd "$(dirname "$0")/../cluster"
for f in mise.*.toml; do
  f="${f#mise.}"
  printf '%s\n' "${f%.toml}"
done | paste -sd, -
