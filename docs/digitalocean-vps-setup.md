# DigitalOcean VPS Setup

This is the repeatable setup for a fresh Ubuntu VPS that can run the exported
`multi-server-test` Linux server through GitHub Actions.

Use placeholders for private values:

```text
<VPS_IP>          public IPv4 or DNS name
<YOUR_IP>/32     your current public IPv4 CIDR for SSH
<LOCAL_KEY>      personal SSH key path on your PC
<CI_KEY>         GitHub Actions deploy SSH key path on your PC
```

Do not commit private keys, real secrets, passphrases, or temporary passwords.

## 1. Create The Droplet

Recommended first dev-test shape:

- Region: nearest low-latency region.
- Image: Ubuntu 24.04 LTS x64.
- Plan: smallest Basic plan you want to stress test.
- Authentication: SSH key.
- Monitoring: enabled.
- Backups: optional; off is fine for a disposable dev-test Droplet.

Add a DigitalOcean Cloud Firewall:

```text
Inbound:
  TCP 22          from <YOUR_IP>/32 for manual-only SSH
  TCP 22          from all IPv4/IPv6 if GitHub Actions deploys over SSH
  TCP 80          from all IPv4/IPv6 for Caddy HTTP->HTTPS and ACME
  TCP 443         from all IPv4/IPv6 for public WSS gameplay

Outbound:
  allow all
```

`19080` is the master server port. `19081+` is the world-server range. In the
production reverse-proxy setup, those ports should be bound to `127.0.0.1` and
should not be open publicly. Caddy is the public WSS edge on `443`.

GitHub-hosted Actions runners do not have one stable source IP. For the simple
SSH deploy workflow in this repo, port `22` must be reachable from GitHub
Actions. If you do not want SSH open broadly, use a self-hosted runner, VPN,
or a provider-specific deployment channel later.

Production VirtuCade should not leave SSH open to all as the long-term default.
For production, prefer one of these:

- A self-hosted GitHub runner on the VPS or a private admin VPS. The runner
  connects outbound to GitHub, so SSH can stay restricted to your admin IP or a
  VPN.
- A deploy workflow that temporarily adds the current GitHub runner IP to the
  DigitalOcean firewall, deploys, then removes it.
- A private network/VPN path such as WireGuard or Tailscale.

Opening SSH to all is acceptable for the first VPS dogfood test because SSH
still requires keys and the CI user is restricted, but it is not the desired
production security posture.

## 2. Create A Personal SSH Key

On Windows PowerShell:

```powershell
ssh-keygen -t ed25519 -C "digitalocean-virtucade" -f "$HOME\.ssh\digitalocean-virtucade"
```

Use a passphrase and save it in a password manager.

Copy the public key:

```powershell
Get-Content "$HOME\.ssh\digitalocean-virtucade.pub" | Set-Clipboard
```

Paste that public key into DigitalOcean when creating the Droplet.

## 3. First SSH Login

```powershell
ssh -i "$HOME\.ssh\digitalocean-virtucade" root@<VPS_IP>
```

If prompted to trust the host fingerprint, type `yes`.

Update the server:

```bash
apt update
apt upgrade -y
apt autoremove -y
reboot
```

Reconnect after reboot and confirm the kernel updated:

```powershell
ssh -i "$HOME\.ssh\digitalocean-virtucade" root@<VPS_IP>
```

```bash
uname -r
```

## 4. Create The Human Deploy User

While logged in as `root`:

```bash
adduser deploy
usermod -aG sudo deploy
mkdir -p /home/deploy/.ssh
cp /root/.ssh/authorized_keys /home/deploy/.ssh/authorized_keys
chown -R deploy:deploy /home/deploy/.ssh
chmod 700 /home/deploy/.ssh
chmod 600 /home/deploy/.ssh/authorized_keys
```

Set a unique `deploy` password and save it. This password is for `sudo`; SSH
still uses your key.

Test from a new PowerShell window:

```powershell
ssh -i "$HOME\.ssh\digitalocean-virtucade" deploy@<VPS_IP>
```

Then test sudo:

```bash
sudo whoami
```

Expected:

```text
root
```

## 5. Install Required Packages

As `deploy`:

```bash
sudo apt install -y unzip curl git
```

Install Caddy from the official package repository:

```bash
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update
sudo apt install -y caddy
sudo systemctl enable --now caddy
```

## 6. Create App Folders

```bash
sudo mkdir -p /opt/virtucade/server /opt/virtucade/data /opt/virtucade/logs /opt/virtucade/world_packs
sudo chown -R deploy:deploy /opt/virtucade
```

Layout:

```text
/opt/virtucade/server/   exported Linux server binary
/opt/virtucade/data/     SQLite DB and persistent app data
/opt/virtucade/logs/     service logs
/opt/virtucade/world_packs/ optional local mirror for server-side pack metadata
```

## 7. Create The Master Server Service

Create the systemd service:

```bash
sudo nano /etc/systemd/system/virtucade.service
```

Paste:

