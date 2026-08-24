#!/bin/bash
# ==============================================================
# Автор: Funnnik
# Совместимость: Ubuntu 22.04 / 24.04+
# Версия: 2.3
# ==============================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== Интеллектуальная подготовка Ubuntu Server 24.04 ===${NC}"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Ошибка: Запустите скрипт с правами root (sudo ./setup_vpn_server.sh)${NC}"
  exit 1
fi

REAL_USER=${SUDO_USER:-$(whoami)}

echo -e "${CYAN}Ответьте на несколько вопросов перед началом настройки:${NC}"

while true; do
    read -p "1. Какой VPN будет использоваться на сервере? (awg / vless): " VPN_TYPE
    VPN_TYPE=$(echo "$VPN_TYPE" | tr '[:upper:]' '[:lower:]')
    if [[ "$VPN_TYPE" == "awg" || "$VPN_TYPE" == "vless" ]]; then
        break
    else
        echo -e "${RED}Пожалуйста, введите 'awg' или 'vless'.${NC}"
    fi
done

if [[ "$VPN_TYPE" == "awg" ]]; then
    read -p "2. Какую подсеть использовать для AmneziaWG? (введите подсеть, пустой ввод для по-умолчанию, или 'r' для случайной из 10.x.x.0/24): " AWG_SUBNET_ANS
    if [[ -z "$AWG_SUBNET_ANS" ]]; then
        AWG_SUBNET="10.187.201.0/24"
        echo -e "${YELLOW}Поле оставлено пустым. Используем подсеть: $AWG_SUBNET${NC}"
    elif [[ "$AWG_SUBNET_ANS" == "r" ]]; then
        AWG_SUBNET="10.$((RANDOM % 256)).$((RANDOM % 256)).0/24"
        echo -e "${YELLOW}Сгенерирована случайная подсеть: $AWG_SUBNET${NC}"
    else
        AWG_SUBNET=$AWG_SUBNET_ANS
    fi
    
    read -p "3. Какой порт использовать для AmneziaWG? (введите порт или 'r' для случайного): " AWG_PORT_ANS
    if [[ "$AWG_PORT_ANS" == "r" ]]; then
        # Генерируем порт от 40000 до 65535 (максимально допустимый порт)
        AWG_PORT=$(shuf -i 40000-65535 -n 1)
        echo -e "${YELLOW}Сгенерирован случайный порт AWG: $AWG_PORT${NC}"
    else
        AWG_PORT=$AWG_PORT_ANS
    fi
    NEXT_Q=4
else
    AWG_SUBNET=""
    AWG_PORT=""
    NEXT_Q=2
fi

read -p "$NEXT_Q. Какой порт использовать для веб-интерфейса панели? (введите порт или 'r' для случайного): " WEB_PORT_ANS
if [[ "$WEB_PORT_ANS" == "r" ]]; then
    # Генерируем порт от 30000 до 65535
    WEB_PORT=$(shuf -i 30000-65535 -n 1)
    echo -e "${YELLOW}Сгенерирован случайный порт для Web UI: $WEB_PORT${NC}"
else
    WEB_PORT=$WEB_PORT_ANS
fi
NEXT_Q=$((NEXT_Q + 1))

read -p "$NEXT_Q. Включить пинг только для доверенных сетей? (y/n/yes/no): " PING_ANS
PING_ANS=$(echo "$PING_ANS" | tr '[:upper:]' '[:lower:]')
NEXT_Q=$((NEXT_Q + 1))

read -p "$NEXT_Q. Установить защищенные DoT серверы (Google + Cloudflare)? (y/n/yes/no): " DOT_ANS
DOT_ANS=$(echo "$DOT_ANS" | tr '[:upper:]' '[:lower:]')
NEXT_Q=$((NEXT_Q + 1))

read -p "$NEXT_Q. Отключить IPv6 полностью? (y/n/yes/no): " IPV6_ANS
IPV6_ANS=$(echo "$IPV6_ANS" | tr '[:upper:]' '[:lower:]')
NEXT_Q=$((NEXT_Q + 1))

