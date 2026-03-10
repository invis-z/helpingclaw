#!/usr/bin/env bash
# HelpingClaw All-In-One OpenClaw Setup Utility
# Usage: ./helpingclaw.sh [command]

set -euo pipefail

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
export OPENCLAW_IMAGE="${OPENCLAW_IMAGE:-ghcr.io/openclaw/openclaw:main}"

resolve_user_home() {
	local user="$1"
	local home=""
	if command -v getent >/dev/null 2>&1; then
		home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)"
	fi
	if [[ -z "$home" && -f /etc/passwd ]]; then
		home="$(awk -F: -v u="$user" '$1==u {print $6}' /etc/passwd 2>/dev/null || true)"
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

	user_exists() {
		local user="$1"
		if command -v getent >/dev/null 2>&1; then
			getent passwd "$user" >/dev/null 2>&1 && return 0
		fi
		id -u "$user" >/dev/null 2>&1
	}

	resolve_nologin_shell() {
		for cand in /usr/sbin/nologin /sbin/nologin /usr/bin/nologin /bin/false; do
			if [[ -x "$cand" ]]; then printf '%s' "$cand"; return 0; fi
		done
		printf '%s' "/usr/sbin/nologin"
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
	OPENCLAW_UID="$(id -u "$OPENCLAW_USER" 2>/dev/null || true)"
	OPENCLAW_CONFIG="$OPENCLAW_HOME/.openclaw"

	if command -v loginctl &>/dev/null; then run_root loginctl enable-linger "$OPENCLAW_USER" || true; fi

	if [[ -n "${OPENCLAW_UID:-}" && -d /run/user ]] && command -v systemctl &>/dev/null; then
		run_root systemctl start "user@${OPENCLAW_UID}.service" || true
	fi

	if ! grep -q "^${OPENCLAW_USER}:" /etc/subuid 2>/dev/null; then
		warn "User '$OPENCLAW_USER' has no subuid range. Rootless Podman may fail."
		warn "Consider running: sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $OPENCLAW_USER"
	fi

	info "Creating configuration directories at: $OPENCLAW_CONFIG"
	run_as_openclaw mkdir -p "$OPENCLAW_CONFIG/workspace" "$OPENCLAW_HOME/.local/share/signal-cli"
	run_as_openclaw chmod 700 "$OPENCLAW_CONFIG" "$OPENCLAW_CONFIG/workspace" "$OPENCLAW_HOME/.local/share/signal-cli" || true

	ENV_FILE="$OPENCLAW_CONFIG/.env"
	if run_as_openclaw test -f "$ENV_FILE"; then
		run_as_openclaw chmod 600 "$ENV_FILE" || true
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
		run_as_openclaw chmod 600 "$ENV_FILE" || true
		success "Created environment file $ENV_FILE with new token."
	fi

	OPENCLAW_JSON="$OPENCLAW_CONFIG/openclaw.json"
	if ! run_as_openclaw test -f "$OPENCLAW_JSON"; then
		printf '%s\n' '{ gateway: { mode: "local" } }' | run_as_openclaw tee "$OPENCLAW_JSON" >/dev/null
		run_as_openclaw chmod 600 "$OPENCLAW_JSON" || true
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
Volume=$OPENCLAW_CONFIG:/home/node/.openclaw:Z
Volume=$OPENCLAW_HOME/.local/share/signal-cli:/home/node/.local/share/signal-cli:Z
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

	run_as_openclaw chmod 700 "$OPENCLAW_HOME/.config" "$OPENCLAW_HOME/.config/containers" "$QUADLET_DIR" || true
	run_as_openclaw chmod 600 "$QUADLET_DIR/openclaw.container" || true
	success "Systemd Quadlet successfully written to $QUADLET_DIR/openclaw.container"

	if command -v systemctl &>/dev/null; then
		# Fix for Podman #24796: user-wait-network-online hangs if network-online.target isn't wanted by any system unit
		_net_deps="$(systemctl list-dependencies network-online.target --reverse --no-pager 2>/dev/null | wc -l || true)"
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
			run_root systemctl daemon-reload || true
			run_root systemctl enable --now podman-network-wait-dummy.service || true
		fi

		info "Configuring and starting user systemd service 'openclaw.service'..."
		run_root systemctl --machine="${OPENCLAW_USER}@" --user daemon-reload || true
		run_root systemctl --machine="${OPENCLAW_USER}@" --user start openclaw.service || true
		info "Enabling Podman auto-update timers for user '${OPENCLAW_USER}'..."
		run_root systemctl --machine="${OPENCLAW_USER}@" --user enable podman-auto-update.timer || true
		run_root systemctl --machine="${OPENCLAW_USER}@" --user start podman-auto-update.timer || true
		success "Systemd services have been started and enabled."
	fi

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


}

