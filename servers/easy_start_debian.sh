#!/usr/bin/env bash
set -euo pipefail

# ===== Параметры =====
TRUSTED_NETS=("62.105.44.144/29" "188.0.160.0/19")    # доверенные сети
SSH_PORT=22                                           # текущий порт SSH
CLOUDFLARED_PORT=5053                                 # локальный порт DoH-прокси
DNS_STUB_LISTEN="127.0.0.1"                           # куда будет слушать DoH-прокси
SYSCTL_DROP_IN="/etc/sysctl.d/99-tuning.conf"
NFT_CONF="/etc/nftables.conf"

# ===== 0. Проверка прав =====
if [[ $EUID -ne 0 ]]; then
  echo "Этот скрипт нужно запускать от root (sudo -i или sudo bash)." >&2
  exit 1
fi

# ===== функции-помощники =====
ensure_pkg() {
  local pkgs=("$@")
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkgs[@]}"
}

nft_flush_and_enable() {
  systemctl enable nftables >/dev/null 2>&1 || true
  systemctl start nftables || true
}

append_unique_line() {
  local file="$1"; shift
  local line="$*"
  grep -qxF "$line" "$file" 2>/dev/null || echo "$line" >>"$file"
}

# ===== 1. Обновление системы =====
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y
apt-get autoremove -y
apt-get autoclean -y

# ===== 2. Установка программ =====
ensure_pkg curl htop fail2ban nano

# ===== 3. Установка speedtest (Ookla) =====
if ! command -v speedtest >/dev/null 2>&1; then
  curl -fsSL https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash
  apt-get install -y speedtest
fi

# ===== 4-5. nftables: ограничить SSH доступ только доверенными сетями + блок пинга для всех, кроме доверенных =====
ensure_pkg nftables
nft_flush_and_enable

# Собираем элементы доверенных сетей для nftables
TRUSTED_SET_V4=""
for net in "${TRUSTED_NETS[@]}"; do
  TRUSTED_SET_V4+="$net, "
done
TRUSTED_SET_V4="${TRUSTED_SET_V4%, }"

# Генерация конфигурации nftables (таблица inet, policy drop)
cat > "$NFT_CONF" <<EOF
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
  set trusted_v4 {
    type ipv4_addr
    flags interval
    elements = { ${TRUSTED_SET_V4} }
  }

  chain input {
    type filter hook input priority 0; policy drop;

    iif "lo" accept
    ct state established,related accept

    # SSH только из доверенных сетей (4)
    ip saddr @trusted_v4 tcp dport ${SSH_PORT} accept

    # ICMP/ICMPv6: разрешить только из доверенных (echo-request)
    ip saddr @trusted_v4 ip protocol icmp icmp type echo-request accept
    ip6 saddr ::1 ip6 nexthdr icmpv6 icmpv6 type echo-request accept

    # Прочие служебные ICMP типы можно ограничить по необходимости,
    # по умолчанию — drop политикой
  }

  chain forward {
    type filter hook forward priority 0; policy drop;
  }

  chain output {
    type filter hook output priority 0; policy accept;
  }
}
EOF

# Применяем правила
nft -f "$NFT_CONF"
systemctl restart nftables

# ===== 6. DNS-over-HTTPS с cloudflared (Cloudflare+Google как апстримы) =====
# Ставим cloudflared
if ! command -v cloudflared >/dev/null 2>&1; then
  ensure_pkg cloudflared
fi

# Конфиг cloudflared как локальный DoH-прокси
mkdir -p /etc/cloudflared
cat > /etc/cloudflared/config.yml <<EOF
proxy-dns: true
proxy-dns-address: ${DNS_STUB_LISTEN}
proxy-dns-port: ${CLOUDFLARED_PORT}
# Апстримы DoH: Cloudflare и Google
upstream:
  - https://cloudflare-dns.com/dns-query
  - https://dns.google/dns-query
EOF

# Сервис cloudflared
cloudflared service install 2>/dev/null || true
# Если unit не установлен через service install, создадим вручную
if ! systemctl list-unit-files | grep -q '^cloudflared\.service'; then
cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=cloudflared DNS over HTTPS proxy
After=network-online.target
Wants=network-online.target

[Service]
User=root
ExecStart=/usr/bin/cloudflared --config /etc/cloudflared/config.yml proxy-dns
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
fi

systemctl daemon-reload
systemctl enable cloudflared
systemctl restart cloudflared

# Настроим resolv.conf через resolvconf/systemd-resolved упрощенно: переключим на 127.0.0.1:${CLOUDFLARED_PORT}
# В Debian 12 часто используется systemd-resolved. Если он активен — используем его.
if systemctl is-active --quiet systemd-resolved; then
  mkdir -p /etc/systemd/resolved.conf.d
  cat > /etc/systemd/resolved.conf.d/override-doh.conf <<EOF
[Resolve]
DNS=${DNS_STUB_LISTEN}:${CLOUDFLARED_PORT}
Domains=~.
DNSSEC=no
FallbackDNS=
EOF
  systemctl restart systemd-resolved
else
  # Фоллбек: статический resolv.conf (обратите внимание на возможную перезапись сетевыми менеджерами)
  chattr -i /etc/resolv.conf 2>/dev/null || true
  cat > /etc/resolv.conf <<EOF
