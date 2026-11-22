#!/usr/bin/env bash
# ============================================================================
# install.sh — разворачивание домашнего AI-сервера с нуля
#
#   Open WebUI + Qdrant + SearXNG + Open Terminal (Docker)
#   Ollama (нативно, systemd) + модель
#
# Использование:
#   ./install.sh                 установить недостающее
#   ./install.sh --edit          создать .env и отредактировать значения
#   ./install.sh --rotate-keys   перегенерировать секреты
#   ./install.sh -y              без вопросов
#   ./install.sh -h              справка
#
# Идемпотентен: не переустанавливает установленное, не перезаписывает .env,
# не трогает данные в томах.
# ============================================================================

set -euo pipefail

MODEL="${MODEL:-qwen3.5:9b}"
EMBED_MODEL="${EMBED_MODEL:-nomic-embed-text}"
DIR="${DIR:-$HOME/openweb}"
PORT="${PORT:-3000}"

WEBUI_TAG="v0.13.4"
QDRANT_TAG="v1.20.2"
SEARXNG_TAG="2026.11.19-368baa340"
TERMINAL_TAG="0.17.20"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
skip() { printf '  \033[90m·\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\n\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
install.sh — AI-сервер: Open WebUI + Qdrant + SearXNG + Open Terminal + Ollama

  ./install.sh                 установить / досоздать недостающее
  ./install.sh --edit          создать .env и отредактировать значения
  ./install.sh --rotate-keys   перегенерировать секреты (разлогинит всех)
  ./install.sh -y              без вопросов, по умолчанию
  ./install.sh -h              эта справка

Переменные окружения:
  MODEL=qwen3.5:9b            модель для Ollama
  EMBED_MODEL=nomic-embed-text
  DIR=~/openweb               папка проекта
  PORT=3000                   внешний порт панели
USAGE
}

rand_hex() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

env_get() { grep -E "^$1=" .env 2>/dev/null | head -1 | cut -d= -f2-; }

env_set() {
  local key="$1" val="$2"
  if grep -qE "^$key=" .env 2>/dev/null; then
    sed -i "s#^$key=.*#$key=$val#" .env
  else
    printf '%s=%s\n' "$key" "$val" >> .env
  fi
}

ensure_env() {
  if [ -f .env ]; then
    skip ".env уже есть — секреты сохранены"
    return
  fi
  warn "создаю .env (ключи: 64 hex = 256 бит)"
  cat > .env <<EOF
WEBUI_SECRET_KEY=$(rand_hex)
OPEN_TERMINAL_API_KEY=$(rand_hex)
WEBUI_URL=http://localhost:$PORT
SEARXNG_BASE_URL=http://localhost:8080
OLLAMA_BASE_URL=http://host.docker.internal:11434
ENABLE_SIGNUP=true
GLOBAL_LOG_LEVEL=INFO
AIOHTTP_CLIENT_TIMEOUT=900
AIOHTTP_CLIENT_STREAM_IDLE_TIMEOUT=600
DATA_VOLUME=open-webui
EOF
  chmod 600 .env
  NEW_ENV=1
  ok ".env создан, права 600"
}

edit_env() {
  if [ ! -t 0 ]; then
    warn "нет терминала — редактирование пропущено"
    return
  fi

  log "Настройка .env (Enter — оставить текущее)"

  local v a

  v=$(env_get WEBUI_URL)
  read -r -p "  Адрес панели             [$v]: " a
  if [ -n "$a" ]; then env_set WEBUI_URL "$a"; fi

  v=$(env_get OLLAMA_BASE_URL)
  read -r -p "  Адрес Ollama             [$v]: " a
  if [ -n "$a" ]; then env_set OLLAMA_BASE_URL "$a"; fi

  v=$(env_get ENABLE_SIGNUP)
  read -r -p "  Регистрация (true/false) [$v]: " a
  if [ -n "$a" ]; then env_set ENABLE_SIGNUP "$a"; fi

  v=$(env_get GLOBAL_LOG_LEVEL)
  read -r -p "  Уровень логов            [$v]: " a
  if [ -n "$a" ]; then env_set GLOBAL_LOG_LEVEL "$a"; fi

  v=$(env_get AIOHTTP_CLIENT_TIMEOUT)
  read -r -p "  Таймаут ответа, сек      [$v]: " a
  if [ -n "$a" ]; then env_set AIOHTTP_CLIENT_TIMEOUT "$a"; fi

  ok ".env обновлён"
}

rotate_keys() {
  warn "перегенерирую секреты: все сессии и подключение терминала станут недействительны"
  env_set WEBUI_SECRET_KEY "$(rand_hex)"
  env_set OPEN_TERMINAL_API_KEY "$(rand_hex)"
  ok "ключи обновлены"
  warn "новый ключ терминала вставьте в Admin → Integrations"
  if [ -f docker-compose.yml ]; then
    docker compose up -d open-webui open-terminal
  fi
}

# ---------------------------------------------------------------------------
# Разбор аргументов
# ---------------------------------------------------------------------------
EDIT_ENV=0
ROTATE=0
ASSUME_YES=0
NEW_ENV=0