```ini
[Unit]
Description=VirtuCade Godot Server
After=network.target

[Service]
Type=simple
User=deploy
WorkingDirectory=/opt/virtucade/server
Environment=MULTI_SERVER_CLIENT_HOST=<VPS_IP_OR_DOMAIN>
Environment=MULTI_SERVER_CLIENT_SCHEME=ws
Environment=MULTI_SERVER_WORLD_PACK_DIR=/opt/virtucade/world_packs
Environment=MULTI_SERVER_WORLD_PACK_BASE_URL=https://shilo.github.io/multi-server-test/world_packs
EnvironmentFile=-/opt/virtucade/virtucade.env
ExecStart=/opt/virtucade/server/multi-server-test.x86_64 --headless
Restart=on-failure
RestartSec=3
StandardOutput=append:/opt/virtucade/logs/server.log
StandardError=append:/opt/virtucade/logs/server.log

[Install]
WantedBy=multi-user.target
```

Enable it:

```bash
sudo systemctl daemon-reload
sudo systemctl enable virtucade
```

Do not start it until GitHub Actions uploads
`/opt/virtucade/server/multi-server-test.x86_64`.

`MULTI_SERVER_CLIENT_HOST` must be the public host clients should connect to.
Use a domain later if one exists. `MULTI_SERVER_CLIENT_SCHEME=ws` is enough for
native-client testing. A GitHub Pages Web client usually needs `wss`, which
requires TLS/certificate setup or a reverse proxy.

GitHub Actions always writes `/opt/virtucade/virtucade.env` so stale runtime
settings cannot survive between deploys. When `VIRTUCADE_GAME_HOST` is set, the
file includes:

```text
MULTI_SERVER_BIND_HOST=127.0.0.1
MULTI_SERVER_PUBLIC_MASTER_URL=wss://<GAME_HOST>/
MULTI_SERVER_PUBLIC_WORLD_URL_TEMPLATE=wss://<GAME_HOST>/{world_key}
MULTI_SERVER_CLIENT_HOST=<GAME_HOST>
MULTI_SERVER_CLIENT_SCHEME=wss
MULTI_SERVER_WORLD_PACK_DIR=/opt/virtucade/world_packs
MULTI_SERVER_WORLD_PACK_BASE_URL=https://shilo.github.io/multi-server-test/world_packs
```

That makes the exported Godot server listen privately while advertising public
`wss://` URLs through Caddy. If `VIRTUCADE_GAME_HOST` is not set, the env file
only contains the pack directory/base URL values and the server falls back to
the normal local/default URL behavior.

The master reads local PCK metadata from `MULTI_SERVER_WORLD_PACK_DIR`, while
clients download the actual PCK bytes from `MULTI_SERVER_WORLD_PACK_BASE_URL`.
Keep `/opt/virtucade/world_packs` mirrored with the PCK files published to
GitHub Pages if you want server-provided PackRat metadata to stay precise.

## 8. Create The Restricted GitHub Deploy User

As `deploy`:

```bash
sudo adduser --disabled-password --gecos "" github-deploy
sudo groupadd virtucade
sudo usermod -aG virtucade deploy
sudo usermod -aG virtucade github-deploy
sudo chown -R deploy:virtucade /opt/virtucade
sudo find /opt/virtucade -type d -exec chmod 2775 {} \;
sudo find /opt/virtucade -type f -exec chmod 664 {} \;
```

Allow only service control for the CI user:

```bash
sudo visudo -f /etc/sudoers.d/virtucade-github-deploy
```

Paste:

```text
github-deploy ALL=(root) NOPASSWD: /usr/bin/systemctl start virtucade, /usr/bin/systemctl stop virtucade, /usr/bin/systemctl restart virtucade, /usr/bin/systemctl status virtucade, /usr/bin/systemctl is-active virtucade, /usr/bin/systemctl reload caddy, /usr/bin/systemctl restart caddy, /usr/bin/systemctl status caddy, /usr/bin/systemctl is-active caddy, /usr/bin/caddy validate --config /tmp/virtucade-Caddyfile, /usr/bin/install -m 644 /tmp/virtucade-Caddyfile /etc/caddy/Caddyfile
```

## 9. Create The GitHub Actions SSH Key

On Windows PowerShell:

```powershell
ssh-keygen -t ed25519 -C "virtucade-deploy-github-actions" -f "$HOME\.ssh\virtucade-deploy-github-actions"
```

Use no passphrase for this CI key. The private key will be protected by GitHub
Actions secrets.

Copy the public key:

```powershell
Get-Content "$HOME\.ssh\virtucade-deploy-github-actions.pub" | Set-Clipboard
```

On the VPS as `deploy`:

```bash
sudo mkdir -p /home/github-deploy/.ssh
sudo nano /home/github-deploy/.ssh/authorized_keys
```

Paste the public key, save, then run:

```bash
sudo chown -R github-deploy:github-deploy /home/github-deploy/.ssh
sudo chmod 700 /home/github-deploy/.ssh
sudo chmod 600 /home/github-deploy/.ssh/authorized_keys
```

