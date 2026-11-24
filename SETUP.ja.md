# Raspberry Pi 4 のセットアップ

[English](SETUP.md)

OS イメージの書き込みから、`mise run cluster:up` を実行できる状態にするまでの各 Pi の準備手順の参考 ([README.ja.md](README.ja.md) も参照)。

k3s のインストール、`cmdline.txt` への cgroup オプションの追記、mise の持ち込みは `mise bootstrap remote` が毎回行うので、ここでは扱わない。「Pi 上で」とあるコマンドは、手順 1 で作ったユーザーで SSH 接続して実行する。それ以外は手元のマシンで実行する。

## 1. イメージを書き込む

[Raspberry Pi Imager](https://www.raspberrypi.com/software/) で以下を選ぶ。

- デバイス: Raspberry Pi 4
- OS: Raspberry Pi OS (other) → **Raspberry Pi OS Lite (64-bit)**
- カスタマイズ:
  - ホスト名: `pi01`、`pi02`、... k3s のノード名になるので、Pi ごとに変える
  - ユーザー名: すべての Pi で同じにする (`mise.toml` のインベントリでは `pi`)。パスワードも設定する
  - ローカライゼーション: タイムゾーンとキーボードレイアウト
  - Wi-Fi: 有線で使うなら設定しない。ノード同士は `eth0` で通信する
  - サービス: SSH を **公開鍵認証のみ** で有効にし、公開鍵 (`~/.ssh/id_ed25519.pub`) を貼る

SD カードの代わりに USB SSD から起動することも検討するとよい。k3s とそのデータストア (etcd / SQLite) は常に書き込みを行うので、SD カードが消耗する。SSD にも同じ手順で書き込める。

## 2. 各 Pi の IPv4 アドレスを固定する

Pi を LAN につないで起動する。ルーターの DHCP リース一覧で各 Pi のアドレスを調べ、MAC アドレスで **予約** する (DHCP 予約、静的リース)。これが一番簡単で、OS を入れ直してもアドレスが変わらない。

ルーターで予約できない場合は、Pi 側で NetworkManager を使って設定する。アドレスはルーターの DHCP の範囲外から選ぶ。Pi 上で:

```bash
# 接続名はイメージによって異なる ("Wired connection 1"、"netplan-eth0" など)
nmcli -t -f NAME,DEVICE connection show
con="Wired connection 1"
sudo nmcli connection modify "$con" \
  ipv4.method manual \
  ipv4.addresses 192.168.1.10/24 \
  ipv4.gateway 192.168.1.1 \
  ipv4.dns 192.168.1.1
# ここで SSH 接続が切れるので、新しいアドレスにつなぎ直す
sudo nmcli connection up "$con"
```

アドレスは控えておく。`mise.toml` の `host` と `cluster/mise.<名前>.toml` の `node_ip` に書く。

## 3. SSH で接続する

手元のマシンで、Pi ごとに:

```bash
ssh pi@192.168.1.10 true
```

ホスト鍵を受け入れる。同じアドレスで OS を入れ直した場合は、先に `ssh-keygen -R 192.168.1.10` で古い鍵を消す。

`~/.ssh/config` に Pi を書いておくと `ssh pi01` でも接続できる (任意)。インベントリはどちらにしても IPv4 アドレスのままにする。

```sshconfig
Host pi01
  HostName 192.168.1.10
  User pi
```

## 4. 更新と sudo の確認

Pi 上で:

```bash
sudo apt update
sudo apt full-upgrade -y

# mise bootstrap はパスワードなしの sudo を使う。Imager で作ったユーザーは Raspberry Pi OS が設定済み
sudo -n true && echo "sudo: ok"

# 任意: Pi 4 のブートローダーを更新する。USB 起動の修正も含まれる
sudo rpi-eeprom-update -a
```

## 5. swap を止める

Kubernetes は swap なしで動かす前提になっている。SD カードへの swap はカードの消耗も早める。Pi 上で:

```bash
swapon --show
```

何か表示されたら、恒久的に止める。Raspberry Pi OS 12 (bookworm) は `dphys-swapfile` を使う:

```bash
sudo dphys-swapfile swapoff
sudo systemctl disable --now dphys-swapfile
sudo rm -f /var/swap
```

新しいイメージは swap の仕組みが異なる (zram や、`rpi-swap` パッケージによる swap ファイル)。手順 8 の再起動後にもう一度 `swapon --show` で確かめ、まだ何か表示されたら、そのイメージのドキュメントに従って止める。

## 6. 時刻

k3s の証明書と、`cluster/manifests/system-upgrade-plans.yaml` のアップグレード時間帯は、どちらも時刻に依存する。Pi 上で:

```bash
# Imager で設定していなければ
sudo timedatectl set-timezone Asia/Tokyo

# 任意: 近くの NTP サーバーを使う (日本なら NICT など)
sudo mkdir -p /etc/systemd/timesyncd.conf.d
printf '[Time]\nNTP=ntp.nict.jp\n' | sudo tee /etc/systemd/timesyncd.conf.d/ntp.conf
sudo systemctl restart systemd-timesyncd

timedatectl   # "System clock synchronized: yes" になる
```

## 7. cgroup オプション (任意)

初回の `mise run cluster:up` で、`cluster/k3s.sh` が `/boot/firmware/cmdline.txt` に `cgroup_memory=1 cgroup_enable=memory` を足し、再起動を求めて止まる。ここで先に足しておくと、その 1 往復を省ける。Pi 上で:

```bash
grep -qw cgroup_enable=memory /boot/firmware/cmdline.txt ||
  sudo sed -i '1 s/$/ cgroup_memory=1 cgroup_enable=memory/' /boot/firmware/cmdline.txt
```

`cmdline.txt` は 1 行のままにしておく必要がある。

## 8. 再起動して確認する

Pi 上で:

```bash
sudo reboot
```

起動したら手元のマシンで:

```bash
ssh pi@192.168.1.10 'hostname; ip -4 -br addr show eth0; swapon --show; cat /proc/cmdline | tr " " "\n" | grep cgroup'
```

各 Pi で、自分のホスト名、`eth0` の固定アドレスが表示され、swap が何も表示されなければよい。手順 7 を行った場合は 2 つの cgroup オプションも表示される。

## 9. リポジトリ側の作業に移る

1. `mise.toml` の `[bootstrap.remote.hosts]` に各 Pi を足す (`host` はその IPv4 アドレス、`mise_env = ["server" か "agent", "<名前>"]`)。
2. `cluster/mise.<名前>.toml` を作り、`node_ip` に同じアドレスを書く。
3. 残りは [README.ja.md](README.ja.md#セットアップ) に従う:

   ```bash
   mise run lint
   mise bootstrap remote --all --dry-run
   mise run cluster:up
   ```

## Pi への Tailscale の導入 (任意)

クラスタはノードに Tailscale を必要としない。サービスは Tailscale operator を通して tailnet に参加し、ノード同士は LAN で通信する。LAN の外から Pi そのものに SSH などで接続したい場合にだけ入れる:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --ssh
```

その場合も、`mise.toml` の `host` と `node_ip` は LAN のアドレスのままにする。k3s を `tailscale0` 上で動かす構成 (`flannel-iface` の指定や、Tailscale の IP を `node-ip` にすること) は別の設計で、このリポジトリでは扱わない。
