#!/bin/sh

set -e  

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' 

error_exit() {
    echo -e "${RED}Ошибка: $1${NC}" >&2
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
echo "Выберите версию конфигурации:"
echo "  1 - старая (v1)"
echo "  2 - новая актуальная (v2, рекомендуется)"
printf "Введите номер [2]: "
read VERSION_CHOICE

if [ "$VERSION_CHOICE" = "1" ]; then
    VERSION="v1"
    echo -e "${YELLOW}Выбрана версия v1 (старая)${NC}"

    FILES="
https://raw.githubusercontent.com/v1rtuozz/openwrt-iptv-rostelecom/refs/heads/main/v1/network|network
https://raw.githubusercontent.com/v1rtuozz/openwrt-iptv-rostelecom/refs/heads/main/v1/firewall|firewall
https://raw.githubusercontent.com/v1rtuozz/openwrt-iptv-rostelecom/refs/heads/main/v1/igmpproxy|igmpproxy
"
else
    VERSION="v2"
    echo -e "${GREEN}Выбрана версия v2 (новая, актуальная)${NC}"
    FILES="
https://raw.githubusercontent.com/v1rtuozz/openwrt-iptv-rostelecom/refs/heads/main/v2/network|network
https://raw.githubusercontent.com/v1rtuozz/openwrt-iptv-rostelecom/refs/heads/main/v2/dhcp|dhcp
https://raw.githubusercontent.com/v1rtuozz/openwrt-iptv-rostelecom/refs/heads/main/v2/firewall|firewall
https://raw.githubusercontent.com/v1rtuozz/openwrt-iptv-rostelecom/refs/heads/main/v2/igmpproxy|igmpproxy
"
fi


TMP_DIR=$(mktemp -d) || error_exit "Не удалось создать временную директорию"
trap 'rm -rf "$TMP_DIR"' EXIT  

echo -e "${GREEN}Скачивание файлов конфигурации (версия $VERSION)...${NC}"


echo "$FILES" | while IFS='|' read -r url filename; do
    [ -z "$url" ] && continue
    echo -n "Загрузка $filename... "
    $DOWNLOADER "$TMP_DIR/$filename" "$url" || error_exit "Не удалось загрузить $url"
    echo -e "${GREEN}OK${NC}"
done


NETWORK_FILE="$TMP_DIR/network"


echo -e "\n${YELLOW}Введите учётные данные для доступа к PPPoE (учётная запись провайдера):${NC}"
printf "Имя пользователя: "
read USERNAME


stty -echo
printf "Пароль: "
read PASSWORD
stty echo
echo


stty -echo
printf "Подтвердите пароль: "
read PASSWORD_CONFIRM
stty echo
echo

if [ "$PASSWORD" != "$PASSWORD_CONFIRM" ]; then
    error_exit "Пароли не совпадают."
fi


escape_sed() {
    echo "$1" | sed 's/|/\\|/g'
}

ESCAPED_USERNAME=$(escape_sed "$USERNAME")
ESCAPED_PASSWORD=$(escape_sed "$PASSWORD")

echo -e "\n${GREEN}Настройка файла network с вашими учётными данными...${NC}"
sed -i "s|option username '.*'|option username '$ESCAPED_USERNAME'|" "$NETWORK_FILE"
sed -i "s|option password '.*'|option password '$ESCAPED_PASSWORD'|" "$NETWORK_FILE"


if ! grep -q "option username '$ESCAPED_USERNAME'" "$NETWORK_FILE"; then
    echo -e "${RED}Предупреждение: не удалось заменить имя пользователя. Возможно, файл имеет другой формат.${NC}"
fi
if ! grep -q "option password '$ESCAPED_PASSWORD'" "$NETWORK_FILE"; then
    echo -e "${RED}Предупреждение: не удалось заменить пароль.${NC}"
fi


install_file() {
    local src="$1"
    local dst="$2"
    local filename=$(basename "$dst")

    if [ -f "$dst" ]; then
        cp "$dst" "$dst.bak" && echo "Создана резервная копия $dst.bak"
    fi

    cp "$src" "$dst" && echo "Установлен $filename"
}

echo -e "\n${GREEN}Установка файлов в /etc/config...${NC}"


echo "$FILES" | while IFS='|' read -r url filename; do
    [ -z "$url" ] && continue
    if [ -f "$TMP_DIR/$filename" ]; then
        install_file "$TMP_DIR/$filename" "/etc/config/$filename"
    fi
done


echo -e "\n${YELLOW}Для применения изменений может потребоваться перезапуск служб.${NC}"
printf "Перезапустить службы сейчас? (y/N): "
read RESTART

if [ "$RESTART" = "y" ] || [ "$RESTART" = "Y" ]; then
    echo "Перезапуск network..."
    /etc/init.d/network restart 2>/dev/null || echo "Не удалось перезапустить network"
    echo "Перезапуск dnsmasq..."
    /etc/init.d/dnsmasq restart 2>/dev/null || echo "Не удалось перезапустить dnsmasq"
    echo "Перезапуск firewall..."
    /etc/init.d/firewall restart 2>/dev/null || echo "Не удалось перезапустить firewall"
    echo "Перезапуск igmpproxy..."
    /etc/init.d/igmpproxy restart 2>/dev/null || echo "Не удалось перезапустить igmpproxy"
else
    echo -e "${YELLOW}Перезапустите службы вручную при необходимости.${NC}"
fi

echo -e "\n${GREEN}Установка завершена.${NC}"
echo "Временные файлы удалены."
