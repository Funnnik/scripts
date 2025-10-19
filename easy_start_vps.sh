#!/bin/bash
# ==============================================================
# VPS Initial Setup Script
# Автор: Funnnik
# Назначение: Автоматическая настройка нового VPS
# Совместимость: Ubuntu 22.04 / 24.04+
# Версия: 1.2
# ==============================================================

set -e

# --- Проверка прав ---
if [ "$EUID" -ne 0 ]; then
  echo "❌ Этот скрипт нужно запускать от root. Используй: sudo bash $0"
  exit 1
fi

echo "🚀 Начинаем автоматическую настройку сервера..."

# --- Обновление системы ---
echo "📦 Проверяем обновления пакетов..."
apt list --upgradable || true
sleep 3

echo "📦 Обновляем систему..."
apt update && apt upgrade -y
apt autoclean && apt autoremove -y
apt install -y curl ufw fail2ban htop
snap install speedtest

# --- Настройка UFW ---
echo "🧱 Настраиваем UFW (фаервол)..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# Разрешаем SSH только с доверенных подсетей
ufw allow from 62.105.44.145/29 to any port ssh
ufw allow from 188.0.160.0/19 to any port ssh

# --- Настройка ICMP (ping) ---
echo "⚙️ Настраиваем ICMP (ping) ограничения..."
UFW_RULES="/etc/ufw/before.rules"
if grep -q "# ok icmp codes for INPUT" "$UFW_RULES"; then
  if ! grep -q "Custom ICMP filtering" "$UFW_RULES"; then
    sed -i '/# ok icmp codes for INPUT/a \
# --- Custom ICMP filtering ---\n\
-A ufw-before-input -p icmp --icmp-type echo-request -s 62.105.44.145/29 -j ACCEPT\n\
-A ufw-before-input -p icmp --icmp-type echo-request -s 188.0.160.0/19 -j ACCEPT\n\
-A ufw-before-input -p icmp --icmp-type echo-request -j DROP\n\
# --- End custom ICMP filtering ---' "$UFW_RULES"
  fi
fi

ufw logging on
ufw --force enable

# --- Настройка DNS over HTTPS ---
echo "🌐 Настраиваем DNS over HTTPS (DoH)..."
RESOLVED_CONF="/etc/systemd/resolved.conf"
cat <<EOF > "$RESOLVED_CONF"
[Resolve]
DNS=1.1.1.1#cloudflare-dns.com 8.8.8.8#dns.google
DNSOverTLS=yes
EOF

systemctl daemon-reload
systemctl restart systemd-resolved
systemctl enable systemd-resolved

# --- Установка Docker ---
echo "🐳 Устанавливаем Docker..."
curl -fsSL https://get.docker.com | sh
usermod -aG docker $SUDO_USER || true

# --- Сетевые оптимизации и BBR ---
echo "⚡ Применяем оптимизацию сети (VPN tuning)..."
sudo tee /etc/sysctl.d/99-vpn-tuning.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.core.rmem_max = 2500000
net.core.wmem_max = 2500000
net.ipv4.tcp_rmem = 4096 87380 2500000
net.ipv4.tcp_wmem = 4096 65536 2500000
net.ipv4.tcp_fastopen = 3
EOF

sudo sysctl --system

# --- Установка Fail2Ban ---
echo "🔐 Устанавливаем и настраиваем Fail2Ban..."
apt install -y fail2ban
systemctl enable fail2ban
systemctl start fail2ban

# --- 🛠 Смена Hostname на localhost---
cp /etc/hosts /etc/hosts.backup
hostnamectl set-hostname localhost
tee /etc/hosts > /dev/null <<EOF
127.0.0.1   localhost
127.0.1.1   localhost
EOF

echo "Готово! Hostname: $(hostname)"
echo "Проверь PTR!"
echo "Бэкап: /etc/hosts.backup"

# --- Финал ---
echo ""
echo "✅ Настройка завершена успешно!"
echo "Рекомендуется выполнить: sudo reboot"
