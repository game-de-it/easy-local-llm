#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

###############################################################################
# Easy Local LLM for Android + Termux + llama.cpp
# Stable Termux edition
#
# 方針:
# - CPU default
# - Vulkan OFF
# - llama.cpp version pinned to b6811
# - tests OFF
# - build llama-server only
###############################################################################

APP_NAME="Easy Local LLM"

BASE_DIR="$HOME/easy-local-llm"
REPO_DIR="$BASE_DIR/llama.cpp"
MODEL_DIR="$BASE_DIR/models"
LOG_DIR="$BASE_DIR/logs"
CACHE_DIR="$BASE_DIR/cache"
PID_FILE="$BASE_DIR/llama-server.pid"
ENV_FILE="$BASE_DIR/runtime.env"

SHORTCUTS_DIR="$HOME/.shortcuts"
DYNAMIC_SHORTCUTS_DIR="$HOME/.termux/widget/dynamic_shortcuts"

MODEL_URL_DEFAULT="https://huggingface.co/unsloth/gemma-3-4b-it-GGUF/resolve/main/gemma-3-4b-it-UD-Q6_K_XL.gguf"
MODEL_FILE_DEFAULT="$MODEL_DIR/gemma-3-4b-it-UD-Q6_K_XL.gguf"
MODEL_NAME_DEFAULT="gemma-3-4b-it-UD-Q6_K_XL"

LLAMA_REPO_URL="https://github.com/ggml-org/llama.cpp"
LLAMA_VERSION_TAG="b6811"

TERMUX_GITHUB_RELEASES_URL="https://github.com/termux/termux-app/releases"
TERMUX_WIKI_URL="https://wiki.termux.dev/wiki/Main_Page"
TERMUX_API_RELEASES_URL="https://github.com/termux/termux-api/releases"
TERMUX_WIDGET_REPO_URL="https://github.com/termux/termux-widget"
HF_MODEL_PAGE_URL="https://huggingface.co/unsloth/gemma-3-4b-it-GGUF"

HOST_DEFAULT="0.0.0.0"
PORT_DEFAULT="8080"
THREADS_DEFAULT="$(nproc)"
JOBS_DEFAULT="$(nproc)"

# CPU default
CTX_SIZE_DEFAULT="2048"
GPU_MODE_DEFAULT="cpu"      # cpu only by default
OPEN_BROWSER_DEFAULT="1"    # 1=yes 0=no
USE_WAKELOCK_DEFAULT="1"    # 1=yes 0=no

BUILD_LOG="$LOG_DIR/build.log"
SERVER_LOG="$LOG_DIR/server.log"
DOWNLOAD_LOG="$LOG_DIR/download.log"
SETUP_LOG="$LOG_DIR/setup.log"

mkdir -p "$BASE_DIR" "$MODEL_DIR" "$LOG_DIR" "$CACHE_DIR"

###############################################################################
# helpers
###############################################################################

green()  { printf "\033[1;32m%s\033[0m\n" "$*"; }
blue()   { printf "\033[1;34m%s\033[0m\n" "$*"; }
yellow() { printf "\033[1;33m%s\033[0m\n" "$*"; }
red()    { printf "\033[1;31m%s\033[0m\n" "$*"; }
bold()   { printf "\033[1m%s\033[0m\n" "$*"; }

step() {
  local n="$1"
  local msg="$2"
  printf "\n\033[1;32m[%s]\033[0m %s\n" "$n" "$msg"
}

info() { printf "\033[1;34m[i]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[!]\033[0m %s\n" "$*"; }
fail() { printf "\033[1;31m[x]\033[0m %s\n" "$*" >&2; exit 1; }

have() {
  command -v "$1" >/dev/null 2>&1
}

need() {
  have "$1" || fail "必要なコマンドが見つかりません: $1"
}

