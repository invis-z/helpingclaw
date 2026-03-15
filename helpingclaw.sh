#!/usr/bin/env bash
# HelpingClaw All-In-One OpenClaw Setup Utility
# Usage: ./helpingclaw.sh [command]

set -Eeuo pipefail

# ==========================================
# 1. CORE UTILITIES (Formerly openclaw-common.sh)
# ==========================================

export CYAN='\e[1;36m'
export GREEN='\e[1;32m'
export YELLOW='\e[1;33m'
export RED='\e[1;31m'
export BOLD='\e[1m'
export NC='\e[0m'

info() { echo -e "${CYAN}ℹ${NC} ${BOLD}$1${NC}"; }
success() { echo -e "${GREEN}✔${NC} ${BOLD}$1${NC}"; }
warn() { echo -e "${YELLOW}⚠${NC} ${BOLD}$1${NC}" >&2; }
err() { echo -e "${RED}✖${NC} ${BOLD}$1${NC}" >&2; }
trap 'err "Script failed at line $LINENO."' ERR

# Dynamic CLI Box Builder
_BOX_LEN=()
_BOX_FMT=()
_BOX_MAX_W=0

box_reset() {
	_BOX_LEN=()
	_BOX_FMT=()
	_BOX_MAX_W=0
}

box_add() {
	local fmt="$1"
	local raw=$(echo "$fmt" | sed 's/\\e\[[0-9;]*m//g')
	local len=$(echo -n "$raw" | wc -L)
	
	_BOX_LEN+=("$len")
	_BOX_FMT+=("$fmt")
	
	if (( len > _BOX_MAX_W )); then
		_BOX_MAX_W=$len
	fi
}

box_add_empty() {
	_BOX_LEN+=(0)
	_BOX_FMT+=("")
}

box_render() {
	local target_w=$(( _BOX_MAX_W + 2 ))
	echo -e "\n${YELLOW}╭$(printf '─%.0s' $(seq 1 $target_w))╮${NC}"
	local num_lines=${#_BOX_LEN[@]}
	for (( i=0; i<num_lines; i++ )); do
		local len="${_BOX_LEN[$i]}"
		local fmt="${_BOX_FMT[$i]}"
		
		if [[ "$len" -eq 0 && -z "$fmt" ]]; then
			 printf "${YELLOW}│${NC}%*s${YELLOW}│${NC}\n" "$target_w" ""
		else
			 local padding=$(( target_w - len - 1 )) # -1 for leading space
			 printf "${YELLOW}│${NC} %b%*s${YELLOW}│${NC}\n" "$fmt" "$padding" ""
		fi
	done
	echo -e "${YELLOW}╰$(printf '─%.0s' $(seq 1 $target_w))╯${NC}"
	box_reset
}

require_cmd() {
	if ! command -v "$1" >/dev/null 2>&1; then
		err "Missing dependency: $1"
		exit 1
	fi
}

export OPENCLAW_USER="${OPENCLAW_PODMAN_USER:-openclaw}"
export OPENCLAW_IMAGE="${OPENCLAW_IMAGE:-ghcr.io/invis-z/lobster:latest}"
export OPENCLAW_SANDBOX_USER="${OPENCLAW_PODMAN_SANDBOX_USER:-sandcastle}"
export OPENCLAW_SANDBOX_GROUP="${OPENCLAW_PODMAN_SANDBOX_GROUP:-sandcastle-crew}"
export OPENCLAW_SANDBOX_DOCKER_IMAGE="${OPENCLAW_SANDBOX_DOCKER_IMAGE:-ghcr.io/invis-z/lobster-sandcastle:bookworm-slim}"

resolve_user_home() {
	local user="$1"
	local home=""
	if command -v getent >/dev/null 2>&1; then
		home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6)"
	fi
	if [[ -z "$home" && -f /etc/passwd ]]; then
		home="$(awk -F: -v u="$user" '$1==u {print $6}' /etc/passwd 2>/dev/null)"
	fi
	if [[ -z "$home" || "$home" == "/" ]]; then
		if [[ -d "/var/home" && ! -d "/home" ]]; then
			home="/var/home/$user"
		else
			home="/home/$user"
		fi
	fi
	echo "$home"
}

export OPENCLAW_HOME="$(resolve_user_home "$OPENCLAW_USER")"

user_exists() {
	local user="$1"
	if command -v getent >/dev/null 2>&1; then
		getent passwd "$user" >/dev/null 2>&1 && return 0
	fi
	id -u "$user" >/dev/null 2>&1
}

group_exists() {
	local group="$1"
	if command -v getent >/dev/null 2>&1; then
		getent group "$group" >/dev/null 2>&1 && return 0
	fi
	grep -q "^${group}:" /etc/group 2>/dev/null
}

resolve_nologin_shell() {
	for cand in /usr/sbin/nologin /sbin/nologin /usr/bin/nologin /bin/false; do
		if [[ -x "$cand" ]]; then printf '%s' "$cand"; return 0; fi
	done
	printf '%s' "/usr/sbin/nologin"
}

is_root() { [[ "$(id -u)" -eq 0 ]]; }

run_root() {
	if is_root; then
		"$@"
	else
		sudo "$@"
	fi
}

run_as_user() {
	local user="$1"
	shift
	if command -v sudo >/dev/null 2>&1; then
		( cd /tmp 2>/dev/null || cd /; sudo -u "$user" "$@" )
	elif is_root && command -v runuser >/dev/null 2>&1; then
		( cd /tmp 2>/dev/null || cd /; runuser -u "$user" -- "$@" )
	else
		err "Need sudo (or root+runuser) to run commands as $user."
		exit 1
	fi
}

run_as_openclaw() {
	run_as_user "$OPENCLAW_USER" env HOME="$OPENCLAW_HOME" "$@"
}


# ==========================================
# 2. COMMAND FUNCTIONS
# ==========================================

