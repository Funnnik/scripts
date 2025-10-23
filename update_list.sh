#!/bin/sh

# === Настройки ===
REMOTE_URL="https://raw.githubusercontent.com/Funnnik/domains/refs/heads/main/kvas.list"
TMP_DIR="/opt/tmp"
MD5_FILE="/opt/var/kvas_md5"
TMP_REMOTE="$TMP_DIR/kvas_remote.list"

mkdir -p "$TMP_DIR" /opt/var

# === Скачиваем файл с GitHub ===
curl -s -o "$TMP_REMOTE" "$REMOTE_URL"

# Проверяем успешность загрузки
if [ ! -s "$TMP_REMOTE" ]; then
    echo "[KVAS] Ошибка: не удалось скачать список с GitHub"
    exit 1
fi

# === Считаем хеш нового файла ===
NEW_HASH=$(md5sum "$TMP_REMOTE" | awk '{print $1}')

# === Проверяем, есть ли старый хеш ===
if [ -f "$MD5_FILE" ]; then
    OLD_HASH=$(cat "$MD5_FILE")
else
    OLD_HASH=""
fi

# === Сравнение хешей ===
if [ "$NEW_HASH" = "$OLD_HASH" ]; then
    echo "[KVAS] Изменений нет. Обновление не требуется."
else
    echo "[KVAS] Обнаружены изменения! Обновляю KVAS..."
    yes | kvas purge
    kvas import "$TMP_REMOTE"
    echo "$NEW_HASH" > "$MD5_FILE"
    echo "[KVAS] Обновление завершено успешно."
fi

# === Очистка ===
rm -f "$TMP_REMOTE"
