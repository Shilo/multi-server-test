#!/usr/bin/env bash
set -Eeuo pipefail

# Bootstrap a fresh Ubuntu VPS for the VirtuCade/multi-server-test deploy flow.
# This script is safe to commit publicly: pass public SSH keys as files and keep
# all private keys, passwords, domains, and GitHub secrets outside the repo.

APP_NAME="virtucade"
APP_ROOT="/opt/virtucade"
SERVICE_NAME="virtucade"
HUMAN_USER="deploy"
CI_USER="github-deploy"
SERVICE_USER="virtucade-run"
APP_GROUP="virtucade"
SERVER_BINARY="multi-server-test.x86_64"
WORLD_PACK_BASE_URL="https://shilo.github.io/multi-server-test/world_packs"
CLIENT_HOST=""
CLIENT_SCHEME="ws"
DEPLOY_STAGE=""
DEPLOY_PUBLIC_KEY_FILE=""
CI_PUBLIC_KEY_FILE=""
SET_DEPLOY_PASSWORD="auto"
RUN_UPGRADE="true"
INSTALL_CADDY="true"

usage() {
	cat <<'EOF'
Usage:
  sudo bash deploy/vps/bootstrap_ubuntu.sh \
    --deploy-public-key-file /tmp/deploy.pub \
    --ci-public-key-file /tmp/github-deploy.pub \
    --client-host <vps-ip-or-domain>

Options:
  --deploy-public-key-file PATH   Public SSH key for the human deploy user.
  --ci-public-key-file PATH       Public SSH key for the restricted GitHub user.
  --client-host HOST              Public direct-test host/IP advertised before WSS is configured.
  --client-scheme SCHEME          Direct-test scheme, default: ws.
  --world-pack-base-url URL       Public world pack URL, default: GitHub Pages path.
  --app-root PATH                 Install root, default: /opt/virtucade.
  --service-name NAME             systemd service name, default: virtucade.
  --human-user NAME               Human sudo user, default: deploy.
  --ci-user NAME                  Restricted CI user, default: github-deploy.
  --service-user NAME             Non-login Godot service user, default: virtucade-run.
  --no-upgrade                    Skip apt upgrade; still installs required packages.
  --no-caddy                      Skip Caddy installation.
  --set-deploy-password           Prompt for the human deploy user's sudo password.
  --no-deploy-password            Do not prompt for a deploy password.
  -h, --help                      Show this help.

Notes:
  - Pass public .pub files only. Never pass private keys to this script.
  - The GitHub Actions private key belongs in GitHub Secrets, not on the VPS.
EOF
}

log() {
	printf '[bootstrap] %s\n' "$*"
}

fail() {
	printf '[bootstrap] ERROR: %s\n' "$*" >&2
	exit 1
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--deploy-public-key-file)
			DEPLOY_PUBLIC_KEY_FILE="${2:-}"
			shift 2
			;;
		--ci-public-key-file)
			CI_PUBLIC_KEY_FILE="${2:-}"
			shift 2
			;;
		--client-host)
			CLIENT_HOST="${2:-}"
			shift 2
			;;
		--client-scheme)
			CLIENT_SCHEME="${2:-}"
			shift 2
			;;
		--world-pack-base-url)
			WORLD_PACK_BASE_URL="${2:-}"
			shift 2
			;;
		--app-root)
			APP_ROOT="${2:-}"
			shift 2
			;;
		--service-name)
			SERVICE_NAME="${2:-}"
			shift 2
			;;
		--human-user)
			HUMAN_USER="${2:-}"
			shift 2
			;;
		--ci-user)
			CI_USER="${2:-}"
			shift 2
			;;
		--service-user)
			SERVICE_USER="${2:-}"
			shift 2
			;;
		--no-upgrade)
			RUN_UPGRADE="false"
			shift
			;;
		--no-caddy)
			INSTALL_CADDY="false"
			shift
			;;
		--set-deploy-password)
			SET_DEPLOY_PASSWORD="yes"
			shift
			;;
		--no-deploy-password)
			SET_DEPLOY_PASSWORD="no"
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			fail "Unknown option: $1"
			;;
	esac
done

