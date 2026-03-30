#!/bin/sh

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

error_exit() {
    printf "${RED}Ошибка: %s${NC}\n" "$1" >&2
    exit 1
}

if [ "$(id -u)" -ne 0 ]; then
    error_exit "Скрипт должен быть запущен от root. Используйте sudo или su."
fi

if command -v wget >/dev/null 2>&1; then
    DOWNLOADER="wget -q -O"
elif command -v curl >/dev/null 2>&1; then
    DOWNLOADER="curl -s -o"
else
    error_exit "Не найден wget или curl. Установите один из них."
fi

# Выбор версии
printf "Выберите версию конфигурации:\n"
printf "  1 - старая (v1)\n"
printf "  2 - новая актуальная (v2, рекомендуется)\n"
printf "Введите номер [2]: "
read VERSION_CHOICE

if [ "$VERSION_CHOICE" = "1" ]; then
    VERSION="v1"
    printf "${YELLOW}Выбрана версия v1 (старая)${NC}\n"

    FILES="
https://raw.githubusercontent.com/v1rtuozz/openwrt-iptv-rostelecom/refs/heads/main/v1/network|network
https://raw.githubusercontent.com/v1rtuozz/openwrt-iptv-rostelecom/refs/heads/main/v1/firewall|firewall
https://raw.githubusercontent.com/v1rtuozz/openwrt-iptv-rostelecom/refs/heads/main/v1/igmpproxy|igmpproxy
"
else
    VERSION="v2"
    printf "${GREEN}Выбрана версия v2 (новая, актуальная)${NC}\n"
    FILES="
https://raw.githubusercontent.com/v1rtuozz/openwrt-iptv-rostelecom/refs/heads/main/v2/network|network
https://raw.githubusercontent.com/v1rtuozz/openwrt-iptv-rostelecom/refs/heads/main/v2/dhcp|dhcp
https://raw.githubusercontent.com/v1rtuozz/openwrt-iptv-rostelecom/refs/heads/main/v2/firewall|firewall
https://raw.githubusercontent.com/v1rtuozz/openwrt-iptv-rostelecom/refs/heads/main/v2/igmpproxy|igmpproxy
"
fi

# Запрос портов
printf "\n${YELLOW}Настройка LAN портов:${NC}\n"
printf "Сколько всего LAN портов (не считая WAN)? [4]: "
read TOTAL_PORTS
if [ -z "$TOTAL_PORTS" ]; then
    TOTAL_PORTS=4
fi
if ! echo "$TOTAL_PORTS" | grep -qE '^[0-9]+$' || [ "$TOTAL_PORTS" -lt 1 ]; then
    error_exit "Некорректное количество портов."
fi

printf "В какой порт LAN подключен IPTV (номер от 1 до %s)? [4]: " "$TOTAL_PORTS"
read IPTV_PORT
if [ -z "$IPTV_PORT" ]; then
    IPTV_PORT=4
fi
if ! echo "$IPTV_PORT" | grep -qE '^[0-9]+$' || [ "$IPTV_PORT" -lt 1 ] || [ "$IPTV_PORT" -gt "$TOTAL_PORTS" ]; then
    error_exit "Некорректный номер порта IPTV."
fi

# Скачивание файлов
TMP_DIR=$(mktemp -d) || error_exit "Не удалось создать временную директорию"
trap 'rm -rf "$TMP_DIR"' EXIT

printf "\n${GREEN}Скачивание файлов конфигурации (версия $VERSION)...${NC}\n"

echo "$FILES" | while IFS='|' read -r url filename; do
    [ -z "$url" ] && continue
    printf "Загрузка %s... " "$filename"
    $DOWNLOADER "$TMP_DIR/$filename" "$url" || error_exit "Не удалось загрузить $url"
    printf "${GREEN}OK${NC}\n"
done

NETWORK_FILE="$TMP_DIR/network"

# Ввод PPPoE логина и пароля
printf "\n${YELLOW}Введите учётные данные для доступа к PPPoE (учётная запись провайдера):${NC}\n"
printf "Имя пользователя: "
read USERNAME

printf "Пароль: "
read -s PASSWORD
printf "\n"

printf "Подтвердите пароль: "
read -s PASSWORD_CONFIRM
printf "\n"

if [ "$PASSWORD" != "$PASSWORD_CONFIRM" ]; then
    error_exit "Пароли не совпадают."
fi

escape_sed() {
    echo "$1" | sed 's/|/\\|/g'
}

ESCAPED_USERNAME=$(escape_sed "$USERNAME")
ESCAPED_PASSWORD=$(escape_sed "$PASSWORD")

printf "\n${GREEN}Настройка файла network с вашими учётными данными...${NC}\n"
sed -i "s|option username '.*'|option username '$ESCAPED_USERNAME'|" "$NETWORK_FILE"
sed -i "s|option password '.*'|option password '$ESCAPED_PASSWORD'|" "$NETWORK_FILE"

if ! grep -q "option username '$ESCAPED_USERNAME'" "$NETWORK_FILE"; then
    printf "${RED}Предупреждение: не удалось заменить имя пользователя. Возможно, файл имеет другой формат.${NC}\n"
