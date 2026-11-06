#!/bin/sh
# Installator v2.1 for Cudy WR3000S (IGMP proxy + VLAN 40 IPTV)
# Run: sh install-v2.1-cudy.sh
# 
# Menu:
#   1 - Install configuration 
#   2 - Recovery backup (if .bak exists)

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

CONFIG_FILES="network dhcp firewall igmpproxy"

error_exit() {
    printf "${RED}Ошибка: %s${NC}\n" "$1" >&2
    exit 1
}

[ "$(id -u)" -eq 0 ] || error_exit "Скрипт должен быть запущен от root."

# ---------- Check model ----------
if command -v ubus >/dev/null 2>&1; then
    MODEL=$(ubus call system board 2>/dev/null | sed -n 's/.*"model": *"\([^"]*\)".*/\1/p' | head -1)
    case "$MODEL" in
        *WR3000S*) ;;
        *)
            printf "${YELLOW}Модель не определена как Cudy WR3000S: '%s'${NC}\n" "$MODEL"
            printf "Продолжить всё равно? (y/N): "
            read C
            case "$C" in y|Y) ;; *) exit 0 ;; esac
            ;;
    esac
fi

# ---------- Check have backup ----------
BACKUP_EXISTS=0
for f in $CONFIG_FILES; do
    if [ -f "/etc/config/$f.bak" ]; then
        BACKUP_EXISTS=1
        break
    fi
done

# ---------- Main menu ----------
printf "${YELLOW}=== Инсталлятор v2.1 для Cudy WR3000S ===${NC}\n\n"
printf "Выберите действие:\n"
printf "  1 - Установка конфигурации\n"
if [ "$BACKUP_EXISTS" -eq 1 ]; then
    printf "  2 - Восстановить бэкап\n"
else
    printf "  2 - Восстановить бэкап ${RED}(недоступно: бэкап не найден)${NC}\n"
fi
printf "Введите номер [1]: "
read ACTION
ACTION=${ACTION:-1}

case "$ACTION" in
    1) ;;
    2)
        if [ "$BACKUP_EXISTS" -eq 0 ]; then
            error_exit "Бэкап не найден — восстановление невозможно"
        fi
        ;;
    *) error_exit "Неверный выбор" ;;
esac

# ==================== Recovery ====================
if [ "$ACTION" = "2" ]; then
    printf "\n${YELLOW}Восстановление из резервных копий...${NC}\n"
    restored=0
    for f in $CONFIG_FILES; do
        if [ -f "/etc/config/$f.bak" ]; then
            cp "/etc/config/$f.bak" "/etc/config/$f"
            printf "  ${GREEN}восстановлен${NC}: /etc/config/$f\n"
            restored=$((restored + 1))
        fi
    done
    if [ "$restored" -eq 0 ]; then
        error_exit "Не найдено ни одного файла бэкапа"
    fi

    printf "\n${YELLOW}Перезапустить службы сейчас? (y/N): "
    read RESTART
    case "$RESTART" in
        y|Y)
            for svc in network dnsmasq firewall igmpproxy; do
                printf "  %s... " "$svc"
                if /etc/init.d/$svc restart >/dev/null 2>&1; then
                    printf "${GREEN}OK${NC}\n"
                else
                    printf "${YELLOW}пропущено${NC}\n"
                fi
            done
            ;;
    esac
    printf "\n${GREEN}=== Восстановление завершено. ===${NC}\n"
    exit 0
fi

# ==================== Install ====================
printf "\n${YELLOW}Учётные данные PPPoE:${NC}\n"
printf "Имя пользователя: "
read USERNAME
printf "Пароль: "
read -s PASSWORD
printf "\n"
printf "Подтвердите пароль: "
read -s PASSWORD_CONFIRM
printf "\n"

if [ "$PASSWORD" != "$PASSWORD_CONFIRM" ]; then
    error_exit "Пароли не совпадают"
fi
case "$USERNAME" in *\'*) error_exit "Недопустимый символ ' в имени пользователя" ;; esac
case "$PASSWORD" in *\'*) error_exit "Недопустимый символ ' в пароле" ;; esac

# ---------- Ports ----------
printf "\n${YELLOW}Настройка портов LAN:${NC}\n"
printf "Сколько всего LAN портов (не считая WAN)? [4]: "
read TOTAL_PORTS
TOTAL_PORTS=${TOTAL_PORTS:-4}
echo "$TOTAL_PORTS" | grep -qE '^[0-9]+$' || error_exit "Некорректное количество портов"
[ "$TOTAL_PORTS" -ge 1 ] || error_exit "Должен быть хотя бы 1 LAN порт"

printf "В какой порт LAN подключен IPTV (1-%s)? [4]: " "$TOTAL_PORTS"
read IPTV_PORT
IPTV_PORT=${IPTV_PORT:-4}
echo "$IPTV_PORT" | grep -qE '^[0-9]+$' || error_exit "Некорректный номер порта"
if [ "$IPTV_PORT" -lt 1 ] || [ "$IPTV_PORT" -gt "$TOTAL_PORTS" ]; then
    error_exit "Порт вне диапазона 1..$TOTAL_PORTS"
