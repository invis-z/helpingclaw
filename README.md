# OpenClaw HelpingClaw Deployment Utility

`helpingclaw.sh` is an all-in-one unified setup script that manages the entire OpenClaw rootless Podman deployment process from a single interface. 

It completely automates user space creation, systemd quadlet generation, interactive Signal/API onboarding, and secure Tailscale HTTPS reverse proxy exposure.

## Prerequisites
- **Podman**: Must be installed on your host system.
- **Sudo / Root Access**: Required to create the `openclaw` system user and systemd directories.

---

## Step 1: Deploy the Gateway Environment

The `deploy` command automatically detects your environment (including immutable OS logic like `/var/home` and SELinux bindings) and scaffolds the OpenClaw service securely.

### Standard Linux (Debian, Ubuntu, Fedora, etc.)
```bash
sudo ./helpingclaw.sh deploy
```

**What the deploy command does:**
1. Creates an isolated `openclaw` system user to securely run the rootless containers.
2. Scaffolds configuration (`~/.openclaw/openclaw.json`) and workspace directories.
3. Generates a secure API Token in `~/.openclaw/.env`.
4. Writes a `systemd` Quadlet (`openclaw.container`) that instructs Podman to:
   - Always pull and run the latest `ghcr.io/openclaw/openclaw:main` image.
   - Update automatically via `podman-auto-update.timer`.
   - Mount volumes securely based on your OS SELinux posture.
   - Bind HTTP ports `18789` strictly to `127.0.0.1` so the dashboard is not public.
5. Starts the core `openclaw.service` under the user daemon.

---

## Step 2: Run the Setup Wizard

Because the main Gateway container is running as an immutable background systemd service mapped to `localhost`, you must interact with the setup wizard using a temporary short-lived container. 

The `onboard` command seamlessly handles dropping down to the `openclaw` user and injecting the wizard.

```bash
# You can run this directly as your normal user if you have sudo privileges,
# or as root. The script safely drops down to the openclaw user automatically.
sudo ./helpingclaw.sh onboard
```

Follow the prompts within the terminal to seamlessly provide your API keys for your preferred providers (e.g. OpenAI, Anthropic) or link your Signal number. This wizard automatically writes the configuration into your `~/.openclaw` directory, which the main Gateway container instantly reads in real-time.

---

## Step 3: Expose Dashboard via Tailscale Serve

Because the Quadlet runs OpenClaw locally on `127.0.0.1:18789` for security, you can directly expose the dashboard securely through your Tailscale network. Tailscale automatically provisions a Let's Encrypt certificate for your Tailnet machine name and terminates HTTPS traffic natively.

Additionally, OpenClaw's Control UI security requires explicitly whitelisting your exact Tailscale domain origin to prevent CSRF attacks. 

### Prerequisites for automation:
Before running the script, ensure your system is connected to your Tailnet and that HTTPS is enabled in your Tailscale Admin Console:
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

**What this script does:**
1. Dynamically resolves your machine's exact Tailscale MagicDNS domain name.
2. Securely injects that full domain into `openclaw.json`'s strict `allowedOrigins` whitelist.
3. Rapidly restarts the OpenClaw service so the security rules lock into place immediately.
4. Executes `sudo tailscale serve --bg http://127.0.0.1:18789` to establish the reverse proxy.

Your OpenClaw dashboard will then be instantly available securely on port 443 via HTTPS at your private Tailscale domain!

---

## Step 4: Access the Shell (Optional)

If you ever need to natively poke around or evaluate state inside the OpenClaw podman container, it can be extremely tricky navigating execution escalation contexts. 

The `enter` command evaluates your current connection state and handles the entire `systemctl` lookup context parsing automatically.

```bash
sudo ./helpingclaw.sh enter
```
It immediately drops you into an interactive bash shell locked securely within `openclaw-container`.

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

---

## Acknowledgments

The `helpingclaw.sh` unified deployment utility and this documentation were developed in collaboration with **Antigravity**, an advanced agentic AI coding assistant designed by Google Deepmind.
