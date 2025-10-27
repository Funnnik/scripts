#!/bin/bash
set -e

echo "🚀 Подготовка VPS Debian 12 к работе..."

# --- Проверка прав ---
if [ "$EUID" -ne 0 ]; then
  echo "❌ Скрипт нужно запускать от root"
  exit 1
fi

# --- Обновление системы ---
echo "🧩 Обновляем систему..."
apt update && apt upgrade -y && apt autoremove -y

# --- Бэкап важных файлов ---
echo "📦 Делаем бэкап /etc/hosts и /etc/resolv.conf..."
cp /etc/hosts /etc/hosts.backup_$(date +%F)
cp /etc/resolv.conf /etc/resolv.conf.backup_$(date +%F)

# --- Настройка UFW ---
echo "🛡️ Настраиваем UFW..."
apt install -y ufw

ufw default deny incoming
ufw default allow outgoing

# Разрешаем SSH только из доверенных сетей
ufw allow from 62.105.44.144/29 to any port 22 proto tcp
ufw allow from 188.0.160.0/19 to any port 22 proto tcp

# Разрешаем VPN-порт (Amnezia WG Easy)
ufw allow 46461/udp

# Веб-панель Amnezia WG Easy — только для доверенных IP
ufw allow from 62.105.44.144/29 to any port 37238 proto tcp
ufw allow from 188.0.160.0/19 to any port 37238 proto tcp
ufw deny 37238/tcp

# Включаем UFW
ufw --force enable

# --- ICMP (пинг) фильтрация ---
echo "🚫 Блокируем пинг для всех, кроме доверенных сетей..."
iptables -A INPUT -p icmp --icmp-type echo-request -j DROP
iptables -I INPUT -p icmp --icmp-type echo-request -s 62.105.44.144/29 -j ACCEPT
iptables -I INPUT -p icmp --icmp-type echo-request -s 188.0.160.0/19 -j ACCEPT

# --- Сохранение правил iptables ---
echo "💾 Сохраняем правила iptables..."
apt install -y iptables-persistent netfilter-persistent
netfilter-persistent save
systemctl enable netfilter-persistent

# --- Настройка DNS-over-HTTPS (через systemd-resolved) ---
echo "🔐 Настраиваем DNS-over-HTTPS..."
apt install -y systemd-resolved
mkdir -p /etc/systemd/resolved.conf.d
cat <<'EOF' >/etc/systemd/resolved.conf
[Resolve]
DNS=1.1.1.1#cloudflare-dns.com 8.8.8.8#dns.google
DNSOverTLS=yes
EOF

systemctl daemon-reexec
systemctl restart systemd-resolved

# --- Установка Docker ---
echo "🐳 Проверяем Docker..."
if ! command -v docker &>/dev/null; then
  echo "🐳 Устанавливаем Docker..."
  curl -fsSL https://get.docker.com | sh
  usermod -aG docker $SUDO_USER || true
else
  echo "✅ Docker уже установлен: $(docker --version)"
fi

# --- Оптимизация сети ---
echo "⚙️ Применяем сетевые оптимизации..."
tee /etc/sysctl.d/99-vpn-tuning.conf <<'EOF' >/dev/null
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

sysctl --system

# --- Защита веб-интерфейса Docker контейнера ---
echo "🛡️ Добавляем защиту для веб-панели Amnezia WG Easy..."
iptables -I DOCKER-USER -p tcp --dport 37238 -s 62.105.44.144/29 -j ACCEPT
iptables -I DOCKER-USER -p tcp --dport 37238 -s 188.0.160.0/19 -j ACCEPT
iptables -A DOCKER-USER -p tcp --dport 37238 -j DROP
iptables -A DOCKER-USER -j RETURN

iptables-save > /etc/iptables.rules

# Создаём systemd сервис для восстановления правил
tee /etc/systemd/system/restore-iptables.service <<'EOF' >/dev/null
[Unit]
Description=Restore iptables rules
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore < /etc/iptables.rules
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable restore-iptables

# --- Проверка ---
echo "✅ Настройка завершена!"
echo "🔁 Рекомендуется перезагрузить сервер для применения всех параметров."
read -r -p "🔁 Перезагрузить сейчас? [y/N]: " REBOOT
if [[ "$REBOOT" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    echo "♻️ Перезагружаюсь..."
    sleep 2
    reboot
else
    echo "⚠️ Перезагрузка пропущена. Не забудь выполнить 'reboot' позже."
fi
