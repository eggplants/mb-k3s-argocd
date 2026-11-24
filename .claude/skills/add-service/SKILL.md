---
name: add-service
description: Add a new app to the k3s cluster under Argo CD, as a Helm chart in charts/ and an Application in apps/ (app-of-apps), reachable inside the tailnet at `https://<name>.<tailnet>` through the Tailscale operator. Use when deploying a new service, adding a Helm chart or an Argo CD Application, or putting an app on the tailnet.
---

# Add a service

Every service on the cluster touches the same places. Work through them in order
and do not skip one: a service missing from Dependabot is as unfinished as one
that does not deploy.

| Step | Files |
|---|---|
| 1. Chart | `charts/<name>/Chart.yaml`, `charts/<name>/values.yaml`, `charts/<name>/templates/*`, `charts/<name>/README.md` |
| 2. Argo CD Application | `apps/templates/<name>.yaml` |
| 3. Secrets (only if needed) | `mise.toml` |
| 4. Dependabot | `.github/dependabot.yml` |
| 5. Lint, commit, deploy | — |

`charts/hello/` and `apps/templates/hello.yaml` are a complete worked example.
Read them before starting.

## 0. Decide first

Settle these before writing anything. Ask the user only for what the request
and the upstream project's docs do not answer.

- **name**: the chart directory, Application name, release name, and the
  device name on the tailnet (`https://<name>.<tailnet>`). Lowercase, short.
  It must not clash with another device in the tailnet: Tailscale would give
  the new one a `-1` suffix.
- **namespace**: its own namespace, named after the app, unless it belongs with
  something already there.
- **image**: repository, a version tag, and its digest. Values pin both:
  `tag: 1.2.3@sha256:...`. Get the digest of the multi-arch index (the nodes are
  Raspberry Pi 4, arm64), e.g. `docker buildx imagetools inspect <image>:<tag>`
  or `crane digest <image>:<tag>`. Check that the index has `linux/arm64`.
- **port** the app listens on, and whether it needs root, a writable root
  filesystem, persistent storage, or a secret.
- **exposure**: an HTTP app gets a Tailscale Ingress (HTTPS, step 1). Anything
  else (DNS, SSH, a database) gets a Service annotated
  `tailscale.com/expose: "true"` and `tailscale.com/hostname: <name>`, which
  puts its ports on the tailnet as they are, without TLS. Nothing is exposed on
  the LAN: k3s runs without Traefik, and a `LoadBalancer` or `NodePort` Service
  needs a reason and the user's go-ahead.
- **storage**: k3s's `local-path` StorageClass keeps a volume on one node's SD
  card or disk. A pod with one is pinned to that node and loses its data with
  it. Say so in the chart's README when the app needs a volume.
- **node**: the hosts are in `[bootstrap.remote.hosts]` in `mise.toml`: one
  tagged `server` (runs the control plane) and any number tagged `agent`. Keep
  workloads off the server when there is an agent to go to, with a *preferred*
  affinity (never required: a cluster may have no agents).

## 1. Chart

A local chart under `charts/`, like `charts/hello/`.

- `Chart.yaml`: `apiVersion: v2`, `type: application`, `version: 0.1.0`,
  `appVersion` set to the app's version. Never bump `version` afterwards: Argo CD
  deploys the branch as it is, and `ct lint` is told not to check it.
- `values.yaml`: at least `image.repository`, `image.tag` (with digest),
  `image.pullPolicy: IfNotPresent`, and
  `tailscale.hostname: <name>` with the comment
  `# the device name on the tailnet: https://<name>.<tailnet>`.
- Name resources after the app (`metadata.name: <name>`), select pods with
  `app: <name>`, and name ports (`web`) so the Service and Ingress refer to names.
- Keep it off the server, as `charts/hello/templates/deployment.yaml` does:

  ```yaml
  affinity:
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          preference:
            matchExpressions:
              - key: node-role.kubernetes.io/control-plane
                operator: DoesNotExist
  ```

- Harden the pod the way `charts/hello/templates/deployment.yaml` does, as far
  as the app allows: `runAsNonRoot`, `seccompProfile: RuntimeDefault`,
  `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`,
  `capabilities.drop: [ALL]`, and an `emptyDir` for any path it must write to.
  A non-root container cannot listen below 1024: move the app to 8080 or the
  like. Say in a comment why when something has to be relaxed.
- Add a `readinessProbe`, and `resources` with requests and a memory limit:
  a Pi 4 has 2–8 GB.
- A ClusterIP Service, and an Ingress copied from
  `charts/hello/templates/ingress.yaml`:

  ```yaml
  # Inside the tailnet only, at https://{{ .Values.tailscale.hostname }}.<tailnet>, with a certificate from Tailscale.
  apiVersion: networking.k8s.io/v1
  kind: Ingress
  metadata:
    name: <name>
  spec:
    ingressClassName: tailscale
    defaultBackend:
      service:
        name: <name>
        port:
          name: web
    tls:
      - hosts:
          - {{ .Values.tailscale.hostname }}
  ```

  The first label of the TLS host is the device name; the tailnet's domain is
  added by Tailscale. No `rules`, no host names, no cert-manager: Tailscale
  terminates TLS, so the app serves plain HTTP behind it. An app that insists
  on knowing its public URL gets `https://<name>.<tailnet>`; take the tailnet
  from `tailnet` in `cluster/settings.toml` and ask the user to confirm it.