cmd_deploy() {
	require_cmd podman
	require_cmd systemctl
	if ! is_root; then require_cmd sudo; fi

	generate_token_hex_32() {
		if command -v openssl >/dev/null 2>&1; then
			openssl rand -hex 32; return 0
		fi
		if command -v python3 >/dev/null 2>&1; then
			python3 -c 'import secrets; print(secrets.token_hex(32))'; return 0
		fi
		if command -v od >/dev/null 2>&1; then
			od -An -N32 -tx1 /dev/urandom | tr -d " \n"; return 0
		fi
		err "Missing dependency: need openssl or python3 (or od) to generate token."
		exit 1
	}

	echo ""
	info "Starting OpenClaw Deployment Setup..."
	echo "──────────────────────────────────────────────"

	if ! user_exists "$OPENCLAW_USER"; then
		NOLOGIN_SHELL="$(resolve_nologin_shell)"
		local USERADD_HOME_ARGS="-m"
		local ADDUSER_HOME_ARGS=""
		if [[ -f /etc/os-release ]] && grep -qE '^ID="?(opensuse-microos|opensuse-aeon|microos)"?' /etc/os-release 2>/dev/null; then
			USERADD_HOME_ARGS="-m -d /var/home/$OPENCLAW_USER"
			ADDUSER_HOME_ARGS="--home /var/home/$OPENCLAW_USER"
			info "MicroOS detected. Enforcing user home to /var/home/$OPENCLAW_USER"
		fi

		info "Creating user '$OPENCLAW_USER' ($NOLOGIN_SHELL, with home)..."
		if command -v useradd >/dev/null 2>&1; then
			run_root useradd $USERADD_HOME_ARGS -s "$NOLOGIN_SHELL" "$OPENCLAW_USER"
		elif command -v adduser >/dev/null 2>&1; then
			run_root adduser $ADDUSER_HOME_ARGS --disabled-password --gecos "" --shell "$NOLOGIN_SHELL" "$OPENCLAW_USER"
		else
			err "Neither useradd nor adduser found, cannot create user $OPENCLAW_USER."; exit 1
		fi
		success "User '$OPENCLAW_USER' created successfully."
	else
		success "User '$OPENCLAW_USER' already exists."
	fi

	OPENCLAW_HOME="$(resolve_user_home "$OPENCLAW_USER")"
	OPENCLAW_UID="$(id -u "$OPENCLAW_USER" 2>/dev/null)"
	OPENCLAW_CONFIG="$OPENCLAW_HOME/.openclaw"

	if command -v loginctl &>/dev/null; then run_root loginctl enable-linger "$OPENCLAW_USER"; fi

	if [[ -n "${OPENCLAW_UID:-}" && -d /run/user ]]; then
		run_root systemctl start "user@${OPENCLAW_UID}.service"
	fi

	if ! grep -q "^${OPENCLAW_USER}:" /etc/subuid 2>/dev/null; then
		warn "User '$OPENCLAW_USER' has no subuid range. Rootless Podman may fail."
		warn "Consider running: sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $OPENCLAW_USER"
	fi

	info "Creating configuration directories at: $OPENCLAW_CONFIG"
	run_as_openclaw mkdir -p "$OPENCLAW_CONFIG/workspace" "$OPENCLAW_HOME/data/local/share/signal-cli"
	run_as_openclaw chmod 700 "$OPENCLAW_CONFIG" "$OPENCLAW_CONFIG/workspace" "$OPENCLAW_HOME/data/local/share/signal-cli"

	ENV_FILE="$OPENCLAW_CONFIG/.env"
	if run_as_openclaw test -f "$ENV_FILE"; then
		run_as_openclaw chmod 600 "$ENV_FILE"
		success "Found existing environment file: $ENV_FILE"
		if ! run_as_openclaw grep -q '^OPENCLAW_GATEWAY_TOKEN=' "$ENV_FILE" 2>/dev/null; then
			TOKEN="$(generate_token_hex_32)"
			printf 'OPENCLAW_GATEWAY_TOKEN=%s\n' "$TOKEN" | run_as_openclaw tee -a "$ENV_FILE" >/dev/null
			success "Appended OPENCLAW_GATEWAY_TOKEN to $ENV_FILE."
		else
			success "Environment file $ENV_FILE already configures OPENCLAW_GATEWAY_TOKEN."
		fi
	else
		TOKEN="$(generate_token_hex_32)"
		printf 'OPENCLAW_GATEWAY_TOKEN=%s\n' "$TOKEN" | run_as_openclaw tee "$ENV_FILE" >/dev/null
		run_as_openclaw chmod 600 "$ENV_FILE"
		success "Created environment file $ENV_FILE with new token."
	fi

	OPENCLAW_JSON="$OPENCLAW_CONFIG/openclaw.json"
	if ! run_as_openclaw test -f "$OPENCLAW_JSON"; then
		printf '%s\n' '{"gateway":{"mode":"local"}}' | run_as_openclaw tee "$OPENCLAW_JSON" >/dev/null
		run_as_openclaw chmod 600 "$OPENCLAW_JSON"
		success "Created default configuration: $OPENCLAW_JSON (minimal gateway.mode=local)."
	else
		success "Preserving existing configuration: $OPENCLAW_JSON"
	fi

	QUADLET_DIR="$OPENCLAW_HOME/.config/containers/systemd"
	info "Generating Podman Quadlet in $QUADLET_DIR"
	run_as_openclaw mkdir -p "$QUADLET_DIR"

	cat <<EOF | run_as_openclaw tee "$QUADLET_DIR/openclaw.container" >/dev/null
[Unit]
Description=OpenClaw gateway (rootless Podman)
Requires=podman-user-wait-network-online.service
After=podman-user-wait-network-online.service

[Container]
Image=$OPENCLAW_IMAGE
AutoUpdate=registry
ContainerName=openclaw
UserNS=keep-id
User=%U:%G
GroupAdd=keep-groups
Volume=$OPENCLAW_CONFIG:/home/node/.openclaw:Z
Volume=$OPENCLAW_HOME/data/local/share/signal-cli:/home/node/.local/share/signal-cli:Z
EnvironmentFile=$OPENCLAW_CONFIG/.env
Environment=HOME=/home/node
Environment=XDG_DATA_HOME=/home/node/.local/share
Environment=TERM=xterm-256color
PublishPort=127.0.0.1:18789:18789
PublishPort=127.0.0.1:18790:18790
Pull=newer
Exec=node dist/index.js gateway --bind lan --port 18789

[Service]
TimeoutStartSec=900
Restart=always

[Install]
WantedBy=default.target
EOF

	run_as_openclaw chmod 700 "$OPENCLAW_HOME/.config" "$OPENCLAW_HOME/.config/containers" "$QUADLET_DIR"
	run_as_openclaw chmod 600 "$QUADLET_DIR/openclaw.container"
	success "Systemd Quadlet successfully written to $QUADLET_DIR/openclaw.container"

	# Fix for Podman #24796: user-wait-network-online hangs if network-online.target isn't wanted by any system unit
	_net_deps="$(systemctl list-dependencies network-online.target --reverse --no-pager 2>/dev/null | wc -l)"
	if [[ "$_net_deps" -le 1 ]]; then
		info "network-online.target is not requested system-wide. Creating dummy service to prevent Podman hang (Issue #24796)..."
		run_root bash -c "cat > /etc/systemd/system/podman-network-wait-dummy.service" <<EOF
[Unit]
Description=Dummy service to pull in network-online.target for Podman
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/bin/echo "Satisfying network-online.target for rootless Podman"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
		run_root systemctl daemon-reload
		run_root systemctl enable --now podman-network-wait-dummy.service
	fi

	info "Configuring and starting user systemd service 'openclaw.service'..."
	run_root systemctl --machine="${OPENCLAW_USER}@" --user daemon-reload
	run_root systemctl --machine="${OPENCLAW_USER}@" --user start openclaw.service
	info "Enabling Podman auto-update timers for user '${OPENCLAW_USER}'..."
	run_root systemctl --machine="${OPENCLAW_USER}@" --user enable podman-auto-update.timer
	run_root systemctl --machine="${OPENCLAW_USER}@" --user start podman-auto-update.timer
	success "Systemd services have been started and enabled."

	echo -e "\n──────────────────────────────────────────────"
	success "Deployment of OpenClaw via rootless Quadlet is complete."
	echo -e "${CYAN}■ Running version:${NC} $OPENCLAW_IMAGE"
	echo -e "${CYAN}■ View Status:${NC}     sudo systemctl --machine=${OPENCLAW_USER}@ --user status openclaw.service"
	echo -e "${CYAN}■ View Logs:${NC}       sudo -u ${OPENCLAW_USER} journalctl --user -fu openclaw.service"
	echo -e "${CYAN}■ API Token File:${NC}  $ENV_FILE"

	if [[ -n "${TOKEN:-}" ]]; then
		box_reset
		box_add "${GREEN}✔ GENERATED API TOKEN${NC}"
		box_add "Here is your new Gateway Token for the onboarding wizard:"
		box_add_empty
		box_add "${BOLD}$TOKEN${NC}"
		box_render
	fi

	if [[ -t 0 && -t 1 ]]; then
		echo ""
		read -r -p "Run setup-sandbox now? [y/N] " _run_setup_sandbox
		if [[ "${_run_setup_sandbox:-}" =~ ^[Yy]([Ee][Ss])?$ ]]; then
			cmd_setup_sandbox
		fi
	fi

}

