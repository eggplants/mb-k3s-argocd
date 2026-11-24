#!/usr/bin/env bash
# Prints "<name>\t<user>@<host>" for each host in ../mise.toml's [bootstrap.remote.hosts] with the given tag.
#   scripts/hosts.sh server
#   scripts/hosts.sh agent
set -euo pipefail
tag="${1:?usage: hosts.sh <tag>}"
cd "$(dirname "$0")/.."
TAG="$tag" yq -p toml -o tsv \
  '.bootstrap.remote.hosts // {} | to_entries[] | select(.value.tags[] == strenv(TAG)) | [.key, (.value.user // "") + "@" + .value.host] | map(sub("^@"; ""))' \
  mise.toml