[ "$(id -u)" -eq 0 ] || fail "Run as root with sudo or from the root account."
[ -n "$DEPLOY_PUBLIC_KEY_FILE" ] || fail "--deploy-public-key-file is required."
[ -n "$CI_PUBLIC_KEY_FILE" ] || fail "--ci-public-key-file is required."
[ -f "$DEPLOY_PUBLIC_KEY_FILE" ] || fail "Missing deploy public key file: $DEPLOY_PUBLIC_KEY_FILE"
[ -f "$CI_PUBLIC_KEY_FILE" ] || fail "Missing CI public key file: $CI_PUBLIC_KEY_FILE"
DEPLOY_STAGE="${APP_ROOT}/deploy-staging"

NAME_RE='^[a-z_][a-z0-9_-]*$'
SERVICE_RE='^[A-Za-z0-9_.@-]+$'
HOST_RE='^[A-Za-z0-9_.-]+$'
URL_RE='^https?://[^[:space:]]+$'
[[ "$HUMAN_USER" =~ $NAME_RE ]] || fail "Invalid --human-user: $HUMAN_USER"
[[ "$CI_USER" =~ $NAME_RE ]] || fail "Invalid --ci-user: $CI_USER"
[[ "$SERVICE_USER" =~ $NAME_RE ]] || fail "Invalid --service-user: $SERVICE_USER"
[[ "$SERVICE_NAME" =~ $SERVICE_RE ]] || fail "Invalid --service-name: $SERVICE_NAME"
[[ "$APP_NAME" =~ $NAME_RE ]] || fail "Invalid APP_NAME: $APP_NAME"
[[ "$APP_ROOT" = /* && "$APP_ROOT" != *[$'\n\r\t '*] ]] || fail "--app-root must be an absolute path without whitespace."
[[ "$CLIENT_SCHEME" =~ ^wss?$ ]] || fail "--client-scheme must be ws or wss."
if [ -n "$CLIENT_HOST" ]; then
	[[ "$CLIENT_HOST" =~ $HOST_RE ]] || fail "Invalid --client-host: $CLIENT_HOST"
fi
[[ "$WORLD_PACK_BASE_URL" =~ $URL_RE ]] || fail "Invalid --world-pack-base-url: $WORLD_PACK_BASE_URL"

validate_public_key_file() {
	local key_file="$1"
	local label="$2"
	local count=0
	while IFS= read -r key_line || [ -n "$key_line" ]; do
		key_line="${key_line%$'\r'}"
		[ -n "$key_line" ] || continue
		[[ "$key_line" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256)[[:space:]][A-Za-z0-9+/=]+([[:space:]].*)?$ ]] \
			|| fail "$label contains a non-public-key line. Pass a clean .pub file only."
		count=$((count + 1))
	done < "$key_file"
	[ "$count" -gt 0 ] || fail "$label does not contain a public key."
}

validate_public_key_file "$DEPLOY_PUBLIC_KEY_FILE" "Deploy public key file"
validate_public_key_file "$CI_PUBLIC_KEY_FILE" "CI public key file"

apt_install() {
	DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

ensure_user() {
	local user="$1"
	local _disabled_password="$2"
	if id "$user" >/dev/null 2>&1; then
		log "User already exists: $user"
		return
	fi
	adduser --disabled-password --gecos "" "$user"
}

ensure_service_user() {
	if id "$SERVICE_USER" >/dev/null 2>&1; then
		log "Service user already exists: $SERVICE_USER"
		return
	fi
	useradd --system --home "$APP_ROOT/data" --shell /usr/sbin/nologin "$SERVICE_USER"
}

install_authorized_key() {
	local user="$1"
	local key_file="$2"
	local home_dir
	home_dir="$(getent passwd "$user" | cut -d: -f6)"
	[ -n "$home_dir" ] || fail "Could not resolve home directory for $user"

	install -d -m 700 -o "$user" -g "$user" "$home_dir/.ssh"
	touch "$home_dir/.ssh/authorized_keys"
	chown "$user:$user" "$home_dir/.ssh/authorized_keys"
	chmod 600 "$home_dir/.ssh/authorized_keys"
	while IFS= read -r key_line || [ -n "$key_line" ]; do
		key_line="${key_line%$'\r'}"
		[ -n "$key_line" ] || continue
		if ! grep -Fxq "$key_line" "$home_dir/.ssh/authorized_keys"; then
			printf '%s\n' "$key_line" >> "$home_dir/.ssh/authorized_keys"
		fi
	done < "$key_file"
}

configure_ssh_key_only() {
	local sshd_config_dir="/etc/ssh/sshd_config.d"
	local sshd_config_file="${sshd_config_dir}/99-${APP_NAME}-key-only.conf"
	log "Disabling SSH password authentication"
	install -d -m 755 "$sshd_config_dir"
	cat > "$sshd_config_file" <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
EOF
	sshd -t
	systemctl reload ssh || systemctl reload sshd
}

configure_packages() {
	log "Updating package indexes"
	apt-get update

	if [ "$RUN_UPGRADE" = "true" ]; then
		log "Upgrading packages with existing config files preserved"
		NEEDRESTART_MODE=a DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
			-o Dpkg::Options::="--force-confdef" \
			-o Dpkg::Options::="--force-confold"
		DEBIAN_FRONTEND=noninteractive apt-get autoremove -y
	fi

	log "Installing base packages"
	apt_install ca-certificates curl git gpg unzip
}

install_caddy() {
	if [ "$INSTALL_CADDY" != "true" ]; then
		log "Skipping Caddy installation"
		return
	fi

	if command -v caddy >/dev/null 2>&1; then
		log "Caddy already installed"
	else
		log "Installing Caddy from the official package repository"
		apt_install debian-keyring debian-archive-keyring apt-transport-https
		install -d -m 755 /usr/share/keyrings /etc/apt/sources.list.d
		curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
			| gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
		curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
			-o /etc/apt/sources.list.d/caddy-stable.list
		apt-get update
		apt_install caddy
	fi

	systemctl enable --now caddy
}

configure_users_and_permissions() {
	log "Creating users and shared app group"
	ensure_user "$HUMAN_USER" "false"
	ensure_user "$CI_USER" "true"

	usermod -aG sudo "$HUMAN_USER"
	if ! getent group "$APP_GROUP" >/dev/null 2>&1; then
		groupadd "$APP_GROUP"
	fi
	ensure_service_user
	usermod -aG "$APP_GROUP" "$HUMAN_USER"
	usermod -aG "$APP_GROUP" "$CI_USER"
	usermod -aG "$APP_GROUP" "$SERVICE_USER"

	install_authorized_key "$HUMAN_USER" "$DEPLOY_PUBLIC_KEY_FILE"
	install_authorized_key "$CI_USER" "$CI_PUBLIC_KEY_FILE"

	if [ "$SET_DEPLOY_PASSWORD" = "yes" ] || { [ "$SET_DEPLOY_PASSWORD" = "auto" ] && [ -t 0 ]; }; then
		log "Set sudo password for $HUMAN_USER"
		passwd "$HUMAN_USER"
	else
		log "Skipped $HUMAN_USER password prompt; run 'sudo passwd $HUMAN_USER' later if needed."
	fi
}

configure_app_folders() {
	log "Creating app folders under $APP_ROOT"
	install -d -m 2775 -o "$HUMAN_USER" -g "$APP_GROUP" "$APP_ROOT"
	install -d -m 2775 -o "$HUMAN_USER" -g "$APP_GROUP" "$APP_ROOT/server" "$APP_ROOT/world_packs"
	install -d -m 0700 -o "$CI_USER" -g "$APP_GROUP" "$DEPLOY_STAGE"
	install -d -m 0750 -o "$SERVICE_USER" -g "$SERVICE_USER" "$APP_ROOT/data"
	install -d -m 2750 -o "$SERVICE_USER" -g "$APP_GROUP" "$APP_ROOT/logs"

	# Keep deploy surfaces group-writable for GitHub Actions without giving the
	# CI user write access to runtime data or logs.
	chown -R "$HUMAN_USER:$APP_GROUP" "$APP_ROOT/server" "$APP_ROOT/world_packs"
	find "$APP_ROOT" "$APP_ROOT/server" "$APP_ROOT/world_packs" -type d -exec chmod 2775 {} \;
	chown "$CI_USER:$APP_GROUP" "$DEPLOY_STAGE"
	chmod 0700 "$DEPLOY_STAGE"
	chown -R "$SERVICE_USER:$SERVICE_USER" "$APP_ROOT/data"
	find "$APP_ROOT/data" -type d -exec chmod 0750 {} \;
	chown -R "$SERVICE_USER:$APP_GROUP" "$APP_ROOT/logs"
	find "$APP_ROOT/logs" -type d -exec chmod 2750 {} \;
}

write_service() {
	local service_path="/etc/systemd/system/${SERVICE_NAME}.service"
	local client_lines=""
	if [ -n "$CLIENT_HOST" ]; then
		client_lines="Environment=MULTI_SERVER_CLIENT_HOST=${CLIENT_HOST}
Environment=MULTI_SERVER_CLIENT_SCHEME=${CLIENT_SCHEME}"
	fi

	log "Writing systemd service: $service_path"
	cat > "$service_path" <<EOF
[Unit]
Description=${APP_NAME} Godot Server
After=network.target
ConditionPathIsExecutable=${APP_ROOT}/server/${SERVER_BINARY}

[Service]
Type=simple
User=${SERVICE_USER}
WorkingDirectory=${APP_ROOT}/server
${client_lines}
Environment=MULTI_SERVER_WORLD_PACK_DIR=${APP_ROOT}/world_packs
Environment=MULTI_SERVER_WORLD_PACK_BASE_URL=${WORLD_PACK_BASE_URL}
EnvironmentFile=-${APP_ROOT}/${APP_NAME}.env
ExecStart=${APP_ROOT}/server/${SERVER_BINARY} --headless
Restart=on-failure
RestartSec=3
StandardOutput=append:${APP_ROOT}/logs/server.log
StandardError=append:${APP_ROOT}/logs/server.log

[Install]
WantedBy=multi-user.target
EOF

	systemctl daemon-reload
	systemctl enable "$SERVICE_NAME"
}

write_sudoers() {
	local sudoers_path="/etc/sudoers.d/${APP_NAME}-github-deploy"
	local temp_sudoers
	temp_sudoers="$(mktemp)"
	log "Writing restricted sudoers file: $sudoers_path"
	cat > "$temp_sudoers" <<EOF
${CI_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl start ${SERVICE_NAME}, /usr/bin/systemctl stop ${SERVICE_NAME}, /usr/bin/systemctl restart ${SERVICE_NAME}, /usr/bin/systemctl is-active ${SERVICE_NAME}, /usr/bin/systemctl reload caddy, /usr/bin/systemctl restart caddy, /usr/bin/systemctl is-active caddy, /usr/bin/caddy validate --config ${DEPLOY_STAGE}/${APP_NAME}-Caddyfile, /usr/bin/install -m 644 ${DEPLOY_STAGE}/${APP_NAME}-Caddyfile /etc/caddy/Caddyfile
EOF
	visudo -cf "$temp_sudoers" >/dev/null
	install -m 440 -o root -g root "$temp_sudoers" "$sudoers_path"
	rm -f "$temp_sudoers"
}

validate_setup() {
	log "Validating setup"
	id "$HUMAN_USER" >/dev/null
	id "$CI_USER" >/dev/null
	id "$SERVICE_USER" >/dev/null
	test -s "$(getent passwd "$HUMAN_USER" | cut -d: -f6)/.ssh/authorized_keys"
	test -s "$(getent passwd "$CI_USER" | cut -d: -f6)/.ssh/authorized_keys"
	test -d "$APP_ROOT/server"
	test -d "$APP_ROOT/world_packs"
	test -d "$DEPLOY_STAGE"
	test "$(systemctl is-enabled "$SERVICE_NAME")" = "enabled"
	if sudo -n -u "$CI_USER" sudo -n /usr/bin/systemctl is-active "$SERVICE_NAME" >/dev/null 2>&1; then
		:
	else
		local status=$?
		[ "$status" -eq 3 ] || fail "CI user cannot run allowed systemctl is-active check."
	fi
	if sudo -n -u "$CI_USER" sudo -n /usr/bin/whoami >/dev/null 2>&1; then
		fail "CI user has broader sudo access than expected."
	fi
	if [ "$INSTALL_CADDY" = "true" ]; then
		command -v caddy >/dev/null
		test "$(systemctl is-enabled caddy)" = "enabled"
	fi
	if [ -f /var/run/reboot-required ]; then
		log "A reboot is recommended before first deploy because package updates require it."
	fi
	log "Bootstrap complete. Deploy artifacts with GitHub Actions before starting ${SERVICE_NAME}.service."
}

configure_packages
install_caddy
configure_users_and_permissions
configure_app_folders
configure_ssh_key_only
write_service
write_sudoers
validate_setup
