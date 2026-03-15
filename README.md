# OpenClaw HelpingClaw Deployment Utility

`helpingclaw.sh` is an all-in-one setup script that manages an OpenClaw rootless Podman deployment from a single interface.

It automates service-user provisioning, sandbox socket setup, Quadlet generation, interactive onboarding, and optional Tailscale HTTPS exposure.

## Prerequisites
- **Podman**: Must be installed on your host system.
- **Sudo / Root Access**: Required for the `deploy`, `setup-sandbox`, and `tailscale` flows.
- **jq**: Required for the `setup-sandbox` and `tailscale` commands.
- **socat**: Required for the sandbox Docker socket proxy service.
- **Tailscale**: Only required if you want to publish the dashboard over your Tailnet.

---

## Step 1: Deploy the Gateway Environment

The `deploy` command detects your environment, creates the required service account, and scaffolds the baseline OpenClaw runtime for a rootless Podman installation.

### Standard Linux (Debian, Ubuntu, Fedora, etc.)
```bash
sudo ./helpingclaw.sh deploy
```

**What the deploy command does:**
1. Creates an isolated `openclaw` system user to securely run the rootless containers.
2. Scaffolds configuration in `~/.openclaw`, including `openclaw.json`, `.env`, and the default workspace directory.
3. Generates an `OPENCLAW_GATEWAY_TOKEN` in `~/.openclaw/.env` if one does not already exist.
4. Writes a user Quadlet at `~/.config/containers/systemd/openclaw.container` that:
   - Pulls and runs `ghcr.io/invis-z/lobster:latest` by default.
   - Enables registry-based auto-updates via `podman-auto-update.timer`.
   - Mounts the OpenClaw config and Signal data directory.
   - Publishes ports `127.0.0.1:18789` and `127.0.0.1:18790` locally.
5. Starts the `openclaw.service` user unit and enables the relevant lingering and auto-update timers.
6. Computes the host UID/GID that map to container uid/gid `1000` from `/etc/subuid` and `/etc/subgid`, then applies ownership to:
   - `~/.openclaw`
   - `~/data/local/share/signal-cli`

---

## Step 2: Configure the Sandbox Runtime

The `setup-sandbox` command manages the separate rootless Podman user that backs OpenClaw's sandbox runtime, updates the gateway config, and rewrites the Quadlet to mount the sandbox socket.

```bash
sudo ./helpingclaw.sh setup-sandbox
```

**What the setup-sandbox command does:**
1. Creates a dedicated `sandcastle` sandbox user and `sandcastle-crew` shared group, unless you override them with environment variables.
2. Configures the sandbox user's Podman socket permissions while keeping the default rootless socket path.
3. Configures OpenClaw to use the fully qualified sandbox image `ghcr.io/invis-z/lobster-sandcastle:bookworm-slim` by default, or `OPENCLAW_SANDBOX_DOCKER_IMAGE` if you override it.
4. Adds the main `openclaw` user to the sandbox group so the gateway can reach the socket.
5. Creates a sandbox workspace source at `~sandcastle/sandboxes` (owned by the sandbox user) and an idmapped mountpoint at `~openclaw/sandboxes` (visible to the openclaw user).
6. Writes a system mount unit for the sandbox workspace idmapped bind mount and enables it immediately.
7. Writes a `user@<openclaw-uid>.service.d` drop-in to order the openclaw user manager after the workspace mount and applies it immediately.
8. Updates `openclaw.json` with sandbox defaults including `agents.defaults.sandbox.workspaceRoot=~sandcastle/sandboxes` and `agents.defaults.sandbox.docker.image`.
9. Rewrites `openclaw.container` to mount the sandbox proxy socket and workspace mapping:
   - Host proxy dir: `/run/openclaw-sandbox/podman`
   - In-container proxy socket: `/var/run/openclaw-sandbox/docker.sock`
10. Re-applies host ownership mapped from container uid/gid `1000` (derived from `/etc/subuid` + `/etc/subgid`) to `~/.openclaw` and `~/data/local/share/signal-cli` after config updates.
11. Installs/enables the system proxy service `openclaw-sandbox-socket-proxy.service` immediately.
12. Reloads `openclaw` user systemd and restores `openclaw.service` if it was active before setup.