save_env() {
  cat > "$ENV_FILE" <<EOF
HOST="${HOST:-$HOST_DEFAULT}"
PORT="${PORT:-$PORT_DEFAULT}"
THREADS="${THREADS:-$THREADS_DEFAULT}"
JOBS="${JOBS:-$JOBS_DEFAULT}"
CTX_SIZE="${CTX_SIZE:-$CTX_SIZE_DEFAULT}"
GPU_MODE="${GPU_MODE:-$GPU_MODE_DEFAULT}"
OPEN_BROWSER="${OPEN_BROWSER:-$OPEN_BROWSER_DEFAULT}"
USE_WAKELOCK="${USE_WAKELOCK:-$USE_WAKELOCK_DEFAULT}"
MODEL_URL="${MODEL_URL:-$MODEL_URL_DEFAULT}"
MODEL_FILE="${MODEL_FILE:-$MODEL_FILE_DEFAULT}"
MODEL_NAME="${MODEL_NAME:-$MODEL_NAME_DEFAULT}"
LLAMA_VERSION="${LLAMA_VERSION:-$LLAMA_VERSION_TAG}"
LAST_SERVER_BIN="${LAST_SERVER_BIN:-}"
EOF
}

load_env() {
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
  fi

  HOST="${HOST:-$HOST_DEFAULT}"
  PORT="${PORT:-$PORT_DEFAULT}"
  THREADS="${THREADS:-$THREADS_DEFAULT}"
  JOBS="${JOBS:-$JOBS_DEFAULT}"
  CTX_SIZE="${CTX_SIZE:-$CTX_SIZE_DEFAULT}"
  GPU_MODE="${GPU_MODE:-$GPU_MODE_DEFAULT}"
  OPEN_BROWSER="${OPEN_BROWSER:-$OPEN_BROWSER_DEFAULT}"
  USE_WAKELOCK="${USE_WAKELOCK:-$USE_WAKELOCK_DEFAULT}"
  MODEL_URL="${MODEL_URL:-$MODEL_URL_DEFAULT}"
  MODEL_FILE="${MODEL_FILE:-$MODEL_FILE_DEFAULT}"
  MODEL_NAME="${MODEL_NAME:-$MODEL_NAME_DEFAULT}"
  LLAMA_VERSION="${LLAMA_VERSION:-$LLAMA_VERSION_TAG}"
  LAST_SERVER_BIN="${LAST_SERVER_BIN:-}"
}

device_mem_mb() {
  awk '/MemTotal/ {printf "%d\n", $2/1024}' /proc/meminfo
}

auto_ctx_size() {
  local mem
  mem="$(device_mem_mb)"
  if [[ "$mem" -lt 5500 ]]; then
    echo 2048
  elif [[ "$mem" -lt 9000 ]]; then
    echo 4096
  else
    echo 4096
  fi
}

get_wlan_ipv4() {
  if have ip; then
    ip -4 addr show wlan0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1
    return 0
  fi
  return 1
}

get_any_ipv4() {
  if have ip; then
    ip -4 addr show 2>/dev/null | awk '/inet / && $2 !~ /^127\./ {print $2}' | cut -d/ -f1 | head -n1
    return 0
  fi
  if have ifconfig; then
    ifconfig 2>/dev/null | awk '/inet / && $2 != "127.0.0.1" {print $2}' | head -n1
    return 0
  fi
  return 1
}

get_local_ip() {
  local ip_addr=""
  ip_addr="$(get_wlan_ipv4 || true)"
  if [[ -n "$ip_addr" ]]; then
    echo "$ip_addr"
    return 0
  fi
  ip_addr="$(get_any_ipv4 || true)"
  if [[ -n "$ip_addr" ]]; then
    echo "$ip_addr"
    return 0
  fi
  echo ""
}

server_pid_running() {
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
  else
    return 1
  fi
}

print_links() {
  echo
  bold "参考URL"
  echo "  llama.cpp             : $LLAMA_REPO_URL"
  echo "  pinned version        : $LLAMA_VERSION_TAG"
  echo "  Hugging Face model    : $HF_MODEL_PAGE_URL"
  echo "  direct model file     : $MODEL_URL"
  echo "  Termux Releases       : $TERMUX_GITHUB_RELEASES_URL"
  echo "  Termux Wiki           : $TERMUX_WIKI_URL"
  echo "  Termux:API Releases   : $TERMUX_API_RELEASES_URL"
  echo "  Termux:Widget         : $TERMUX_WIDGET_REPO_URL"
  echo
}