if [[ "$VPN_TYPE" == "awg" ]]; then
    echo -e "${YELLOW}$NEXT_Q. Для AmneziaWG (awg) Docker будет установлен автоматически.${NC}"
    DOCKER_ANS="y"
else
    read -p "$NEXT_Q. Установить ли Docker? (y/n/yes/no): " DOCKER_ANS
    DOCKER_ANS=$(echo "$DOCKER_ANS" | tr '[:upper:]' '[:lower:]')
fi

echo -e "${GREEN}Спасибо! Начинаю автоматическую настройку...${NC}"
sleep 2

echo -e "\n${YELLOW}[1/10] Обновление системы...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt update && apt upgrade -y -q -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"

echo -e "\n${YELLOW}[2/10] Оптимизация ядра для $VPN_TYPE...${NC}"
cat <<EOF > /etc/sysctl.d/99-vpn-optimizations.conf
net.ipv4.ip_forward=1
EOF

if [[ "$VPN_TYPE" == "awg" ]]; then
    cat <<EOF >> /etc/sysctl.d/99-vpn-optimizations.conf
net.ipv4.conf.all.src_valid_mark=1
net.core.rmem_max = 4194304
net.core.wmem_max = 4194304
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
EOF
    sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
elif [[ "$VPN_TYPE" == "vless" ]]; then
    modprobe tcp_bbr
    echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
    cat <<EOF >> /etc/sysctl.d/99-vpn-optimizations.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
fs.file-max = 1000000
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
EOF
fi
sysctl --system

echo -e "\n${YELLOW}[3/10] Настройка SWAP...${NC}"
if [ "$(swapon --show | wc -l)" -gt 0 ] || [ "$(free | awk '/^Swap:/ {print $2}')" -gt 0 ]; then
    echo -e "${CYAN}SWAP раздел или файл уже существует. Пропускаем создание.${NC}"
else
    echo -e "${CYAN}SWAP не найден. Создаю SWAP-файл на 2GB...${NC}"
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf
    sysctl -p /etc/sysctl.d/99-swappiness.conf
    echo -e "${GREEN}SWAP на 2GB успешно создан и включен.${NC}"
fi

echo -e "\n${YELLOW}[4/10] Настройка IPv6...${NC}"
if [[ "$IPV6_ANS" == "y" || "$IPV6_ANS" == "yes" ]]; then
    cat <<EOF > /etc/sysctl.d/99-disable-ipv6.conf
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    sysctl --system
    echo -e "${GREEN}IPv6 полностью отключен.${NC}"
else
    echo -e "${CYAN}IPv6 оставлен включенным.${NC}"
fi

echo -e "\n${YELLOW}[5/10] Настройка файрвола UFW...${NC}"
apt install -y ufw

sed -i 's/IPV6=yes/IPV6=no/' /etc/default/ufw

# Динамическое определение порта SSH
SSH_PORT=$(grep -E "^Port\s" /etc/ssh/sshd_config | awk '{print $2}')
if [[ -z "$SSH_PORT" ]]; then
    SSH_PORT=22
fi
ufw allow proto tcp from 0.0.0.0/0 to any port $SSH_PORT comment 'Allow SSH IPv4'

# Открываем порт для веб-интерфейса (только TCP)
ufw allow $WEB_PORT/tcp comment 'Allow Web UI'

if [[ "$VPN_TYPE" == "vless" ]]; then
    ufw allow 80/tcp comment 'Allow HTTP for VLESS'
    ufw allow 443/tcp comment 'Allow HTTPS for VLESS'
elif [[ "$VPN_TYPE" == "awg" && -n "$AWG_PORT" ]]; then
    ufw allow $AWG_PORT/udp comment 'Allow AmneziaWG'
fi