### Sandbox configuration notes

- The generated gateway config points OpenClaw at the sandbox Docker socket via `DOCKER_HOST=unix:///var/run/openclaw-sandbox/docker.sock`.
- The default sandbox image is a fully qualified GHCR reference to avoid Podman short-name resolution issues.
- If you tune upstream OpenClaw sandbox Docker limits manually, prefer setting an explicit `agents.defaults.sandbox.docker.pidsLimit` and leave `memorySwap` unset on hosts that do not expose the swap controller in the delegated rootless cgroup.

---

## Step 3: Run the Setup Wizard

Because the main gateway container runs as a background user service, the onboarding flow uses a temporary container for the interactive setup wizard.

The `onboard` command handles switching to the `openclaw` user when needed, loads the existing environment file, temporarily stops the service if necessary, and then launches the wizard container with the correct mounts.

```bash
# You can run this directly as your normal user if you have sudo privileges,
# or as root. The script safely drops down to the openclaw user automatically.
sudo ./helpingclaw.sh onboard
```

Follow the prompts to provide your provider credentials or configure Signal. The wizard writes directly into `~/.openclaw`, and the script restarts the user service afterward if it had to stop it first.

---

## Step 4: Expose Dashboard via Tailscale Serve

Because the Quadlet binds OpenClaw locally on `127.0.0.1`, you can expose the dashboard securely through your Tailscale network. Tailscale provisions the certificate for your Tailnet machine name and terminates HTTPS traffic natively.

Additionally, OpenClaw's Control UI security requires explicitly whitelisting your exact Tailscale domain origin to prevent CSRF attacks. 

### Prerequisites for automation
Before running the script, ensure your system is connected to your Tailnet and that HTTPS is enabled in your Tailscale admin console:
```bash
# 1. Ensure Tailscale is installed and connected
sudo tailscale up

# 2. In your Tailscale Admin Console (https://login.tailscale.com/admin/dns):
#    - Enable "MagicDNS"
#    - Enable "HTTPS Certificates"
```

Once confirmed, the `tailscale` command completely automates the rest of the reverse proxy setup:

```bash
sudo ./helpingclaw.sh tailscale
```

**What the `tailscale` command does:**
1. Dynamically resolves your machine's exact Tailscale MagicDNS domain name.
2. Securely injects that full domain into `openclaw.json`'s strict `allowedOrigins` whitelist.
3. Rapidly restarts the OpenClaw service so the security rules lock into place immediately.
4. Executes `sudo tailscale serve --bg http://127.0.0.1:18789` to establish the reverse proxy.

Your OpenClaw dashboard will then be instantly available securely on port 443 via HTTPS at your private Tailscale domain!

---

## Step 5: Access the Shell (Optional)

If you need to inspect the running OpenClaw container directly, the `enter` command checks that the user service is active and then opens an interactive shell inside the container.

```bash
sudo ./helpingclaw.sh enter
```
It immediately drops you into an interactive bash shell inside the running `openclaw` container.

---

## Managing the Service Manually

Because OpenClaw is running as a **user systemd service** under the `openclaw` user space, and not as a traditional root service, you must use `--machine=openclaw@` to interact with it natively from normal prompts:

**Check Status**:
```bash
sudo systemctl --machine=openclaw@ --user status openclaw.service
```

**View Service Logs**:
```bash
sudo -u openclaw journalctl --user -fu openclaw.service
```

**Restart the Service**:
```bash
sudo systemctl --machine=openclaw@ --user restart openclaw.service
```

**Open a Shell in the Running Container**:
```bash
sudo ./helpingclaw.sh enter
```

---

## Acknowledgments

The `helpingclaw.sh` unified deployment utility and this documentation were developed in collaboration with **Antigravity**, an advanced agentic AI coding assistant designed by Google Deepmind, and **GitHub Copilot** using **GPT-5.4** and **Claude Sonnet 4.6**.
