#!/usr/bin/env bash
# Бэкап стенда Open WebUI.
# Запуск:  ./ops/backup.sh          (из папки ~/openweb)
# Cron:    0 3 * * * /home/david/openweb/ops/backup.sh >> $HOME/backups/openweb/cron.log 2>&1
#
# Что делает:
#   1. останавливает open-webui (чтобы SQLite попал в архив целым);
#   2. пакует том с данными и том Qdrant;
#   3. пакует папку workspace (файлы терминала, они на диске, не в томе);
#   4. копирует .env и docker-compose.yml — без них бэкап неполный;
#   5. поднимает open-webui обратно;
#   6. оставляет последние 7 копий.

set -euo pipefail

cd "$(dirname "$0")/.."

STAMP="$(date +%Y%m%d-%H%M)"
DEST="${BACKUP_DIR:-$HOME/backups/openweb}"
KEEP="${BACKUP_KEEP:-7}"

mkdir -p "$DEST"

echo "[$(date '+%F %T')] старт бэкапа -> $DEST"

# 1. остановить приложение (данные консистентны)
docker compose stop open-webui >/dev/null

# 2-3. тома и workspace
for vol in open-webui openweb_qdrant_data; do
  if docker volume inspect "$vol" >/dev/null 2>&1; then
    echo "  том $vol"
    docker run --rm -u "$(id -u):$(id -g)" -v "$vol":/data:ro -v "$DEST":/backup alpine \ 
      tar czf "/backup/${vol}-${STAMP}.tar.gz" -C /data .
  else
    echo "  том $vol отсутствует — пропуск"
  fi
done

if [ -d workspace ]; then
  echo "  папка workspace"
  tar czf "$DEST/workspace-${STAMP}.tar.gz" -C . workspace
fi

# 4. конфигурация
cp .env "$DEST/env-${STAMP}.bak"
cp docker-compose.yml "$DEST/compose-${STAMP}.yml"

# 5. поднять обратно
docker compose start open-webui >/dev/null

# 6. ротация
for prefix in open-webui openweb_qdrant_data workspace; do
  ls -1t "$DEST/${prefix}-"*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f
done
ls -1t "$DEST"/env-*.bak 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f

echo "[$(date '+%F %T')] готово"
du -sh "$DEST" | sed 's/^/  размер хранилища: /'