cmd_onboard() {
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
		source "$ENV_FILE" >/dev/null 2>&1 || true
		set +a
		success "Loaded environment configurations."
	fi

	SELINUX_MOUNT_OPTS=""
	if [[ "$(uname -s 2>/dev/null)" == "Linux" ]] && command -v getenforce >/dev/null 2>&1; then
		_selinux_mode="$(getenforce 2>/dev/null || true)"
		if [[ "$_selinux_mode" == "Enforcing" || "$_selinux_mode" == "Permissive" ]]; then
			SELINUX_MOUNT_OPTS=",Z"
			info "SELinux enforcing detected. Applying :Z labels to volumes."
		fi
	fi

	ENV_FILE_ARGS=()
	if [[ -f "$ENV_FILE" ]]; then
		ENV_FILE_ARGS+=(--env-file "$ENV_FILE")
	fi

	echo ""
	info "Starting OpenClaw Onboarding Wizard..."
	echo "──────────────────────────────────────────────"

	if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
		export XDG_RUNTIME_DIR="/run/user/$(id -u)"
	fi
	_RESTART_SVC=0
	if command -v systemctl &>/dev/null; then
		_state="$(systemctl --user show -p ActiveState --value openclaw.service 2>/dev/null || echo unknown)"
		if [[ "$_state" != "inactive" && "$_state" != "failed" ]]; then
			info "Stopping openclaw.service to release SELinux volume locks..."
			systemctl --user stop openclaw.service || true
			_RESTART_SVC=1
		fi
	fi

	podman run --pull=newer --rm -it \
		--init \
		--userns=keep-id \
		--user "$(id -u):$(id -g)" \
		-e HOME=/home/node \
		-e XDG_DATA_HOME=/home/node/.local/share \
		-e TERM=xterm-256color \
		-e BROWSER=echo \
		-e OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-}" \
		-v "$CONFIG_DIR:/home/node/.openclaw:rw${SELINUX_MOUNT_OPTS}" \
		-v "$OPENCLAW_HOME/.local/share/signal-cli:/home/node/.local/share/signal-cli:rw${SELINUX_MOUNT_OPTS}" \
		"${ENV_FILE_ARGS[@]}" \
		"$OPENCLAW_IMAGE" \
		node dist/index.js onboard "$@"

	if [[ "$_RESTART_SVC" -eq 1 ]]; then
		info "Restarting openclaw.service..."
		systemctl --user start openclaw.service || true
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

	TAILNET_DOMAIN="$(tailscale status --json | jq -r '.Self.DNSName' || true)"
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
	
	run_root systemctl --machine="${OPENCLAW_USER}@" --user restart openclaw.service || {
			warn "systemctl restart failed! Service might not be running yet."
	}

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
	echo ""
	info "Connecting to OpenClaw Container Shell..."
	echo "──────────────────────────────────────────────"

	if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
		export XDG_RUNTIME_DIR="/run/user/$(id -u)"
	fi

	if command -v systemctl &>/dev/null; then
		if [[ "$(id -un)" == "$OPENCLAW_USER" ]]; then
			_state="$(systemctl --user show -p ActiveState --value openclaw.service 2>/dev/null || echo unknown)"
		else
			_state="$(run_root systemctl --machine="${OPENCLAW_USER}@" --user show -p ActiveState --value openclaw.service 2>/dev/null || echo unknown)"
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
	box_add "  ${CYAN}deploy${NC}      Install OpenClaw, create quadlet, & start user daemon."
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
shift || true

case "$COMMAND" in
	deploy)
		cmd_deploy "$@"
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
