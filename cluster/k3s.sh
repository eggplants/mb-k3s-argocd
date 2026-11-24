#!/usr/bin/env bash
# The bootstrap task: runs on every `mise bootstrap`, so it must be safe to repeat.
# Installs k3s $K3S_VERSION as $K3S_ROLE on a new node, and restarts it after [bootstrap.files] changes config.yaml.
# A running node is left at its version: manifests/system-upgrade-plans.yaml upgrades it, and installing here would downgrade it.
set -euo pipefail
die() {
  echo "k3s.sh: $*" >&2
  exit 1
}

case "${K3S_ROLE:-}" in
  server) unit=k3s other=k3s-agent ;;
  agent) unit=k3s-agent other=k3s ;;
  *) die "K3S_ROLE is not set; give the host mise_env = [\"server\"] or [\"agent\"] in ../mise.toml" ;;
esac
[[ -n "${K3S_NODE_IP:-}" ]] ||
  die "node_ip is not set; give the host mise_env = [\"$K3S_ROLE\", \"<name>\"] in ../mise.toml, and node_ip in mise.<name>.toml"
# k3s would still start with an address this node does not have, and the other nodes could not reach it
ip -4 -o addr show | awk '{ sub("/.*", "", $4); print $4 }' | grep -qxF "$K3S_NODE_IP" ||
  die "this node has no IPv4 address $K3S_NODE_IP (node_ip); fix mise.<name>.toml or the node's address"
config=/etc/rancher/k3s/config.yaml
stamp=/var/lib/rancher/k3s/mise-config.stamp

# Raspberry Pi OS boots with the memory cgroup off, and k3s does not start without it.
cmdline=/boot/firmware/cmdline.txt
[[ -e "$cmdline" ]] || cmdline=/boot/cmdline.txt
missing=()
for p in cgroup_memory=1 cgroup_enable=memory; do
  grep -qw "$p" "$cmdline" || missing+=("$p")
done
if ((${#missing[@]})); then
  sudo cp "$cmdline" "$cmdline.bak"
  # cmdline.txt is a single line
  sudo sed -i "1 s/\$/ ${missing[*]}/" "$cmdline"
  die "added '${missing[*]}' to $cmdline (backup: $cmdline.bak); reboot this node and run mise bootstrap remote again"
fi

[[ ! -e "/etc/systemd/system/$other.service" ]] ||
  die "$other.service is installed on this $K3S_ROLE; run 'mise run cluster:reset $(hostname)' on your machine first"
[[ "$K3S_ROLE" == server || -s /etc/rancher/k3s/token ]] ||
  die "/etc/rancher/k3s/token is missing; run 'mise run cluster:token' on your machine first"

if [[ ! -e "/etc/systemd/system/$unit.service" ]]; then
  echo "k3s.sh: installing k3s $K3S_VERSION ($K3S_ROLE)"
  curl -sfL https://get.k3s.io | sudo env INSTALL_K3S_VERSION="$K3S_VERSION" INSTALL_K3S_EXEC="$K3S_ROLE" sh -
  sudo touch "$stamp"
elif [[ "$config" -nt "$stamp" ]]; then
  echo "k3s.sh: $config changed; restarting $unit"
  sudo systemctl restart "$unit"
  sudo touch "$stamp"
fi
