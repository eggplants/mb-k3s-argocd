# mb-k3s-argocd

[日本語](README.ja.md)

A template for turning Raspberry Pi 4s into one k3s server and n k3s agents, managed with GitOps by Argo CD.

## Requirements

- One or more Raspberry Pi 4s. Write Raspberry Pi OS Lite (64-bit) with [Raspberry Pi Imager](https://www.raspberrypi.com/software/), setting the hostname, the user and an SSH public key.
  Refefenced instruction: [SETUP.md](SETUP.md)
- The user on each Pi can run `sudo` without a password (the Raspberry Pi OS default)
- A fixed IPv4 address for each Pi. The nodes and your machine connect to each other at these addresses
  - Set them up on the router, e.g. with DHCP reservations
- A [Tailscale](https://tailscale.com/) tailnet. Services are reachable only from inside the tailnet
- [mise](https://mise.jdx.dev/) and an SSH client on your machine

## Setup

```text
git clone https://github.com/eggplants/mb-k3s-argocd
cd mb-k3s-argocd
mise install
mise generate git-pre-commit -w

# Set `server_ip`, `tailnet` and `repo_url`
$EDITOR cluster/settings.toml

# Match `[bootstrap.remote.hosts.*]` to your Pis
# `host` is the node's IPv4 address
# Exactly one server, with `tags = ["server"]` and `mise_env = ["server", "<name>"]`
# Zero or more agents, with `tags = ["agent"]` and `mise_env = ["agent", "<name>"]`
$EDITOR mise.toml

# Make `cluster/mise.<name>.toml` for each node, with `node_ip` set to the same IPv4 address as its `host`
# It becomes k3s's `node-ip`. The server's `node_ip` must equal `server_ip`
$EDITOR cluster/mise.pi01.toml

# Stops here if the inventory, `cluster/mise.<name>.toml` and `server_ip` disagree
mise run lint
git add cluster mise.toml
git commit -m "feat: setup"
git push

# Start the cluster
# The first time, `cluster/k3s.sh` adds `cgroup_memory=1 cgroup_enable=memory` to `/boot/firmware/cmdline.txt` and stops
mise bootstrap remote --all --dry-run
mise run cluster:up

# Reboot the nodes it names, then run it again
mise run cluster:up

# Give the Tailscale operator its OAuth client (see below)
mise run cluster:tailscale-oauth

# Check
mise run cluster:status
mise run cluster:kubeconfig
```

## Tailscale

Services are put on the tailnet by the [Tailscale Kubernetes Operator](https://tailscale.com/kb/1236/kubernetes-operator).

Each Ingress with `ingressClassName: tailscale` becomes one device on the tailnet, reachable at `https://<tls host>.<tailnet>`.

Do the following in the [Tailscale admin console](https://console.tailscale.com/admin/machines).

1. Turn on MagicDNS and HTTPS Certificates under [DNS](https://console.tailscale.com/admin/dns).
   Set `tailnet` in `cluster/settings.toml` to the DNS name shown there, like `tail1234.ts.net`.

2. Add the following to `tagOwners` under [Definitions](https://console.tailscale.com/admin/acls/visual/tags).

   ```json
   "tagOwners": {
     "tag:k8s-operator": [],
     "tag:k8s": ["tag:k8s-operator"],
   }
   ```

3. Create an OAuth client as the [operator's prerequisites](https://tailscale.com/kb/1236/kubernetes-operator#prerequisites) describe.
   Give it the tag `tag:k8s-operator`.
   Grant it the `write` scopes for Devices Core, Auth Keys and Services.

4. Apply the client ID and secret with `mise run cluster:tailscale-oauth`.

## Argo CD

```bash
mise run cluster:argocd-password
```

Log in as `admin` at `https://argocd.<tailnet>` and change the password. Once it is changed, `argocd-initial-admin-secret` can be deleted.

If the repository is private, add its credentials under Settings → Repositories in Argo CD.

The `argocd` CLI goes through the Tailscale proxy, so pass `--grpc-web` (`argocd login argocd.<tailnet> --grpc-web`).

## Add an app

See the [`add-service` skill](.claude/skills/add-service/SKILL.md).

## Add or rebuild an agent

```bash
# Add: add `[bootstrap.remote.hosts.pi04]` (`host` is its IPv4 address, `mise_env = ["agent", "pi04"]`) to mise.toml
# and cluster/mise.pi04.toml (`node_ip`), pass mise run lint, then
mise run cluster:token
mise bootstrap remote pi04

# Rebuild: uninstall k3s and delete the node
mise run cluster:reset pi02
mise run cluster:token
mise bootstrap remote pi02
```

## Apply changes

After changing anything under `cluster/`, run:

```bash
mise bootstrap remote --all --dry-run
mise bootstrap remote --all
```

## Upgrade k3s / Argo CD / the Tailscale operator

[system-upgrade-controller](https://docs.k3s.io/upgrades/automated) upgrades k3s to the newest patch version every week.

To move to the next minor version, change `k3s_version` in `cluster/settings.toml`.

For Argo CD and the Tailscale operator, change `version` in `cluster/manifests/argocd.yaml` and `cluster/manifests/tailscale-operator.yaml`.

After either change, run:

```bash
mise bootstrap remote --tag server
```
