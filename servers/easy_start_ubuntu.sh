#!/bin/bash
# ==============================================================
# Автор: Funnnik
# Совместимость: Ubuntu 22.04 / 24.04+
# Версия: 2.0
# ==============================================================

# Настройка цветов для вывода
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== Интеллектуальная подготовка Ubuntu Server 24.04 ===${NC}"

# Проверка на root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Ошибка: Запустите скрипт с правами root (sudo ./setup_vpn_server.sh)${NC}"
  exit 1
fi

REAL_USER=${SUDO_USER:-$(whoami)}

# ==========================================
# БЛОК ВОПРОСОВ (ИНТЕРАКТИВ)
# ==========================================
echo -e "${CYAN}Ответьте на несколько вопросов перед началом настройки:${NC}"

# Вопрос 1: Тип VPN
while true; do
    read -p "1. Какой VPN будет использоваться на сервере? (awg / vless): " VPN_TYPE
    VPN_TYPE=$(echo "$VPN_TYPE" | tr '[:upper:]' '[:lower:]')
    if [[ "$VPN_TYPE" == "awg" || "$VPN_TYPE" == "vless" ]]; then
        break
    else
        echo -e "${RED}Пожалуйста, введите 'awg' или 'vless'.${NC}"
    fi
done

# Вопрос 2: Ping
read -p "2. Включить пинг только для доверенных сетей? (y/n/yes/no): " PING_ANS
PING_ANS=$(echo "$PING_ANS" | tr '[:upper:]' '[:lower:]')

# Вопрос 3: DoT
read -p "3. Установить защищенные DoT серверы (Google + Cloudflare)? (y/n/yes/no): " DOT_ANS
DOT_ANS=$(echo "$DOT_ANS" | tr '[:upper:]' '[:lower:]')

# Вопрос 4: Docker (если выбран AWG, ставим автоматически)
if [[ "$VPN_TYPE" == "awg" ]]; then
    echo -e "${YELLOW}Для AmneziaWG (awg) Docker будет установлен автоматически.${NC}"
    DOCKER_ANS="y"
else
    read -p "4. Установить ли Docker? (y/n/yes/no): " DOCKER_ANS
    DOCKER_ANS=$(echo "$DOCKER_ANS" | tr '[:upper:]' '[:lower:]')
fi

echo -e "${GREEN}Спасибо! Начинаю автоматическую настройку...${NC}"
sleep 2

# ==========================================
# 1. ОБНОВЛЕНИЕ СИСТЕМЫ
# ==========================================
echo -e "\n${YELLOW}[1/10] Обновление системы...${NC}"
apt update && apt upgrade -y

# ==========================================
# 2. НАСТРОЙКА ЯДРА И СЕТИ
# ==========================================
echo -e "\n${YELLOW}[2/10] Оптимизация ядра для $VPN_TYPE...${NC}"
cat <<EOF > /etc/sysctl.d/99-vpn-optimizations.conf
# Общие сетевые настройки маршрутизации
net.ipv4.ip_forward=1
EOF

if [[ "$VPN_TYPE" == "awg" ]]; then
    # Оптимизации для AmneziaWG (UDP буферы)
    cat <<EOF >> /etc/sysctl.d/99-vpn-optimizations.conf
net.ipv4.conf.all.src_valid_mark=1
net.core.rmem_max = 4194304
net.core.wmem_max = 4194304
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
EOF
    sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

elif [[ "$VPN_TYPE" == "vless" ]]; then
    # Оптимизации для VLESS / 3x-ui (TCP BBR, File Descriptors)
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

# ==========================================
# 4. НАСТРОЙКА SWAP
# ==========================================
echo -e "\n${YELLOW}[4/10] Настройка SWAP (2GB)...${NC}"
if ! grep -q "/swapfile" /etc/fstab; then
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf
    sysctl -p /etc/sysctl.d/99-swappiness.conf
    echo -e "${GREEN}SWAP на 2GB успешно создан и включен.${NC}"
else
    echo -e "${CYAN}SWAP уже настроен, пропускаем.${NC}"
