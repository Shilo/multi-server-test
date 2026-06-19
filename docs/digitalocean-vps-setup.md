# DigitalOcean VPS Setup

This is the repeatable setup for a fresh Ubuntu VPS that can run the exported
`multi-server-test` Linux server through GitHub Actions.

## Quick Start

After the Droplet exists, the DigitalOcean firewall is assigned, and both local
public keys exist, upload and run the bootstrap:

```powershell
scp -i "$HOME\.ssh\digitalocean-virtucade" deploy\vps\bootstrap_ubuntu.sh "$HOME\.ssh\digitalocean-virtucade.pub" "$HOME\.ssh\virtucade-deploy-github-actions.pub" root@<VPS_IP>:/tmp/
ssh -i "$HOME\.ssh\digitalocean-virtucade" root@<VPS_IP> "bash /tmp/bootstrap_ubuntu.sh --deploy-public-key-file /tmp/digitalocean-virtucade.pub --ci-public-key-file /tmp/virtucade-deploy-github-actions.pub --client-host <VPS_IP> --set-deploy-password"
```

Then add/update the GitHub Actions secrets in
[Add GitHub Actions Secrets](#13-add-github-actions-secrets) and run the manual
release deploy workflow.

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
  TCP 19080-19180 from all IPv4/IPv6 only for temporary direct ws:// testing before DNS/WSS

Outbound:
  allow all
```

`19080` is the master server port. `19081+` is the world-server range. In the
production reverse-proxy setup, those ports should be bound to `127.0.0.1` and
should not be open publicly. Caddy is the public WSS edge on `443`.

Before a real domain is configured, the deploy workflow advertises direct
`ws://<VIRTUCADE_HOST>:19080+` URLs. For that temporary direct-IP test, open the
Godot port range. After `VIRTUCADE_GAME_HOST` is configured and Caddy WSS works,
close `19080-19180` publicly and keep only `80/443` plus SSH.

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

## 3. Automated VPS Bootstrap

The recommended path is to let the repo script perform the Linux setup. It
creates the users, app folders, restricted sudoers file, systemd service, and
Caddy installation without committing private data to the repo.

First create the GitHub Actions deploy key on your PC if it does not exist yet:

```powershell
ssh-keygen -t ed25519 -C "virtucade-deploy-github-actions" -f "$HOME\.ssh\virtucade-deploy-github-actions"
```

Use no passphrase for this CI key. The private key belongs only in GitHub
Actions secrets.

Upload the bootstrap script and public keys to the fresh VPS:

```powershell
scp -i "$HOME\.ssh\digitalocean-virtucade" `
  deploy\vps\bootstrap_ubuntu.sh `
  "$HOME\.ssh\digitalocean-virtucade.pub" `
  "$HOME\.ssh\virtucade-deploy-github-actions.pub" `
  root@<VPS_IP>:/tmp/
```

Run the bootstrap as root:

```powershell
ssh -i "$HOME\.ssh\digitalocean-virtucade" root@<VPS_IP>
```

```bash
bash /tmp/bootstrap_ubuntu.sh \
  --deploy-public-key-file /tmp/digitalocean-virtucade.pub \
  --ci-public-key-file /tmp/virtucade-deploy-github-actions.pub \
  --client-host <VPS_IP> \
  --set-deploy-password
```

What the script does:

- updates apt packages and installs `curl`, `git`, `gpg`, `unzip`, and Caddy;
- creates the human `deploy` sudo user;
- creates the restricted `github-deploy` CI user;
- creates the non-sudo `virtucade-run` runtime user that owns the Godot process;
- installs only the public SSH keys you pass in;
- creates `/opt/virtucade/server`, `/opt/virtucade/data`,
  `/opt/virtucade/logs`, `/opt/virtucade/world_packs`, and
  `/opt/virtucade/caddy`;
- keeps `/opt/virtucade` group-writable by `deploy` and `github-deploy` so the
  existing GitHub deploy workflow can stage `server.next` and `world_packs.next`
  before swapping them into place;
- writes and enables `virtucade.service`;
- enables Caddy so it starts after reboot;
- disables SSH password authentication so SSH remains key-only;
- writes the limited `github-deploy` sudoers rule required by the deploy
  workflow;
- validates the resulting users, folders, services, Caddy install, and exact
  Caddy sudoers commands required by GitHub Actions.

The script intentionally does not:

- create DigitalOcean firewall rules;
- create DNS records;
- create GitHub repository secrets;
- copy or print private keys;
- start `virtucade.service` before GitHub Actions uploads the server binary.

After the script succeeds, test both SSH users before running GitHub Actions:

```powershell
ssh -i "$HOME\.ssh\digitalocean-virtucade" deploy@<VPS_IP>
```

```bash
sudo whoami
exit
```

```powershell
ssh -i "$HOME\.ssh\virtucade-deploy-github-actions" github-deploy@<VPS_IP>
```

```bash
whoami
sudo -n systemctl is-active virtucade
touch /opt/virtucade/server/permission-test.txt
rm /opt/virtucade/server/permission-test.txt
sudo -n whoami
exit
```

Expected:

```text
whoami                                -> github-deploy
sudo -n systemctl is-active virtucade -> allowed; may print inactive before first deploy
touch server/...                      -> allowed
sudo -n whoami                        -> denied
```

After rebuilding a destroyed VPS, update both SSH host-key records:

- remove the old VPS host key from your local `known_hosts` if SSH warns that
  the host identity changed;
- recreate the `VIRTUCADE_KNOWN_HOSTS` GitHub secret from the new VPS host key.

Then continue at [Add GitHub Actions Secrets](#13-add-github-actions-secrets).

## Existing VPS Migration

If the VPS was created manually before this bootstrap script existed, it can keep
running as-is for direct `ws://` testing. Before testing the domain/Caddy WSS
path, update it to match the current script:

```bash
id virtucade-run >/dev/null 2>&1 || sudo useradd --system --home /opt/virtucade/data --shell /usr/sbin/nologin virtucade-run
sudo groupadd --force virtucade
sudo usermod -aG virtucade deploy
sudo usermod -aG virtucade github-deploy
sudo usermod -aG virtucade virtucade-run
sudo install -d -m 2775 -o deploy -g virtucade /opt/virtucade/server /opt/virtucade/world_packs /opt/virtucade/caddy
sudo install -d -m 0750 -o virtucade-run -g virtucade-run /opt/virtucade/data
sudo install -d -m 2750 -o virtucade-run -g virtucade /opt/virtucade/logs
sudo chgrp -R virtucade /opt/virtucade/server /opt/virtucade/world_packs
sudo chmod -R g+rwX /opt/virtucade/server /opt/virtucade/world_packs
```

Then edit `/etc/systemd/system/virtucade.service` so the service runs as:

```ini
User=virtucade-run
```

Update `/etc/sudoers.d/virtucade-github-deploy` so the Caddy commands use:

```text
/opt/virtucade/caddy/virtucade-Caddyfile
```

Reload systemd after editing:

```bash
sudo systemctl daemon-reload
```

## 4. Manual Setup Fallback

The remaining steps document the manual path we used originally. Prefer the
bootstrap script above for new droplets, and use this section when debugging or
when you want to inspect each command by hand.

## 5. First SSH Login

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

## 6. Create The Human Deploy User

While logged in as `root`:

```bash
adduser deploy
usermod -aG sudo deploy
useradd --system --home /opt/virtucade/data --shell /usr/sbin/nologin virtucade-run
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

## 7. Install Required Packages

As `deploy`:

```bash
sudo apt install -y unzip curl git
```

Disable SSH password authentication after key login is confirmed:

```bash
sudo mkdir -p /etc/ssh/sshd_config.d
sudo tee /etc/ssh/sshd_config.d/99-virtucade-key-only.conf >/dev/null <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
EOF
sudo sshd -t
sudo systemctl reload ssh
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

`enable --now` does two things:

- `enable` makes Caddy start automatically after a VPS reboot.
- `--now` starts Caddy immediately.

Confirm Caddy is installed, enabled, and running:

```bash
command -v caddy
systemctl is-enabled caddy
systemctl is-active caddy
```

Caddy is the WSS/TLS edge for the game. It listens publicly on `80/443`, obtains
and renews HTTPS certificates automatically after DNS points at the VPS, then
proxies browser `wss://` traffic to Godot's private `ws://127.0.0.1:19080+`
ports. The Godot master does not start, stop, or reload Caddy.

## 8. Create App Folders

```bash
sudo groupadd --force virtucade
sudo usermod -aG virtucade deploy
sudo usermod -aG virtucade virtucade-run
sudo install -d -m 2775 -o deploy -g virtucade /opt/virtucade
sudo install -d -m 2775 -o deploy -g virtucade /opt/virtucade/server /opt/virtucade/world_packs /opt/virtucade/caddy
sudo install -d -m 0750 -o virtucade-run -g virtucade-run /opt/virtucade/data
sudo install -d -m 2750 -o virtucade-run -g virtucade /opt/virtucade/logs
```

Layout:

```text
/opt/virtucade/server/   exported Linux server binary
/opt/virtucade/data/     reserved app data folder for future explicit persistence wiring
/opt/virtucade/logs/     service logs
/opt/virtucade/world_packs/ optional local mirror for server-side pack metadata
/opt/virtucade/caddy/    GitHub-uploaded Caddyfile before root validates/installs it
```

## 9. Create The Master Server Service

Create the systemd service:

```bash
sudo nano /etc/systemd/system/virtucade.service
```

Paste:

```ini
[Unit]
Description=VirtuCade Godot Server
After=network.target
ConditionPathIsExecutable=/opt/virtucade/server/multi-server-test.x86_64

[Service]
Type=simple
User=virtucade-run
WorkingDirectory=/opt/virtucade/server
Environment=MULTI_SERVER_CLIENT_HOST=<VPS_IP_OR_DOMAIN>
Environment=MULTI_SERVER_CLIENT_SCHEME=ws
Environment=MULTI_SERVER_WORLD_PACK_DIR=/opt/virtucade/world_packs
Environment=MULTI_SERVER_WORLD_PACK_BASE_URL=https://virtucade.xyz/world_packs
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

`systemctl enable virtucade` makes the Godot master start automatically after a
VPS reboot. World servers are not enabled as separate services; the master starts
and stops them on demand.

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
MULTI_SERVER_WORLD_PACK_DIR=/opt/virtucade/world_packs
MULTI_SERVER_WORLD_PACK_BASE_URL=https://virtucade.xyz/world_packs
```

That makes the exported Godot server listen privately while advertising public
`wss://` URLs through Caddy. If `VIRTUCADE_GAME_HOST` is not set, the env file
also includes:

```text
MULTI_SERVER_CLIENT_HOST=<VIRTUCADE_HOST>
MULTI_SERVER_CLIENT_SCHEME=ws
```

That keeps direct-IP `ws://` native-client testing usable before a real domain
is pointed at the VPS.

The master reads local PCK metadata from `MULTI_SERVER_WORLD_PACK_DIR`, while
clients download the actual PCK bytes from `MULTI_SERVER_WORLD_PACK_BASE_URL`.
Keep `/opt/virtucade/world_packs` mirrored with the PCK files published to
GitHub Pages if you want server-provided PackRat metadata to stay precise.
Use the final public Pages domain, such as `https://virtucade.xyz/world_packs`,
for `MULTI_SERVER_WORLD_PACK_BASE_URL`. Do not use the old
`https://shilo.github.io/multi-server-test/world_packs` URL after configuring a
custom domain, because GitHub redirects it to the custom domain and browser PCK
fetches can fail CORS.

## 10. Create The Restricted GitHub Deploy User

As `deploy`:

```bash
sudo adduser --disabled-password --gecos "" github-deploy
sudo groupadd --force virtucade
sudo usermod -aG virtucade deploy
sudo usermod -aG virtucade github-deploy
sudo usermod -aG virtucade virtucade-run
sudo install -d -m 2775 -o deploy -g virtucade /opt/virtucade /opt/virtucade/server /opt/virtucade/world_packs /opt/virtucade/caddy
sudo install -d -m 0750 -o virtucade-run -g virtucade-run /opt/virtucade/data
sudo install -d -m 2750 -o virtucade-run -g virtucade /opt/virtucade/logs
```

Allow only the commands needed by the CI user: service control plus validating
and installing the generated Caddyfile:

```bash
sudo visudo -f /etc/sudoers.d/virtucade-github-deploy
```

Paste:

```text
github-deploy ALL=(root) NOPASSWD: /usr/bin/systemctl start virtucade, /usr/bin/systemctl stop virtucade, /usr/bin/systemctl restart virtucade, /usr/bin/systemctl is-active virtucade, /usr/bin/systemctl reload caddy, /usr/bin/systemctl restart caddy, /usr/bin/systemctl is-active caddy, /usr/bin/caddy validate --adapter caddyfile --config /opt/virtucade/caddy/virtucade-Caddyfile, /usr/bin/install -m 644 /opt/virtucade/caddy/virtucade-Caddyfile /etc/caddy/Caddyfile
```

## 11. Create The GitHub Actions SSH Key

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

## 12. Test The Restricted CI User

From Windows PowerShell:

```powershell
ssh -i "$HOME\.ssh\virtucade-deploy-github-actions" github-deploy@<VPS_IP>
```

On the VPS:

```bash
whoami
sudo -n systemctl is-active virtucade
touch /opt/virtucade/server/permission-test.txt
touch /root/should-fail.txt
sudo -n apt update
rm /opt/virtucade/server/permission-test.txt
exit
```

Expected:

```text
whoami                                -> github-deploy
sudo -n systemctl is-active virtucade -> allowed; may print inactive before first deploy
touch server/...                      -> allowed
touch /root/...                       -> denied
sudo -n apt update                    -> denied
```

## 13. Add GitHub Actions Secrets

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
into the VPS at least once. Use the exact same host value you put in
`VIRTUCADE_HOST`; if Actions connects to a DNS name, collect the DNS host key,
not only the raw IP:

```powershell
ssh-keygen -F <VIRTUCADE_HOST>
ssh-keygen -F <VIRTUCADE_HOST> | Select-String -NotMatch "^#" | ForEach-Object { $_.Line } | Set-Clipboard
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

## 14. Deploy From GitHub Actions

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

## 15. Check The Running Server

SSH as `deploy`:

```powershell
ssh -i "$HOME\.ssh\digitalocean-virtucade" deploy@<VPS_IP>
```

Check services:

```bash
systemctl status virtucade --no-pager
systemctl status caddy --no-pager
systemctl is-enabled virtucade
systemctl is-enabled caddy
systemctl is-active virtucade
systemctl is-active caddy
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