cmd_setup_sandbox() {
	require_cmd podman
	require_cmd jq
	require_cmd socat
	require_cmd systemctl
	info "Checking sandbox prerequisites and host capabilities..."
	_SELINUX_ACTIVE=0
	if [[ "$(uname -s 2>/dev/null)" == "Linux" ]] && command -v getenforce >/dev/null 2>&1; then
		_selinux_mode="$(getenforce 2>/dev/null || true)"
		if [[ "$_selinux_mode" == "Enforcing" || "$_selinux_mode" == "Permissive" ]]; then
			_SELINUX_ACTIVE=1
			require_cmd semanage
			require_cmd semodule
			require_cmd restorecon
		fi
	fi
	if ! is_root; then require_cmd sudo; fi

	_RESTART_SVC=0

	echo ""
	info "Starting OpenClaw Setup-Sandbox Configuration..."
	echo "──────────────────────────────────────────────"

	if ! user_exists "$OPENCLAW_USER"; then
		err "OpenClaw user '$OPENCLAW_USER' does not exist yet."
		err "Please run 'sudo ./helpingclaw.sh deploy' first."
		exit 1
	fi

	if ! group_exists "$OPENCLAW_SANDBOX_GROUP"; then
		info "Creating sandbox group '$OPENCLAW_SANDBOX_GROUP'..."
		run_root groupadd "$OPENCLAW_SANDBOX_GROUP"
		success "Sandbox group '$OPENCLAW_SANDBOX_GROUP' created successfully."
	else
		info "Sandbox group '$OPENCLAW_SANDBOX_GROUP' already exists."
	fi

	if ! user_exists "$OPENCLAW_SANDBOX_USER"; then
		NOLOGIN_SHELL="$(resolve_nologin_shell)"
		local USERADD_HOME_ARGS="-m"
		local ADDUSER_HOME_ARGS=""
		if [[ -f /etc/os-release ]] && grep -qE '^ID="?(opensuse-microos|opensuse-aeon|microos)"?' /etc/os-release 2>/dev/null; then
			USERADD_HOME_ARGS="-m -d /var/home/$OPENCLAW_SANDBOX_USER"
			ADDUSER_HOME_ARGS="--home /var/home/$OPENCLAW_SANDBOX_USER"
			info "MicroOS detected. Enforcing user home to /var/home/$OPENCLAW_SANDBOX_USER"
		fi
		info "Creating sandbox user '$OPENCLAW_SANDBOX_USER'..."
		if command -v useradd >/dev/null 2>&1; then
			run_root useradd $USERADD_HOME_ARGS -g "$OPENCLAW_SANDBOX_GROUP" -s "$NOLOGIN_SHELL" "$OPENCLAW_SANDBOX_USER"
		else
			run_root adduser $ADDUSER_HOME_ARGS --disabled-password --gecos "" --ingroup "$OPENCLAW_SANDBOX_GROUP" --shell "$NOLOGIN_SHELL" "$OPENCLAW_SANDBOX_USER"
		fi
		success "Sandbox user '$OPENCLAW_SANDBOX_USER' created successfully."
	else
		run_root usermod -aG "$OPENCLAW_SANDBOX_GROUP" "$OPENCLAW_SANDBOX_USER"
		success "Sandbox user '$OPENCLAW_SANDBOX_USER' already exists."
	fi

	SANDBOX_HOME="$(resolve_user_home "$OPENCLAW_SANDBOX_USER")"
	SANDBOX_UID="$(id -u "$OPENCLAW_SANDBOX_USER" 2>/dev/null)"

	info "Adding '$OPENCLAW_USER' to group '$OPENCLAW_SANDBOX_GROUP'..."
	run_root usermod -aG "$OPENCLAW_SANDBOX_GROUP" "$OPENCLAW_USER"

	info "Configuring Podman socket for sandbox user..."
	run_as_user "$OPENCLAW_SANDBOX_USER" mkdir -p "$SANDBOX_HOME/.config/systemd/user/podman.socket.d"

	cat <<EOF | run_as_user "$OPENCLAW_SANDBOX_USER" tee "$SANDBOX_HOME/.config/systemd/user/podman.socket.d/override.conf" >/dev/null
[Socket]
SocketMode=0660
FlushPending=yes
EOF

	# pam_systemd creates /run/user/$UID with mode 700; we need 710 so the
	# openclaw user (in the same group) can traverse into it to reach the socket.
	# A user service owned by the sandbox user can chmod its own runtime dir.
	info "Writing runtime-dir permission helper: $SANDBOX_HOME/.config/systemd/user/podman-runtime-dir-perms.service"
	cat <<'EOF' | run_as_user "$OPENCLAW_SANDBOX_USER" tee "$SANDBOX_HOME/.config/systemd/user/podman-runtime-dir-perms.service" >/dev/null
[Unit]
Description=Open sandbox runtime dir for group traversal
Before=podman.socket

[Service]
Type=oneshot
ExecStart=chmod 710 /run/user/%U
RemainAfterExit=yes

[Install]
WantedBy=default.target
EOF

	info "Writing sandbox image maintenance units (pull + prune) for $OPENCLAW_SANDBOX_USER..."
	cat <<EOF | run_as_user "$OPENCLAW_SANDBOX_USER" tee "$SANDBOX_HOME/.config/systemd/user/openclaw-sandbox-image-maintenance.service" >/dev/null
[Unit]
Description=OpenClaw sandbox image maintenance (pull + prune)

[Service]
Type=oneshot
ExecStart=/usr/bin/bash -lc '/usr/bin/podman pull "$OPENCLAW_SANDBOX_DOCKER_IMAGE"; /usr/bin/podman image prune -f --filter dangling=true'
EOF

	cat <<'EOF' | run_as_user "$OPENCLAW_SANDBOX_USER" tee "$SANDBOX_HOME/.config/systemd/user/openclaw-sandbox-image-maintenance.timer" >/dev/null
[Unit]
Description=Run OpenClaw sandbox image maintenance daily at 09:00 UTC

[Timer]
OnCalendar=*-*-* 09:00:00 UTC
RandomizedDelaySec=900
Persistent=true

[Install]
WantedBy=timers.target
EOF

	if command -v loginctl &>/dev/null; then run_root loginctl enable-linger "$OPENCLAW_SANDBOX_USER"; fi

	info "Reloading sandbox user systemd manager and enabling socket services..."
	run_root systemctl --machine="${OPENCLAW_SANDBOX_USER}@" --user daemon-reload
	run_root systemctl --machine="${OPENCLAW_SANDBOX_USER}@" --user enable --now podman-runtime-dir-perms.service
	run_root systemctl --machine="${OPENCLAW_SANDBOX_USER}@" --user enable --now podman.socket
	run_root systemctl --machine="${OPENCLAW_SANDBOX_USER}@" --user enable --now openclaw-sandbox-image-maintenance.timer
	run_root systemctl --machine="${OPENCLAW_SANDBOX_USER}@" --user start openclaw-sandbox-image-maintenance.service || true
	info "Sandbox podman socket should be exposed at /run/user/$SANDBOX_UID/podman/podman.sock"

	OPENCLAW_HOME="$(resolve_user_home "$OPENCLAW_USER")"
	OPENCLAW_CONFIG="$OPENCLAW_HOME/.openclaw"
	OPENCLAW_JSON="$OPENCLAW_CONFIG/openclaw.json"
	QUADLET_DIR="$OPENCLAW_HOME/.config/containers/systemd"
	OPENCLAW_UID="$(id -u "$OPENCLAW_USER" 2>/dev/null)"
	OPENCLAW_PROXY_RUNTIME_DIR="openclaw-sandbox/podman"
	OPENCLAW_PROXY_DIR="/run/$OPENCLAW_PROXY_RUNTIME_DIR"
	OPENCLAW_PROXY_SOCKET="$OPENCLAW_PROXY_DIR/docker.sock"


	_state="$(run_root systemctl --machine="${OPENCLAW_USER}@" --user show -p ActiveState --value openclaw.service 2>/dev/null)"
	if [[ "$_state" != "inactive" && "$_state" != "failed" ]]; then
		info "Stopping openclaw.service before updating sandbox configuration..."
		run_root systemctl --machine="${OPENCLAW_USER}@" --user stop openclaw.service
		_RESTART_SVC=1
	fi
	# Restart the openclaw user manager so it picks up the new sandcastle-crew
	# group membership added by usermod above. Without this the running process
	# tree won't see the new group and the socket mount will be denied.
	if [[ -n "${OPENCLAW_UID:-}" ]]; then
		info "Restarting user manager for '${OPENCLAW_USER}' to apply new group membership..."
		run_root systemctl restart "user@${OPENCLAW_UID}.service"
	fi

	if ! run_as_openclaw test -f "$OPENCLAW_JSON"; then
		err "OpenClaw configuration not found at: $OPENCLAW_JSON"
		err "Please run 'sudo ./helpingclaw.sh deploy' first."
		exit 1
	else
		SANDBOX_WORKSPACE_SOURCE="$SANDBOX_HOME/sandboxes"
		OPENCLAW_WORKSPACE_MOUNTPOINT="$OPENCLAW_HOME/sandboxes"
		SANDBOX_WORKSPACE_ROOT="$SANDBOX_HOME/sandboxes"
		info "Preparing sandbox workspace mount: $SANDBOX_WORKSPACE_SOURCE -> $OPENCLAW_WORKSPACE_MOUNTPOINT"
		if command -v systemd-escape >/dev/null 2>&1; then
			SANDBOX_WORKSPACE_MOUNT_UNIT="$(systemd-escape --path --suffix=mount "$OPENCLAW_WORKSPACE_MOUNTPOINT")"
		else
			SANDBOX_WORKSPACE_MOUNT_UNIT="${OPENCLAW_WORKSPACE_MOUNTPOINT//\//_}.mount"
		fi
		OPENCLAW_GID="$(id -g "$OPENCLAW_USER" 2>/dev/null)"
		SANDBOX_GID="$(id -g "$OPENCLAW_SANDBOX_USER" 2>/dev/null)"
		_u0_subuid_entry="$(awk -F: -v u="$OPENCLAW_USER" '$1==u {print $2 ":" $3; exit}' /etc/subuid 2>/dev/null)"
		_u1_subuid_entry="$(awk -F: -v u="$OPENCLAW_SANDBOX_USER" '$1==u {print $2 ":" $3; exit}' /etc/subuid 2>/dev/null)"
		_u0_subgid_entry="$(awk -F: -v u="$OPENCLAW_USER" '$1==u {print $2 ":" $3; exit}' /etc/subgid 2>/dev/null)"
		_u1_subgid_entry="$(awk -F: -v u="$OPENCLAW_SANDBOX_USER" '$1==u {print $2 ":" $3; exit}' /etc/subgid 2>/dev/null)"

		info "Primary idmap: uid $SANDBOX_UID -> $OPENCLAW_UID, gid $SANDBOX_GID -> $OPENCLAW_GID"
		_IDMAP_OPTS="u:${SANDBOX_UID}:${OPENCLAW_UID}:1"
		if [[ -n "${_u0_subuid_entry:-}" && -n "${_u1_subuid_entry:-}" ]]; then
			_u0_subuid_start="${_u0_subuid_entry%%:*}"; _u0_subuid_size="${_u0_subuid_entry##*:}"
			_u1_subuid_start="${_u1_subuid_entry%%:*}"; _u1_subuid_size="${_u1_subuid_entry##*:}"
			_subuid_size=$(( _u0_subuid_size < _u1_subuid_size ? _u0_subuid_size : _u1_subuid_size ))
			_IDMAP_OPTS+="\ u:${_u1_subuid_start}:${_u0_subuid_start}:${_subuid_size}"
			info "Adding subuid idmap: ${_u1_subuid_start}:${_u0_subuid_start}:${_subuid_size}"
		else
			warn "Missing subuid range for $OPENCLAW_USER or $OPENCLAW_SANDBOX_USER; subordinate uid mapping skipped."
		fi
		_IDMAP_OPTS+="\ g:${SANDBOX_GID}:${OPENCLAW_GID}:1"
		if [[ -n "${_u0_subgid_entry:-}" && -n "${_u1_subgid_entry:-}" ]]; then
			_u0_subgid_start="${_u0_subgid_entry%%:*}"; _u0_subgid_size="${_u0_subgid_entry##*:}"
			_u1_subgid_start="${_u1_subgid_entry%%:*}"; _u1_subgid_size="${_u1_subgid_entry##*:}"
			_subgid_size=$(( _u0_subgid_size < _u1_subgid_size ? _u0_subgid_size : _u1_subgid_size ))
			_IDMAP_OPTS+="\ g:${_u1_subgid_start}:${_u0_subgid_start}:${_subgid_size}"
			info "Adding subgid idmap: ${_u1_subgid_start}:${_u0_subgid_start}:${_subgid_size}"
		else
			warn "Missing subgid range for $OPENCLAW_USER or $OPENCLAW_SANDBOX_USER; subordinate gid mapping skipped."
		fi
		info "Resolved idmapped mount options: bind,X-mount.idmap=${_IDMAP_OPTS}"

		run_as_user "$OPENCLAW_SANDBOX_USER" mkdir -p "$SANDBOX_WORKSPACE_SOURCE"
		run_as_user "$OPENCLAW_SANDBOX_USER" chmod 700 "$SANDBOX_WORKSPACE_SOURCE"
		run_root mkdir -p "$OPENCLAW_WORKSPACE_MOUNTPOINT"

		cat <<EOF | run_root tee "/etc/systemd/system/$SANDBOX_WORKSPACE_MOUNT_UNIT" >/dev/null
[Unit]
Description=OpenClaw sandbox workspace idmapped bind mount
Before=openclaw-sandbox-socket-proxy.service

[Mount]
What=$SANDBOX_WORKSPACE_SOURCE
Where=$OPENCLAW_WORKSPACE_MOUNTPOINT
Type=none
Options=bind,X-mount.idmap=${_IDMAP_OPTS}

[Install]
WantedBy=multi-user.target
EOF
		run_root chmod 644 "/etc/systemd/system/$SANDBOX_WORKSPACE_MOUNT_UNIT"
		run_root systemctl daemon-reload
		info "Enabling sandbox workspace mount unit: $SANDBOX_WORKSPACE_MOUNT_UNIT"
		run_root systemctl enable --now "$SANDBOX_WORKSPACE_MOUNT_UNIT"
		run_root mkdir -p "/etc/systemd/system/user@${OPENCLAW_UID}.service.d"
		info "Writing openclaw user mount dependency drop-in for user@$OPENCLAW_UID.service"
		cat <<EOF | run_root tee "/etc/systemd/system/user@${OPENCLAW_UID}.service.d/openclaw-sandbox-workspace.conf" >/dev/null
[Unit]
Wants=$SANDBOX_WORKSPACE_MOUNT_UNIT
After=$SANDBOX_WORKSPACE_MOUNT_UNIT
RequiresMountsFor=$OPENCLAW_WORKSPACE_MOUNTPOINT
EOF
		run_root systemctl daemon-reload
		info "Restarting openclaw user manager to pick up mount dependencies..."
		run_root systemctl restart "user@${OPENCLAW_UID}.service" || run_root systemctl start "user@${OPENCLAW_UID}.service"
		tmp_file="$(mktemp)"
		trap 'rm -f "$tmp_file"' RETURN
		info "Updating sandbox configuration in $OPENCLAW_JSON"
		run_as_openclaw jq --arg sandbox_workspace_root "$SANDBOX_WORKSPACE_ROOT" --arg sandbox_docker_image "$OPENCLAW_SANDBOX_DOCKER_IMAGE" '
			.gateway = (.gateway // {}) |
			.gateway.mode = (.gateway.mode // "local") |
			.agents = (.agents // {}) |
			.agents.defaults = (.agents.defaults // {}) |
			.agents.defaults.sandbox = (.agents.defaults.sandbox // {}) |
			.agents.defaults.sandbox.mode = "all" |
			.agents.defaults.sandbox.workspaceRoot = $sandbox_workspace_root |
			.agents.defaults.sandbox.docker = (.agents.defaults.sandbox.docker // {}) |
			.agents.defaults.sandbox.docker.image = $sandbox_docker_image
		' "$OPENCLAW_JSON" > "$tmp_file"
		run_as_openclaw tee "$OPENCLAW_JSON" >/dev/null < "$tmp_file"
		trap - RETURN
		rm -f "$tmp_file"
		success "Updated configuration: $OPENCLAW_JSON with sandbox enabled, workspaceRoot=$SANDBOX_WORKSPACE_ROOT, docker.image=$OPENCLAW_SANDBOX_DOCKER_IMAGE."
	fi

	info "Generating system sandbox socket proxy service..."
	info "Preparing proxy runtime directory: $OPENCLAW_PROXY_DIR"
	run_root mkdir -p "$OPENCLAW_PROXY_DIR"
	run_root chown "$OPENCLAW_USER:$(id -gn "$OPENCLAW_USER" 2>/dev/null)" "$OPENCLAW_PROXY_DIR"
	run_root chmod 0770 "$OPENCLAW_PROXY_DIR"
	if [[ "$_SELINUX_ACTIVE" -eq 1 ]]; then
		info "SELinux active. Installing dedicated proxy policy and labels..."
		run_root mkdir -p /etc/selinux/local
		cat <<'EOF' | run_root tee /etc/selinux/local/openclaw-sandbox.cil >/dev/null
(block openclaw_sandbox
(type openclaw_proxy_t)
(type openclaw_proxy_sock_t)
(typeattributeset domain (openclaw_proxy_t))
(typeattributeset file_type (openclaw_proxy_sock_t))
(roletype system_r openclaw_proxy_t)
(allow init_t openclaw_proxy_t (process (transition)))
(allow init_t openclaw_proxy_sock_t (dir (create getattr setattr search)))

(allow container_t openclaw_proxy_t (unix_stream_socket (connectto)))
(allow container_t openclaw_proxy_sock_t (sock_file (getattr open read write)))

(allow openclaw_proxy_t openclaw_proxy_t (unix_dgram_socket (create ioctl read write getattr setattr bind connect sendto)))
(allow openclaw_proxy_t openclaw_proxy_t (unix_stream_socket (create ioctl read write getattr setattr bind connect listen accept)))
(allow openclaw_proxy_t openclaw_proxy_sock_t (dir (getattr search write add_name remove_name)))
(allow openclaw_proxy_t openclaw_proxy_sock_t (sock_file (create getattr setattr unlink open read write)))
(allow openclaw_proxy_t container_runtime_t (unix_stream_socket (connectto)))
(allow openclaw_proxy_t container_file_t (sock_file (getattr open read write)))
(allow openclaw_proxy_t container_var_run_t (sock_file (getattr open read write)))
(allow openclaw_proxy_t user_tmp_t (dir (getattr search)))
(allow openclaw_proxy_t user_tmp_t (sock_file (getattr open read write)))
(allow openclaw_proxy_t bin_t (file (entrypoint getattr open read execute execute_no_trans map)))
(allow openclaw_proxy_t shell_exec_t (file (entrypoint getattr open read execute execute_no_trans map)))
(allow openclaw_proxy_t lib_t (file (getattr open read map execute)))
)
EOF
		run_root semodule -i /etc/selinux/local/openclaw-sandbox.cil
		if ! run_root semanage fcontext -a -t openclaw_sandbox.openclaw_proxy_sock_t "${OPENCLAW_PROXY_DIR#/var}(/.*)?" 2>/dev/null; then
			run_root semanage fcontext -m -t openclaw_sandbox.openclaw_proxy_sock_t "${OPENCLAW_PROXY_DIR#/var}(/.*)?"
		fi
		# Workspace source/root are home-backed and idmapped; rely on container
		# relabel behavior from the quadlet bind mount rather than persistent
		# semanage fcontext overrides here.
	else
		info "SELinux not active. Skipping semanage/restorecon/semodule steps."
	fi
	_proxy_selinux_context_line=""
	_proxy_restorecon_pre_line=""
	if [[ "$_SELINUX_ACTIVE" -eq 1 ]]; then
		_proxy_selinux_context_line="SELinuxContext=system_u:system_r:openclaw_sandbox.openclaw_proxy_t:s0"
		_proxy_restorecon_pre_line="ExecStartPre=+/usr/sbin/restorecon -RF %t/$OPENCLAW_PROXY_RUNTIME_DIR"
	fi
	info "Writing proxy service unit: /etc/systemd/system/openclaw-sandbox-socket-proxy.service"
	cat <<EOF | run_root tee /etc/systemd/system/openclaw-sandbox-socket-proxy.service >/dev/null
[Unit]
Description=OpenClaw sandbox Docker socket proxy
Requires=user@${SANDBOX_UID}.service
After=user@${SANDBOX_UID}.service

[Service]
Type=simple
User=$OPENCLAW_USER
Group=$(id -gn "$OPENCLAW_USER" 2>/dev/null)
$_proxy_selinux_context_line
RuntimeDirectory=$OPENCLAW_PROXY_RUNTIME_DIR
RuntimeDirectoryMode=0770
$_proxy_restorecon_pre_line
ExecStartPre=/usr/bin/rm -f %t/$OPENCLAW_PROXY_RUNTIME_DIR/docker.sock
ExecStartPre=/usr/bin/bash -c "for _ in {1..30}; do [[ -S /run/user/$SANDBOX_UID/podman/podman.sock ]] && exit 0; sleep 1; done; echo 'Timed out waiting for sandbox podman socket' >&2; exit 1"
ExecStart=/usr/bin/socat -t 15 UNIX-LISTEN:%t/$OPENCLAW_PROXY_RUNTIME_DIR/docker.sock,reuseaddr,fork,mode=0660 UNIX-CONNECT:/run/user/$SANDBOX_UID/podman/podman.sock
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
	run_root chmod 644 /etc/systemd/system/openclaw-sandbox-socket-proxy.service
	run_root systemctl daemon-reload
	info "Enabling proxy service; Docker-compatible socket target is $OPENCLAW_PROXY_SOCKET"
	run_root systemctl enable --now openclaw-sandbox-socket-proxy.service

	info "Generating sandbox-enabled Podman Quadlet in $QUADLET_DIR"
	run_as_openclaw mkdir -p "$QUADLET_DIR"
	info "Writing sandbox-enabled quadlet: $QUADLET_DIR/openclaw.container"

	cat <<EOF | run_as_openclaw tee "$QUADLET_DIR/openclaw.container" >/dev/null
[Unit]
Description=OpenClaw gateway (rootless Podman)
Requires=podman-user-wait-network-online.service
After=podman-user-wait-network-online.service

[Container]
Image=$OPENCLAW_IMAGE
AutoUpdate=registry
ContainerName=openclaw
UserNS=keep-id
User=%U:%G
GroupAdd=keep-groups
Volume=$OPENCLAW_CONFIG:/home/node/.openclaw:Z
Volume=$OPENCLAW_HOME/data/local/share/signal-cli:/home/node/.local/share/signal-cli:Z
Volume=$OPENCLAW_PROXY_DIR:/var/run/openclaw-sandbox:rw
Volume=$OPENCLAW_WORKSPACE_MOUNTPOINT:$SANDBOX_WORKSPACE_ROOT:z
EnvironmentFile=$OPENCLAW_CONFIG/.env
Environment=HOME=/home/node
Environment=XDG_DATA_HOME=/home/node/.local/share
Environment=TERM=xterm-256color
Environment=DOCKER_HOST=unix:///var/run/openclaw-sandbox/docker.sock
PublishPort=127.0.0.1:18789:18789
PublishPort=127.0.0.1:18790:18790
Pull=newer
Exec=node dist/index.js gateway --bind lan --port 18789

[Service]
TimeoutStartSec=900
Restart=always

[Install]
WantedBy=default.target
EOF

	run_as_openclaw chmod 600 "$QUADLET_DIR/openclaw.container"
	success "Systemd Quadlet successfully written to $QUADLET_DIR/openclaw.container"

	info "Reloading openclaw user systemd and applying service changes..."
	run_root systemctl --machine="${OPENCLAW_USER}@" --user daemon-reload
	if [[ "$_RESTART_SVC" -eq 1 ]]; then
		info "Restarting openclaw.service with sandbox integration enabled..."
		run_root systemctl --machine="${OPENCLAW_USER}@" --user start openclaw.service
		success "openclaw.service was restored after configuration changes."
	else
		success "openclaw.service was already stopped and left stopped."
	fi

	echo -e "\n──────────────────────────────────────────────"
	success "Sandbox configuration setup is complete."
	echo -e "${CYAN}■ Sandbox User:${NC}    $OPENCLAW_SANDBOX_USER"
	echo -e "${CYAN}■ Sandbox Group:${NC}   $OPENCLAW_SANDBOX_GROUP"
	echo -e "${CYAN}■ Workspace Source:${NC} $SANDBOX_WORKSPACE_SOURCE"
	echo -e "${CYAN}■ Workspace Root:${NC}   $SANDBOX_WORKSPACE_ROOT"
	echo -e "${CYAN}■ Mount Unit:${NC}       $SANDBOX_WORKSPACE_MOUNT_UNIT"
	echo -e "${CYAN}■ Proxy Socket:${NC}     $OPENCLAW_PROXY_SOCKET"
	echo -e "${CYAN}■ Mount Status:${NC}     sudo systemctl status $SANDBOX_WORKSPACE_MOUNT_UNIT"
	echo -e "${CYAN}■ Proxy Status:${NC}     sudo systemctl status openclaw-sandbox-socket-proxy.service"
	echo -e "${CYAN}■ View Status:${NC}     sudo systemctl --machine=${OPENCLAW_USER}@ --user status openclaw.service"
	echo -e "${CYAN}■ View Logs:${NC}       sudo -u ${OPENCLAW_USER} journalctl --user -fu openclaw.service"
}

cmd_onboard() {
	require_cmd systemctl
	# Auto-switch to the openclaw user if run as root
	if [[ "$(id -u)" -eq 0 ]]; then
		info "Switching to '$OPENCLAW_USER' user..."
		_SCRIPT="$(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "$PWD/$0")"
		if ! sudo -u "$OPENCLAW_USER" test -r "$_SCRIPT" 2>/dev/null; then
			_TMP_SCRIPT="$(mktemp /tmp/helpingclaw.XXXXXX.sh)"
			cat "$_SCRIPT" > "$_TMP_SCRIPT"
			chmod 755 "$_TMP_SCRIPT"
			_SCRIPT="$_TMP_SCRIPT"
			_CLEANUP_TMP=1
		fi

		run_as_openclaw "$_SCRIPT" onboard "$@"
		_RET=$?

		if [[ "${_CLEANUP_TMP:-}" == "1" ]]; then
			rm -f "$_SCRIPT"
		fi
		exit $_RET
	fi

	if [[ "$(id -un)" != "$OPENCLAW_USER" ]]; then
		err "Error: This script must be run as '$OPENCLAW_USER' or 'root'."
		exit 1
	fi

	CONFIG_DIR="$OPENCLAW_HOME/.openclaw"
	ENV_FILE="$CONFIG_DIR/.env"
	WORKSPACE_DIR="$CONFIG_DIR/workspace"

	if [[ -f "$ENV_FILE" ]]; then
		set -a
		source "$ENV_FILE" >/dev/null 2>&1
		set +a
		success "Loaded environment configurations."
	fi

	SELINUX_MOUNT_OPTS=""
	if [[ "$(uname -s 2>/dev/null)" == "Linux" ]] && command -v getenforce >/dev/null 2>&1; then
		_selinux_mode="$(getenforce 2>/dev/null)"
		if [[ "$_selinux_mode" == "Enforcing" || "$_selinux_mode" == "Permissive" ]]; then
			SELINUX_MOUNT_OPTS=",Z"
			info "SELinux enforcing detected. Applying :Z labels to volumes."
		fi
	fi

	ENV_FILE_ARGS=()
	if [[ -f "$ENV_FILE" ]]; then
		ENV_FILE_ARGS+=(--env-file "$ENV_FILE")
	fi

	quadlet_container_values() {
		local _key="$1"
		local _file="$2"
		awk -v key="$_key" '
			BEGIN { in_container=0 }
			/^[[:space:]]*\[Container\][[:space:]]*$/ { in_container=1; next }
			/^[[:space:]]*\[[^]]+\][[:space:]]*$/ { in_container=0 }
			in_container && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
				sub(/^[^=]*=[[:space:]]*/, "", $0)
				sub(/[[:space:]]*[#;].*$/, "", $0)
				gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
				if (length($0) > 0) print
			}
		' "$_file"
	}

	QUADLET_FILE="$OPENCLAW_HOME/.config/containers/systemd/openclaw.container"
	if [[ ! -f "$QUADLET_FILE" ]]; then
		err "Quadlet file not found: $QUADLET_FILE"
		err "Please run 'sudo ./helpingclaw.sh deploy' first (or 'setup-sandbox' if sandbox mode is expected)."
		exit 1
	fi

	VOLUME_ARGS=()
	QUADLET_ENV_ARGS=()
	while IFS= read -r _quadlet_volume; do
		VOLUME_ARGS+=( -v "$_quadlet_volume" )
	done < <(quadlet_container_values "Volume" "$QUADLET_FILE")

	while IFS= read -r _quadlet_env; do
		QUADLET_ENV_ARGS+=( -e "$_quadlet_env" )
	done < <(quadlet_container_values "Environment" "$QUADLET_FILE")

	if (( ${#VOLUME_ARGS[@]} > 0 )); then
		info "Onboarding will reuse Quadlet volume mounts from $QUADLET_FILE"
	fi
	if (( ${#QUADLET_ENV_ARGS[@]} > 0 )); then
		info "Onboarding will reuse Quadlet environment entries from $QUADLET_FILE"
	fi

	if (( ${#VOLUME_ARGS[@]} == 0 )); then
		err "No Volume entries found in Quadlet: $QUADLET_FILE"
		err "Please run 'sudo ./helpingclaw.sh deploy' (or 'setup-sandbox') to regenerate a valid quadlet before onboarding."
		exit 1
	fi

	echo ""
	info "Starting OpenClaw Onboarding Wizard..."
	echo "──────────────────────────────────────────────"

	if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
		export XDG_RUNTIME_DIR="/run/user/$(id -u)"
	fi
	_RESTART_SVC=0
	_state="$(systemctl --user show -p ActiveState --value openclaw.service 2>/dev/null)"
	if [[ "$_state" != "inactive" && "$_state" != "failed" ]]; then
		info "Stopping openclaw.service to release SELinux volume locks..."
		systemctl --user stop openclaw.service
		_RESTART_SVC=1
	fi

	podman run --pull=newer --rm -it \
		--init \
		--userns=keep-id \
		--user "$(id -u):$(id -g)" \
		"${VOLUME_ARGS[@]}" \
		"${QUADLET_ENV_ARGS[@]}" \
		-e OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-}" \
		"${ENV_FILE_ARGS[@]}" \
		"$OPENCLAW_IMAGE" \
		node dist/index.js onboard "$@"

	if [[ "$_RESTART_SVC" -eq 1 ]]; then
		info "Restarting openclaw.service..."
		systemctl --user start openclaw.service
	fi
}

cmd_tailscale() {
	require_cmd tailscale
	require_cmd jq
	
	CONFIG_DIR="$OPENCLAW_HOME/.openclaw"
	OPENCLAW_JSON="$CONFIG_DIR/openclaw.json"

	if [[ ! -f "$OPENCLAW_JSON" ]]; then
		err "OpenClaw configuration not found at: $OPENCLAW_JSON"
		err "Please run 'deploy' and 'onboard' first!"
		exit 1
	fi

	echo ""
	info "Automating Tailscale Origin Setup..."
	echo "──────────────────────────────────────────────"

	if ! tailscale status --json | jq -e '.TailscaleIPs | length > 0' >/dev/null 2>&1; then
		warn "Tailscale does not appear to be running or logged in."
		err  "Please verify 'sudo tailscale up' finishes successfully first."
		exit 1
	fi

	TAILNET_DOMAIN="$(tailscale status --json | jq -r '.Self.DNSName')"
	if [[ -z "$TAILNET_DOMAIN" || "$TAILNET_DOMAIN" == "null" ]]; then
		err "Could not resolve a valid Tailscale Domain/MagicDNS name."
		err "Are MagicDNS and HTTPS Certificates enabled in your Tailscale Admin Console?"
		exit 1
	fi

	TAILNET_DOMAIN="${TAILNET_DOMAIN%.}"
	FULL_ORIGIN="https://${TAILNET_DOMAIN}"

	success "Discovered Tailscale Domain: ${BOLD}${FULL_ORIGIN}${NC}"
	info "Patching openclaw.json allowedOrigins configuration..."

	run_as_openclaw bash -c "
		tmp_file=\$(mktemp)
		jq '
			.gateway.controlUi.allowedOrigins = [\"$FULL_ORIGIN\"]
		' \"$OPENCLAW_JSON\" > \"\$tmp_file\"
		
		mv \"\$tmp_file\" \"$OPENCLAW_JSON\"
		chmod 600 \"$OPENCLAW_JSON\"
	"

	success "Whitelisted '$FULL_ORIGIN' inside openclaw.json securely."
	info "Restarting OpenClaw Gateway service to apply new security rules..."
	
	run_root systemctl --machine="${OPENCLAW_USER}@" --user restart openclaw.service

	echo ""
	info "Configuring Tailscale Serve Proxy..."
	if run_root tailscale serve --bg http://127.0.0.1:18789; then
			box_reset
			box_add "${GREEN}✔ TAILSCALE DEPLOYMENT COMPLETE${NC}"
			box_add "OpenClaw is now exposed securely to your private Tailnet directly."
			box_add_empty
			box_add "View the dashboard at: ${BOLD}$FULL_ORIGIN${NC}"
			box_render
	else
			err "Tailscale Serve command failed to configure correctly."
			exit 1
	fi
}

cmd_enter() {
	require_cmd systemctl
	echo ""
	info "Connecting to OpenClaw Container Shell..."
	echo "──────────────────────────────────────────────"

	if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
		export XDG_RUNTIME_DIR="/run/user/$(id -u)"
	fi

	if [[ "$(id -un)" == "$OPENCLAW_USER" ]]; then
		_state="$(systemctl --user show -p ActiveState --value openclaw.service 2>/dev/null)"
	else
		_state="$(run_root systemctl --machine="${OPENCLAW_USER}@" --user show -p ActiveState --value openclaw.service 2>/dev/null)"
	fi
	if [[ "$_state" != "active" ]]; then
		warn "openclaw.service is not currently active! (State: $_state)"
		err "The container must be running to execute a shell inside it."
		if [[ "$(id -un)" == "$OPENCLAW_USER" ]]; then
			err "Try running: systemctl --user start openclaw.service"
		else
			err "Try running: sudo systemctl --machine=${OPENCLAW_USER}@ --user start openclaw.service"
		fi
		exit 1
	fi

	info "Entering 'openclaw' as node user..."
	if [[ "$(id -un)" == "$OPENCLAW_USER" ]]; then
		podman exec -it openclaw bash
	else
		run_as_openclaw podman exec -it openclaw bash
	fi
}

show_help() {
	box_reset
	box_add "${BOLD}HelpingClaw All-In-One Deployment Utility${NC}"
	box_add_empty
	box_add "Usage: ${CYAN}./helpingclaw.sh [command]${NC}"
	box_add_empty
	box_add "${YELLOW}Commands:${NC}"
	box_add "  ${CYAN}deploy${NC}         Install OpenClaw, create quadlet, & start user daemon."
	box_add "  ${CYAN}setup-sandbox${NC}  Configure sandbox runtime, update quadlet, & restart service."
	box_add "  ${CYAN}onboard${NC}     Launch interactive API wizard inside an ephemeral container."
	box_add "  ${CYAN}tailscale${NC}   Auto-whitelist origin domain and securely expose dashboard."
	box_add "  ${CYAN}enter${NC}       Open an interactive bash shell inside the running container."
	box_render
	exit 1
}

# ==========================================
# 3. CLI ROUTING
# ==========================================

COMMAND="${1:-help}"
if [[ $# -gt 0 ]]; then
	shift
fi

case "$COMMAND" in
	deploy)
		cmd_deploy "$@"
		;;
	setup-sandbox)
		cmd_setup_sandbox "$@"
		;;
	onboard)
		cmd_onboard "$@"
		;;
	tailscale)
		cmd_tailscale "$@"
		;;
	enter)
		cmd_enter "$@"
		;;
	help|--help|-h)
		show_help
		;;
	*)
		err "Unknown command: $COMMAND"
		show_help
		;;
esac
