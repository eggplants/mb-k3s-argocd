#!/usr/bin/env bash
# Checks that ../mise.toml's [bootstrap.remote.hosts] and cluster/mise.<name>.toml agree:
# one server, each host's mise_env is ["<its tag>", "<its name>"], and each host is the IPv4 address in node_ip.
set -euo pipefail
cd "$(dirname "$0")/.."
errors=0
err() {
  echo "check-inventory: $*" >&2
  errors=$((errors + 1))
}
ipv4='^((25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])$'

n="$(scripts/hosts.sh server | wc -l | tr -d ' ')"
[[ "$n" == 1 ]] || err "$n hosts are tagged server; there must be exactly 1"

server_ip="$(yq -p toml -oy '.server_ip' cluster/settings.toml)"
while IFS=$'\t' read -r name host tags envs; do
  [[ "$tags" == server || "$tags" == agent ]] || err "$name: tags must be [\"server\"] or [\"agent\"], not [$tags]"
  [[ "$envs" == "$tags,$name" ]] || err "$name: mise_env must be [\"$tags\", \"$name\"], not [$envs]"
  [[ "$host" =~ $ipv4 ]] || err "$name: host must be the node's IPv4 address, not $host"
  file="cluster/mise.$name.toml"
  if [[ ! -f "$file" ]]; then
    err "$name: $file is missing; copy another node's and set node_ip = \"$host\""
    continue
  fi
  node_ip="$(yq -p toml -oy '.vars.node_ip // ""' "$file")"
  [[ "$node_ip" == "$host" ]] || err "$name: node_ip in $file ($node_ip) differs from its host ($host)"
  [[ "$tags" != server || "$node_ip" == "$server_ip" ]] ||
    err "$name: server_ip in cluster/settings.toml ($server_ip) differs from the server's node_ip ($node_ip)"
done < <(yq -p toml -o tsv '.bootstrap.remote.hosts // {} | to_entries[] | [.key, .value.host, (.value.tags // [] | join(",")), (.value.mise_env // [] | join(","))]' mise.toml)

# a node file left behind after its host was removed
names=" $(yq -p toml -oy '.bootstrap.remote.hosts // {} | keys | join(" ")' mise.toml) "
for f in cluster/mise.*.toml; do
  env="${f#cluster/mise.}"
  env="${env%.toml}"
  [[ "$env" == server || "$env" == agent || "$names" == *" $env "* ]] ||
    err "$f belongs to no host in [bootstrap.remote.hosts]; delete it or add the host"
done

((errors == 0))
