#!/bin/bash
# ==============================================================
# VPS Initial Setup Script
# Автор: Funnnik
# Назначение: Автоматическая настройка нового VPS
# Совместимость: Ubuntu 22.04 / 24.04+
# Версия: 1.1
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
apt install -y curl ufw fail2ban nano htop

# --- Настройка UFW ---
echo "🧱 Настраиваем UFW (фаервол)..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# Разрешаем SSH только с доверенных подсетей
ufw allow from 62.105.44.145/29 to any port 22
ufw allow from 188.0.160.0/19 to any port 22

# Разрешаем пинг (ICMP) только с этих же подсетей
echo "⚙️ Настраиваем ICMP (ping) через before.rules..."
UFW_RULES="/etc/ufw/before.rules"
if ! grep -q "ufw-before-input" "$UFW_RULES"; then
  echo "Файл before.rules отсутствует — пропускаем настройку ICMP."
else
  # Добавим правила, если их нет
  grep -q "icmp --icmp-type echo-request" "$UFW_RULES" || cat <<EOF >> "$UFW_RULES"

# --- Custom ICMP rules (added by setup script) ---
-A ufw-before-input -p icmp --icmp-type echo-request -s 62.105.44.145/29 -j ACCEPT
-A ufw-before-input -p icmp --icmp-type echo-request -s 188.0.160.0/19 -j ACCEPT
-A ufw-before-input -p icmp --icmp-type echo-request -j DROP
# --- End custom ICMP rules ---
EOF
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

# --- Включение TCP BBR ---
echo "⚡ Включаем TCP BBR..."
SYSCTL_CONF="/etc/sysctl.conf"
if ! grep -q "tcp_congestion_control=bbr" "$SYSCTL_CONF"; then
  cat <<EOF >> "$SYSCTL_CONF"

# Enable BBR congestion control
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
fi
sysctl -p

# --- Установка Fail2Ban ---
echo "🔐 Устанавливаем и настраиваем Fail2Ban..."
apt install -y fail2ban
systemctl enable fail2ban
systemctl start fail2ban

# --- Финал ---
echo ""
echo "✅ Настройка завершена успешно!"
echo "Рекомендуется выполнить: sudo reboot"
echo "После перезагрузки Docker будет доступен без sudo."