- Secrets never go in the repository. See step 3.
- `README.md` in English, in the shape of `charts/hello/README.md`: one
  paragraph on what it is and its URL (`https://<name>.<tailnet>`), then
  `## Install` / `## Upgrade` / `## Uninstall`. Uninstall always says: delete
  `apps/templates/<name>.yaml` and push, that the app keeps running until its
  resources are deleted too (the Application has no resources-finalizer), how to
  delete them, that deleting the Ingress removes the device from the tailnet,
  and to remove its line from `.github/dependabot.yml`.

Check it renders: `helm template <name> charts/<name>/`.

## 2. Argo CD Application

`apps/templates/<name>.yaml`, copied from `apps/templates/hello.yaml` with the
name, path, release name, namespace and the comments changed. Keep the missing
`resources-finalizer` and the `syncPolicy` without `prune`:

```yaml
# <One line on what the app is.>
# No resources-finalizer: deleting this Application must leave <App> running.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <name>
  namespace: argocd
spec:
  project: default
  source:
    repoURL: {{ .Values.repoURL }}
    targetRevision: {{ .Values.targetRevision }}
    path: charts/<name>
    helm:
      releaseName: <name>
  destination:
    server: https://kubernetes.default.svc
    namespace: <namespace>
  syncPolicy:
    # no prune: something dropped from the chart stays until it is removed by hand
    automated:
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

`repoURL` and `targetRevision` come from `cluster/settings.toml` through
`cluster/manifests/argocd-apps.yaml`; never write them out. Nothing in
`cluster/` changes: the `apps` Application picks up the new file by itself, so
`mise bootstrap remote` is not needed.

Check it renders: `helm template apps apps/`.

## 3. Secrets

Only if the app needs one. Add a `cluster:<name>-setup` task to `mise.toml`,
after the other `cluster:*` tasks, in the shape of `cluster:tailscale-oauth`: it
reads the secret from `/dev/tty` (or generates it with `openssl rand`) and
creates it on the server over SSH, so it is never printed, passed as an
argument, or stored in the repository:

```toml
[tasks."cluster:<name>-setup"]
description = "Store <App>'s <secret> (asked for here, never printed or stored in this repository)"
quiet = true
raw = true
run = '''
#!/usr/bin/env bash
set -euo pipefail
server="$(scripts/hosts.sh server | cut -f2)"
read -rsp '<App> <secret>: ' secret </dev/tty
echo
# the script and the secret both go over stdin, which keeps the secret out of the server's process list
{ printf 'secret=%q\n' "$secret"; cat <<'EOF'; } | ssh "$server" sudo bash -s
set -euo pipefail
k3s kubectl create namespace <namespace> --dry-run=client -o yaml | k3s kubectl apply -f - >/dev/null
printf '%s' "$secret" |
  k3s kubectl -n <namespace> create secret generic <name> --from-file=<key>=/dev/stdin --dry-run=client -o yaml |
  k3s kubectl apply -f - >/dev/null
echo "cluster:<name>-setup: done"
EOF
'''
```

mise renders `run` with Tera first: avoid `{{`, `{%` and `{#` in the script
(e.g. no `${#var}`; use `[[ "$var" =~ .{6} ]]` for a length check). The chart
refers to the Secret by name and does not create it. Mention the task under
`## Install` in the chart's README.

## 4. Dependabot

Add `/charts/<name>` to the `docker` entry's `directories` in
`.github/dependabot.yml`, before `/cluster/manifests`.

## 5. Lint, commit, deploy

```bash
mise run fmt
mise run lint    # rumdl, ct lint on apps/ and every chart, the inventory, mise fmt, tombi
```

Commit as one `feat: <name>` commit: the chart, the Application, any task in
`mise.toml`, and Dependabot. Use the `commit` skill if it is available.

Pushing to the branch Argo CD watches (`repo_revision` in
`cluster/settings.toml`) changes the live cluster: ask before pushing. If the
app needs a secret, run its `cluster:<name>-setup` task first, or the pods wait
for it.

Argo CD polls every 3 minutes. Then verify, and report each result rather than
assuming. `mise run cluster:kubeconfig` once makes `kubectl` work in the
repository; `curl` needs this machine to be on the tailnet:

```bash
kubectl -n argocd get application apps <name>
kubectl -n <namespace> get pods,ingress
kubectl -n tailscale get pods   # one ts-<name>-... proxy per Ingress
curl -sSI https://<name>.<tailnet>/
```

Both Applications should be `Synced` and `Healthy`, the Ingress should show
`<name>.<tailnet>` as its address, and `curl` should get the app's response.
The first request can take a few seconds while Tailscale issues the
certificate. If the Application is missing, check `apps` first: a template that
fails to render leaves `apps` `Unknown` with the error in its conditions. If the
Ingress has no address, check the operator's log
(`kubectl -n tailscale logs deploy/operator`): a missing OAuth client
(`mise run cluster:tailscale-oauth`) or tag owner is the usual cause.