print_beginner_notes() {
  echo
  bold "初心者向けメモ"
  echo "  1. このスクリプトは安定性重視で CPU 動作をデフォルトにしています。"
  echo "  2. 同じWi-Fi内のPCやタブレットからアクセスできます。"
  echo "  3. 重い場合は CTX_SIZE=2048 のまま使うのがおすすめです。"
  echo "  4. 長時間使う場合は Android のバッテリー最適化を見直すと安定しやすいです。"
  echo "  5. Termux:Widget を入れると次回からホーム画面1タップ起動ができます。"
  echo
}

print_urls() {
  local local_ip="$1"
  echo
  bold "アクセス先"
  echo "  この端末内         : http://127.0.0.1:$PORT"
  if [[ -n "$local_ip" ]]; then
    echo "  同じWi-Fi内の端末  : http://$local_ip:$PORT"
  else
    echo "  同じWi-Fi内の端末  : IP取得失敗のため未表示"
  fi
  echo
}

open_browser_if_possible() {
  local local_ip="$1"
  local url=""
  if [[ -n "$local_ip" ]]; then
    url="http://$local_ip:$PORT"
  else
    url="http://127.0.0.1:$PORT"
  fi

  if [[ "$OPEN_BROWSER" = "1" ]] && have termux-open-url; then
    info "ブラウザを開きます: $url"
    termux-open-url "$url" >/dev/null 2>&1 || true
  fi
}

recommend_retry_commands() {
  echo
  bold "再試行例"
  echo "  軽めの設定で起動:"
  echo "    CTX_SIZE=2048 $0 start"
  echo
  echo "  ログ確認:"
  echo "    $0 logs"
  echo
}

