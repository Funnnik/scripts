#!/bin/sh

export PATH=/opt/bin:/opt/sbin:/usr/bin:/bin:/sbin

REMOTE_URL="https://raw.githubusercontent.com/Funnnik/domains/refs/heads/main/kvas.list"
TMP_DIR="/opt/tmp"
MD5_FILE="/opt/var/kvas_md5"
TMP_REMOTE="$TMP_DIR/kvas_remote.list"
LOCK_FILE="/opt/var/update_list.lock"

# --- Блокировка от повторного запуска ---
if [ -f "$LOCK_FILE" ]; then
    echo "[KVAS] Скрипт уже выполняется. Выход..."
    exit 0
fi
touch "$LOCK_FILE"

cleanup() {
    rm -f "$LOCK_FILE"
}
trap cleanup EXIT

mkdir -p "$TMP_DIR" /opt/var

# === Скачиваем новый список ===
curl -s -o "$TMP_REMOTE" "$REMOTE_URL"
if [ ! -s "$TMP_REMOTE" ]; then
    echo "[KVAS] Ошибка: не удалось скачать список с GitHub"
    exit 1
fi

# === Считаем хеш ===
NEW_HASH=$(md5sum "$TMP_REMOTE" | awk '{print $1}')
[ -f "$MD5_FILE" ] && OLD_HASH=$(cat "$MD5_FILE") || OLD_HASH=""

# === Проверяем изменения ===
if [ "$NEW_HASH" = "$OLD_HASH" ]; then
    echo "[KVAS] Изменений нет. Обновление не требуется."
    rm -f "$TMP_REMOTE"
    exit 0
fi

echo "[KVAS] Обнаружены изменения! Обновляю KVAS..."

# === Очистка с подтверждением (без зависания) ===
TMP_ANSWER="$TMP_DIR/kvas_answer.txt"
echo "Y" > "$TMP_ANSWER"
kvas purge < "$TMP_ANSWER"
rm -f "$TMP_ANSWER"

# === Импорт нового списка ===
kvas import "$TMP_REMOTE"

# === Сохраняем новый хеш ===
echo "$NEW_HASH" > "$MD5_FILE"

echo "[KVAS] Обновление завершено успешно."
rm -f "$TMP_REMOTE"
