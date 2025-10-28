#!/usr/bin/env bash
set -euo pipefail

# ===== Параметры =====
TRUSTED_NETS=("62.105.44.144/29" "188.0.160.0/19")    # доверенные сети [web:24]
SSH_PORT=22                                           # текущий порт SSH [web:24]
CLOUDFLARED_PORT=5053                                 # локальный порт DoH-прокси [web:132]
DNS_STUB_LISTEN="127.0.0.1"                           # куда будет слушать DoH-прокси [web:132]
SYSCTL_DROP_IN="/etc/sysctl.d/99-tuning.conf"         # файл с сетевыми тюнингами [web:24]
NFT_CONF="/etc/nftables.conf"                         # основной конфиг nftables [web:24]

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
}  # [web:24]

nft_flush_and_enable() {
  systemctl enable nftables >/dev/null 2>&1 || true
  systemctl start nftables || true
}  # [web:24]

append_unique_line() {
  local file="$1"; shift
  local line="$*"
  grep -qxF "$line" "$file" 2>/dev/null || echo "$line" >>"$file"
}  # [web:24]

# ===== 1. Обновление системы =====
apt-get update -y  # [web:24]
DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y  # [web:24]
apt-get autoremove -y  # [web:24]
apt-get autoclean -y  # [web:24]

# ===== 2. Установка программ =====
ensure_pkg curl htop fail2ban nano  # [web:24]

# ===== 3. Установка speedtest (Ookla) =====
if ! command -v speedtest >/dev/null 2>&1; then
  curl -fsSL https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash  # [web:24]
  apt-get install -y speedtest  # [web:24]
fi

# ===== 4-5. nftables: ограничить SSH доступ только доверенными сетями + блок пинга для всех, кроме доверенных =====
ensure_pkg nftables  # [web:24]
nft_flush_and_enable  # [web:24]

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

    # SSH только из доверенных сетей (IPv4)
    ip saddr @trusted_v4 tcp dport ${SSH_PORT} accept

    # ICMP/ICMPv6: разрешить только из доверенных (echo-request)
    ip saddr @trusted_v4 ip protocol icmp icmp type echo-request accept
    ip6 saddr ::1 ip6 nexthdr icmpv6 icmpv6 type echo-request accept
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
nft -f "$NFT_CONF"  # [web:24]
systemctl restart nftables  # [web:24]

# ===== 6. DNS-over-HTTPS с cloudflared (Cloudflare+Google) =====

# 6.0 Добавляем официальный репозиторий Cloudflare перед установкой
if ! apt-cache policy | grep -q "pkg.cloudflare.com.*cloudflared"; then
  install -d -m 0755 /usr/share/keyrings  # [web:132]
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null  # [web:132]
  echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' > /etc/apt/sources.list.d/cloudflared.list  # [web:132]
  apt-get update -y  # [web:132]
fi

# 6.1 Установка cloudflared
if ! command -v cloudflared >/dev/null 2>&1; then
  apt-get install -y cloudflared  # [web:132]
fi

# 6.2 Конфиг cloudflared как локальный DoH-прокси
mkdir -p /etc/cloudflared  # [web:132]
cat > /etc/cloudflared/config.yml <<EOF
proxy-dns: true
proxy-dns-address: ${DNS_STUB_LISTEN}
proxy-dns-port: ${CLOUDFLARED_PORT}
# Апстримы DoH: Cloudflare и Google
upstream:
  - https://cloudflare-dns.com/dns-query
  - https://dns.google/dns-query
EOF
# [web:132]

# 6.3 Сервис cloudflared
cloudflared service install 2>/dev/null || true  # [web:132]
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
systemctl daemon-reload  # [web:24]
systemctl enable cloudflared  # [web:132]
systemctl restart cloudflared  # [web:132]

# 6.4 Настроить системный резолвер на 127.0.0.1:PORT
if systemctl is-active --quiet systemd-resolved; then
  mkdir -p /etc/systemd/resolved.conf.d  # [web:24]
  cat > /etc/systemd/resolved.conf.d/override-doh.conf <<EOF
[Resolve]
DNS=${DNS_STUB_LISTEN}:${CLOUDFLARED_PORT}
Domains=~.
DNSSEC=no
FallbackDNS=
EOF
  systemctl restart systemd-resolved  # [web:24]
