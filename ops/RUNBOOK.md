# Ранбук: Open WebUI на домашнем сервере

Один файл на все случаи: что где лежит, как обновлять, как откатывать, что делать, когда сломалось.

## 1. Что где лежит

| Компонент | Где | Порт |
|---|---|---|
| Open WebUI | контейнер `open-webui` | `3000` → 8080 |
| Qdrant | контейнер `qdrant` | `6333` |
| SearXNG | контейнер `searxng` | `8080` |
| Open Terminal | контейнер `open-terminal` | `8000` |
| Ollama | **нативно в WSL**, не в докере | `11434` |
| Проект | `~/openweb` | — |

| Данные | Где |
|---|---|
| Чаты, пользователи, настройки | том `open-webui` |
| Векторы Knowledge | том `openweb_qdrant_data` |
| Файлы терминала | папка `~/openweb/workspace` (видна в Windows) |
| Секреты | `~/openweb/.env` |
| Бэкапы | `~/backups/openweb` |

## 2. Ежедневные команды

```bash
cd ~/openweb
docker compose ps              # статус
docker compose logs -f open-webui
docker compose restart open-webui
docker compose up -d           # применить изменения compose
```

## 3. Обновление

```bash
cd ~/openweb
./ops/backup.sh                 # 1. бэкап, обязательно
nano docker-compose.yml         # 2. поменять тег в image:
docker compose pull             # 3. скачать
docker compose up -d            # 4. поднять
docker compose ps               # 5. ждём healthy
```

Читать release notes перед сменой тега: <https://github.com/open-webui/open-webui/releases>. Миграции базы односторонние.

Текущие зафиксированные версии:

```yaml
image: ghcr.io/open-webui/open-webui:v0.13.4
image: qdrant/qdrant:v1.20.2
image: searxng/searxng:2026.11.19-368baa340
image: ghcr.io/open-webui/open-terminal:0.17.20
```

## 4. Откат

```bash
nano docker-compose.yml         # вернуть прежний тег
docker compose pull && docker compose up -d
```

Если версия содержала миграцию — тега мало, нужен restore (раздел 5).

## 5. Восстановление из бэкапа

> Осторожно: команды ниже затирают текущие данные. Делать только осознанно.

```bash
cd ~/openweb
docker compose stop open-webui

# чаты и настройки
docker run --rm -v open-webui:/data -v $HOME/backups/openweb:/backup alpine \
  sh -c "rm -rf /data/* && tar xzf /backup/open-webui-ДАТА.tar.gz -C /data"

# векторы
docker run --rm -v openweb_qdrant_data:/data -v $HOME/backups/openweb:/backup alpine \
  sh -c "rm -rf /data/* && tar xzf /backup/openweb_qdrant_data-ДАТА.tar.gz -C /data"

# файлы терминала
tar xzf $HOME/backups/openweb/workspace-ДАТА.tar.gz -C ~/openweb

docker compose start open-webui
```

Проверка бэкапа **до** аварии: раз в месяц развернуть в отдельный том и поднять контейнер на другом порту.

## 6. Типовые сбои

| Симптом | Причина | Лечение |
|---|---|---|
| Поиск: «Search failed», `curl .../format=json` → 403 | в `searxng/settings.yml` нет `json` в `search.formats` или включён `limiter` | поправить файл, `docker compose restart searxng` |
| Модель зациклилась, повторяет рассуждение | слабая модель + падающий инструмент | остановить, **новый чат**; для агентских задач брать `gpt-oss` |
| Модель пишет код вместо выполнения | не включён интерпретатор в чате | проверить тумблер, либо системный промпт пресета |
| `docker compose` пишет «no configuration file» | запущено не из `~/openweb` | `cd ~/openweb` |
| Контейнер не стартует после обновления | миграция или несовместимый тег | `docker compose logs --tail=100 open-webui`, затем откат |
| Пропали чаты | подхватился другой том | `docker compose config \| grep source` → должно быть `open-webui` |

## 7. Что нельзя

- `docker compose down -v` — удаляет тома с данными.
- `docker volume prune` — сносит всё неиспользуемое без вопросов.
- Тег `:latest` и автообновление (Watchtower) — приносят новые версии без бэкапа.
- Менять `WEBUI_SECRET_KEY` после первого запуска — разлогинит всех.