fi

# ==========================================
# 5. ОТКЛЮЧЕНИЕ IPV6
# ==========================================
echo -e "\n${YELLOW}[5/10] Полное отключение IPv6...${NC}"
cat <<EOF > /etc/sysctl.d/99-disable-ipv6.conf
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
sysctl --system

# ==========================================
# 6. НАСТРОЙКА UFW И PING
# ==========================================
echo -e "\n${YELLOW}[6/10] Настройка файрвола UFW...${NC}"
apt install -y ufw
ufw allow 22/tcp comment 'Allow SSH IPv4'

if [[ "$PING_ANS" == "y" || "$PING_ANS" == "yes" ]]; then
    echo -e "${CYAN}Применяю правила ограничения PING...${NC}"
    # Заменяем стандартное правило UFW для echo-request на кастомное
    sed -i 's/-A ufw-before-input -p icmp --icmp-type echo-request -j ACCEPT/-A ufw-before-input -p icmp --icmp-type echo-request -s 62.105.44.145\/29 -j ACCEPT\n-A ufw-before-input -p icmp --icmp-type echo-request -s 188.0.160.0\/19 -j ACCEPT\n-A ufw-before-input -p icmp --icmp-type echo-request -j DROP/' /etc/ufw/before.rules
fi

echo "y" | ufw enable

# ==========================================
# 7. УСТАНОВКА FAIL2BAN
# ==========================================
echo -e "\n${YELLOW}[7/10] Настройка Fail2Ban для защиты SSH...${NC}"
apt install -y fail2ban
cat <<EOF > /etc/fail2ban/jail.local
[DEFAULT]
bantime = 24h
findtime = 10m
maxretry = 3
banaction = ufw

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
EOF
systemctl enable --now fail2ban
systemctl restart fail2ban

# ==========================================
# 8. НАСТРОЙКА DoT СЕРВЕРОВ
# ==========================================
echo -e "\n${YELLOW}[8/10] Настройка DNS...${NC}"
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

# ==========================================
# 9. УСТАНОВКА DOCKER
# ==========================================
echo -e "\n${YELLOW}[9/10] Установка среды выполнения...${NC}"
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

# ==========================================
# 10. ФИНАЛИЗАЦИЯ И ОЧИСТКА
# ==========================================
echo -e "\n${YELLOW}[10/10] Финализация и очистка системы...${NC}"
apt autoremove -y
apt clean

echo -e "\n${GREEN}================================================================${NC}"
echo -e "${GREEN}✅ Сервер успешно подготовлен! (${VPN_TYPE^^} Edition) ✅${NC}"
echo -e "${GREEN}================================================================${NC}"
echo -e "Что было сделано:"
echo -e "  [+] Система полностью обновлена."
echo -e "  [+] Ядро оптимизировано под $VPN_TYPE."
echo -e "  [+] Создан SWAP-раздел на 2GB (swappiness=10)."
echo -e "  [+] IPv6 отключен на уровне sysctl."
echo -e "  [+] UFW активирован (SSH 22/tcp открыт)."
if [[ "$PING_ANS" == "y" || "$PING_ANS" == "yes" ]]; then
echo -e "  [+] PING разрешен ТОЛЬКО для 62.105.44.145/29 и 188.0.160.0/19."
fi
echo -e "  [+] Fail2Ban настроен (бан на 24ч после 3 неверных попыток)."
if [[ "$DOT_ANS" == "y" || "$DOT_ANS" == "yes" ]]; then
echo -e "  [+] Включен шифрованный DNS (DoT 8.8.8.8 и 1.1.1.1)."
fi
if [[ "$DOCKER_ANS" == "y" || "$DOCKER_ANS" == "yes" ]]; then
echo -e "  [+] Установлен Docker (пользователь $REAL_USER имеет права)."
fi
echo -e "================================================================\n"

read -p "Нажмите Enter для перезагрузки сервера или Ctrl+C для отмены..."

echo -e "${YELLOW}Перезагрузка сервера...${NC}"
reboot