for arg in "$@"; do
  case "$arg" in
    --edit)        EDIT_ENV=1 ;;
    --rotate-keys) ROTATE=1 ;;
    -y|--yes)      ASSUME_YES=1 ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "неизвестный аргумент: $arg (см. --help)" ;;
  esac
done

# ---------------------------------------------------------------------------
# 1. Проверки окружения
# ---------------------------------------------------------------------------
log "Проверка окружения"

[ "$(uname -s)" = "Linux" ] || die "Нужен Linux (в Windows используйте WSL2)"
command -v curl >/dev/null || die "Нет curl: sudo apt-get install -y curl"
command -v sudo >/dev/null || die "Нужен sudo"

. /etc/os-release 2>/dev/null || true
ok "система: ${PRETTY_NAME:-Linux}"
ok "пользователь: $USER"

if grep -qi microsoft /proc/version 2>/dev/null; then
  ok "обнаружен WSL2"
fi

# ---------------------------------------------------------------------------
# 2. Docker
# ---------------------------------------------------------------------------
log "Docker"

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  skip "уже установлен и доступен без sudo"
else
  if command -v docker >/dev/null 2>&1; then
    warn "docker есть, но нет доступа — добавляю $USER в группу docker"
    sudo usermod -aG docker "$USER"
    if command -v sg >/dev/null 2>&1; then
      ok "перезапуск скрипта с группой docker"
      exec sg docker -c "$(printf '%q ' "$0" "$@")"
    fi
    die "перелогиньтесь и запустите скрипт снова"
  fi

  warn "устанавливаю Docker Engine + compose plugin"
  curl -fsSL https://get.docker.com | sudo sh
  sudo usermod -aG docker "$USER"
  sudo systemctl enable --now docker >/dev/null 2>&1 || true

  if command -v sg >/dev/null 2>&1; then
    ok "перезапуск скрипта с группой docker"
    exec sg docker -c "$(printf '%q ' "$0" "$@")"
  fi
  die "Docker установлен. Перелогиньтесь и запустите скрипт снова"
fi

docker compose version >/dev/null 2>&1 || die "Нет docker compose plugin"
ok "docker $(docker --version | awk '{print $3}' | tr -d ,)"
ok "compose $(docker compose version --short 2>/dev/null || echo ok)"

# ---------------------------------------------------------------------------
# 3. Ollama
# ---------------------------------------------------------------------------
log "Ollama"

if ! command -v ollama >/dev/null 2>&1; then
  warn "устанавливаю ollama"
  curl -fsSL https://ollama.com/install.sh | sh
else
  skip "уже установлена"
fi

if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q '^ollama.service'; then
  sudo systemctl enable --now ollama >/dev/null 2>&1 || true
fi

for i in $(seq 1 30); do
  if curl -sf http://localhost:11434/api/tags >/dev/null 2>&1; then
    break
  fi
  if [ "$i" -eq 30 ]; then
    die "Ollama не отвечает на localhost:11434"
  fi
  sleep 1
done
ok "API Ollama отвечает"

pull_model() {
  local m="$1"
  if ollama list 2>/dev/null | awk '{print $1}' | grep -qx "$m"; then
    skip "модель $m уже скачана"
  else
    warn "скачиваю $m (долго)"
    ollama pull "$m"
    ok "модель $m готова"
  fi
}

pull_model "$MODEL"
pull_model "$EMBED_MODEL"

# ---------------------------------------------------------------------------
# 4. Файлы проекта
# ---------------------------------------------------------------------------
log "Файлы проекта: $DIR"

mkdir -p "$DIR"/{searxng,workspace,ops}
cd "$DIR"

ensure_env

if [ "$ROTATE" -eq 1 ]; then
  rotate_keys
fi

if [ "$EDIT_ENV" -eq 1 ] || { [ "$NEW_ENV" -eq 1 ] && [ "$ASSUME_YES" -eq 0 ]; }; then
  edit_env
fi

if [ -f searxng/settings.yml ]; then
  skip "searxng/settings.yml уже есть"
else
  warn "создаю конфиг SearXNG с поддержкой JSON"
  cat > searxng/settings.yml <<'EOF'
use_default_settings: true

server:
  secret_key: "CHANGE_ME"
  limiter: false

search:
  formats:
    - html
    - json
EOF
  sed -i "s/CHANGE_ME/$(rand_hex)/" searxng/settings.yml
  ok "settings.yml создан"
fi

if [ -f docker-compose.yml ]; then
  skip "docker-compose.yml уже есть — не перезаписываю"
else
  warn "создаю docker-compose.yml"
  cat > docker-compose.yml <<EOF