nameserver ${DNS_STUB_LISTEN}
options edns0
EOF
fi

# 6.1 Проверка DoH (простой тест: dig через локальный DNS)
if command -v dig >/dev/null 2>&1; then
  dig +short @${DNS_STUB_LISTEN} -p ${CLOUDFLARED_PORT} one.one.one.one A >/dev/null 2>&1 && echo "DoH OK (cloudflared отвечает)"
else
  ensure_pkg dnsutils
  dig +short @${DNS_STUB_LISTEN} -p ${CLOUDFLARED_PORT} one.one.one.one A >/dev/null 2>&1 && echo "DoH OK (cloudflared отвечает)"
fi

# ===== 7. Сетевые оптимизации (sysctl) =====
cat > "${SYSCTL_DROP_IN}" <<'EOF'
# Маршрутизация (на случай VPN/NAT; forward оставим выкл. по умолчанию — включим позже при необходимости)
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0

# Безопасность стека
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# ICMP rate limit
net.ipv4.icmp_ratelimit = 100
net.ipv4.icmp_ratemask = 88089

# Буферы и общие оптимизации TCP (умеренные дефолты)
net.core.rmem_max = 2500000
net.core.wmem_max = 2500000
net.ipv4.tcp_rmem = 4096 87380 2500000
net.ipv4.tcp_wmem = 4096 65536 2500000
EOF
sysctl --system >/dev/null

# ===== 8. Рекомендуемые настройки Fail2ban =====
# Базовая jail.local c sshd
mkdir -p /etc/fail2ban
cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
backend = systemd
destemail = root@localhost
sender = fail2ban@localhost
mta = sendmail
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
mode = aggressive
port = ssh
logpath = %(sshd_log)s
maxretry = 5
EOF
systemctl enable fail2ban
systemctl restart fail2ban

# ===== 9. Проверяем Docker, ставим если нет =====
if ! command -v docker >/dev/null 2>&1; then
  # официальная установка Docker CE
  apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
  apt-get update -y
  ensure_pkg ca-certificates gnupg
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
$(. /etc/os-release && echo ${VERSION_CODENAME}) stable" \
  > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  ensure_pkg docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable docker
  systemctl start docker
fi

# 9.1 Добавляем текущего пользователя в группу docker
if id "$(logname 2>/dev/null || echo ${SUDO_USER:-})" >/dev/null 2>&1; then
  usermod -aG docker "$(logname 2>/dev/null || echo ${SUDO_USER:-})"
fi

# ===== 10. Вопрос об отключении IPv6 =====
read -r -p "Отключить IPv6? (да/нет): " DIS_IPV6
if [[ "${DIS_IPV6,,}" == "да" || "${DIS_IPV6,,}" == "yes" ]]; then
  cat > /etc/sysctl.d/70-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
  sysctl --system >/dev/null
  echo "IPv6 отключен через sysctl. Для полного отключения можно добавить ipv6.disable=1 в GRUB и перезагрузить."
fi

# ===== 11. Вопрос про AmneziaWG =====
read -r -p "Здесь будет AmneziaWG? (да/нет): " USE_AWG
if [[ "${USE_AWG,,}" == "да" || "${USE_AWG,,}" == "yes" ]]; then
  # Порт Web-интерфейса (TCP), разрешить только доверенным сетям
  while true; do
    read -r -p "На каком порту будет Web интерфейс? (TCP, 1-65535): " WEB_PORT
    if [[ "$WEB_PORT" =~ ^[0-9]+$ ]] && ((WEB_PORT>=1 && WEB_PORT<=65535)); then
      break
    else
      echo "Некорректный порт."
    fi
  done

  # Добавим правило для WEB_PORT в nftables (только доверенные сети)
  nft add rule inet filter input ip saddr @trusted_v4 tcp dport ${WEB_PORT} accept

  # Порт UDP для AmneziaWG, открыть для всех
  while true; do
    read -r -p "Введите порт UDP для AmneziaWG (1-65535): " WG_UDP
    if [[ "$WG_UDP" =~ ^[0-9]+$ ]] && ((WG_UDP>=1 && WG_UDP<=65535)); then
      break
    else
      echo "Некорректный порт."
    fi
  done
  nft add rule inet filter input udp dport ${WG_UDP} accept

  # Подсказка по docker-compose (порт веб и udp)
  cat <<EOF

Подсказка: используйте эти порты в docker-compose для AmneziaWG/WG-Easy:
  - "0.0.0.0:${WEB_PORT}:${WEB_PORT}/tcp" (или используйте стандартный порт UI внутри контейнера с внешним ${WEB_PORT})
  - "0.0.0.0:${WG_UDP}:${WG_UDP}/udp"

Если интерфейс контейнера отличается, убедитесь что сервис слушает именно на этих портах.

EOF

else
  read -r -p "Перезагрузить сервер сейчас для применения всех настроек? (да/нет): " REBOOT
  if [[ "${REBOOT,,}" == "да" || "${REBOOT,,}" == "yes" ]]; then
    reboot
  else
    echo "Настройки применены без перезагрузки."
  fi
fi

echo "Готово."