fi
if ! grep -q "option password '$ESCAPED_PASSWORD'" "$NETWORK_FILE"; then
    printf "${RED}Предупреждение: не удалось заменить пароль.${NC}\n"
fi

# Функция для настройки портов в network
fix_network_ports() {
    local netfile="$1"
    local total="$2"
    local iptv_port="$3"
    local tmpfile="${netfile}.tmp"

    # Формируем списки портов для br-lan и br-iptv
    lan_ports=""
    for i in $(seq 1 "$total"); do
        if [ "$i" -ne "$iptv_port" ]; then
            lan_ports="${lan_ports}\n\tlist ports 'lan$i'"
        fi
    done
    iptv_port_line="\tlist ports 'lan$iptv_port'"

    # Обработка awk: ищем секции config device с именем br-lan и br-iptv
    awk -v lan_ports="$lan_ports" -v iptv_port_line="$iptv_port_line" '
    BEGIN {
        in_brlan = 0
        in_briptv = 0
        printed_extra = 0
    }
    /^config device/ {
        # Начинается новая секция device, сбрасываем флаги
        if (in_brlan) {
            # Выводим сохранённые строки lan_ports, если ещё не вывели
            if (!printed_extra) {
                print lan_ports
                printed_extra = 1
            }
            in_brlan = 0
        }
        if (in_briptv) {
            if (!printed_extra) {
                print iptv_port_line
                printed_extra = 1
            }
            in_briptv = 0
        }
        print
        next
    }
    in_brlan {
        # Внутри секции br-lan
        if ($0 ~ /^[[:space:]]*list ports/) {
            # Пропускаем строки list ports, они будут заменены
            next
        }
        if ($0 ~ /^[[:space:]]*option igmp_snooping/) {
            # Выводим текущую строку и затем вставляем наши порты
            print
            if (!printed_extra) {
                print lan_ports
                printed_extra = 1
            }
            next
        }
        print
        next
    }
    in_briptv {
        # Внутри секции br-iptv
        if ($0 ~ /^[[:space:]]*list ports/) {
            # Пропускаем старые list ports
            next
        }
        if ($0 ~ /^[[:space:]]*option igmp_snooping/ || $0 ~ /^[[:space:]]*option igmpversion/) {
            # Выводим текущую строку и затем вставляем наш порт
            print
            if (!printed_extra) {
                print iptv_port_line
                printed_extra = 1
            }
            next
        }
        print
        next
    }
    {
        # Обычные строки, проверяем начало секции по имени
        if ($0 ~ /^[[:space:]]*option name .br-lan./) {
            in_brlan = 1
            printed_extra = 0
        } else if ($0 ~ /^[[:space:]]*option name .br-iptv./) {
            in_briptv = 1
            printed_extra = 0
        }
        print
    }
    END {
        # Если файл закончился внутри секции, выводим порты
        if (in_brlan && !printed_extra) {
            print lan_ports
        }
        if (in_briptv && !printed_extra) {
            print iptv_port_line
        }
    }' "$netfile" > "$tmpfile"

    mv "$tmpfile" "$netfile"
}

printf "\n${GREEN}Настройка портов LAN в network...${NC}\n"
fix_network_ports "$NETWORK_FILE" "$TOTAL_PORTS" "$IPTV_PORT"

# Установка файлов
install_file() {
    local src="$1"
    local dst="$2"
    local filename=$(basename "$dst")

    if [ -f "$dst" ]; then
        cp "$dst" "$dst.bak" && printf "Создана резервная копия %s.bak\n" "$dst"
    fi

    cp "$src" "$dst" && printf "Установлен %s\n" "$filename"
}

printf "\n${GREEN}Установка файлов в /etc/config...${NC}\n"

echo "$FILES" | while IFS='|' read -r url filename; do
    [ -z "$url" ] && continue
    if [ -f "$TMP_DIR/$filename" ]; then
        install_file "$TMP_DIR/$filename" "/etc/config/$filename"
    fi
done

printf "\n${YELLOW}Для применения изменений может потребоваться перезапуск служб.${NC}\n"
printf "Перезапустить службы сейчас? (y/N): "
read RESTART

if [ "$RESTART" = "y" ] || [ "$RESTART" = "Y" ]; then
    printf "Перезапуск network...\n"
    /etc/init.d/network restart 2>/dev/null || printf "Не удалось перезапустить network\n"
    printf "Перезапуск dnsmasq...\n"
    /etc/init.d/dnsmasq restart 2>/dev/null || printf "Не удалось перезапустить dnsmasq\n"
    printf "Перезапуск firewall...\n"
    /etc/init.d/firewall restart 2>/dev/null || printf "Не удалось перезапустить firewall\n"
    printf "Перезапуск igmpproxy...\n"
    /etc/init.d/igmpproxy restart 2>/dev/null || printf "Не удалось перезапустить igmpproxy\n"
else
    printf "${YELLOW}Перезапустите службы вручную при необходимости.${NC}\n"
fi

printf "\n${GREEN}Установка завершена.${NC}\n"
printf "Временные файлы удалены.\n"