if [[ "$VPN_TYPE" == "awg" ]] && ! grep -q "*nat" /etc/ufw/before.rules; then
    echo -e "${CYAN}Добавляю правила NAT (MASQUERADE) для сети $AWG_SUBNET в UFW...${NC}"
    DEFAULT_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
    sed -i "1i # NAT table rules\n*nat\n:POSTROUTING ACCEPT [0:0]\n-A POSTROUTING -s $AWG_SUBNET -o $DEFAULT_IFACE -j MASQUERADE\nCOMMIT\n" /etc/ufw/before.rules
fi

if [[ "$PING_ANS" == "y" || "$PING_ANS" == "yes" ]]; then
    echo -e "${CYAN}Применяю правила ограничения PING...${NC}"
    sed -i 's/-A ufw-before-input -p icmp --icmp-type echo-request -j ACCEPT/-A ufw-before-input -p icmp --icmp-type echo-request -s 62.105.44.145\/29 -j ACCEPT\n-A ufw-before-input -p icmp --icmp-type echo-request -s 188.0.160.0\/19 -j ACCEPT\n-A ufw-before-input -p icmp --icmp-type echo-request -j DROP/' /etc/ufw/before.rules
fi

echo "y" | ufw enable

echo -e "\n${YELLOW}[6/10] Настройка Fail2Ban для защиты SSH...${NC}"
apt install -y fail2ban
cat <<EOF > /etc/fail2ban/jail.local
[DEFAULT]
bantime = 24h
findtime = 10m
maxretry = 3
banaction = ufw

[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
EOF
systemctl enable --now fail2ban
systemctl restart fail2ban

echo -e "\n${YELLOW}[7/10] Настройка DNS...${NC}"
if [[ "$DOT_ANS" == "y" || "$DOT_ANS" == "yes" ]]; then
    echo -e "${CYAN}Настраиваем DoT (Google + Cloudflare)...${NC}"
    cp /etc/systemd/resolved.conf /etc/systemd/resolved.conf.bak
    sed -i '/^#DNS=/d; /^#DNSOverTLS=/d; /^DNS=/d; /^DNSOverTLS=/d' /etc/systemd/resolved.conf
    echo "DNS=8.8.8.8 1.1.1.1" >> /etc/systemd/resolved.conf
    echo "DNSOverTLS=yes" >> /etc/systemd/resolved.conf
    systemctl restart systemd-resolved
    echo -e "${GREEN}DoT серверы установлены.${NC}"
else
    echo -e "${CYAN}Пропуск настройки DoT.${NC}"
fi

echo -e "\n${YELLOW}[8/10] Установка среды выполнения (Docker)...${NC}"
if [[ "$DOCKER_ANS" == "y" || "$DOCKER_ANS" == "yes" ]]; then
    if ! command -v docker &> /dev/null; then
        echo -e "${CYAN}Устанавливаем Docker...${NC}"
        curl -sSL https://get.docker.com | sh
        usermod -aG docker "$REAL_USER"
        echo -e "${GREEN}Docker успешно установлен. Пользователь $REAL_USER добавлен в группу.${NC}"
    else
        echo -e "${GREEN}Docker уже установлен, пропускаем.${NC}"
    fi
else
    echo -e "${CYAN}Установка Docker пропущена.${NC}"
fi

echo -e "\n${YELLOW}[9/10] Очистка системы...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt autoremove -y
apt clean

echo -e "\n${YELLOW}[10/10] Завершение...${NC}"
echo -e "${CYAN}Финализация завершена.${NC}"

echo -e "\n${GREEN}================================================================${NC}"
echo -e "${GREEN}✅ Сервер успешно подготовлен! (${VPN_TYPE^^} Edition) ✅${NC}"
if [[ "$VPN_TYPE" == "awg" ]]; then
    echo -e "${CYAN}Подсеть AWG: ${AWG_SUBNET}${NC}"
    echo -e "${CYAN}Порт AWG: ${AWG_PORT}${NC}"
fi
echo -e "${CYAN}Порт Web-интерфейса: ${WEB_PORT}${NC}"
echo -e "${GREEN}================================================================${NC}"
read -p "Нажмите Enter для перезагрузки сервера или Ctrl+C для отмены..."
echo -e "${YELLOW}Перезагрузка сервера...${NC}"
reboot