else
  chattr -i /etc/resolv.conf 2>/dev/null || true  # [web:24]
  cat > /etc/resolv.conf <<EOF
nameserver ${DNS_STUB_LISTEN}
options edns0
EOF
fi

# 6.5 Проверка DoH (через dig)
if ! command -v dig >/dev/null 2>&1; then
  ensure_pkg dnsutils  # [web:24]
fi
if dig +short @${DNS_STUB_LISTEN} -p ${CLOUDFLARED_PORT} one.one.one.one A >/dev/null 2>&1; then
  echo "DoH OK (cloudflared отвечает)"  # [web:132]
else
  echo "Внимание: не удалось подтвердить ответ DoH" >&2  # [web:132]
fi

# ===== 7. Сетевые оптимизации (sysctl) =====
cat > "${SYSCTL_DROP_IN}" <<'EOF'
# Маршрутизация (по умолчанию выкл., включите при необходимости VPN/NAT)
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

# Буферы TCP (умеренные дефолты)
net.core.rmem_max = 2500000
net.core.wmem_max = 2500000
net.ipv4.tcp_rmem = 4096 87380 2500000
net.ipv4.tcp_wmem = 4096 65536 2500000
EOF
sysctl --system >/dev/null  # [web:24]

# ===== 8. Рекомендуемые настройки Fail2ban =====
mkdir -p /etc/fail2ban  # [web:24]
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
systemctl enable fail2ban  # [web:24]
systemctl restart fail2ban  # [web:24]

# ===== 9. Проверяем Docker, ставим если нет =====
if ! command -v docker >/dev/null 2>&1; then
  apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true  # [web:24]
  apt-get update -y  # [web:24]
  ensure_pkg ca-certificates gnupg  # [web:24]
  install -d -m 0755 /etc/apt/keyrings  # [web:24]
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg  # [web:24]
  chmod a+r /etc/apt/keyrings/docker.gpg  # [web:24]
  echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
$(. /etc/os-release && echo ${VERSION_CODENAME}) stable" \
  > /etc/apt/sources.list.d/docker.list  # [web:24]
  apt-get update -y  # [web:24]
  ensure_pkg docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin  # [web:24]
  systemctl enable docker  # [web:24]
  systemctl start docker  # [web:24]
fi

# 9.1 Добавляем текущего пользователя в группу docker
if id "$(logname 2>/dev/null || echo ${SUDO_USER:-})" >/dev/null 2>&1; then
  usermod -aG docker "$(logname 2>/dev/null || echo ${SUDO_USER:-})"  # [web:24]
fi

# ===== 10. Вопрос об отключении IPv6 =====
read -r -p "Отключить IPv6? (да/нет): " DIS_IPV6
if [[ "${DIS_IPV6,,}" == "да" || "${DIS_IPV6,,}" == "yes" ]]; then
  cat > /etc/sysctl.d/70-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
  sysctl --system >/dev/null  # [web:132]
  echo "IPv6 отключен через sysctl. Для полного отключения можно добавить ipv6.disable=1 в GRUB и перезагрузить."  # [web:132]
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
  nft add rule inet filter input ip saddr @trusted_v4 tcp dport ${WEB_PORT} accept  # [web:24]

  # Порт UDP для AmneziaWG, открыть для всех
  while true; do
    read -r -p "Введите порт UDP для AmneziaWG (1-65535): " WG_UDP
    if [[ "$WG_UDP" =~ ^[0-9]+$ ]] && ((WG_UDP>=1 && WG_UDP<=65535)); then
      break
    else
      echo "Некорректный порт."
    fi
  done
  nft add rule inet filter input udp dport ${WG_UDP} accept  # [web:24]

  cat <<EOF

Подсказка: используйте эти порты в docker-compose для AmneziaWG/WG-Easy:
  - "0.0.0.0:${WEB_PORT}:${WEB_PORT}/tcp" (внешний ${WEB_PORT} для UI)
  - "0.0.0.0:${WG_UDP}:${WG_UDP}/udp" (внешний ${WG_UDP} для VPN)

EOF

else
  read -r -p "Перезагрузить сервер сейчас для применения всех настроек? (да/нет): " REBOOT
  if [[ "${REBOOT,,}" == "да" || "${REBOOT,,}" == "yes" ]]; then
    reboot  # [web:24]
  else
    echo "Настройки применены без перезагрузки."  # [web:24]
  fi
fi

echo "Готово."  # [web:24]
