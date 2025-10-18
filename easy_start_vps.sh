#!/bin/bash
# VPS Setup Script - автоматическая настройка нового сервера
# Автор: <Funnnik>
# Версия: 1.0

set -e  # остановить скрипт при ошибке

# Проверка прав
if [ "$EUID" -ne 0 ]; then
  echo "❌ Запусти этот скрипт от root: sudo bash vps-setup.sh"
  exit 1
fi

echo "🚀 Начинаем настройку сервера..."

# --- Обновление ОС ---
echo "📦 Обновляем систему..."
apt update && apt upgrade -y
apt install curl iptables-persistent ufw -y

# --- Настройка UFW ---
echo "🧱 Настройка UFW..."
ufw default deny incoming
ufw default allow outgoing
ufw allow from 62.105.44.145/29 to any port 22
ufw allow from 188.0.160.0/19 to any port 22
ufw logging on
ufw enable

# --- Настройка iptables ---
echo "⚙️ Настройка iptables..."
iptables -A INPUT -p icmp --icmp-type echo-request -j DROP
iptables -I INPUT -p icmp --icmp-type echo-request -s 62.105.44.145/29 -j ACCEPT
iptables -I INPUT -p icmp --icmp-type echo-request -s 188.0.160.0/19 -j ACCEPT
netfilter-persistent save
systemctl enable netfilter-persistent

# --- Настройка DoH (DNS over HTTPS) ---
echo "🌐 Настройка DNS over HTTPS (DoH)..."
RESOLVED_CONF="/etc/systemd/resolved.conf"
sed -i '/^\[Resolve\]/q' $RESOLVED_CONF 2>/dev/null || echo "[Resolve]" > $RESOLVED_CONF
cat <<EOF > $RESOLVED_CONF
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

# --- Включение BBR ---
echo "⚡ Включаем TCP BBR..."
SYSCTL_CONF="/etc/sysctl.conf"
grep -q "tcp_congestion_control=bbr" $SYSCTL_CONF || cat <<EOF >> $SYSCTL_CONF

# Enable BBR congestion control
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl -p

# --- Установка Fail2ban ---
echo "🔐 Устанавливаем Fail2Ban..."
apt install fail2ban -y
systemctl enable fail2ban
systemctl start fail2ban

# --- Финальное сообщение ---
echo "✅ Настройка завершена!"
echo "Если ты только что установил Docker, выйди и снова войди в систему, чтобы применить группу docker."
echo "Рекомендуется перезагрузить сервер: sudo reboot"
