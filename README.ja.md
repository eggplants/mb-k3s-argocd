# mb-k3s-argocd

[English](README.md)

Raspberry Pi 4 を 1 台の k3s server と n 台の k3s agent にし、Argo CD で GitOps する構成のテンプレート。

## 必要なもの

- Raspberry Pi 4 を 1 台以上。Raspberry Pi OS Lite (64-bit) を [Raspberry Pi Imager](https://www.raspberrypi.com/software/) で書き込み、ホスト名、ユーザー、SSH 公開鍵を設定しておく。
  参考手順: [SETUP.ja.md](SETUP.ja.md)
- 各 Pi のユーザーがパスワードなしで `sudo` できること (Raspberry Pi OS の既定)
- 各 Pi の固定 IPv4 アドレス。ノード同士と手元のマシンはこのアドレスで接続する
  - 別途ルーター側で DHCP の予約などを行う
- [Tailscale](https://tailscale.com/) の tailnet。サービスには tailnet 内からだけ接続する
- 手元のマシンに [mise](https://mise.jdx.dev/) と SSH クライアント

## セットアップ

```bash
git clone https://github.com/eggplants/mb-k3s-argocd
cd mb-k3s-argocd
mise install
mise generate git-pre-commit -w

# `server_ip`、`tailnet`、`repo_url` を設定
$EDITOR cluster/settings.toml

# `[bootstrap.remote.hosts.*]` を実際の Pi に合わせる
# `host` はそのノードの IPv4 アドレス
# server は `tags = ["server"]` と `mise_env = ["server", "<名前>"]` の 1 台だけ
# agent は `tags = ["agent"]` と `mise_env = ["agent", "<名前>"]` で 0 台以上
$EDITOR mise.toml

# ノードごとに `cluster/mise.<名前>.toml` を作り、`node_ip` に `host` と同じ IPv4 アドレスを書く
# k3s の `node-ip` になる。server の `node_ip` は `server_ip` と同じにする
$EDITOR cluster/mise.pi01.toml

# inventory、`cluster/mise.<名前>.toml`、`server_ip` が食い違っていればここで止まる
mise run lint
git add cluster mise.toml
git commit -m "feat: setup"
git push

# クラスタを起動
# 初回は `cluster/k3s.sh` が `/boot/firmware/cmdline.txt` に `cgroup_memory=1 cgroup_enable=memory` を足して止まる
mise bootstrap remote --all --dry-run
mise run cluster:up

# 表示されたノードを再起動してから再実行
mise run cluster:up

# Tailscale operator に OAuth クライアントを渡す (後述)
mise run cluster:tailscale-oauth

# 確認
mise run cluster:status
mise run cluster:kubeconfig
```

## Tailscale

サービスは [Tailscale Kubernetes Operator](https://tailscale.com/kb/1236/kubernetes-operator) で tailnet に公開する。

`ingressClassName: tailscale` の Ingress ごとに tailnet にデバイスが 1 台でき、`https://<tls の host>.<tailnet>` で接続できる。

[Tailscale の管理画面](https://console.tailscale.com/admin/machines)で以下を行う。

1. [DNS](https://console.tailscale.com/admin/dns) で MagicDNS と HTTPS Certificates を有効にする。
   `cluster/settings.toml` の `tailnet` には、ここに表示される `tail1234.ts.net` のような DNS 名を書く。

2. [Definitions](https://console.tailscale.com/admin/acls/visual/tags) の `tagOwners` に以下を足す。

   ```json
   "tagOwners": {
     "tag:k8s-operator": [],
     "tag:k8s": ["tag:k8s-operator"],
   }
   ```

3. [operator の前提条件](https://tailscale.com/kb/1236/kubernetes-operator#prerequisites) に従って OAuth クライアントを作る。
   タグは `tag:k8s-operator` を設定する。
   スコープは Devices Core / Auth Keys / Services の `write` を付与する。

4. `mise run cluster:tailscale-oauth` でクライアント ID とシークレットを反映する。

## Argo CD

```bash
mise run cluster:argocd-password
```

`https://argocd.<tailnet>` に `admin` でログインし、パスワードを変える。変えたら `argocd-initial-admin-secret` は消してよい。

リポジトリが private の場合は、Argo CD の Settings → Repositories で認証情報を登録する。

`argocd` CLI は Tailscale のプロキシ越しに使うので、`--grpc-web` を付ける (`argocd login argocd.<tailnet> --grpc-web`)。

## アプリを足す

[`add-service` スキル](.claude/skills/add-service/SKILL.md) を参照。

## agent ノードを足す・作り直す

```bash
# 足す: mise.toml に `[bootstrap.remote.hosts.pi04]` (`host` は IPv4、`mise_env = ["agent", "pi04"]`) と
# cluster/mise.pi04.toml (`node_ip`) を足し、mise run lint を通してから
mise run cluster:token
mise bootstrap remote pi04

# 作り直す: k3s を消してノードを削除する
mise run cluster:reset pi02
mise run cluster:token
mise bootstrap remote pi02
```

## 変更適用

`cluster/` 以下を変えた場合、以下を実行する。

```bash
mise bootstrap remote --all --dry-run
mise bootstrap remote --all
```

## k3s / Argo CD / Tailscale operator を更新する

k3s については [system-upgrade-controller](https://docs.k3s.io/ja/upgrades/automated) が毎週パッチバージョンを自動更新する。

次のマイナーバージョンに更新する場合、 `cluster/settings.toml` の `k3s_version` を更新する。

Argo CD と Tailscale operator は `cluster/manifests/argocd.yaml`、`cluster/manifests/tailscale-operator.yaml` の `version` を更新する。

それぞれ更新後以下を実行する。

```bash
mise bootstrap remote --tag server
```