fi

# ---------- Port list ----------
LAN_PORTS=""
i=1
while [ "$i" -le "$TOTAL_PORTS" ]; do
    if [ "$i" -ne "$IPTV_PORT" ]; then
        LAN_PORTS="${LAN_PORTS}    list ports 'lan$i'
"
    fi
    i=$((i + 1))
done
IPTV_LINE="    list ports 'lan$IPTV_PORT'"

# ---------- Generation config to temp dir ----------
TMPD=$(mktemp -d) || error_exit "Не удалось создать временную директорию"
trap 'rm -rf "$TMPD"' EXIT

# ----- Network -----
: > "$TMPD/network"
cat >> "$TMPD/network" <<'EOF'
config interface 'loopback'
    option device 'lo'
    option proto 'static'
    list ipaddr '127.0.0.1/8'

config globals 'globals'
    option ula_prefix 'fd54:519a:125c::/48'
    option packet_steering '1'

config device
    option name 'br-lan'
    option type 'bridge'
EOF
printf "%s" "$LAN_PORTS" >> "$TMPD/network"
cat >> "$TMPD/network" <<'EOF'
    option igmp_snooping '1'

config interface 'lan'
    option device 'br-lan'
    option proto 'static'
    list ipaddr '192.168.1.1/24'
    option ip6assign '60'

config device 'dev_wan20'
    option name 'wan.20'
    option type '8021q'
    option ifname 'wan'
    option vid '20'

config interface 'wan'
    option device 'wan.20'
    option proto 'pppoe'
EOF
printf "    option username '%s'\n" "$USERNAME" >> "$TMPD/network"
printf "    option password '%s'\n" "$PASSWORD" >> "$TMPD/network"
cat >> "$TMPD/network" <<'EOF'
    option ipv6 'auto'
    option mtu '1492'
    option keepalive '5 10'
    option delegate '0'
    option norelease '1'

config device 'dev_wan40'
    option name 'wan.40'
    option type '8021q'
    option ifname 'wan'
    option vid '40'

config interface 'iptv'
    option device 'wan.40'
    option proto 'static'
    list ipaddr '10.0.0.1/24'
    option defaultroute '0'
    option delegate '0'

config device
    option name 'br-iptv'
    option type 'bridge'
EOF
printf "%s\n" "$IPTV_LINE" >> "$TMPD/network"
cat >> "$TMPD/network" <<'EOF'
    option igmp_snooping '0'

config interface 'iptv_lan'
    option device 'br-iptv'
    option proto 'static'
    list ipaddr '192.168.100.1/24'
    option delegate '0'
EOF

# ----- DHCP -----
cat > "$TMPD/dhcp" <<'EOF'
config dnsmasq
    option domainneeded '1'
    option boguspriv '1'
    option filterwin2k '0'
    option localise_queries '1'
    option rebind_protection '1'
    option rebind_localhost '1'
    option local '/lan/'
    option domain 'lan'
    option expandhosts '1'
    option nonegcache '0'
    option cachesize '1000'
    option authoritative '1'
    option readethers '1'
    option leasefile '/tmp/dhcp.leases'
    option resolvfile '/tmp/resolv.conf.d/resolv.conf.auto'
    option nonwildcard '1'
    option localservice '1'
    option ednspacket_max '1232'
    option filter_aaaa '0'
    option filter_a '0'

config dhcp 'lan'
    option interface 'lan'
    option start '100'
    option limit '150'
    option leasetime '12h'
    option dhcpv4 'server'
    option dhcpv6 'server'
    option ra 'server'
    option ra_slaac '1'
    list ra_flags 'managed-config'
    list ra_flags 'other-config'

config dhcp 'wan'
    option interface 'wan'
    option ignore '1'

config odhcpd 'odhcpd'
    option maindhcp '0'
    option leasefile '/tmp/hosts/odhcpd'
    option leasetrigger '/usr/sbin/odhcpd-update'
    option loglevel '4'
    option piofolder '/tmp/odhcpd-piofolder'

config dhcp 'iptv_lan'
    option interface 'iptv_lan'
    option start '100'
    option limit '150'
    option leasetime '12h'
    option dhcpv4 'server'
EOF

# ----- Firewall -----
cat > "$TMPD/firewall" <<'EOF'
config defaults
    option input 'REJECT'
    option output 'ACCEPT'
    option forward 'REJECT'
    option synflood_protect '1'

config zone
    option name 'lan'
    option input 'ACCEPT'
    option output 'ACCEPT'
    option forward 'ACCEPT'
    list network 'lan'

config zone
    option name 'wan'
    option input 'REJECT'
    option output 'ACCEPT'
    option forward 'REJECT'
    option masq '1'
    option mtu_fix '1'
    list network 'wan'