confirm_yes_no() {
  local prompt="${1:-続行しますか? [y/N] }"
  local ans
  read -r -p "$prompt" ans || true
  case "${ans:-}" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

###############################################################################
# widget shortcuts
###############################################################################

create_widget_shortcuts() {
  mkdir -p "$SHORTCUTS_DIR"

  cat > "$SHORTCUTS_DIR/LLM起動" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
"$HOME/easy-llm.sh" start
EOF

  cat > "$SHORTCUTS_DIR/LLM停止" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
"$HOME/easy-llm.sh" stop
EOF

  cat > "$SHORTCUTS_DIR/LLM状態" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
"$HOME/easy-llm.sh" status
EOF

  cat > "$SHORTCUTS_DIR/LLM URL" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
"$HOME/easy-llm.sh" urls
EOF

  chmod +x \
    "$SHORTCUTS_DIR/LLM起動" \
    "$SHORTCUTS_DIR/LLM停止" \
    "$SHORTCUTS_DIR/LLM状態" \
    "$SHORTCUTS_DIR/LLM URL"

  info "Termux:Widget 用ショートカットを作成しました"
  info "  $SHORTCUTS_DIR/LLM起動"
  info "  $SHORTCUTS_DIR/LLM停止"
  info "  $SHORTCUTS_DIR/LLM状態"
  info "  $SHORTCUTS_DIR/LLM URL"
}

remove_widget_shortcuts() {
  rm -f \
    "$SHORTCUTS_DIR/LLM起動" \
    "$SHORTCUTS_DIR/LLM停止" \
    "$SHORTCUTS_DIR/LLM状態" \
    "$SHORTCUTS_DIR/LLM URL"

  rm -f \
    "$DYNAMIC_SHORTCUTS_DIR/LLM起動" \
    "$DYNAMIC_SHORTCUTS_DIR/LLM停止" \
    "$DYNAMIC_SHORTCUTS_DIR/LLM状態" \
    "$DYNAMIC_SHORTCUTS_DIR/LLM URL"
}

print_widget_guide() {
  echo
  bold "Termux:Widget の使い方"
  echo "  1. Termux:Widget をインストール"
  echo "  2. ホーム画面に Termux:Widget を追加"
  echo "  3. 一覧に 'LLM起動' などが表示されます"
  echo "  4. 次回から 'LLM起動' をタップするだけで使えます"
  echo
}

###############################################################################
# llama.cpp setup/build
###############################################################################

clone_or_update_repo() {
  if [[ -d "$REPO_DIR/.git" ]]; then
    info "既存リポジトリを更新します"
    git -C "$REPO_DIR" fetch --tags --all 2>&1 | tee -a "$SETUP_LOG"
  else
    info "llama.cpp を clone します"
    git clone "$LLAMA_REPO_URL" "$REPO_DIR" 2>&1 | tee -a "$SETUP_LOG"
  fi
}

checkout_pinned_version() {
  cd "$REPO_DIR"
  info "llama.cpp を $LLAMA_VERSION_TAG に固定します"
  git fetch --tags 2>&1 | tee -a "$SETUP_LOG"
  git checkout "$LLAMA_VERSION_TAG" 2>&1 | tee -a "$SETUP_LOG"
}

build_server_cpu_only() {
  cd "$REPO_DIR"
  mkdir -p "$LOG_DIR"
  : > "$BUILD_LOG"

  info "古い build ディレクトリを削除します"
  rm -rf build

  info "CMake 構成を作成します"
  cmake -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_VULKAN=OFF \
    -DLLAMA_BUILD_SERVER=ON \
    -DLLAMA_BUILD_TESTS=OFF \
    -DGGML_BUILD_TESTS=OFF \
    2>&1 | tee "$BUILD_LOG"

  info "利用可能な server ターゲットを確認します"
  local target=""
  if cmake --build build --target help | grep -q 'llama-server'; then
    target="llama-server"
  elif cmake --build build --target help | grep -qE '(^| )server($| )'; then
    target="server"
  else
    cmake --build build --target help | tee -a "$BUILD_LOG"
    fail "server ターゲットが見つかりませんでした"
  fi

  info "ビルドターゲット: $target"
  cmake --build build -j"$JOBS" --target "$target" 2>&1 | tee -a "$BUILD_LOG"

  if [[ -x "$REPO_DIR/build/bin/llama-server" ]]; then
    LAST_SERVER_BIN="$REPO_DIR/build/bin/llama-server"
  elif [[ -x "$REPO_DIR/build/bin/server" ]]; then
    LAST_SERVER_BIN="$REPO_DIR/build/bin/server"
  else
    fail "server 実行ファイルが見つかりません"
  fi

  save_env
}

###############################################################################
# commands
###############################################################################

cmd_help() {
  cat <<EOF
$APP_NAME

使い方:
  $0 install     初回セットアップ + ビルド + モデルDL + 起動
  $0 start       サーバ起動
  $0 stop        サーバ停止
  $0 restart     サーバ再起動
  $0 status      状態確認
  $0 urls        現在のURL表示
  $0 logs        サーバログ表示
  $0 uninstall   環境削除
  $0 help        このヘルプ

主な環境変数:
  HOST=0.0.0.0
  PORT=8080
  CTX_SIZE=2048|4096
  THREADS=<number>
  OPEN_BROWSER=1|0
  USE_WAKELOCK=1|0

例:
  $0 install
  CTX_SIZE=2048 $0 start
  PORT=9000 $0 restart
  $0 uninstall
EOF
}

cmd_install() {
  load_env

  step "1/8" "Termux と端末の基本確認"
  need bash
  need pkg
  need git
  need awk
  need grep
  need sed
  need cmake
  need make
  need clang

  local arch
  arch="$(uname -m)"
  info "CPU architecture: $arch"
  if [[ "$arch" != "aarch64" && "$arch" != "arm64" ]]; then
    warn "aarch64 以外です。性能や互換性が落ちる可能性があります。"
  fi

  CTX_SIZE="$(auto_ctx_size)"
  info "RAMに応じて推奨コンテキストを自動設定: CTX_SIZE=$CTX_SIZE"

  step "2/8" "必要パッケージをインストール"
  pkg update -y 2>&1 | tee "$SETUP_LOG"
  pkg upgrade -y 2>&1 | tee -a "$SETUP_LOG"
  pkg install -y git cmake clang make wget curl iproute2 procps 2>&1 | tee -a "$SETUP_LOG"

  if ! have termux-open-url; then
    warn "termux-open-url が見つかりません。環境によってはブラウザ自動起動が使えません。"
  fi

  step "3/8" "llama.cpp を取得"
  clone_or_update_repo

  step "4/8" "動作確認済みバージョンへ固定"
  checkout_pinned_version

  step "5/8" "CPU モードで llama-server をビルド"
  build_server_cpu_only

  step "6/8" "モデルをダウンロード"
  mkdir -p "$(dirname "$MODEL_FILE")"
  : > "$DOWNLOAD_LOG"
  if [[ -f "$MODEL_FILE" && -s "$MODEL_FILE" ]]; then
    info "モデルは既に存在します"
    info "  $MODEL_FILE"
  else
    info "ダウンロード先:"
    info "  $MODEL_FILE"
    info "ダウンロード元:"
    info "  $MODEL_URL"
    if have curl; then
      curl -L --progress-bar "$MODEL_URL" -o "$MODEL_FILE" 2>>"$DOWNLOAD_LOG"
    else
      wget --show-progress -O "$MODEL_FILE" "$MODEL_URL" 2>>"$DOWNLOAD_LOG"
    fi
  fi

  [[ -s "$MODEL_FILE" ]] || fail "モデルファイルが空です。ダウンロードに失敗した可能性があります。"

  step "7/8" "Termux:Widget 用ショートカットを作成"
  create_widget_shortcuts

  step "8/8" "サーバを起動"
  cmd_start

  local local_ip
  local_ip="$(get_local_ip || true)"

  echo
  bold "セットアップ完了"
  echo "  サーバ種別         : $(basename "$LAST_SERVER_BIN")"
  echo "  利用モデル         : $MODEL_NAME"
  echo "  モデルファイル      : $MODEL_FILE"
  echo "  llama.cpp version   : $LLAMA_VERSION_TAG"
  echo "  動作モード          : CPU"
  echo "  ホスト              : $HOST"
  echo "  ポート              : $PORT"
  echo "  コンテキスト長      : $CTX_SIZE"
  echo "  スレッド数          : $THREADS"
  print_urls "$local_ip"
  print_beginner_notes
  print_widget_guide
  print_links
  open_browser_if_possible "$local_ip"
}

cmd_start() {
  load_env

  need curl
  need awk
  need grep

  [[ -f "$MODEL_FILE" ]] || fail "モデルファイルがありません: $MODEL_FILE"

  local server_bin="${LAST_SERVER_BIN:-}"
  if [[ -z "$server_bin" || ! -x "$server_bin" ]]; then
    if [[ -x "$REPO_DIR/build/bin/llama-server" ]]; then
      server_bin="$REPO_DIR/build/bin/llama-server"
    elif [[ -x "$REPO_DIR/build/bin/server" ]]; then
      server_bin="$REPO_DIR/build/bin/server"
    else
      fail "server 実行ファイルがありません。先に '$0 install' を実行してください。"
    fi
  fi

  if server_pid_running; then
    warn "既にサーバが起動しています (PID=$(cat "$PID_FILE"))"
    cmd_urls
    exit 0
  fi

  if [[ "$USE_WAKELOCK" = "1" ]] && have termux-wake-lock; then
    info "termux-wake-lock を有効化します"
    termux-wake-lock || true
  fi

  mkdir -p "$LOG_DIR"
  : > "$SERVER_LOG"

  info "サーバを起動します"
  info "  binary  = $server_bin"
  info "  mode    = CPU"
  info "  host    = $HOST"
  info "  port    = $PORT"
  info "  ctx     = $CTX_SIZE"
  info "  threads = $THREADS"

  set +e
  nohup "$server_bin" \
    -m "$MODEL_FILE" \
    --host "$HOST" \
    --port "$PORT" \
    -t "$THREADS" \
    -c "$CTX_SIZE" \
    -ngl 0 \
    >"$SERVER_LOG" 2>&1 &
  local pid=$!
  set -e

  echo "$pid" > "$PID_FILE"

  printf "\n"
  info "起動待ち..."
  local i
  for i in $(seq 1 90); do
    if curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
      LAST_SERVER_BIN="$server_bin"
      save_env

      green "サーバ起動成功"
      local local_ip
      local_ip="$(get_local_ip || true)"

      echo "  PID                : $pid"
      print_urls "$local_ip"
      open_browser_if_possible "$local_ip"
      return 0
    fi

    if ! kill -0 "$pid" 2>/dev/null; then
      warn "サーバプロセスが終了しました。"
      break
    fi

    printf "\r待機中... %02d/90" "$i"
    sleep 1
  done
  printf "\n"

  red "サーバ起動に失敗しました。"
  echo "確認ログ:"
  echo "  $SERVER_LOG"
  echo
  tail -n 80 "$SERVER_LOG" || true
  recommend_retry_commands
  exit 1
}

cmd_stop() {
  if server_pid_running; then
    local pid
    pid="$(cat "$PID_FILE")"
    info "サーバを停止します: PID=$pid"
    kill "$pid" || true
    sleep 2
    rm -f "$PID_FILE"
    if have termux-wake-unlock; then
      termux-wake-unlock || true
    fi
    green "停止しました"
  else
    warn "停止対象のサーバは見つかりませんでした"
    rm -f "$PID_FILE" || true
  fi
}

cmd_restart() {
  cmd_stop
  cmd_start
}

cmd_status() {
  load_env
  echo
  bold "状態"
  echo "  APP                : $APP_NAME"
  echo "  BASE_DIR           : $BASE_DIR"
  echo "  MODEL_FILE         : $MODEL_FILE"
  echo "  MODEL_URL          : $MODEL_URL"
  echo "  LLAMA_VERSION      : $LLAMA_VERSION"
  echo "  HOST               : $HOST"
  echo "  PORT               : $PORT"
  echo "  THREADS            : $THREADS"
  echo "  CTX_SIZE           : $CTX_SIZE"
  echo "  MODE               : CPU"
  echo "  SERVER_BIN         : ${LAST_SERVER_BIN:-unknown}"
  echo "  SERVER_LOG         : $SERVER_LOG"
  echo "  BUILD_LOG          : $BUILD_LOG"
  if server_pid_running; then
    echo "  RUNNING            : yes (PID=$(cat "$PID_FILE"))"
  else
    echo "  RUNNING            : no"
  fi
  echo
  cmd_urls
}

cmd_logs() {
  mkdir -p "$LOG_DIR"
  if [[ -f "$SERVER_LOG" ]]; then
    tail -n 200 -f "$SERVER_LOG"
  else
    warn "サーバログがありません: $SERVER_LOG"
  fi
}

cmd_urls() {
  load_env
  local local_ip
  local_ip="$(get_local_ip || true)"
  print_urls "$local_ip"
}

cmd_uninstall() {
  load_env

  echo
  bold "アンインストール"
  echo "この操作で以下を削除します:"
  echo "  - llama.cpp の取得物とビルド成果物"
  echo "  - ダウンロードしたモデル"
  echo "  - ログ、設定、PID"
  echo "  - Termux:Widget 用ショートカット"
  echo
  echo "削除対象ディレクトリ:"
  echo "  $BASE_DIR"
  echo

  if ! confirm_yes_no "本当に削除しますか? [y/N] "; then
    echo "中止しました。"
    exit 0
  fi

  step "1/4" "起動中サーバを停止"
  if server_pid_running; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]]; then
      info "停止します: PID=$pid"
      kill "$pid" || true
      sleep 2
    fi
  fi
  rm -f "$PID_FILE" || true

  if have termux-wake-unlock; then
    termux-wake-unlock || true
  fi

  step "2/4" "Termux:Widget 用ショートカットを削除"
  remove_widget_shortcuts

  step "3/4" "本体データを削除"
  rm -rf "$BASE_DIR"

  step "4/4" "案内を表示"
  green "削除が完了しました。"
  echo
  echo "手動で必要になることがあるもの:"
  echo "  1. ホーム画面に置いたショートカットの削除"
  echo "  2. Termux:Widget アプリのアンインストール"
  echo "  3. Termux アプリのアンインストール"
  echo
  echo "easy-llm.sh 自体は残っています。不要なら次で削除できます:"
  echo "  rm -f \"$HOME/easy-llm.sh\""
  echo
}

###############################################################################
# entry point
###############################################################################

case "${1:-install}" in
  install)     cmd_install ;;
  start)       cmd_start ;;
  stop)        cmd_stop ;;
  restart)     cmd_restart ;;
  status)      cmd_status ;;
  urls)        cmd_urls ;;
  logs)        cmd_logs ;;
  uninstall)   cmd_uninstall ;;
  help|-h|--help) cmd_help ;;
  *)
    red "不明なコマンド: ${1:-}"
    echo
    cmd_help
    exit 1
    ;;
esac
