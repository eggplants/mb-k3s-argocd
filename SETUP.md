# Setting up a Raspberry Pi 4

[日本語](SETUP.ja.md)

A reference for preparing each Pi, from writing the OS image until `mise run cluster:up` can take over (see [README.md](README.md)).

`mise bootstrap remote` installs k3s, adds the cgroup options to `cmdline.txt`, and brings its own mise on every run, so none of that is done here. Commands under "On the Pi" run over SSH as the user made in step 1; the rest run on your machine.

## 1. Write the image

In [Raspberry Pi Imager](https://www.raspberrypi.com/software/):

- Device: Raspberry Pi 4
- OS: Raspberry Pi OS (other) → **Raspberry Pi OS Lite (64-bit)**
- Customisation:
  - Hostname: `pi01`, `pi02`, ... It becomes the k3s node name, so every Pi needs its own
  - Username: the same on every Pi (`pi` in `mise.toml`'s inventory), with a password
  - Localisation: your time zone and keyboard layout
  - Wi-Fi: leave it off when the Pi is wired; the nodes talk over `eth0`
  - Services: enable SSH with **public-key authentication only**, and paste your public key (`~/.ssh/id_ed25519.pub`)

Booting from a USB SSD instead of the SD card is worth considering: k3s and etcd/SQLite write constantly, which wears SD cards out. Write the image to the SSD the same way.

## 2. Give each Pi a fixed IPv4 address

Plug the Pis into the LAN and boot them. Find each one's address in the router's DHCP lease list, then **reserve** it (DHCP reservation / static lease by MAC address). This is the easiest way, and the address stays the same after a reinstall.

If the router cannot reserve addresses, set one on the Pi with NetworkManager instead. Pick an address outside the router's DHCP range. On the Pi:

```bash
# the connection's name differs between images, e.g. "Wired connection 1" or "netplan-eth0"
nmcli -t -f NAME,DEVICE connection show
con="Wired connection 1"
sudo nmcli connection modify "$con" \
  ipv4.method manual \
  ipv4.addresses 192.168.1.10/24 \
  ipv4.gateway 192.168.1.1 \
  ipv4.dns 192.168.1.1
# the SSH session drops here; reconnect at the new address
sudo nmcli connection up "$con"
```

Write the addresses down: they go into `host` in `mise.toml` and `node_ip` in `cluster/mise.<name>.toml`.

## 3. Connect over SSH

On your machine, for each Pi:

```bash
ssh pi@192.168.1.10 true
```

Accept the host key. If the Pi was reinstalled at the same address, remove the old key first with `ssh-keygen -R 192.168.1.10`.

Optionally, add the Pis to `~/.ssh/config` so `ssh pi01` works too. The inventory keeps using IPv4 addresses either way:

```sshconfig
Host pi01
  HostName 192.168.1.10
  User pi
```

## 4. Update and check sudo

On the Pi:

```bash
sudo apt update
sudo apt full-upgrade -y

# mise bootstrap needs sudo without a password; Raspberry Pi OS sets this up for the user Imager made
sudo -n true && echo "sudo: ok"

# optional: the Pi 4's bootloader, which also brings USB boot fixes
sudo rpi-eeprom-update -a
```

## 5. Turn off swap

Kubernetes is meant to run without swap, and swapping to an SD card wears it out. On the Pi:

```bash
swapon --show
```

If anything is listed, turn it off for good. Raspberry Pi OS 12 (bookworm) uses `dphys-swapfile`:

```bash
sudo dphys-swapfile swapoff
sudo systemctl disable --now dphys-swapfile
sudo rm -f /var/swap
```

Newer images manage swap differently (zram, or a swap file from the `rpi-swap` package). Check `swapon --show` again after the reboot in step 8, and if it still lists anything, turn it off the way that image's documentation describes.

## 6. Time

k3s's certificates and the upgrade window in `cluster/manifests/system-upgrade-plans.yaml` both depend on the clock. On the Pi:

```bash
# if Imager did not set it
sudo timedatectl set-timezone Asia/Tokyo

# optional: a nearby NTP server, e.g. NICT in Japan
sudo mkdir -p /etc/systemd/timesyncd.conf.d
printf '[Time]\nNTP=ntp.nict.jp\n' | sudo tee /etc/systemd/timesyncd.conf.d/ntp.conf
sudo systemctl restart systemd-timesyncd

timedatectl   # "System clock synchronized: yes"
```

## 7. cgroup options (optional)

`cluster/k3s.sh` adds `cgroup_memory=1 cgroup_enable=memory` to `/boot/firmware/cmdline.txt` on the first `mise run cluster:up`, then stops and asks for a reboot. Adding them now saves that round. On the Pi:

```bash
grep -qw cgroup_enable=memory /boot/firmware/cmdline.txt ||
  sudo sed -i '1 s/$/ cgroup_memory=1 cgroup_enable=memory/' /boot/firmware/cmdline.txt
```

`cmdline.txt` must stay a single line.

## 8. Reboot and check

On the Pi:

```bash
sudo reboot
```

Then from your machine:

```bash
ssh pi@192.168.1.10 'hostname; ip -4 -br addr show eth0; swapon --show; cat /proc/cmdline | tr " " "\n" | grep cgroup'
```

Each Pi should show its own hostname, its fixed address on `eth0`, no swap, and (if step 7 was done) the two cgroup options.

## 9. Hand over to the repository

1. Add each Pi to `[bootstrap.remote.hosts]` in `mise.toml` (`host` = its IPv4 address, `mise_env = ["server" or "agent", "<name>"]`).
2. Create `cluster/mise.<name>.toml` with `node_ip` set to the same address.
3. Run the rest of [README.md](README.md#setup):

   ```bash
   mise run lint
   mise bootstrap remote --all --dry-run
   mise run cluster:up
   ```

## Tailscale on the Pis (optional)

The cluster does not need Tailscale on the nodes: services join the tailnet through the Tailscale operator, and the nodes talk to each other over the LAN. Install it on a Pi only to reach that Pi itself from outside the LAN, e.g. over SSH:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --ssh
```

Keep `host` in `mise.toml` and `node_ip` on the LAN addresses. Moving k3s onto `tailscale0` (`flannel-iface`, Tailscale IPs as `node-ip`) is a different design, which this repository does not support.