## 10. Test The Restricted CI User

From Windows PowerShell:

```powershell
ssh -i "$HOME\.ssh\virtucade-deploy-github-actions" github-deploy@<VPS_IP>
```

On the VPS:

```bash
whoami
sudo -n systemctl status virtucade
touch /opt/virtucade/server/permission-test.txt
touch /root/should-fail.txt
sudo -n apt update
rm /opt/virtucade/server/permission-test.txt
exit
```

Expected:

```text
whoami                                  -> github-deploy
sudo -n systemctl status virtucade      -> allowed
touch /opt/virtucade/server/...         -> allowed
touch /root/...                         -> denied
sudo -n apt update                      -> denied
```

## 11. Add GitHub Actions Secrets

In the GitHub repository:

```text
Settings -> Secrets and variables -> Actions -> New repository secret
```

Add:

```text
VIRTUCADE_HOST=<VPS_IP or DNS host>
VIRTUCADE_USER=github-deploy
VIRTUCADE_SSH_KEY=<contents of CI private key>
VIRTUCADE_KNOWN_HOSTS=<pinned VPS SSH host key line>
VIRTUCADE_GAME_HOST=<public gameplay DNS name>
VIRTUCADE_ACME_EMAIL=<optional ACME contact email>
```

Use repository variables for `VIRTUCADE_GAME_HOST` and `VIRTUCADE_ACME_EMAIL`
if they are not private. Use secrets if you want to hide them.

Copy the CI private key on Windows:

```powershell
Get-Content "$HOME\.ssh\virtucade-deploy-github-actions" -Raw | Set-Clipboard
```

Only the private key without `.pub` goes into `VIRTUCADE_SSH_KEY`. Never paste
your personal DigitalOcean private key into GitHub.

Create `VIRTUCADE_KNOWN_HOSTS` from your PC after you have successfully SSH'd
into the VPS at least once:

```powershell
ssh-keygen -F <VPS_IP>
ssh-keygen -F <VPS_IP> | Select-String -NotMatch "^#" | ForEach-Object { $_.Line } | Set-Clipboard
```

Paste the copied non-comment host-key lines into the secret. They usually look
like:

```text
<VPS_IP> ssh-ed25519 <public-host-key>
<VPS_IP> ssh-rsa <public-host-key>
<VPS_IP> ecdsa-sha2-nistp256 <public-host-key>
```

These are public server identity keys, not private keys. This avoids trusting a
fresh `ssh-keyscan` result during every deploy. If `ssh-keyscan` works on your
machine, it is also acceptable to use it once manually, but do not run
`ssh-keyscan` inside the deploy workflow.

## 12. Deploy From GitHub Actions

Run:

```text
GitHub -> Actions -> Manual Release Deploy -> Run workflow
```

Use `main`. Leave `version` blank to bump minor, or enter an exact version such
as `0.8`.

The workflow:

1. Builds and smokes locally in CI.
2. Publishes Web client and PCK files to GitHub Pages.
3. Verifies the hosted files and reads the hosted PCK `Last-Modified` headers.
4. Writes `/opt/virtucade/virtucade.env` every deploy. If
   `VIRTUCADE_GAME_HOST` is set, also renders a Caddyfile and validates it on
   the VPS before touching the running service.
5. Uploads and extracts the full `builds/server/` Linux export folder into a
   staging folder, including native sidecars such as SQLite.
6. Uploads and extracts `builds/world_packs/*.pck` into a staging folder after
   syncing their modified times to the hosted GitHub Pages headers. This keeps
   the master server's PackRat metadata aligned with the static host.
7. Stops `virtucade.service`.
8. Swaps the staged files into `/opt/virtucade/server/` and
   `/opt/virtucade/world_packs/`.
9. Starts `virtucade.service` and verifies it is active.
10. Installs/reloads the Caddyfile only after the Godot backend is healthy.
11. Tags the verified release.

## 13. Check The Running Server

SSH as `deploy`:

```powershell
ssh -i "$HOME\.ssh\digitalocean-virtucade" deploy@<VPS_IP>
```

Check service:

```bash
systemctl status virtucade
tail -n 100 /opt/virtucade/logs/server.log
```

Stop/start manually if needed:

```bash
sudo systemctl stop virtucade
sudo systemctl start virtucade
sudo systemctl restart virtucade
```

## Notes

- `root` is for emergency/admin recovery.
- `deploy` is the human admin account with sudo.
- `github-deploy` is CI-only and intentionally restricted.
- The service runs only the master server. The master starts/stops world server
  processes itself.
- Caddy is a separate system service. The master does not start or reload it.
- Do not disable root SSH until `deploy` login and recovery are proven.
- DigitalOcean bills powered-off Droplets. Destroy the Droplet to stop Droplet
  billing.

Sources:

- Caddy install docs: https://caddyserver.com/docs/install
- Caddy systemd service docs: https://caddyserver.com/docs/running
- Caddy automatic HTTPS docs: https://caddyserver.com/docs/automatic-https