config zone
    option name 'iptv'
    option input 'REJECT'
    option output 'ACCEPT'
    option forward 'REJECT'
    list network 'iptv'

config zone
    option name 'iptv_lan'
    option input 'ACCEPT'
    option output 'ACCEPT'
    option forward 'REJECT'
    list network 'iptv_lan'

config forwarding
    option src 'iptv'
    option dest 'iptv_lan'

config forwarding
    option src 'iptv_lan'
    option dest 'wan'

config forwarding
    option src 'lan'
    option dest 'wan'

config rule
    option name 'Allow-IPTV-IGMP'
    option src 'iptv'
    option proto 'igmp'
    option target 'ACCEPT'
    option family 'ipv4'

config rule
    option name 'Allow-IPTV-LAN-IGMP'
    option src 'iptv_lan'
    option proto 'igmp'
    option target 'ACCEPT'
    option family 'ipv4'

config rule
    option name 'Allow-IPTV-Multicast-UDP'
    option src 'iptv'
    option proto 'udp'
    option dest 'iptv_lan'
    option dest_ip '224.0.0.0/4'
    option target 'ACCEPT'

config rule
    option name 'Allow-DHCP-Renew'
    option src 'wan'
    option proto 'udp'
    option dest_port '68'
    option target 'ACCEPT'
    option family 'ipv4'

config rule
    option name 'Allow-Ping'
    option src 'wan'
    option proto 'icmp'
    option icmp_type 'echo-request'
    option family 'ipv4'
    option target 'ACCEPT'

config rule
    option name 'Allow-IGMP'
    option src 'wan'
    option proto 'igmp'
    option family 'ipv4'
    option target 'ACCEPT'
EOF

# ----- igmpproxy -----
cat > "$TMPD/igmpproxy" <<'EOF'
config igmpproxy
    option quickleave 1

config phyint
    option network 'iptv'
    option direction 'upstream'
    list altnet '198.18.20.5'
    list altnet '10.179.47.27'
    list altnet '10.171.151.11'
    list altnet '212.12.12.235'
    list altnet '212.12.12.234'
    list altnet '212.193.149.193'
    list altnet '212.193.157.250'
    list altnet '46.235.189.194'
    list altnet '195.209.81.195'
    list altnet '212.193.155.254'
    list altnet '212.193.153.129'
    list altnet '212.193.155.240'
    list altnet '65.9.46.41'

config phyint
    option network 'iptv_lan'
    option direction 'downstream'
EOF

# ==================== BACKUP (pre-install) ====================
printf "\n${GREEN}Создание резервных копий (только если их ещё нет)...${NC}\n"
for f in $CONFIG_FILES; do
    if [ -f "/etc/config/$f" ]; then
        if [ ! -f "/etc/config/$f.bak" ]; then
            cp "/etc/config/$f" "/etc/config/$f.bak"
            printf "  ${GREEN}создан${NC}: /etc/config/$f.bak\n"
        else
            printf "  ${YELLOW}уже существует${NC}: /etc/config/$f.bak (оригинал сохранён)\n"
        fi
    else
        printf "  ${YELLOW}пропущен${NC}: /etc/config/$f (файл отсутствует)\n"
    fi
done

# ==================== INSTALL ====================
printf "\n${GREEN}Установка файлов в /etc/config...${NC}\n"
for f in $CONFIG_FILES; do
    cp "$TMPD/$f" "/etc/config/$f"
    printf "  установлен: /etc/config/$f\n"
done

# ==================== CHECK ====================
printf "\n${YELLOW}Проверка синтаксиса конфигов...${NC}\n"
if command -v uci >/dev/null 2>&1; then
    for f in $CONFIG_FILES; do
        if uci -q show "$f" >/dev/null 2>&1; then
            printf "  %s: ${GREEN}OK${NC}\n" "$f"
        else
            printf "  %s: ${YELLOW}предупреждение (uci не смог прочитать)${NC}\n" "$f"
        fi
    done
fi

# ==================== ПЕРЕЗАПУСК ====================
printf "\n${YELLOW}Перезапустить службы сейчас? (y/N): "
read RESTART
case "$RESTART" in
    y|Y)
        for svc in network dnsmasq firewall igmpproxy; do
            printf "  %s... " "$svc"
            if /etc/init.d/$svc restart >/dev/null 2>&1; then
                printf "${GREEN}OK${NC}\n"
            else
                printf "${YELLOW}пропущено${NC}\n"
            fi
        done
        ;;
    *)
        printf "${YELLOW}Перезапусти вручную: /etc/init.d/network restart && /etc/init.d/igmpproxy restart${NC}\n"
        ;;
esac

printf "\n${GREEN}=== Установка v2.1 завершена. ===${NC}\n"
printf "Для отката запусти скрипт снова и выбери пункт 2.\n"
