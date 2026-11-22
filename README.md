# LLM Stack — разворачивание домашнего AI-сервера

Стек из четырёх сервисов в Docker Compose + Ollama нативно на хосте:

| Сервис | Роль |
|---|---|
| Open WebUI | панель: чат, RAG, поиск, терминал |
| Qdrant | векторная БД для знаний |
| SearXNG | веб-поиск без сторонних API |
| Open Terminal | песочница с файлами и shell для агентских задач |
| Ollama (нативно) | локальные модели, GPU |

Версии всех образов зафиксированы тегами — обновления не прилетают сами.

## Быстрый старт

```bash
./install.sh
```

Скрипт идемпотентен: ставит Docker и Ollama (если их нет), скачивает модель,
создаёт `.env` с секретами, `searxng/settings.yml`, `docker-compose.yml`,
поднимает стек и прогоняет пять проверок готовности.

```bash
./install.sh --edit          # отредактировать .env (URL, регистрация, таймауты)
./install.sh --rotate-keys   # перегенерировать секреты
MODEL=qwen3.5:9b ./install.sh
```

## Структура

```
install.sh              идемпотентный установщик
docker-compose.yml      стек (проверяется в CI)
.env.example            шаблон настроек, секреты в .env (не в git)
searxng/settings.yml    конфиг поиска (json включён)
ops/backup.sh           бэкап томов + конфигов, ротация 7 копий
ops/RUNBOOK.md          инструкция: обновление, откат, восстановление, сбои
.github/workflows/ci.yml CI: валидация установщика и compose на каждый push
```

## Бэкап

```bash
./ops/backup.sh          # вручную, перед обновлением
```

## Обновление

```bash
./ops/backup.sh
# поменять тег в docker-compose.yml
docker compose pull && docker compose up -d
```

## CI

На каждый push GitHub Actions проверяет:
- синтаксис `install.sh` и `ops/backup.sh` (`bash -n`);
- валидность `docker-compose.yml` (`docker compose config`);
- `shellcheck` (если доступен).

## Безопасность

В git не попадают: `.env`, `workspace/`, бэкапы. Секреты генерируются при первом
запуске. Публикуйте только конфиги и код — ключи, панель 3x-ui и `.env` держите
локально.