services:
  open-webui:
    image: ghcr.io/open-webui/open-webui:$WEBUI_TAG
    container_name: open-webui
    restart: unless-stopped
    ports:
      - "$PORT:8080"
    volumes:
      - open-webui:/app/backend/data
    environment:
      WEBUI_URL: \${WEBUI_URL}
      WEBUI_SECRET_KEY: \${WEBUI_SECRET_KEY}
      ENABLE_SIGNUP: \${ENABLE_SIGNUP}
      GLOBAL_LOG_LEVEL: \${GLOBAL_LOG_LEVEL}
      OLLAMA_BASE_URL: \${OLLAMA_BASE_URL}
      AIOHTTP_CLIENT_TIMEOUT: \${AIOHTTP_CLIENT_TIMEOUT}
      AIOHTTP_CLIENT_STREAM_IDLE_TIMEOUT: \${AIOHTTP_CLIENT_STREAM_IDLE_TIMEOUT}
      VECTOR_DB: qdrant
      QDRANT_URI: http://qdrant:6333
      ENABLE_WEB_SEARCH: "true"
      WEB_SEARCH_ENGINE: searxng
      SEARXNG_QUERY_URL: http://searxng:8080/search?q=<query>
    extra_hosts:
      - "host.docker.internal:host-gateway"
    depends_on:
      - qdrant
      - searxng
      - open-terminal
    networks:
      - webui-net
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=5).getcode()==200 else 1)"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 120s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "5"

  qdrant:
    image: qdrant/qdrant:$QDRANT_TAG
    container_name: qdrant
    restart: unless-stopped
    volumes:
      - qdrant_data:/qdrant/storage
    networks:
      - webui-net

  searxng:
    image: searxng/searxng:$SEARXNG_TAG
    container_name: searxng
    restart: unless-stopped
    ports:
      - "127.0.0.1:8080:8080"
    volumes:
      - ./searxng:/etc/searxng
      - searxng_cache:/var/cache/searxng
    environment:
      SEARXNG_BASE_URL: \${SEARXNG_BASE_URL}
    networks:
      - webui-net

  open-terminal:
    image: ghcr.io/open-webui/open-terminal:$TERMINAL_TAG
    container_name: open-terminal
    restart: unless-stopped
    ports:
      - "127.0.0.1:8000:8000"
    volumes:
      - ./workspace:/home/user
    environment:
      OPEN_TERMINAL_API_KEY: \${OPEN_TERMINAL_API_KEY}
    networks:
      - webui-net

volumes:
  open-webui:
    name: \${DATA_VOLUME}
  qdrant_data:
  searxng_cache:

networks:
  webui-net:
    driver: bridge
EOF
  ok "docker-compose.yml создан"
fi

# ---------------------------------------------------------------------------
# 5. Запуск
# ---------------------------------------------------------------------------
log "Запуск стека"

docker compose pull
docker compose up -d

log "Ожидание готовности Open WebUI (до 3 минут)"
for i in $(seq 1 90); do
  if curl -sf "http://localhost:$PORT/health" >/dev/null 2>&1; then
    ok "Open WebUI отвечает"
    break
  fi
  if [ "$i" -eq 90 ]; then
    die "Open WebUI не поднялся: docker compose logs --tail=80 open-webui"
  fi
  sleep 2
done

# ---------------------------------------------------------------------------
# 6. Проверки
# ---------------------------------------------------------------------------
log "Проверки"

fail=0
check() {
  local name="$1" url="$2" expect="${3:-200}" code
  code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$url" || echo 000)
  if [ "$code" = "$expect" ]; then
    ok "$name ($code)"
  else
    warn "$name → $code, ожидался $expect"
    fail=$((fail + 1))
  fi
}

check "Open WebUI"    "http://localhost:$PORT/health"
check "SearXNG JSON"  "http://localhost:8080/search?q=test&format=json"
check "Open Terminal" "http://localhost:8000/health"
check "Qdrant"        "http://localhost:6333/collections"
check "Ollama API"    "http://localhost:11434/api/tags"

if docker compose ps --format '{{.Name}} {{.Status}}' 2>/dev/null | grep -q 'open-webui.*healthy'; then
  ok "контейнер open-webui: healthy"
else
  warn "open-webui ещё не healthy (первые минуты — норма)"
fi

if ollama list 2>/dev/null | awk '{print $1}' | grep -qx "$MODEL"; then
  ok "модель $MODEL на месте"
else
  warn "модель $MODEL не найдена"
  fail=$((fail + 1))
fi

# ---------------------------------------------------------------------------
# 7. Итог
# ---------------------------------------------------------------------------
log "Готово"

TERM_KEY=$(env_get OPEN_TERMINAL_API_KEY)

cat <<EOF

  Панель:            http://localhost:$PORT
  Проект:            $DIR
  Файлы терминала:   $DIR/workspace  (видны в Windows)
  Конфиг:            $DIR/.env  (править: ./install.sh --edit)

  Первый вход:
    1. Откройте панель и создайте аккаунт — он станет админом.
    2. Admin → Settings → Documents → Embedding:
         Engine: Ollama, Model: $EMBED_MODEL
    3. Admin → Settings → Integrations → Open Terminal → «+»:
         URL: http://open-terminal:8000
         Key: $TERM_KEY

EOF

if [ "$fail" -gt 0 ]; then
  warn "проверок с замечаниями: $fail"
  exit 1
fi

ok "все проверки пройдены"
