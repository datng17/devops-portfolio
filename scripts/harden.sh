#!/usr/bin/env bash
# devops-portfolio/scripts/harden.sh
# Baseline Linux hardening for AWS EC2 (Ubuntu/Debian + RHEL/Amazon Linux).
# SSH key-only auth, UFW/firewalld rules, fail2ban, kernel sysctl tuning.
# Run as root. Idempotent / re-runnable.
set -euo pipefail

ADMIN="${ADMIN_USER:-deploy}"
SSH_PORT="${SSH_PORT:-22}"

# ---- OS detection -----------------------------------------------------------
if command -v apt-get >/dev/null 2>&1; then
  PKG="apt"
elif command -v dnf >/dev/null 2>&1; then
  PKG="dnf"
elif command -v yum >/dev/null 2>&1; then
  PKG="yum"
else
  echo "[!] Unsupported package manager" >&2
  exit 1
fi
echo "[*] Detected package manager: $PKG"

pkg_update() {
  case "$PKG" in
    apt) apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y ;;
    dnf) dnf -y upgrade --refresh ;;
    yum) yum -y update ;;
  esac
}

pkg_install() {
  case "$PKG" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    dnf) dnf -y install "$@" ;;
    yum) yum -y install "$@" ;;
  esac
}

echo "[*] Updating packages"
pkg_update

# ---- Admin user (key-only sudo) --------------------------------------------
echo "[*] Ensuring admin user '$ADMIN' exists"
if ! id "$ADMIN" &>/dev/null; then
  if [ "$PKG" = "apt" ]; then
    adduser --disabled-password --gecos "" "$ADMIN"
  else
    adduser "$ADMIN"
    passwd -l "$ADMIN"   # lock password; key-only
  fi
fi
# sudo group differs across distros
if getent group sudo >/dev/null 2>&1; then
  usermod -aG sudo "$ADMIN"
else
  usermod -aG wheel "$ADMIN"
fi
install -d -m 700 -o "$ADMIN" -g "$ADMIN" "/home/$ADMIN/.ssh"
touch "/home/$ADMIN/.ssh/authorized_keys"
chmod 600 "/home/$ADMIN/.ssh/authorized_keys"
chown "$ADMIN:$ADMIN" "/home/$ADMIN/.ssh/authorized_keys"
# NOTE: paste the deploy public key into authorized_keys out-of-band before
# closing your current session, or you will be locked out.

# ---- SSH hardening (key-only) ----------------------------------------------
echo "[*] SSH hardening (key-only auth)"
SSHD=/etc/ssh/sshd_config
cp -n "$SSHD" "${SSHD}.bak.$(date +%Y%m%d%H%M%S)" || true
set_sshd() {
  local key="$1" val="$2"
  if grep -qiE "^\s*#?\s*${key}\b" "$SSHD"; then
    sed -i "s|^\s*#\?\s*${key}\b.*|${key} ${val}|I" "$SSHD"
  else
    echo "${key} ${val}" >> "$SSHD"
  fi
}
set_sshd "Port"                    "$SSH_PORT"
set_sshd "PermitRootLogin"         "no"
set_sshd "PasswordAuthentication"  "no"
set_sshd "ChallengeResponseAuthentication" "no"
set_sshd "KbdInteractiveAuthentication"    "no"
set_sshd "PubkeyAuthentication"    "yes"
set_sshd "PermitEmptyPasswords"    "no"
set_sshd "X11Forwarding"           "no"
set_sshd "MaxAuthTries"            "3"
set_sshd "LoginGraceTime"          "30"
set_sshd "ClientAliveInterval"     "300"
set_sshd "ClientAliveCountMax"     "2"
sshd -t   # validate before restart
systemctl restart sshd 2>/dev/null || systemctl restart ssh

# ---- Firewall ---------------------------------------------------------------
if command -v ufw >/dev/null 2>&1 || [ "$PKG" = "apt" ]; then
  echo "[*] Firewall via UFW (default deny inbound)"
  pkg_install ufw
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "${SSH_PORT}/tcp"
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw --force enable
else
  echo "[*] Firewall via firewalld (default deny inbound)"
  pkg_install firewalld
  systemctl enable --now firewalld
  firewall-cmd --permanent --add-port="${SSH_PORT}/tcp"
  firewall-cmd --permanent --add-service=http
  firewall-cmd --permanent --add-service=https
  firewall-cmd --reload
fi

# ---- fail2ban ---------------------------------------------------------------
echo "[*] fail2ban for SSH brute-force protection"
pkg_install fail2ban
cat >/etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled  = true
port     = ${SSH_PORT}
maxretry = 3
EOF
systemctl enable --now fail2ban
systemctl restart fail2ban

# ---- Kernel sysctl tuning ---------------------------------------------------
echo "[*] Kernel network + security hardening"
cat >/etc/sysctl.d/99-hardening.conf <<'EOF'
# --- Spoofing / routing protection ---
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.default.accept_source_route=0
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.secure_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
net.ipv6.conf.all.accept_redirects=0
net.ipv6.conf.all.accept_source_route=0

# --- ICMP / broadcast ---
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.icmp_ignore_bogus_error_responses=1

# --- TCP hardening ---
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_max_syn_backlog=2048
net.ipv4.tcp_synack_retries=2
net.ipv4.tcp_syn_retries=5

# --- Logging martians ---
net.ipv4.conf.all.log_martians=1

# --- Memory / ASLR ---
kernel.randomize_va_space=2
kernel.kptr_restrict=2
kernel.dmesg_restrict=1
fs.protected_hardlinks=1
fs.protected_symlinks=1
EOF
sysctl --system

# ---- Automatic security updates --------------------------------------------
echo "[*] Automatic security updates"
if [ "$PKG" = "apt" ]; then
  pkg_install unattended-upgrades
  dpkg-reconfigure -f noninteractive unattended-upgrades
else
  pkg_install dnf-automatic || pkg_install yum-cron || true
  systemctl enable --now dnf-automatic.timer 2>/dev/null || \
    systemctl enable --now yum-cron 2>/dev/null || true
fi

echo "[+] Hardening complete."
echo "[!] Verify SSH key access in a NEW session (port ${SSH_PORT}) BEFORE closing this one."
