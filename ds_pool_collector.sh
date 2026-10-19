#!/bin/bash
#==============================================================================
# ds_pool_collector.sh  v1.0.0
#
#   JBoss EAP 8.1 (IronJacamar) データソース接続プール統計 収集スクリプト
#
#   対象環境 : ECS タスク上の UBI 9.x コンテナで稼働する JBoss EAP 8.1 (standalone)
#   取得方法 : jboss-cli.sh で管理モデルを参照
#                /subsystem=datasources/{data-source|xa-data-source}=*/statistics={pool|jdbc}
#              ※ JMX の jboss.as:subsystem=datasources,data-source=*,statistics=pool と
#                 同一の値です（JMX クライアントを別途用意せずに取得できます）
#              ※ jboss-cli は常駐セッション(FIFO)で 1 回だけ起動し、毎回の JVM 起動を避けます
#   出力     : CSV（時系列 / サマリー / 時間別推移 / 枯渇イベント / 待機スレッド /
#              JVM・スレッド / 設定 / メタ情報）と、それらを 1 ファイルにまとめたバンドル
#   依存     : bash 4.1+, awk, sed, grep, date, mkfifo（UBI 9 / ubi-minimal 標準）
#
#   クイックスタート:
#     ./ds_pool_collector.sh --check                    # 接続確認と現在値の表示
#     ./ds_pool_collector.sh -i 10 -d 24h --background  # 10秒間隔で24時間、バックグラウンド収集
#     ./ds_pool_collector.sh --status                   # 収集状況の確認
#     ./ds_pool_collector.sh --stop                     # 停止（最終レポートを作成）
#     ./ds_pool_collector.sh --export > bundle.txt      # 結果 CSV を 1 ファイルで出力
#   詳細: ./ds_pool_collector.sh --help
#==============================================================================

SCRIPT_VERSION="1.0.0"
export LC_ALL=C
umask 022

#------------------------------------------------------------------------------
# 既定値
#------------------------------------------------------------------------------
BASE_DIR="${DSPOOL_BASE_DIR:-/tmp/dspool}"
INTERVAL=10
DURATION_SEC=0
MAX_COUNT=0
UNTIL_EPOCH=0
WARN_PCT=80
WARN_SET=0
BUCKET_MIN=60
BUCKET_SET=0
TZ_OPT=""
CLI_MODE="persistent"
CLI_HEAP="64m"
CLI_CMD_TIMEOUT=30
CLI_CONNECT_TIMEOUT=60
CONTROLLER=""
CLI_USER="${DSPOOL_CLI_USER:-}"
CLI_PASSWORD="${DSPOOL_CLI_PASSWORD:-}"
JBOSS_HOME_OPT=""
JBOSS_CLI_OPT=""
DS_FILTER=""
DO_QUEUED=1
DO_CONTEXT=1
DO_TDUMP=0
TDUMP_MIN_INTERVAL=300
TDUMP_MAX=12
QDUMP_MIN_INTERVAL=60
ENABLE_STATS=0
CLEAR_STATS=0
REPORT_EVERY=300
DEBUG=0
MODE="run"
BACKGROUND=0
IS_DAEMON=0
RUN_DIR=""
TARGET_DIR=""
EXPORT_GZ=0
EXPORT_ALL=0

F_META="ds_pool_meta.csv"
F_CONFIG="ds_pool_config.csv"
F_TS="ds_pool_timeseries.csv"
F_CTX="ds_pool_context.csv"
F_SUMMARY="ds_pool_summary.csv"
F_HOURLY="ds_pool_hourly.csv"
F_EVENTS="ds_pool_events.csv"
F_WAITERS="ds_pool_waiters.csv"
F_WAITRAW="ds_pool_waiters_raw.csv"
F_BUNDLE="ds_pool_bundle.txt"

# 実行時の状態
LOG_FILE=""
WORK_DIR=""
AWK_DIR=""
CLI_ERR_LOG="/dev/null"
CLI_PID=""
CLI_WFD=""
CLI_RFD=""
SEQ=0
SAMPLES=0
STOP_REQ=0
SLEEP_PID=""
TDUMP_PID=""
TDUMP_LAST=0
TDUMP_COUNT=0
STATS_REENABLE_LAST=0
PID_FILE=""
OWN_PID_FILE=0
DSLIST_FILE=""
HOST_LABEL="${HOSTNAME:-}"
ORIG_ARGS=("$@")

#------------------------------------------------------------------------------
# ヘルプ
#------------------------------------------------------------------------------
usage() {
  cat <<'USAGE'
使い方: ds_pool_collector.sh [オプション]

JBoss EAP 8.1 のデータソース接続プール（IronJacamar）の統計を jboss-cli で定期取得し、
CSV に出力します。ECS タスク（UBI 9 コンテナ）内で実行してください。

■ 動作モード
  (指定なし)            フォアグラウンドで収集（Ctrl+C で停止し、レポートを作成）
  --background          バックグラウンドで収集（ECS Exec のセッション切断後も継続）
  --check               接続確認と、データソース一覧・現在値の表示のみ行う
  --status [DIR]        収集状況を表示
  --stop                実行中の収集を停止（最終レポートを作成）
  --report-only DIR     既存の時系列CSVから サマリー/時間別/イベント CSV を再作成
  --export [DIR]        結果CSVを1ファイル（バンドル形式）で標準出力へ出力
  --export-gz [DIR]     同上（gzip+base64 で圧縮。gzip がある場合）
  --export-all          --export 時に待機スレッド・スレッドダンプ・ログも含める
  -h, --help            このヘルプ
  --version             バージョン表示

■ 収集設定
  -i, --interval SEC    取得間隔（秒）                         既定: 10
  -d, --duration TIME   収集時間（例: 3600, 90m, 2h, 1d, 1h30m）既定: 無制限
  -n, --count N         取得回数の上限
      --until "DATE"    終了日時（例: "2026-10-20 09:00"）
  -o, --out-dir DIR     出力先の親ディレクトリ                 既定: /tmp/dspool
      --ds NAME[,NAME]  対象データソースを限定（リソース名）
      --warn-pct PCT    高使用率と判定する使用率(%)            既定: 80
      --bucket MIN      時間別推移の集計単位（分）             既定: 60
      --tz TZ           タイムスタンプのタイムゾーン（例: Asia/Tokyo, JST-9, UTC）
                        既定: コンテナの設定（TZ 未設定なら UTC）
      --enable-stats    統計が無効なデータソースの統計を実行時に有効化
                        （設定ファイルは変更しません。再起動で元に戻ります。
                          収集中のリロード等で無効に戻った場合は自動で再度有効化）
      --clear-stats     収集開始時にプール統計をクリア（最大値などをリセット）
      --no-queued       待機スレッド（dump-queued-threads-in-pool）を取得しない
      --no-context      JVM・スレッド情報（ds_pool_context.csv）を取得しない
      --thread-dump     枯渇検知時にスレッドダンプを取得
      --thread-dump-interval SEC  スレッドダンプの最小間隔（秒）   既定: 300
      --thread-dump-max N         スレッドダンプの最大取得回数     既定: 12
      --report-every SEC  サマリーCSVの途中更新間隔（秒）         既定: 300

■ jboss-cli 接続
      --jboss-home DIR  JBOSS_HOME（既定: 実行中のサーバープロセス/環境変数から自動検出）
      --cli PATH        jboss-cli.sh のパス
      --controller URL  例: remote+http://127.0.0.1:9990（既定: 自動）
      --user USER       管理ユーザー（ローカル認証が使えない場合）
      --password PASS   パスワード（環境変数 DSPOOL_CLI_PASSWORD でも指定可）
      --cli-mode MODE   persistent（常駐セッション・既定）| oneshot（毎回起動）
      --cli-heap SIZE   jboss-cli の最大ヒープ                 既定: 64m
      --cli-timeout SEC 1回の取得のタイムアウト（秒）          既定: 30
      --debug           取得した生データを保存（パスワードはマスク）

■ 出力（<出力先>/dspool_<ホスト>_<開始日時>/）
  ds_pool_timeseries.csv  時系列（サンプル×データソースごとの使用件数・判定）
  ds_pool_summary.csv     サマリー（最大/最小/平均/95%値・枯渇判定・所見コード）
  ds_pool_hourly.csv      時間別推移（--bucket 単位の 最大/最小/平均）
  ds_pool_events.csv      枯渇・待ちイベント（連続区間）
  ds_pool_waiters.csv     接続待ちスレッドの呼び出し元（アプリケーションのフレーム）
  ds_pool_context.csv     JVM スレッド / ヒープ / IOワーカー / トランザクション
  ds_pool_config.csv      データソース設定（パスワードはマスク）
  ds_pool_meta.csv        収集条件・サーバー情報
  ds_pool_bundle.txt      上記CSVを1ファイルにまとめたもの（Excel 変換の入力に使用可）
  queued_threads/         枯渇時の待機スレッドのスタック
  thread_dumps/           --thread-dump 指定時のスレッドダンプ
  collector.log           実行ログ

■ 例
  ./ds_pool_collector.sh --check
  ./ds_pool_collector.sh -i 10 -d 24h --tz Asia/Tokyo --background
  ./ds_pool_collector.sh --status
  ./ds_pool_collector.sh --stop
  ./ds_pool_collector.sh --export > /tmp/bundle.txt
USAGE
}

#------------------------------------------------------------------------------
# ログ
#------------------------------------------------------------------------------
now_str() { date '+%Y-%m-%d %H:%M:%S'; }
log() {
  local line
  line="[$(now_str)] $*"
  printf '%s\n' "$line" >&2
  if [[ -n $LOG_FILE ]]; then printf '%s\n' "$line" >> "$LOG_FILE" 2>/dev/null; fi
  return 0
}
info() { log "INFO  $*"; }
warn() { log "WARN  $*"; }
err()  { log "ERROR $*"; }
die()  { err "$*"; exit 1; }

#------------------------------------------------------------------------------
# 引数
#------------------------------------------------------------------------------
is_uint() { [[ $1 =~ ^[0-9]+$ ]]; }

parse_duration() {
  local s=$1 total=0 n u
  if is_uint "$s"; then echo $((10#$s)); return 0; fi
  [[ -n $s ]] || return 1
  while [[ -n $s ]]; do
    if [[ $s =~ ^([0-9]+)([sSmMhHdD])(.*)$ ]]; then
      n=$((10#${BASH_REMATCH[1]})); u=${BASH_REMATCH[2]}; s=${BASH_REMATCH[3]}
      case $u in
        s|S) ;;
        m|M) n=$((n * 60)) ;;
        h|H) n=$((n * 3600)) ;;
        d|D) n=$((n * 86400)) ;;
      esac
      total=$((total + n))
    else
      return 1
    fi
  done
  echo "$total"
}

need_arg() { (( $# >= 2 )) || die "オプション $1 には値が必要です"; }
opt_dir_arg() { (( $# >= 2 )) && [[ $2 != -* ]]; }

parse_args() {
  local opt
  while (( $# > 0 )); do
    opt=$1
    if [[ $opt == --*=* ]]; then
      set -- "${opt%%=*}" "${opt#*=}" "${@:2}"
      opt=$1
    fi
    case $opt in
      -h|--help) usage; exit 0 ;;
      --version) echo "ds_pool_collector.sh $SCRIPT_VERSION"; exit 0 ;;
      -i|--interval) need_arg "$@"; INTERVAL=$2; shift ;;
      -d|--duration) need_arg "$@"; DURATION_SEC=$(parse_duration "$2") || die "収集時間の指定が不正です: $2"; shift ;;
      -n|--count) need_arg "$@"; MAX_COUNT=$2; shift ;;
      --until) need_arg "$@"; UNTIL_EPOCH=$(date -d "$2" +%s 2>/dev/null) || die "日時の指定が不正です: $2"; shift ;;
      -o|--out-dir) need_arg "$@"; BASE_DIR=$2; shift ;;
      --ds) need_arg "$@"; DS_FILTER=$2; shift ;;
      --warn-pct) need_arg "$@"; WARN_PCT=$2; WARN_SET=1; shift ;;
      --bucket) need_arg "$@"; BUCKET_MIN=$2; BUCKET_SET=1; shift ;;
      --tz) need_arg "$@"; TZ_OPT=$2; shift ;;
      --enable-stats) ENABLE_STATS=1 ;;
      --clear-stats) CLEAR_STATS=1 ;;
      --no-queued) DO_QUEUED=0 ;;
      --no-context) DO_CONTEXT=0 ;;
      --thread-dump) DO_TDUMP=1 ;;
      --thread-dump-interval) need_arg "$@"; TDUMP_MIN_INTERVAL=$2; shift ;;
      --thread-dump-max) need_arg "$@"; TDUMP_MAX=$2; shift ;;
      --report-every) need_arg "$@"; REPORT_EVERY=$2; shift ;;
      --jboss-home) need_arg "$@"; JBOSS_HOME_OPT=$2; shift ;;
      --cli) need_arg "$@"; JBOSS_CLI_OPT=$2; shift ;;
      --controller) need_arg "$@"; CONTROLLER=$2; shift ;;
      --user) need_arg "$@"; CLI_USER=$2; shift ;;
      --password) need_arg "$@"; CLI_PASSWORD=$2; shift ;;
      --cli-mode) need_arg "$@"; CLI_MODE=$2; shift ;;
      --cli-heap) need_arg "$@"; CLI_HEAP=$2; shift ;;
      --cli-timeout) need_arg "$@"; CLI_CMD_TIMEOUT=$2; shift ;;
      --debug) DEBUG=1 ;;
      --background) BACKGROUND=1 ;;
      --check) MODE="check" ;;
      --status) MODE="status"; if opt_dir_arg "$@"; then TARGET_DIR=$2; shift; fi ;;
      --stop) MODE="stop" ;;
      --report-only) need_arg "$@"; MODE="report"; TARGET_DIR=$2; shift ;;
      --export) MODE="export"; if opt_dir_arg "$@"; then TARGET_DIR=$2; shift; fi ;;
      --export-gz) MODE="export"; EXPORT_GZ=1; if opt_dir_arg "$@"; then TARGET_DIR=$2; shift; fi ;;
      --export-all) EXPORT_ALL=1 ;;
      --_daemon) IS_DAEMON=1 ;;
      --_run-dir) need_arg "$@"; RUN_DIR=$2; shift ;;
      *) die "不明なオプションです: $1（--help を参照）" ;;
    esac
    shift
  done
}

validate_args() {
  { is_uint "$INTERVAL" && (( 10#$INTERVAL >= 1 )); } || die "--interval は 1 以上の整数で指定してください"
  INTERVAL=$((10#$INTERVAL))
  is_uint "$MAX_COUNT" || die "--count は整数で指定してください"
  { is_uint "$WARN_PCT" && (( 10#$WARN_PCT >= 1 && 10#$WARN_PCT <= 100 )); } || die "--warn-pct は 1～100 で指定してください"
  { is_uint "$BUCKET_MIN" && (( 10#$BUCKET_MIN >= 1 )); } || die "--bucket は 1 以上の整数（分）で指定してください"
  is_uint "$TDUMP_MIN_INTERVAL" || die "--thread-dump-interval は整数で指定してください"
  is_uint "$TDUMP_MAX" || die "--thread-dump-max は整数で指定してください"
  { is_uint "$REPORT_EVERY" && (( 10#$REPORT_EVERY >= 10 )); } || die "--report-every は 10 以上の整数で指定してください"
  { is_uint "$CLI_CMD_TIMEOUT" && (( 10#$CLI_CMD_TIMEOUT >= 5 )); } || die "--cli-timeout は 5 以上の整数で指定してください"
  [[ $CLI_HEAP =~ ^[0-9]+[kKmMgG]?$ ]] || die "--cli-heap の指定が不正です: $CLI_HEAP"
  case $CLI_MODE in persistent|oneshot) ;; *) die "--cli-mode は persistent か oneshot を指定してください" ;; esac
  if [[ $CLI_MODE == oneshot ]] && (( INTERVAL < 10 )); then
    warn "oneshot モードでは毎回 JVM を起動するため、--interval は 10 秒以上を推奨します"
  fi
}

setup_tz() {
  [[ -z $TZ_OPT || $TZ_OPT == local ]] && return 0
  case $TZ_OPT in
    UTC|utc) export TZ=UTC0 ;;
    JST|jst) export TZ=JST-9 ;;
    */*)
      if [[ -e /usr/share/zoneinfo/$TZ_OPT ]]; then
        export TZ=$TZ_OPT
      elif [[ $TZ_OPT == Asia/Tokyo ]]; then
        export TZ=JST-9
      else
        warn "タイムゾーン定義 $TZ_OPT がありません（tzdata 未導入）。JST-9 のような POSIX 形式で指定してください"
        export TZ=$TZ_OPT
      fi ;;
    *) export TZ=$TZ_OPT ;;
  esac
}

csvq_sh() {
  local s=$1
  if [[ $s == *[\",]* || $s == *$'\n'* ]]; then s=${s//\"/\"\"}; printf '"%s"' "$s"; else printf '%s' "$s"; fi
}

#------------------------------------------------------------------------------
# サーバープロセス・環境の検出
#------------------------------------------------------------------------------
SERVER_PID=""; SERVER_JAVA=""; SERVER_HOME=""; SERVER_MGMT_ADDR=""; SERVER_MGMT_PORT=""; SERVER_PORT_OFFSET=0
detect_server_proc() {
  local d args a prev="" first
  for d in /proc/[0-9]*; do
    [[ -r $d/cmdline ]] || continue
    args=$(tr '\0' '\n' 2>/dev/null < "$d/cmdline") || continue
    [[ $args == *jboss-modules.jar* ]] || continue
    [[ $args == *$'\n'org.jboss.as.standalone* || $args == *$'\n'org.jboss.as.server$'\n'* ]] || continue
    SERVER_PID=${d#/proc/}
    first=1
    while IFS= read -r a; do
      if (( first )); then
        first=0
        [[ $a == /* && -x $a ]] && SERVER_JAVA=$a
        prev=$a; continue
      fi
      case $a in
        -Djboss.home.dir=*) SERVER_HOME=${a#*=} ;;
        -Djboss.bind.address.management=*) SERVER_MGMT_ADDR=${a#*=} ;;
        -bmanagement=*) SERVER_MGMT_ADDR=${a#*=} ;;
        -Djboss.management.http.port=*) SERVER_MGMT_PORT=${a#*=} ;;
        -Djboss.socket.binding.port-offset=*) SERVER_PORT_OFFSET=${a#*=} ;;
      esac
      [[ $prev == -bmanagement ]] && SERVER_MGMT_ADDR=$a
      prev=$a
    done <<< "$args"
    return 0
  done
  return 1
}

detect_env() {
  local c addr port
  detect_server_proc || true
  if [[ -n $JBOSS_HOME_OPT ]]; then
    JBOSS_HOME=$JBOSS_HOME_OPT
  elif [[ -n $SERVER_HOME && -d $SERVER_HOME ]]; then
    JBOSS_HOME=$SERVER_HOME
  elif [[ -n ${JBOSS_HOME:-} && -d ${JBOSS_HOME} ]]; then
    :
  else
    JBOSS_HOME=""
    for c in /opt/server /opt/eap /opt/jboss-eap-8.1 /opt/jboss-eap /opt/jboss/wildfly /opt/wildfly; do
      if [[ -f $c/bin/jboss-cli.sh ]]; then JBOSS_HOME=$c; break; fi
    done
  fi
  JBOSS_CLI=${JBOSS_CLI_OPT:-${JBOSS_HOME:+$JBOSS_HOME/bin/jboss-cli.sh}}
  [[ -n $JBOSS_CLI && -f $JBOSS_CLI ]] || die "jboss-cli.sh が見つかりません。--jboss-home または --cli で指定してください"
  [[ -n $JBOSS_HOME ]] || JBOSS_HOME=$(cd "$(dirname "$JBOSS_CLI")/.." && pwd)

  if [[ -n ${JAVA:-} && -x ${JAVA} ]]; then CLI_JAVA=$JAVA
  elif [[ -n $SERVER_JAVA ]]; then CLI_JAVA=$SERVER_JAVA
  elif [[ -n ${JAVA_HOME:-} && -x $JAVA_HOME/bin/java ]]; then CLI_JAVA=$JAVA_HOME/bin/java
  elif command -v java >/dev/null 2>&1; then CLI_JAVA=$(command -v java)
  else die "java が見つかりません（JAVA_HOME を設定してください）"
  fi

  if [[ -z $CONTROLLER ]]; then
    addr=$SERVER_MGMT_ADDR
    port=${SERVER_MGMT_PORT:-9990}
    is_uint "$port" || port=9990
    if is_uint "$SERVER_PORT_OFFSET"; then port=$((port + SERVER_PORT_OFFSET)); fi
    case $addr in ""|0.0.0.0|::|"[::]"|localhost) addr=127.0.0.1 ;; esac
    [[ $addr == *:* && $addr != \[* ]] && addr="[$addr]"
    if [[ $addr != 127.0.0.1 || $port != 9990 ]]; then CONTROLLER="remote+http://$addr:$port"; fi
  fi

  CLI_ARGS=(--connect)
  [[ -n $CONTROLLER ]] && CLI_ARGS+=("--controller=$CONTROLLER")
  [[ -n $CLI_USER ]] && CLI_ARGS+=("--user=$CLI_USER")
  [[ -n $CLI_PASSWORD ]] && CLI_ARGS+=("--password=$CLI_PASSWORD")
  CLI_ARGS+=("--timeout=15000" "--command-timeout=$CLI_CMD_TIMEOUT")
  CLI_JAVA_OPTS=${DSPOOL_CLI_JAVA_OPTS:-"-Xms16m -Xmx$CLI_HEAP -XX:+UseSerialGC -XX:TieredStopAtLevel=1 -XX:-UsePerfData -Xss512k -Djava.awt.headless=true"}
  [[ -n $HOST_LABEL ]] || HOST_LABEL=$(cat /proc/sys/kernel/hostname 2>/dev/null)
  [[ -n $HOST_LABEL ]] || HOST_LABEL=unknown
}

check_deps() {
  local c missing=()
  for c in awk sed grep date sleep mkdir rm mv cat tr; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  (( ${#missing[@]} == 0 )) || die "必要なコマンドがありません: ${missing[*]}"
  if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 1) )); then
    die "bash 4.1 以上が必要です（現在: $BASH_VERSION）"
  fi
  if [[ $CLI_MODE == persistent ]] && ! command -v mkfifo >/dev/null 2>&1; then
    warn "mkfifo が無いため oneshot モードで実行します"
    CLI_MODE=oneshot
  fi
}

#------------------------------------------------------------------------------
# awk プログラム（作業ディレクトリへ展開して使用）
#------------------------------------------------------------------------------
write_awk_files() {
  local dir=$1
  mkdir -p "$dir" || die "作業ディレクトリを作成できません: $dir"

  cat > "$dir/common.awk" <<'EOF_AWK'
# ---- 共通関数 ----
function trim(s) { sub(/^[ \t\r\n]+/, "", s); sub(/[ \t\r\n]+$/, "", s); return s }
function csvq(s) {
  if (s ~ /[",\r\n]/ || s ~ /^[ \t]/ || s ~ /[ \t]$/) { gsub(/"/, "\"\"", s); return "\"" s "\"" }
  return s
}
function csvsplit(line, F,    n, i, c, f, inq, len) {
  split("", F)
  if (index(line, "\"") == 0) return split(line, F, ",")
  n = 0; f = ""; inq = 0; len = length(line)
  for (i = 1; i <= len; i++) {
    c = substr(line, i, 1)
    if (inq) {
      if (c == "\"") { if (substr(line, i + 1, 1) == "\"") { f = f "\""; i++ } else inq = 0 }
      else f = f c
    } else if (c == "\"") inq = 1
    else if (c == ",") { F[++n] = f; f = "" }
    else f = f c
  }
  F[++n] = f
  return n
}
function joinarr(A, n,    s, i) { s = ""; for (i = 1; i <= n; i++) s = s (i > 1 ? "," : "") A[i]; return s }
# DMR: 文字列中以外の " の数
function nq(s,    t) { t = s; gsub(/\\\\/, "", t); gsub(/\\"/, "", t); return gsub(/"/, "", t) }
# DMR: "key" => value の分解（KV_K / KV_V）
function kvparse(line,    k) {
  if (!match(line, /^[ \t]*"[^"]*" => /)) return 0
  k = substr(line, RSTART, RLENGTH); sub(/^[ \t]*"/, "", k); sub(/" => $/, "", k)
  KV_K = k; KV_V = substr(line, RSTART + RLENGTH)
  return 1
}
# DMR 値の正規化（5 / 0L / "str" / true / undefined / expression "..."）
function dmr(v) {
  v = trim(v); sub(/,$/, "", v); v = trim(v)
  if (v == "undefined") return ""
  if (v ~ /^-?[0-9]+L$/) return substr(v, 1, length(v) - 1)
  if (substr(v, 1, 11) == "expression ") v = substr(v, 12)
  if (substr(v, 1, 12) == "big decimal ") v = substr(v, 13)
  if (substr(v, 1, 12) == "big integer ") v = substr(v, 13)
  if (length(v) >= 2 && substr(v, 1, 1) == "\"" && substr(v, length(v), 1) == "\"") {
    v = substr(v, 2, length(v) - 2); gsub(/\\"/, "\"", v); gsub(/\\\\/, "\\", v)
  }
  return v
}
# 日付（tz 非依存の計算）
function days_civil(y, m, d,    era, yoe, doy, doe) {
  y -= (m <= 2) ? 1 : 0
  era = (y >= 0) ? y : y - 399; era = int(era / 400)
  yoe = y - era * 400
  doy = int((153 * ((m > 2) ? m - 3 : m + 9) + 2) / 5) + d - 1
  doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
  return era * 146097 + doe - 719468
}
function civil_str(z,    era, doe, yoe, y, doy, mp, d, m) {
  z += 719468
  era = (z >= 0) ? z : z - 146096; era = int(era / 146097)
  doe = z - era * 146097
  yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
  y = yoe + era * 400
  doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100))
  mp = int((5 * doy + 2) / 153)
  d = doy - int((153 * mp + 2) / 5) + 1
  m = (mp < 10) ? mp + 3 : mp - 9
  if (m <= 2) y++
  return sprintf("%04d-%02d-%02d", y, m, d)
}
function fmt_lsec(s,    d, r) {
  s = int(s); d = int(s / 86400); r = s - d * 86400
  if (r < 0) { r += 86400; d-- }
  return civil_str(d) sprintf(" %02d:%02d:%02d", int(r / 3600), int((r % 3600) / 60), r % 60)
}
function fmt_dur(s,    d) {
  s = int(s); d = int(s / 86400); s -= d * 86400
  return (d > 0 ? d "d " : "") sprintf("%02d:%02d:%02d", int(s / 3600), int((s % 3600) / 60), s % 60)
}
function off2sec(o,    sg) {
  if (o !~ /^[+-][0-9][0-9][0-9][0-9]$/) return 0
  sg = (substr(o, 1, 1) == "-") ? -1 : 1
  return sg * (substr(o, 2, 2) * 3600 + substr(o, 4, 2) * 60)
}
function r1(x) { return sprintf("%.1f", x) }
function lvl(s) { return (s == "FAILURE") ? 4 : (s == "EXHAUSTED") ? 3 : (s == "WAIT") ? 2 : (s == "HIGH") ? 1 : (s == "OK") ? 0 : -1 }
function lvname(l) { return (l >= 4) ? "FAILURE" : (l == 3) ? "EXHAUSTED" : (l == 2) ? "WAIT" : (l == 1) ? "HIGH" : "OK" }
# ---- CSV 列定義 ----
function ts_header(    s) {
  s = "timestamp,ds_name,status,in_use_count,active_count,idle_count,available_count,max_pool_size,usage_pct,active_pct"
  s = s ",queued_threads,d_wait_count,d_blocking_failure_count,max_used_count,max_wait_count,status_detail"
  s = s ",min_pool_size,blocking_timeout_ms,jndi_name,ds_type,ds_enabled,stats_enabled"
  s = s ",interval_sec,d_created_count,d_destroyed_count,d_timed_out,d_total_get_time_ms,d_total_blocking_time_ms"
  s = s ",wait_count,blocking_failure_count,created_count,destroyed_count,timed_out"
  s = s ",avg_get_time_ms,max_get_time_ms,total_get_time_ms,avg_usage_time_ms,max_usage_time_ms,total_usage_time_ms"
  s = s ",avg_blocking_time_ms,max_wait_time_ms,total_blocking_time_ms,avg_creation_time_ms,max_creation_time_ms,total_creation_time_ms"
  s = s ",avg_pool_time_ms,max_pool_time_ms,total_pool_time_ms"
  s = s ",jdbc_stats_enabled,ps_cache_access,ps_cache_hit,ps_cache_miss,ps_cache_hit_pct,ps_cache_add,ps_cache_delete,ps_cache_size"
  s = s ",xa_commit_count,xa_commit_avg_ms,xa_commit_max_ms,xa_commit_total_ms"
  s = s ",xa_prepare_count,xa_prepare_avg_ms,xa_prepare_max_ms,xa_prepare_total_ms"
  s = s ",xa_rollback_count,xa_rollback_avg_ms,xa_rollback_max_ms,xa_rollback_total_ms"
  s = s ",xa_start_count,xa_start_avg_ms,xa_start_max_ms,xa_start_total_ms"
  s = s ",xa_end_count,xa_end_avg_ms,xa_end_max_ms,xa_end_total_ms"
  s = s ",xa_recover_count,xa_recover_avg_ms,xa_recover_max_ms,xa_recover_total_ms"
  s = s ",xa_forget_count,xa_forget_avg_ms,xa_forget_max_ms,xa_forget_total_ms"
  s = s ",epoch,utc_offset,host"
  return s
}
function ctx_header() {
  return "timestamp,cli_ms,thread_count,peak_thread_count,daemon_thread_count,heap_used_mb,heap_committed_mb,heap_max_mb,heap_used_pct,io_busy_task_threads,io_max_task_threads,io_busy_pct,io_queue_size,tx_inflight,tx_timed_out,d_tx_timed_out,ds_in_use_total,ds_exhausted,epoch,utc_offset,host"
}
function waitraw_header() { return "timestamp,epoch,ds_name,thread_name,app_frame" }
EOF_AWK

  cat > "$dir/hdr.awk" <<'EOF_AWK'
BEGIN {
  if (which == "ts") print ts_header()
  else if (which == "ctx") print ctx_header()
  else if (which == "wait") print waitraw_header()
  else if (which == "meta") print "category,key,value"
  exit
}
EOF_AWK

  cat > "$dir/sample.awk" <<'EOF_AWK'
# ---- 1回分の jboss-cli 出力を解析して CSV 行を追記 ----
BEGIN {
  NTC = split(ts_header(), TC, ",")
  NCC = split(ctx_header(), CC, ",")
  pm("ActiveCount", "active_count"); pm("AvailableCount", "available_count")
  pm("AverageBlockingTime", "avg_blocking_time_ms"); pm("AverageCreationTime", "avg_creation_time_ms")
  pm("AverageGetTime", "avg_get_time_ms"); pm("AveragePoolTime", "avg_pool_time_ms")
  pm("AverageUsageTime", "avg_usage_time_ms"); pm("BlockingFailureCount", "blocking_failure_count")
  pm("CreatedCount", "created_count"); pm("DestroyedCount", "destroyed_count")
  pm("IdleCount", "idle_count"); pm("InUseCount", "in_use_count")
  pm("MaxCreationTime", "max_creation_time_ms"); pm("MaxGetTime", "max_get_time_ms")
  pm("MaxPoolTime", "max_pool_time_ms"); pm("MaxUsageTime", "max_usage_time_ms")
  pm("MaxUsedCount", "max_used_count"); pm("MaxWaitCount", "max_wait_count")
  pm("MaxWaitTime", "max_wait_time_ms"); pm("TimedOut", "timed_out")
  pm("TotalBlockingTime", "total_blocking_time_ms"); pm("TotalCreationTime", "total_creation_time_ms")
  pm("TotalGetTime", "total_get_time_ms"); pm("TotalPoolTime", "total_pool_time_ms")
  pm("TotalUsageTime", "total_usage_time_ms"); pm("WaitCount", "wait_count")
  n = split("Commit Prepare Rollback Start End Recover Forget", X, " ")
  for (i = 1; i <= n; i++) {
    l = tolower(X[i])
    pm("XA" X[i] "Count", "xa_" l "_count"); pm("XA" X[i] "AverageTime", "xa_" l "_avg_ms")
    pm("XA" X[i] "MaxTime", "xa_" l "_max_ms"); pm("XA" X[i] "TotalTime", "xa_" l "_total_ms")
  }
  jm("PreparedStatementCacheAccessCount", "ps_cache_access"); jm("PreparedStatementCacheHitCount", "ps_cache_hit")
  jm("PreparedStatementCacheMissCount", "ps_cache_miss"); jm("PreparedStatementCacheAddCount", "ps_cache_add")
  jm("PreparedStatementCacheDeleteCount", "ps_cache_delete"); jm("PreparedStatementCacheCurrentSize", "ps_cache_size")
  NCUM = split("wait_count blocking_failure_count created_count destroyed_count timed_out total_get_time_ms total_blocking_time_ms", CUM, " ")
  while ((getline ln < statefile) > 0) { i = index(ln, "\t"); if (i > 1) ST[substr(ln, 1, i - 1)] = substr(ln, i + 1) }
  close(statefile)
  while ((getline ln < dslistfile) > 0) { n = split(ln, a, "\t"); if (n >= 3) QMAP[a[1]] = a[2] SUBSEP a[3] }
  close(dslistfile)
  if (dsfilter != "") { n = split(dsfilter, a, ","); for (i = 1; i <= n; i++) DSF[trim(a[i])] = 1 }
  started = 0; ended = 0; sec = ""; cur = ""; instr = 0; qk = ""; qth = ""; qfr = ""; NDS = 0; NW = 0
}
function pm(a, c) { PM[a] = c }
function jm(a, c) { JM[a] = c }
function regds(type, name,    k) {
  k = type SUBSEP name
  if (!(k in DSSEEN)) { DSSEEN[k] = 1; NDS++; DSK[NDS] = k; DST[NDS] = type; DSN[NDS] = name }
  return k
}
function appframe(f) {
  return (f !~ /^(java\.|javax\.|jakarta\.|jdk\.|sun\.|com\.sun\.|org\.jboss\.|org\.wildfly\.|io\.undertow\.|org\.apache\.jasper\.|org\.xnio\.|io\.smallrye\.|org\.hibernate\.|org\.eclipse\.|com\.arjuna\.|org\.springframework\.|org\.glassfish\.|io\.netty\.|org\.h2\.|com\.zaxxer\.|org\.postgresql\.|oracle\.|com\.mysql\.|com\.microsoft\.sqlserver\.|org\.mariadb\.|com\.ibm\.)/)
}
function flushq() {
  if (qk != "" && qth != "") { NW++; WK[NW] = qk; WT[NW] = qth; WF[NW] = (qfr == "") ? "(unknown)" : qfr }
  qth = ""; qfr = ""
}
function cfgv(k, pk, attr, col) {
  if (("cfg", k, attr) in V) { R[col] = V["cfg", k, attr]; ST["g|" pk "|" attr] = R[col] }
  else if (("g|" pk "|" attr) in ST) R[col] = ST["g|" pk "|" attr]
}
function dlt(pk, col,    c, p) {
  c = R[col]; p = ST["c|" pk "|" col]
  if (c == "" || p == "") return ""
  if (c + 0 < p + 0) { RESET = 1; return c + 0 }
  return c - p
}
{
  sub(/\r$/, "")
  ln = $0
  if (substr(ln, 1, 9) == "DSPOOL_S ") { if (substr(ln, 10) == seq) started = 1; next }
  if (!started) next
  if (substr(ln, 1, 9) == "DSPOOL_E ") { if (substr(ln, 10) == seq) ended = 1; next }
  if (substr(ln, 1, 9) == "DSPOOL_B ") {
    flushq()
    sec = substr(ln, 10); cur = ""; instr = 0; qk = ""
    if (substr(sec, 1, 2) == "q.") { i = substr(sec, 3); if (i in QMAP) { qk = QMAP[i]; QDONE[qk] = 1 } }
    next
  }
  if (substr(ln, 1, 9) == "DSPOOL_F ") {
    f = substr(ln, 10); FAILED[f] = 1
    if (substr(f, 1, 2) == "q." && (substr(f, 3) in QMAP)) delete QDONE[QMAP[substr(f, 3)]]
    next
  }
  if (sec == "") next
  if (substr(sec, 1, 2) == "q.") {
    if (qk == "") next
    if ((p = index(ln, "Queued thread: ")) > 0) {
      flushq()
      qth = substr(ln, p + 15); sub(/"?,?[ \t]*$/, "", qth)
      QN[qk]++
      QT[qk] = QT[qk] "Queued thread: " qth "\n"
      next
    }
    if (qth != "" && match(ln, /^  [^ "]+:[^ :"]*:-?[0-9]+/)) {
      fr = substr(ln, 3, RLENGTH - 2)
      QT[qk] = QT[qk] "    at " fr "\n"
      if (qfr == "" && appframe(fr)) qfr = fr
    }
    next
  }
  if (substr(sec, 1, 4) == "ctx.") {
    if (!kvparse(ln)) next
    v = dmr(KV_V)
    if (sec == "ctx.thr" && KV_K == "result") C["thread_count"] = v
    else if (sec == "ctx.pthr" && KV_K == "result") C["peak_thread_count"] = v
    else if (sec == "ctx.dthr" && KV_K == "result") C["daemon_thread_count"] = v
    else if (sec == "ctx.heap") { if (KV_K == "used" || KV_K == "committed" || KV_K == "max") C["heap_" KV_K] = v }
    else if (sec == "ctx.io") {
      if (KV_K == "busy-task-thread-count") { C["io_busy"] += v; C["io_ok"] = 1 }
      else if (KV_K == "max-pool-size") C["io_max"] += v
      else if (KV_K == "queue-size") C["io_queue"] += v
    }
    else if (sec == "ctx.txi" && KV_K == "result") C["tx_inflight"] = v
    else if (sec == "ctx.txt" && KV_K == "result") C["tx_timed_out"] = v
    next
  }
  kind = sec; sub(/\..*$/, "", kind)
  if (index(ln, "(\"data-source\" => \"") || index(ln, "(\"xa-data-source\" => \"")) {
    type = index(ln, "(\"xa-data-source\" => \"") ? "xa-data-source" : "data-source"
    p = index(ln, " => \""); nm = substr(ln, p + 5); sub(/"\),?[ \t]*$/, "", nm)
    cur = regds(type, nm); instr = 0
    next
  }
  if (instr) { if (nq(ln) % 2 == 1) instr = 0; next }
  if (nq(ln) % 2 == 1) { instr = 1; next }
  if (cur != "" && kvparse(ln)) V[kind, cur, KV_K] = dmr(KV_V)
}
END {
  flushq()
  ok = (started && ended && complete == 1) ? 1 : 0
  if (!ok || NDS == 0) {
    if (ST["dslist"] != "") {
      n = split(ST["dslist"], a, "\035")
      for (i = 1; i <= n; i++) if (split(a[i], b, "\036") == 2) regds(b[1], b[2])
    }
  }
  inuse_total = 0; exh_cnt = 0; anyexh = 0; anyoff = 0
  for (i = 1; i <= NDS; i++) {
    k = DSK[i]; type = DST[i]; name = DSN[i]; pk = type "|" name
    if (dsfilter != "" && !(name in DSF)) continue
    split("", R)
    R["timestamp"] = ts; R["epoch"] = epoch; R["utc_offset"] = off; R["host"] = host
    R["ds_name"] = name; R["ds_type"] = type
    cfgv(k, pk, "jndi-name", "jndi_name"); cfgv(k, pk, "enabled", "ds_enabled")
    cfgv(k, pk, "min-pool-size", "min_pool_size"); cfgv(k, pk, "max-pool-size", "max_pool_size")
    cfgv(k, pk, "blocking-timeout-wait-millis", "blocking_timeout_ms")
    if (R["min_pool_size"] == "") R["min_pool_size"] = 0
    if (R["max_pool_size"] == "") R["max_pool_size"] = 20
    if (R["blocking_timeout_ms"] == "") R["blocking_timeout_ms"] = 30000
    havepool = (("pool", k, "ActiveCount") in V) ? 1 : 0
    if (havepool) {
      for (a2 in PM) if (("pool", k, a2) in V) R[PM[a2]] = V["pool", k, a2]
      R["stats_enabled"] = V["pool", k, "statistics-enabled"]
    } else if (("cfg", k, "statistics-enabled") in V) R["stats_enabled"] = V["cfg", k, "statistics-enabled"]
    if (("jdbc", k, "statistics-enabled") in V) {
      for (a2 in JM) if (("jdbc", k, a2) in V) R[JM[a2]] = V["jdbc", k, a2]
      R["jdbc_stats_enabled"] = V["jdbc", k, "statistics-enabled"]
      if (R["ps_cache_access"] + 0 > 0) R["ps_cache_hit_pct"] = r1(R["ps_cache_hit"] * 100 / R["ps_cache_access"])
    }
    q = ""
    if (k in QDONE) q = (k in QN) ? QN[k] : 0
    R["queued_threads"] = q
    lv = -1; det = ""; RESET = 0
    if (!ok) { st = "ERROR"; det = "CLI_FAILED" }
    else if (R["ds_enabled"] == "false") st = "DISABLED"
    else if (!havepool) st = "NO_POOL"
    else if (R["stats_enabled"] != "true") { st = "STATS_OFF"; anyoff = 1 }
    else {
      maxp = R["max_pool_size"] + 0; iu = R["in_use_count"] + 0; av = R["available_count"] + 0
      if (maxp > 0) { R["usage_pct"] = r1(iu * 100 / maxp); R["active_pct"] = r1(R["active_count"] * 100 / maxp) }
      if (("e|" pk) in ST) R["interval_sec"] = epoch - ST["e|" pk]
      R["d_wait_count"] = dlt(pk, "wait_count")
      R["d_blocking_failure_count"] = dlt(pk, "blocking_failure_count")
      R["d_created_count"] = dlt(pk, "created_count")
      R["d_destroyed_count"] = dlt(pk, "destroyed_count")
      R["d_timed_out"] = dlt(pk, "timed_out")
      R["d_total_get_time_ms"] = dlt(pk, "total_get_time_ms")
      R["d_total_blocking_time_ms"] = dlt(pk, "total_blocking_time_ms")
      lv = 0
      df = R["d_blocking_failure_count"] + 0; dw = R["d_wait_count"] + 0
      exh = (av <= 0 || (maxp > 0 && iu >= maxp) || q + 0 > 0)
      if (df > 0) { lv = 4; det = det "FAIL+" df ";" }
      if (exh) { if (lv < 3) lv = 3; if (av <= 0) det = det "AVAIL=0;"; if (q + 0 > 0) det = det "QUEUED=" q ";" }
      if (dw > 0) { if (lv < 2) lv = 2; det = det "WAIT+" dw ";" }
      if (R["usage_pct"] + 0 >= warn) { if (lv < 1) lv = 1; det = det "USAGE>=" warn "%;" }
      if (RESET) det = det "COUNTER_RESET;"
      sub(/;$/, "", det)
      st = lvname(lv)
      for (j = 1; j <= NCUM; j++) ST["c|" pk "|" CUM[j]] = R[CUM[j]]
      ST["e|" pk] = epoch
      inuse_total += iu
      if (lv >= 3) { exh_cnt++; anyexh = 1 }
    }
    if (lv < 0) {
      for (a2 in PM) R[PM[a2]] = ""
      for (a2 in JM) R[JM[a2]] = ""
      R["ps_cache_hit_pct"] = ""; R["queued_threads"] = ""
    }
    R["status"] = st; R["status_detail"] = det
    out = ""
    for (j = 1; j <= NTC; j++) out = out (j > 1 ? "," : "") csvq(R[TC[j]])
    print out >> ts_csv
    printf "CON %s %-22s %-9s in_use %s/%s (%s%%) idle %s avail %s queued %s wait+%s fail+%s\n", substr(ts, 12), name, st, \
      (R["in_use_count"] == "" ? "-" : R["in_use_count"]), R["max_pool_size"], (R["usage_pct"] == "" ? "-" : R["usage_pct"]), \
      (R["idle_count"] == "" ? "-" : R["idle_count"]), (R["available_count"] == "" ? "-" : R["available_count"]), \
      (q == "" ? "-" : q), (R["d_wait_count"] == "" ? "-" : R["d_wait_count"]), (R["d_blocking_failure_count"] == "" ? "-" : R["d_blocking_failure_count"])
    if (dump_queued && (k in QN) && QN[k] > 0 && epoch - (ST["qd|" pk] + 0) >= qmin) {
      safe = name; gsub(/[^A-Za-z0-9._-]/, "_", safe)
      fn = qdir "/queued_" tsc "_" safe ".txt"
      printf "# timestamp=%s datasource=%s type=%s queued_threads=%d in_use=%s/%s\n", ts, name, type, QN[k], R["in_use_count"], R["max_pool_size"] > fn
      printf "%s", QT[k] > fn
      close(fn)
      ST["qd|" pk] = epoch
    }
  }
  for (w = 1; w <= NW; w++) {
    split(WK[w], b, SUBSEP)
    if (dsfilter != "" && !(b[2] in DSF)) continue
    print csvq(ts) "," epoch "," csvq(b[2]) "," csvq(WT[w]) "," csvq(WF[w]) >> waiters_csv
  }
  if (do_ctx) {
    split("", R)
    R["timestamp"] = ts; R["epoch"] = epoch; R["utc_offset"] = off; R["host"] = host; R["cli_ms"] = cli_ms
    if (ok) {
      R["thread_count"] = C["thread_count"]; R["peak_thread_count"] = C["peak_thread_count"]; R["daemon_thread_count"] = C["daemon_thread_count"]
      if (C["heap_used"] != "") R["heap_used_mb"] = r1(C["heap_used"] / 1048576)
      if (C["heap_committed"] != "") R["heap_committed_mb"] = r1(C["heap_committed"] / 1048576)
      if (C["heap_max"] + 0 > 0) { R["heap_max_mb"] = r1(C["heap_max"] / 1048576); R["heap_used_pct"] = r1(C["heap_used"] * 100 / C["heap_max"]) }
      if (C["io_ok"]) {
        R["io_busy_task_threads"] = C["io_busy"] + 0; R["io_max_task_threads"] = C["io_max"] + 0; R["io_queue_size"] = C["io_queue"] + 0
        if (C["io_max"] + 0 > 0) R["io_busy_pct"] = r1(C["io_busy"] * 100 / C["io_max"])
      }
      R["tx_inflight"] = C["tx_inflight"]; R["tx_timed_out"] = C["tx_timed_out"]
      if (C["tx_timed_out"] != "" && ST["ctx|tx_timed_out"] != "") {
        dd = C["tx_timed_out"] - ST["ctx|tx_timed_out"]; R["d_tx_timed_out"] = (dd < 0) ? C["tx_timed_out"] : dd
      }
      if (C["tx_timed_out"] != "") ST["ctx|tx_timed_out"] = C["tx_timed_out"]
      R["ds_in_use_total"] = inuse_total; R["ds_exhausted"] = exh_cnt
    }
    out = ""
    for (j = 1; j <= NCC; j++) out = out (j > 1 ? "," : "") csvq(R[CC[j]])
    print out >> ctx_csv
  }
  if (ok && NDS > 0) {
    s = ""
    for (i = 1; i <= NDS; i++) { s = s (i > 1 ? "\035" : "") DST[i] "\036" DSN[i]; printf "%d\t%s\t%s\n", i, DST[i], DSN[i] > dslistnew }
    close(dslistnew)
    ST["dslist"] = s
  }
  for (key in ST) printf "%s\t%s\n", key, ST[key] > (statefile ".new")
  close(statefile ".new")
  if (anyexh) print "EXH"
  if (anyoff) print "OFF"
}
EOF_AWK

  cat > "$dir/init.awk" <<'EOF_AWK'
# ---- サーバー情報・データソース設定のスナップショット ----
BEGIN {
  DEF["min-pool-size"] = "0"; DEF["max-pool-size"] = "20"; DEF["blocking-timeout-wait-millis"] = "30000"
  DEF["idle-timeout-minutes"] = "30"; DEF["pool-prefill"] = "false"; DEF["pool-use-strict-min"] = "false"
  DEF["pool-fair"] = "true"; DEF["flush-strategy"] = "FailingConnectionOnly"; DEF["background-validation"] = "false"
  DEF["validate-on-match"] = "false"; DEF["allocation-retry"] = "0"; DEF["allocation-retry-wait-millis"] = "5000"
  DEF["prepared-statements-cache-size"] = "0"; DEF["use-fast-fail"] = "false"
  NP = split("jndi-name enabled pool-statistics-enabled(runtime) statistics-enabled driver-name driver-class datasource-class xa-datasource-class connection-url user-name min-pool-size initial-pool-size max-pool-size blocking-timeout-wait-millis idle-timeout-minutes pool-prefill pool-use-strict-min pool-fair flush-strategy background-validation background-validation-millis validate-on-match check-valid-connection-sql valid-connection-checker-class-name exception-sorter-class-name stale-connection-checker-class-name use-fast-fail allocation-retry allocation-retry-wait-millis query-timeout set-tx-query-timeout use-try-lock transaction-isolation track-statements prepared-statements-cache-size share-prepared-statements use-ccm jta mcp", PRI, " ")
  for (i = 1; i <= NP; i++) PRIO[PRI[i]] = i
  DEPTH = 0; INSTR = 0; sec = ""; ent = ""; inres = 0; collecting = 0; NE = 0; NM = 0
}
function scan(line,    i, c, n) {
  n = length(line)
  for (i = 1; i <= n; i++) {
    c = substr(line, i, 1)
    if (INSTR) { if (c == "\\") i++; else if (c == "\"") INSTR = 0 }
    else if (c == "\"") INSTR = 1
    else if (c == "{" || c == "[") DEPTH++
    else if (c == "}" || c == "]") DEPTH--
  }
}
function addent(type, nm,    e) { e = type SUBSEP nm; if (!(e in ENSEEN)) { ENSEEN[e] = 1; EN[++NE] = e }; return e }
function mask_url(u,    out, rest, seg, p) {
  out = ""; rest = u
  while (match(tolower(rest), /(password|passwd|pwd)=/)) {
    out = out substr(rest, 1, RSTART + RLENGTH - 1); rest = substr(rest, RSTART + RLENGTH)
    if (match(rest, /[;&?)]/)) { out = out "********"; rest = substr(rest, RSTART) } else { out = out "********"; rest = "" }
  }
  u = out rest
  if (match(u, /:thin:[^\/@:]+\/[^@]+@/)) {
    seg = substr(u, RSTART, RLENGTH); p = index(seg, "/")
    u = substr(u, 1, RSTART - 1) substr(seg, 1, p) "********@" substr(u, RSTART + RLENGTH)
  }
  return u
}
function addattr(e, key, val, note,    n) {
  if (key == "statistics" || key == "connection-properties" || key == "xa-datasource-properties") return
  if (note == "") {
    if (val == "") { if (key in DEF) { val = DEF[key]; note = "default" } else note = "undefined" }
    else if (tolower(key) ~ /password|credential|secret/) { val = "********"; note = "masked" }
  }
  if (tolower(key) ~ /url$/) val = mask_url(val)
  if (!((e, key) in AV)) { n = ++NA[e]; AK[e, n] = key }
  AV[e, key] = val; AN[e, key] = note
}
function finish_collect(    v) {
  if (!collecting) return
  v = cbuf; gsub(/[ \t]+/, " ", v); sub(/,$/, "", v)
  addattr(cent, ckey, v, "")
  collecting = 0
}
function meta_line(    p, cat, key, v) {
  p = index(substr(sec, 3), "."); cat = substr(sec, 3, p - 1); key = substr(sec, 3 + p)
  if (!kvparse(ln)) return
  if (key == "heap") {
    if (d0 >= 2 && (KV_K == "init" || KV_K == "used" || KV_K == "committed" || KV_K == "max")) META[++NM] = cat SUBSEP "heap-" KV_K "-mb" SUBSEP r1(dmr(KV_V) / 1048576)
    return
  }
  if (d0 != 1 || KV_K != "result") return
  v = dmr(KV_V)
  if (key == "start-time" && v ~ /^[0-9]+$/) v = fmt_lsec(int(v / 1000) + off2sec(off))
  if (key == "uptime-ms" && v ~ /^[0-9]+$/) META[++NM] = cat SUBSEP "uptime" SUBSEP fmt_dur(int(v / 1000))
  META[++NM] = cat SUBSEP key SUBSEP v
}
function prop_line(    t, nm, p, v) {
  if (match(ln, /^[ \t]*\("(data-source|xa-data-source)" => "/)) {
    t = index(ln, "(\"xa-data-source\"") ? "xa-data-source" : "data-source"
    p = index(ln, " => \""); nm = substr(ln, p + 5); sub(/"\),?[ \t]*$/, "", nm)
    ent = addent(t, nm); return
  }
  if (match(ln, /^[ \t]*\("(connection-properties|xa-datasource-properties)" => "/)) {
    t = index(ln, "xa-datasource-properties") ? "xa-datasource-properties" : "connection-properties"
    p = index(ln, " => \""); nm = substr(ln, p + 5); sub(/"\),?[ \t]*$/, "", nm)
    pname = t "." nm; return
  }
  if ((p = index(ln, "\"value\" => ")) > 0 && pname != "" && ent != "") {
    v = substr(ln, p + 11); sub(/[ \t]+$/, "", v); sub(/,$/, "", v); sub(/}$/, "", v); sub(/,$/, "", v)
    v = dmr(v)
    if (tolower(pname) ~ /pass|pwd|secret|credential/ && v != "") addattr(ent, pname, "********", "masked")
    else addattr(ent, pname, v, (v == "" ? "undefined" : "-"))
    pname = ""
  }
}
{
  sub(/\r$/, "")
  ln = $0
  if (substr(ln, 1, 9) == "DSPOOL_S ") { if (substr(ln, 10) == seq) started = 1; next }
  if (!started) next
  if (substr(ln, 1, 9) == "DSPOOL_E ") { if (substr(ln, 10) == seq) ended = 1; next }
  if (substr(ln, 1, 9) == "DSPOOL_B ") {
    finish_collect()
    sec = substr(ln, 10); DEPTH = 0; INSTR = 0; ent = ""; inres = 0; pname = ""
    if (sec == "ccm") ent = addent("jca", "cached-connection-manager")
    next
  }
  if (substr(ln, 1, 9) == "DSPOOL_F ") next
  if (sec == "") next
  d0 = DEPTH; s0 = INSTR
  scan(ln)
  if (substr(sec, 1, 2) == "m.") { meta_line(); next }
  if (substr(sec, 1, 6) == "cprop.") { prop_line(); next }
  if (!s0 && match(ln, /^[ \t]*\("(data-source|xa-data-source|jdbc-driver)" => "/)) {
    t = ln; sub(/^[ \t]*\("/, "", t); sub(/".*$/, "", t)
    p = index(ln, " => \""); nm = substr(ln, p + 5); sub(/"\),?[ \t]*$/, "", nm)
    ent = addent(t, nm); inres = 0
    next
  }
  if (collecting) {
    cbuf = cbuf " " trim(ln)
    if (DEPTH <= resdepth && !INSTR) finish_collect()
    next
  }
  if (!s0 && kvparse(ln)) {
    if (!inres) {
      if (KV_K == "result" && substr(trim(KV_V), 1, 1) == "{" && DEPTH > d0) { inres = 1; resdepth = d0 + 1 }
      next
    }
    if (d0 == resdepth && ent != "") {
      if (DEPTH > resdepth || INSTR) { collecting = 1; ckey = KV_K; cbuf = trim(KV_V); cent = ent; next }
      if (substr(sec, 1, 5) == "pool.") { if (KV_K == "statistics-enabled") addattr(ent, "pool-statistics-enabled(runtime)", dmr(KV_V), "") }
      else addattr(ent, KV_K, dmr(KV_V), "")
      next
    }
  }
  if (inres && DEPTH < resdepth) inres = 0
}
END {
  finish_collect()
  if (!(started && ended)) exit 1
  for (i = 1; i <= NM; i++) { split(META[i], a, SUBSEP); print csvq(a[1]) "," csvq(a[2]) "," csvq(a[3]) > meta_out }
  close(meta_out)
  print "ds_name,ds_type,attribute,value,note" > cfg_out
  for (e = 1; e <= NE; e++) {
    en = EN[e]; split(en, b, SUBSEP)
    for (i = 1; i <= NP; i++) { key = PRI[i]; if ((en, key) in AV) print csvq(b[2]) "," csvq(b[1]) "," csvq(key) "," csvq(AV[en, key]) "," csvq(AN[en, key]) > cfg_out }
    for (i = 1; i <= NA[en]; i++) { key = AK[en, i]; if (!(key in PRIO)) print csvq(b[2]) "," csvq(b[1]) "," csvq(key) "," csvq(AV[en, key]) "," csvq(AN[en, key]) > cfg_out }
  }
  close(cfg_out)
  n = 0
  printf "" > dslist_out
  for (e = 1; e <= NE; e++) { split(EN[e], b, SUBSEP); if (b[1] == "data-source" || b[1] == "xa-data-source") printf "%d\t%s\t%s\n", ++n, b[1], b[2] > dslist_out }
  close(dslist_out)
}
EOF_AWK

  cat > "$dir/report.awk" <<'EOF_AWK'
# ---- 時系列CSV → サマリー / 時間別 / イベント / 待機スレッド集計 ----
BEGIN {
  NSC = split("ds_name,ds_type,jndi_name,verdict,notes,period_start,period_end,duration_sec,samples,valid_samples,interval_sec,min_pool_size,max_pool_size,blocking_timeout_ms,in_use_min,in_use_avg,in_use_p95,in_use_max,in_use_max_at,active_min,active_avg,active_max,idle_min,idle_avg,idle_max,available_min,available_avg,usage_pct_avg,usage_pct_p95,usage_pct_max,max_used_count,max_used_pct,max_wait_count,queued_threads_max,high_samples,exhausted_samples,exhausted_pct,exhausted_time_sec,exhaustion_events,longest_event_sec,first_exhausted_at,last_exhausted_at,wait_total,blocking_failure_total,created_total,destroyed_total,timed_out_total,avg_get_time_ms,max_get_time_ms,avg_usage_time_ms,max_usage_time_ms,avg_creation_time_ms,max_creation_time_ms,avg_blocking_time_ms,max_wait_time_ms,stats_off_samples,error_samples,counter_resets,host", SC, ",")
  NHC = split("ds_name,bucket_start,bucket_end,samples,valid_samples,worst_status,in_use_min,in_use_avg,in_use_max,active_min,active_avg,active_max,idle_min,idle_avg,idle_max,available_min,usage_pct_avg,usage_pct_max,max_pool_size,high_samples,exhausted_samples,wait_delta,blocking_failure_delta,queued_threads_max,created_delta,destroyed_delta,timed_out_delta,max_used_count_end,max_get_time_ms_end", HC, ",")
  NEC = split("event_id,ds_name,severity,start_time,end_time,duration_sec,samples,in_use_max,available_min,usage_pct_max,queued_threads_max,wait_delta,blocking_failure_delta,max_get_time_ms_end,max_wait_count_end,top_waiter_frame", EC, ",")
  NWC = split("ds_name,app_frame,occurrences,samples,first_seen,last_seen,example_thread", WC, ",")
  if (bucket + 0 <= 0) bucket = 3600
  if (def_interval + 0 <= 0) def_interval = 10
  if (warn == "") warn = 80
  fileno = 0; ND = 0; NEV = 0; NWK = 0
}
function g(name) { return (name in H) ? F[H[name]] : "" }
function gw(name) { return (name in HW) ? F[HW[name]] : "" }
FNR == 1 {
  fileno++
  sub(/\r$/, "")
  n = csvsplit($0, F)
  if (fileno == 1) { for (i = 1; i <= n; i++) H[F[i]] = i }
  else { for (i = 1; i <= n; i++) HW[F[i]] = i; close_all_events() }
  next
}
fileno == 1 { sub(/\r$/, ""); if ($0 != "") ts_row(); next }
fileno == 2 { sub(/\r$/, ""); if ($0 != "") wait_row(); next }
function close_event(d,    e) {
  e = EVO[d]; EVO[d] = 0
  EV_dur[e] = EV_eep[e] - EV_sep[e] + def_interval
  n_ev[d]++
  if (EV_dur[e] > long_ev[d] + 0) long_ev[d] = EV_dur[e]
}
function close_all_events(    d) { for (d = 1; d <= ND; d++) if (EVO[d]) close_event(d) }
function ts_row(    ds, d, st, ep, tsx, off, L, iu, ac, idl, av, mp, up, upk, q, iv, bk, bkey, exh, e, dw, df) {
  csvsplit($0, F)
  ds = g("ds_name"); if (ds == "") return
  st = g("status"); ep = g("epoch") + 0; tsx = g("timestamp"); off = off2sec(g("utc_offset"))
  if (!(ds in DI)) { d = ++ND; DI[ds] = d; DSNAME[d] = ds; first_ts[d] = tsx; first_ep[d] = ep }
  d = DI[ds]
  n_total[d]++; last_ts[d] = tsx; last_ep[d] = ep
  if (g("ds_type") != "") dtype[d] = g("ds_type")
  if (g("jndi_name") != "") djndi[d] = g("jndi_name")
  if (g("host") != "") dhost[d] = g("host")
  if (g("min_pool_size") != "") dmin[d] = g("min_pool_size")
  if (g("max_pool_size") != "") dmax[d] = g("max_pool_size")
  if (g("blocking_timeout_ms") != "") dbto[d] = g("blocking_timeout_ms")
  L = lvl(st)
  if (st == "STATS_OFF") n_off[d]++
  else if (st == "DISABLED") n_dis[d]++
  else if (L < 0) n_err[d]++
  bk = int((ep + off) / bucket) * bucket
  bkey = d SUBSEP bk
  if (!(bkey in BN)) { NB[d]++; BL[d, NB[d]] = bk; BN[bkey] = 0; BV[bkey] = 0; BW[bkey] = -1; BS[bkey] = "" }
  BN[bkey]++
  if (L < 0) { if (BS[bkey] == "") BS[bkey] = st; if (EVO[d]) close_event(d); return }
  iu = g("in_use_count") + 0; ac = g("active_count") + 0; idl = g("idle_count") + 0; av = g("available_count") + 0
  mp = g("max_pool_size") + 0; up = g("usage_pct") + 0; q = g("queued_threads")
  dw = g("d_wait_count") + 0; df = g("d_blocking_failure_count") + 0
  iv = g("interval_sec") + 0; if (iv <= 0 || iv > 3 * def_interval) iv = def_interval
  nv = ++n_valid[d]
  if (nv == 1 || iu < iu_min[d]) iu_min[d] = iu
  if (nv == 1 || iu > iu_max[d]) { iu_max[d] = iu; iu_max_at[d] = tsx }
  iu_sum[d] += iu; IH[d, iu]++
  if (nv == 1 || ac < ac_min[d]) ac_min[d] = ac
  if (nv == 1 || ac > ac_max[d]) ac_max[d] = ac
  ac_sum[d] += ac
  if (nv == 1 || idl < id_min[d]) id_min[d] = idl
  if (nv == 1 || idl > id_max[d]) id_max[d] = idl
  id_sum[d] += idl
  if (nv == 1 || av < av_min[d]) av_min[d] = av
  av_sum[d] += av
  upk = int(up * 10 + 0.5); UH[d, upk]++
  if (nv == 1 || upk < up_mink[d]) up_mink[d] = upk
  if (nv == 1 || upk > up_maxk[d]) up_maxk[d] = upk
  if (nv == 1 || up > up_max[d]) up_max[d] = up
  up_sum[d] += up
  if (q != "" && q + 0 > q_max[d] + 0) q_max[d] = q + 0
  exh = (av <= 0 || (mp > 0 && iu >= mp) || q + 0 > 0)
  if (exh) { n_exh[d]++; exh_time[d] += iv; if (first_exh[d] == "") first_exh[d] = tsx; last_exh[d] = tsx }
  if (up >= warn) n_high[d]++
  w_tot[d] += dw; f_tot[d] += df
  c_tot[d] += g("d_created_count") + 0; x_tot[d] += g("d_destroyed_count") + 0; t_tot[d] += g("d_timed_out") + 0
  if (g("max_used_count") != "") muc[d] = g("max_used_count")
  if (g("max_wait_count") != "") mwc[d] = g("max_wait_count")
  agt[d] = g("avg_get_time_ms"); mgt[d] = g("max_get_time_ms"); aut[d] = g("avg_usage_time_ms"); mut[d] = g("max_usage_time_ms")
  act[d] = g("avg_creation_time_ms"); mct[d] = g("max_creation_time_ms"); abt[d] = g("avg_blocking_time_ms"); mwt[d] = g("max_wait_time_ms")
  if (prev_mp[d] != "" && prev_mp[d] != mp) resized[d] = 1
  prev_mp[d] = mp
  if (index(g("status_detail"), "COUNTER_RESET")) resets[d]++
  BV[bkey]++
  if (BV[bkey] == 1 || iu < Bimin[bkey]) Bimin[bkey] = iu
  if (BV[bkey] == 1 || iu > Bimax[bkey]) Bimax[bkey] = iu
  Bisum[bkey] += iu
  if (BV[bkey] == 1 || ac < Bamin[bkey]) Bamin[bkey] = ac
  if (BV[bkey] == 1 || ac > Bamax[bkey]) Bamax[bkey] = ac
  Basum[bkey] += ac
  if (BV[bkey] == 1 || idl < Bdmin[bkey]) Bdmin[bkey] = idl
  if (BV[bkey] == 1 || idl > Bdmax[bkey]) Bdmax[bkey] = idl
  Bdsum[bkey] += idl
  if (BV[bkey] == 1 || av < Bvmin[bkey]) Bvmin[bkey] = av
  Busum[bkey] += up
  if (BV[bkey] == 1 || up > Bumax[bkey]) Bumax[bkey] = up
  Bmp[bkey] = mp
  if (up >= warn) Bhigh[bkey]++
  if (exh) Bexh[bkey]++
  Bw[bkey] += dw; Bf[bkey] += df
  Bc[bkey] += g("d_created_count") + 0; Bx[bkey] += g("d_destroyed_count") + 0; Bt[bkey] += g("d_timed_out") + 0
  if (q != "" && q + 0 > Bq[bkey] + 0) Bq[bkey] = q + 0
  Bmu[bkey] = g("max_used_count"); Bmg[bkey] = g("max_get_time_ms")
  if (L > BW[bkey]) BW[bkey] = L
  if (L >= 2) {
    if (EVO[d] && ep - EV_eep[EVO[d]] > 3 * def_interval) close_event(d)
    if (!EVO[d]) {
      e = ++NEV; EVO[d] = e; EV_d[e] = d; EV_sts[e] = tsx; EV_sep[e] = ep
      EV_n[e] = 0; EV_lv[e] = 0; EV_iu[e] = iu; EV_av[e] = av; EV_up[e] = up; EV_q[e] = 0; EV_w[e] = 0; EV_f[e] = 0
    }
    e = EVO[d]
    EV_n[e]++; EV_ets[e] = tsx; EV_eep[e] = ep
    if (L > EV_lv[e]) EV_lv[e] = L
    if (iu > EV_iu[e]) EV_iu[e] = iu
    if (av < EV_av[e]) EV_av[e] = av
    if (up > EV_up[e]) EV_up[e] = up
    if (q + 0 > EV_q[e]) EV_q[e] = q + 0
    EV_w[e] += dw; EV_f[e] += df
    EV_mg[e] = g("max_get_time_ms"); EV_mw[e] = g("max_wait_count")
  } else if (EVO[d]) close_event(d)
}
function wait_row(    ds, fr, th, ep, tsx, wk, d, e) {
  csvsplit($0, F)
  ds = gw("ds_name"); fr = gw("app_frame"); th = gw("thread_name"); ep = gw("epoch") + 0; tsx = gw("timestamp")
  if (ds == "") return
  wk = ds SUBSEP fr
  if (!(wk in WN)) { NWK++; WKS[NWK] = wk; WFIRST[wk] = tsx; WTH[wk] = th; WN[wk] = 0; WS[wk] = 0; WLEP[wk] = -1 }
  WN[wk]++; WLAST[wk] = tsx
  if (WLEP[wk] != ep) { WS[wk]++; WLEP[wk] = ep }
  if (ds in DI) {
    d = DI[ds]
    for (e = 1; e <= NEV; e++) if (EV_d[e] == d && ep >= EV_sep[e] && ep <= EV_eep[e]) { EVF[e, fr]++; break }
  }
}
function hpct(d, p,    target, c, v) {
  target = p / 100 * n_valid[d]; c = 0
  for (v = iu_min[d]; v <= iu_max[d]; v++) { if ((d, v) in IH) c += IH[d, v]; if (c >= target) return v }
  return iu_max[d]
}
function upct(d, p,    target, c, k) {
  target = p / 100 * n_valid[d]; c = 0
  for (k = up_mink[d]; k <= up_maxk[d]; k++) { if ((d, k) in UH) c += UH[d, k]; if (c >= target) return r1(k / 10) }
  return r1(up_maxk[d] / 10)
}
function outrow(A, n, file,    s, i) { s = ""; for (i = 1; i <= n; i++) s = s (i > 1 ? "," : "") csvq(R[A[i]]); print s > file }
END {
  close_all_events()
  # サマリー
  print joinarr(SC, NSC) > out_summary
  for (d = 1; d <= ND; d++) {
    split("", R)
    nv = n_valid[d] + 0
    R["ds_name"] = DSNAME[d]; R["ds_type"] = dtype[d]; R["jndi_name"] = djndi[d]; R["host"] = dhost[d]
    R["period_start"] = first_ts[d]; R["period_end"] = last_ts[d]; R["duration_sec"] = last_ep[d] - first_ep[d]
    R["samples"] = n_total[d]; R["valid_samples"] = nv; R["interval_sec"] = def_interval
    R["min_pool_size"] = dmin[d]; R["max_pool_size"] = dmax[d]; R["blocking_timeout_ms"] = dbto[d]
    R["stats_off_samples"] = n_off[d] + 0; R["error_samples"] = n_err[d] + 0; R["counter_resets"] = resets[d] + 0
    if (nv > 0) {
      R["in_use_min"] = iu_min[d]; R["in_use_avg"] = r1(iu_sum[d] / nv); R["in_use_p95"] = hpct(d, 95)
      R["in_use_max"] = iu_max[d]; R["in_use_max_at"] = iu_max_at[d]
      R["active_min"] = ac_min[d]; R["active_avg"] = r1(ac_sum[d] / nv); R["active_max"] = ac_max[d]
      R["idle_min"] = id_min[d]; R["idle_avg"] = r1(id_sum[d] / nv); R["idle_max"] = id_max[d]
      R["available_min"] = av_min[d]; R["available_avg"] = r1(av_sum[d] / nv)
      R["usage_pct_avg"] = r1(up_sum[d] / nv); R["usage_pct_p95"] = upct(d, 95); R["usage_pct_max"] = r1(up_max[d])
      R["max_used_count"] = muc[d]
      if (dmax[d] + 0 > 0 && muc[d] != "") R["max_used_pct"] = r1(muc[d] * 100 / dmax[d])
      R["max_wait_count"] = mwc[d]; R["queued_threads_max"] = q_max[d] + 0
      R["high_samples"] = n_high[d] + 0; R["exhausted_samples"] = n_exh[d] + 0
      R["exhausted_pct"] = r1(n_exh[d] * 100 / nv); R["exhausted_time_sec"] = exh_time[d] + 0
      R["exhaustion_events"] = n_ev[d] + 0; R["longest_event_sec"] = long_ev[d] + 0
      R["first_exhausted_at"] = first_exh[d]; R["last_exhausted_at"] = last_exh[d]
      R["wait_total"] = w_tot[d] + 0; R["blocking_failure_total"] = f_tot[d] + 0
      R["created_total"] = c_tot[d] + 0; R["destroyed_total"] = x_tot[d] + 0; R["timed_out_total"] = t_tot[d] + 0
      R["avg_get_time_ms"] = agt[d]; R["max_get_time_ms"] = mgt[d]; R["avg_usage_time_ms"] = aut[d]; R["max_usage_time_ms"] = mut[d]
      R["avg_creation_time_ms"] = act[d]; R["max_creation_time_ms"] = mct[d]; R["avg_blocking_time_ms"] = abt[d]; R["max_wait_time_ms"] = mwt[d]
    }
    if (nv == 0) v = (n_off[d] > 0) ? "STATS_OFF" : (n_dis[d] > 0) ? "DISABLED" : (n_err[d] > 0) ? "ERROR" : "NO_DATA"
    else if (f_tot[d] > 0) v = "FAILURE"
    else if (n_exh[d] > 0) v = "EXHAUSTED"
    else if (w_tot[d] > 0) v = "WAIT"
    else if (up_max[d] >= warn) v = "HIGH"
    else v = "OK"
    R["verdict"] = v
    nt = ""
    if (f_tot[d] > 0) nt = nt "FAILURES;"
    if (n_exh[d] > 0) nt = nt "EXHAUSTED;"
    if (w_tot[d] > 0) nt = nt "WAITS;"
    if (nv > 0 && up_max[d] >= warn) nt = nt "HIGH_USAGE;"
    if (nv > 0 && muc[d] != "" && dmax[d] + 0 > 0 && muc[d] + 0 >= dmax[d] + 0) nt = nt "PEAK_AT_MAX;"
    if (nv > 0 && mut[d] + 0 >= 60000) nt = nt "LONG_HOLD;"
    if (nv > 0 && mgt[d] + 0 >= 1000) nt = nt "SLOW_GET;"
    if (nv > 0 && mct[d] + 0 >= 1000) nt = nt "SLOW_CREATE;"
    if (nv > 0 && x_tot[d] - t_tot[d] >= 10) nt = nt "CHURN;"
    if (t_tot[d] > 0) nt = nt "IDLE_TIMEOUT;"
    if (nv > 0 && iu_min[d] >= 1 && last_ep[d] - first_ep[d] >= 3600) nt = nt "NEVER_IDLE;"
    if (resized[d]) nt = nt "POOL_RESIZED;"
    if (resets[d] > 0) nt = nt "COUNTER_RESET;"
    if (n_off[d] > 0) nt = nt "STATS_OFF;"
    if (n_err[d] > 0) nt = nt "ERRORS;"
    sub(/;$/, "", nt)
    R["notes"] = nt
    outrow(SC, NSC, out_summary)
  }
  close(out_summary)
  # 時間別推移
  print joinarr(HC, NHC) > out_hourly
  for (d = 1; d <= ND; d++) for (b = 1; b <= NB[d]; b++) {
    bk = BL[d, b]; bkey = d SUBSEP bk
    split("", R)
    R["ds_name"] = DSNAME[d]; R["bucket_start"] = fmt_lsec(bk); R["bucket_end"] = fmt_lsec(bk + bucket)
    R["samples"] = BN[bkey]; R["valid_samples"] = BV[bkey]
    if (BV[bkey] > 0) {
      nb = BV[bkey]
      R["worst_status"] = lvname(BW[bkey])
      R["in_use_min"] = Bimin[bkey]; R["in_use_avg"] = r1(Bisum[bkey] / nb); R["in_use_max"] = Bimax[bkey]
      R["active_min"] = Bamin[bkey]; R["active_avg"] = r1(Basum[bkey] / nb); R["active_max"] = Bamax[bkey]
      R["idle_min"] = Bdmin[bkey]; R["idle_avg"] = r1(Bdsum[bkey] / nb); R["idle_max"] = Bdmax[bkey]
      R["available_min"] = Bvmin[bkey]; R["usage_pct_avg"] = r1(Busum[bkey] / nb); R["usage_pct_max"] = r1(Bumax[bkey])
      R["max_pool_size"] = Bmp[bkey]; R["high_samples"] = Bhigh[bkey] + 0; R["exhausted_samples"] = Bexh[bkey] + 0
      R["wait_delta"] = Bw[bkey] + 0; R["blocking_failure_delta"] = Bf[bkey] + 0
      R["created_delta"] = Bc[bkey] + 0; R["destroyed_delta"] = Bx[bkey] + 0; R["timed_out_delta"] = Bt[bkey] + 0
      R["queued_threads_max"] = Bq[bkey] + 0; R["max_used_count_end"] = Bmu[bkey]; R["max_get_time_ms_end"] = Bmg[bkey]
    } else R["worst_status"] = BS[bkey]
    outrow(HC, NHC, out_hourly)
  }
  close(out_hourly)
  # イベント（開始時刻順）
  for (i = 1; i <= NEV; i++) ORD[i] = i
  for (i = 2; i <= NEV; i++) {
    x = ORD[i]; j = i - 1
    while (j >= 1 && (EV_sep[ORD[j]] > EV_sep[x] || (EV_sep[ORD[j]] == EV_sep[x] && EV_d[ORD[j]] > EV_d[x]))) { ORD[j + 1] = ORD[j]; j-- }
    ORD[j + 1] = x
  }
  for (k in EVF) { split(k, a, SUBSEP); if (EVF[k] > TOPC[a[1]] + 0) { TOPC[a[1]] = EVF[k]; TOPF[a[1]] = a[2] } }
  print joinarr(EC, NEC) > out_events
  for (i = 1; i <= NEV; i++) {
    e = ORD[i]
    split("", R)
    R["event_id"] = i; R["ds_name"] = DSNAME[EV_d[e]]; R["severity"] = lvname(EV_lv[e])
    R["start_time"] = EV_sts[e]; R["end_time"] = EV_ets[e]; R["duration_sec"] = EV_dur[e]; R["samples"] = EV_n[e]
    R["in_use_max"] = EV_iu[e]; R["available_min"] = EV_av[e]; R["usage_pct_max"] = r1(EV_up[e]); R["queued_threads_max"] = EV_q[e]
    R["wait_delta"] = EV_w[e]; R["blocking_failure_delta"] = EV_f[e]; R["max_get_time_ms_end"] = EV_mg[e]; R["max_wait_count_end"] = EV_mw[e]
    if (e in TOPF) R["top_waiter_frame"] = TOPF[e] " (x" TOPC[e] ")"
    outrow(EC, NEC, out_events)
  }
  close(out_events)
  # 待機スレッドの呼び出し元
  for (i = 1; i <= NWK; i++) WO[i] = i
  for (i = 2; i <= NWK; i++) {
    x = WO[i]; j = i - 1
    while (j >= 1 && wless(x, WO[j])) { WO[j + 1] = WO[j]; j-- }
    WO[j + 1] = x
  }
  print joinarr(WC, NWC) > out_waiters
  for (i = 1; i <= NWK; i++) {
    wk = WKS[WO[i]]; split(wk, a, SUBSEP)
    split("", R)
    R["ds_name"] = a[1]; R["app_frame"] = a[2]; R["occurrences"] = WN[wk]; R["samples"] = WS[wk]
    R["first_seen"] = WFIRST[wk]; R["last_seen"] = WLAST[wk]; R["example_thread"] = WTH[wk]
    outrow(WC, NWC, out_waiters)
  }
  close(out_waiters)
}
function wless(x, y,    ax, ay, dx, dy) {
  split(WKS[x], ax, SUBSEP); split(WKS[y], ay, SUBSEP)
  dx = (ax[1] in DI) ? DI[ax[1]] : 999999; dy = (ay[1] in DI) ? DI[ay[1]] : 999999
  if (dx != dy) return dx < dy
  return WN[WKS[x]] > WN[WKS[y]]
}
EOF_AWK

  cat > "$dir/tdump.awk" <<'EOF_AWK'
# ---- dump-all-threads (DMR) → jstack 風テキスト ----
BEGIN { print "# Thread dump via jboss-cli (dump-all-threads)  " ts; print ""; tid = "" }
function flush(    i, j, m) {
  if (tid == "") return
  printf "\"%s\" #%s\n   java.lang.Thread.State: %s\n", tname, tid, tstate
  for (i = 1; i <= nfr; i++) {
    print FR[i]
    if (i == 1 && lname != "") print "\t- " (tstate == "BLOCKED" ? "waiting to lock" : "parking/waiting on") " <" lname ">" (lowner != "" ? " owned by \"" lowner "\"" : "")
    for (j = 1; j <= nmon; j++) { split(MON[j], m, SUBSEP); if (m[1] + 1 == i) print "\t- locked <" m[3] "> (a " m[2] ")" }
  }
  if (nsyn > 0) { print ""; print "   Locked ownable synchronizers:"; for (j = 1; j <= nsyn; j++) { split(SYN[j], m, SUBSEP); print "\t- <" m[2] "> (a " m[1] ")" } }
  print ""
  tid = ""
}
{
  sub(/\r$/, "")
  if (!kvparse($0)) next
  k = KV_K; v = dmr(KV_V)
  if (k == "thread-id") { flush(); tid = v; tname = ""; tstate = ""; lname = ""; lowner = ""; sect = ""; nfr = 0; nmon = 0; nsyn = 0; skipf = 0; next }
  if (tid == "") next
  if (k == "thread-name" && sect == "") { tname = v; next }
  if (k == "thread-state" && sect == "") { tstate = v; next }
  if (k == "lock-name" && sect == "") { lname = v; next }
  if (k == "lock-owner-name" && sect == "") { lowner = v; next }
  if (k == "lock-info") { sect = "li"; next }
  if (k == "stack-trace") { sect = "st"; ff = ""; fl = ""; fc = ""; fm = ""; next }
  if (k == "locked-monitors") { sect = "mon"; next }
  if (k == "locked-synchronizers") { sect = "syn"; next }
  if (k == "suspended" || k == "in-native" || k == "lock-owner-id" || k == "blocked-time") { sect = ""; next }
  if (sect == "li" && k == "identity-hash-code") { sect = ""; next }
  if (sect == "st") {
    if (k == "file-name") ff = v; else if (k == "line-number") fl = v; else if (k == "class-name") fc = v; else if (k == "method-name") fm = v
    else if (k == "native-method") {
      FR[++nfr] = "\tat " fc "." fm "(" ((v == "true") ? "Native Method" : (ff == "" ? "Unknown Source" : ff (fl + 0 >= 0 ? ":" fl : ""))) ")"
      ff = ""; fl = ""; fc = ""; fm = ""
    }
  } else if (sect == "mon") {
    if (skipf) { if (k == "native-method") skipf = 0; next }
    if (k == "class-name") mc = v; else if (k == "identity-hash-code") mh = v
    else if (k == "locked-stack-depth") { MON[++nmon] = v SUBSEP mc SUBSEP sprintf("0x%x", mh); mc = ""; mh = ""; skipf = 1 }
  } else if (sect == "syn") {
    if (k == "class-name") sc = v; else if (k == "identity-hash-code") SYN[++nsyn] = sc SUBSEP sprintf("0x%x", v)
  }
}
END { flush() }
EOF_AWK

  cat > "$dir/print_summary.awk" <<'EOF_AWK'
function g(n) { return (n in H) ? F[H[n]] : "" }
function jv(v) { return (v == "FAILURE") ? "取得失敗(タイムアウト)あり" : (v == "EXHAUSTED") ? "枯渇あり" : (v == "WAIT") ? "待ち発生" : (v == "HIGH") ? "高使用率" : (v == "OK") ? "正常" : (v == "STATS_OFF") ? "統計無効" : (v == "DISABLED") ? "DS無効" : (v == "ERROR") ? "取得エラー" : "データなし" }
FNR == 1 { n = csvsplit($0, F); for (i = 1; i <= n; i++) H[F[i]] = i; print ""; print "==================== 接続プール 収集結果サマリー ===================="; next }
{
  csvsplit($0, F)
  printf "[%s] 判定: %s (%s)\n", g("ds_name"), jv(g("verdict")), g("verdict")
  printf "  期間       : %s ～ %s  （サンプル %s / 有効 %s）\n", g("period_start"), g("period_end"), g("samples"), g("valid_samples")
  if (g("valid_samples") + 0 > 0) {
    printf "  使用中接続 : 最小 %s / 平均 %s / 95%%値 %s / 最大 %s （最大プール %s, 使用率 最大 %s%%）\n", g("in_use_min"), g("in_use_avg"), g("in_use_p95"), g("in_use_max"), g("max_pool_size"), g("usage_pct_max")
    printf "  枯渇・待ち : 枯渇 %s サンプル（約 %s 秒）/ イベント %s 回 / 待ち %s 回 / 取得失敗 %s 回 / 最大待機スレッド %s\n", g("exhausted_samples"), g("exhausted_time_sec"), g("exhaustion_events"), g("wait_total"), g("blocking_failure_total"), g("queued_threads_max")
    printf "  サーバー値 : MaxUsedCount %s / MaxWaitCount %s / 最大取得時間 %s ms / 最大使用時間 %s ms\n", g("max_used_count"), g("max_wait_count"), g("max_get_time_ms"), g("max_usage_time_ms")
  }
  if (g("notes") != "") printf "  所見コード : %s\n", g("notes")
}
END { print "======================================================================" }
EOF_AWK

  cat > "$dir/print_check.awk" <<'EOF_AWK'
function g(n) { return (n in H) ? F[H[n]] : "" }
function dash(v) { return (v == "") ? "-" : v }
FNR == 1 {
  n = csvsplit($0, F); for (i = 1; i <= n; i++) H[F[i]] = i
  printf "%-24s %-15s %-9s %-6s %-9s %6s %7s %5s %6s %6s  %s\n", "DATASOURCE", "TYPE", "STATUS", "STATS", "MIN/MAX", "IN_USE", "ACTIVE", "IDLE", "AVAIL", "QUEUED", "JNDI"
  next
}
{
  csvsplit($0, F)
  printf "%-24s %-15s %-9s %-6s %-9s %6s %7s %5s %6s %6s  %s\n", g("ds_name"), g("ds_type"), g("status"), dash(g("stats_enabled")), g("min_pool_size") "/" g("max_pool_size"), dash(g("in_use_count")), dash(g("active_count")), dash(g("idle_count")), dash(g("available_count")), dash(g("queued_threads")), g("jndi_name")
  if (g("status") == "STATS_OFF") off++
}
END { if (off > 0) print "OFF=" off }
EOF_AWK
}

awk_run() { awk -f "$AWK_DIR/common.awk" "$@"; }

#------------------------------------------------------------------------------
# jboss-cli 実行（persistent: FIFO による常駐セッション / oneshot: 毎回起動）
#------------------------------------------------------------------------------
cli_exec_env() {
  unset JAVA_TOOL_OPTIONS _JAVA_OPTIONS JDK_JAVA_OPTIONS
  export JAVA_OPTS="$CLI_JAVA_OPTS" JAVA="$CLI_JAVA" JBOSS_HOME
}

close_cli_fds() {
  if [[ -n $CLI_WFD ]]; then exec {CLI_WFD}>&-; fi
  if [[ -n $CLI_RFD ]]; then exec {CLI_RFD}<&-; fi
}

kill_tree() {
  local pid=$1 d s kids=()
  for d in /proc/[0-9]*; do
    read -r s 2>/dev/null < "$d/stat" || continue
    s=${s##*) }
    set -- $s
    [[ ${2:-} == "$pid" ]] && kids+=("${d#/proc/}")
  done
  kill -TERM "$pid" "${kids[@]}" 2>/dev/null
  sleep 1
  kill -KILL "$pid" "${kids[@]}" 2>/dev/null
  return 0
}

cli_p_alive() { [[ -n $CLI_PID ]] && kill -0 "$CLI_PID" 2>/dev/null; }

cli_p_read_until() {  # marker timeout outfile
  local marker=$1 tmo=$2 out=$3 line="" acc="" rc ofd end
  end=$((SECONDS + tmo))
  exec {ofd}>>"$out"
  while :; do
    if IFS= read -r -t 2 line <&"$CLI_RFD"; then
      line=$acc$line; acc=""
      printf '%s\n' "$line" 1>&"$ofd"
      if [[ $line == "$marker" ]]; then exec {ofd}>&-; return 0; fi
    else
      rc=$?
      acc=$acc$line
      if (( rc <= 128 )) || ! cli_p_alive; then exec {ofd}>&-; return 1; fi
      if (( SECONDS >= end )); then exec {ofd}>&-; return 2; fi
    fi
  done
}

cli_p_stop() {
  local i
  if [[ -n $CLI_WFD ]]; then
    printf 'quit\n' 1>&"$CLI_WFD" 2>/dev/null
    exec {CLI_WFD}>&-
    CLI_WFD=""
  fi
  if [[ -n $CLI_PID ]]; then
    for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$CLI_PID" 2>/dev/null || break; sleep 0.3; done
    kill -0 "$CLI_PID" 2>/dev/null && kill_tree "$CLI_PID"
    wait "$CLI_PID" 2>/dev/null
    CLI_PID=""
  fi
  if [[ -n $CLI_RFD ]]; then exec {CLI_RFD}<&-; CLI_RFD=""; fi
  [[ -n $WORK_DIR ]] && rm -f "$WORK_DIR/cli.in" "$WORK_DIR/cli.out" 2>/dev/null
  return 0
}

cli_p_start() {
  local fin="$WORK_DIR/cli.in" fout="$WORK_DIR/cli.out"
  cli_p_stop
  rm -f "$fin" "$fout"
  mkfifo -m 600 "$fin" "$fout" || { err "FIFO を作成できません: $WORK_DIR"; return 1; }
  ( trap '' INT HUP; cli_exec_env; exec "$JBOSS_CLI" "${CLI_ARGS[@]}" "--file=$fin" ) >"$fout" 2>>"$CLI_ERR_LOG" </dev/null &
  CLI_PID=$!
  exec {CLI_WFD}<>"$fin"
  exec {CLI_RFD}<>"$fout"
  printf 'echo DSPOOL_READY\n' 1>&"$CLI_WFD"
  if cli_p_read_until "DSPOOL_READY" "$CLI_CONNECT_TIMEOUT" /dev/null; then
    info "jboss-cli 常駐セッションを開始しました (pid=$CLI_PID)"
    return 0
  fi
  err "jboss-cli の常駐セッションを開始できません（詳細: $CLI_ERR_LOG）"
  cli_p_stop
  return 1
}

cli_p_exchange() {  # seq block out timeout
  local seq=$1 blk=$2 out=$3 tmo=$4 rc
  : > "$out"
  if ! cli_p_alive; then cli_p_start || return 1; fi
  { printf 'echo DSPOOL_S %s\n' "$seq"; cat "$blk"; printf 'echo DSPOOL_E %s\n' "$seq"; } 1>&"$CLI_WFD" 2>/dev/null || { cli_p_stop; return 1; }
  cli_p_read_until "DSPOOL_E $seq" "$tmo" "$out"; rc=$?
  if (( rc != 0 )); then
    warn "jboss-cli の応答がありません（rc=$rc）。セッションを再起動します"
    cli_p_stop
  fi
  return $rc
}

cli_o_exchange() {  # seq block out timeout
  local seq=$1 blk=$2 out=$3 tmo=$4 f="$WORK_DIR/oneshot.cli" pid end
  { printf 'echo DSPOOL_S %s\n' "$seq"; cat "$blk"; printf 'echo DSPOOL_E %s\n' "$seq"; } > "$f"
  ( trap '' INT HUP; close_cli_fds; cli_exec_env; exec "$JBOSS_CLI" "${CLI_ARGS[@]}" "--file=$f" ) >"$out" 2>>"$CLI_ERR_LOG" </dev/null &
  pid=$!
  end=$((SECONDS + tmo + CLI_CONNECT_TIMEOUT))
  while kill -0 "$pid" 2>/dev/null; do
    if (( SECONDS >= end )); then warn "jboss-cli がタイムアウトしました"; kill_tree "$pid"; break; fi
    sleep 0.2
  done
  wait "$pid" 2>/dev/null
  grep -qx "DSPOOL_E $seq" "$out"
}

cli_exchange() {  # seq block out timeout
  if [[ $CLI_MODE == persistent ]]; then
    if cli_p_exchange "$@"; then return 0; fi
    return 1
  fi
  cli_o_exchange "$@"
}

q_block() {  # id operation
  printf 'echo DSPOOL_B %s\ntry\n%s\ncatch\necho DSPOOL_F %s\nend-try\n' "$1" "$2" "$1"
}

cli_quote() {
  local s=$1
  if [[ $s =~ ^[A-Za-z0-9_.-]+$ ]]; then
    printf '%s' "$s"
  else
    s=${s//\\/\\\\}; s=${s//\"/\\\"}
    printf '"%s"' "$s"
  fi
}

ds_selected() {
  local n=$1 x
  [[ -z $DS_FILTER ]] && return 0
  IFS=',' read -r -a _sel <<< "$DS_FILTER"
  for x in "${_sel[@]}"; do [[ ${x// /} == "$n" ]] && return 0; done
  return 1
}

build_init_block() {
  local f=$1 t s
  {
    q_block "m.server.product-name" ":read-attribute(name=product-name)"
    q_block "m.server.product-version" ":read-attribute(name=product-version)"
    q_block "m.server.release-version" ":read-attribute(name=release-version)"
    q_block "m.server.server-name" ":read-attribute(name=name)"
    q_block "m.server.server-state" ":read-attribute(name=server-state)"
    q_block "m.server.running-mode" ":read-attribute(name=running-mode)"
    q_block "m.server.suspend-state" ":read-attribute(name=suspend-state)"
    q_block "m.server.node-name" "/core-service=server-environment:read-attribute(name=node-name)"
    q_block "m.server.host-name" "/core-service=server-environment:read-attribute(name=host-name)"
    q_block "m.server.config-file" "/core-service=server-environment:read-attribute(name=config-file)"
    q_block "m.jvm.vm-name" "/core-service=platform-mbean/type=runtime:read-attribute(name=vm-name)"
    q_block "m.jvm.vm-vendor" "/core-service=platform-mbean/type=runtime:read-attribute(name=vm-vendor)"
    q_block "m.jvm.vm-version" "/core-service=platform-mbean/type=runtime:read-attribute(name=vm-version)"
    q_block "m.jvm.spec-version" "/core-service=platform-mbean/type=runtime:read-attribute(name=spec-version)"
    q_block "m.jvm.start-time" "/core-service=platform-mbean/type=runtime:read-attribute(name=start-time)"
    q_block "m.jvm.uptime-ms" "/core-service=platform-mbean/type=runtime:read-attribute(name=uptime)"
    q_block "m.jvm.available-processors" "/core-service=platform-mbean/type=operating-system:read-attribute(name=available-processors)"
    q_block "m.jvm.os-name" "/core-service=platform-mbean/type=operating-system:read-attribute(name=name)"
    q_block "m.jvm.heap" "/core-service=platform-mbean/type=memory:read-attribute(name=heap-memory-usage)"
    for t in data-source xa-data-source; do
      if [[ $t == data-source ]]; then s=ds; else s=xa; fi
      q_block "cfg.$s" "/subsystem=datasources/$t=*:read-resource(include-runtime=true,resolve-expressions=true)"
      q_block "pool.$s" "/subsystem=datasources/$t=*/statistics=pool:read-resource(include-runtime=true)"
    done
    q_block "cprop.ds" "/subsystem=datasources/data-source=*/connection-properties=*:read-resource(resolve-expressions=true)"
    q_block "cprop.xa" "/subsystem=datasources/xa-data-source=*/xa-datasource-properties=*:read-resource(resolve-expressions=true)"
    q_block "drv" "/subsystem=datasources/jdbc-driver=*:read-resource(include-runtime=true)"
    q_block "ccm" "/subsystem=jca/cached-connection-manager=cached-connection-manager:read-resource(include-runtime=true)"
  } > "$f"
}

build_sample_block() {
  local f="$WORK_DIR/sample.cli" t s i type name
  {
    for t in data-source xa-data-source; do
      if [[ $t == data-source ]]; then s=ds; else s=xa; fi
      q_block "cfg.$s" "/subsystem=datasources/$t=*:read-resource(include-runtime=true,resolve-expressions=true)"
      q_block "pool.$s" "/subsystem=datasources/$t=*/statistics=pool:read-resource(include-runtime=true)"
      q_block "jdbc.$s" "/subsystem=datasources/$t=*/statistics=jdbc:read-resource(include-runtime=true)"
    done
    if (( DO_QUEUED )) && [[ -s $DSLIST_FILE ]]; then
      while IFS=$'\t' read -r i type name; do
        [[ -n $name ]] || continue
        ds_selected "$name" || continue
        q_block "q.$i" "/subsystem=datasources/$type=$(cli_quote "$name"):dump-queued-threads-in-pool"
      done < "$DSLIST_FILE"
    fi
    if (( DO_CONTEXT )); then
      q_block "ctx.thr" "/core-service=platform-mbean/type=threading:read-attribute(name=thread-count)"
      q_block "ctx.pthr" "/core-service=platform-mbean/type=threading:read-attribute(name=peak-thread-count)"
      q_block "ctx.dthr" "/core-service=platform-mbean/type=threading:read-attribute(name=daemon-thread-count)"
      q_block "ctx.heap" "/core-service=platform-mbean/type=memory:read-attribute(name=heap-memory-usage)"
      q_block "ctx.io" "/subsystem=io/worker=*:read-resource(include-runtime=true)"
      q_block "ctx.txi" "/subsystem=transactions:read-attribute(name=number-of-inflight-transactions)"
      q_block "ctx.txt" "/subsystem=transactions:read-attribute(name=number-of-timed-out-transactions)"
    fi
  } > "$f"
}

#------------------------------------------------------------------------------
# メタ情報・初期スナップショット
#------------------------------------------------------------------------------
meta_add() { printf '%s,%s,%s\n' "$(csvq_sh "$1")" "$(csvq_sh "$2")" "$(csvq_sh "$3")" >> "$RUN_DIR/$F_META"; }

meta_get() {  # dir category key
  [[ -f $1/$F_META ]] || return 1
  awk -F, -v c="$2" -v k="$3" '$1 == c && $2 == k { v = $3 } END { gsub(/"/, "", v); if (v != "") print v }' "$1/$F_META"
}

json_str() {
  printf '%s' "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n 1 | sed 's/.*:[[:space:]]*"\(.*\)"$/\1/'
}

ecs_meta() {
  local uri=${ECS_CONTAINER_METADATA_URI_V4:-${ECS_CONTAINER_METADATA_URI:-}} task cont k v
  [[ -n $uri ]] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  task=$(curl -fsS --max-time 3 "$uri/task" 2>/dev/null) || task=""
  cont=$(curl -fsS --max-time 3 "$uri" 2>/dev/null) || cont=""
  for k in Cluster TaskARN Family Revision AvailabilityZone LaunchType; do
    v=$(json_str "$task" "$k"); [[ -n $v ]] && meta_add ecs "$k" "$v"
  done
  v=$(json_str "$cont" Name); [[ -n $v ]] && meta_add ecs ContainerName "$v"
  v=$(json_str "$cont" Image); [[ -n $v ]] && meta_add ecs Image "$v"
  return 0
}

write_collector_meta() {
  local a args="" masknext=0 skipnext=0
  for a in "${ORIG_ARGS[@]}"; do
    if (( skipnext )); then skipnext=0; continue; fi
    if (( masknext )); then args+=" ********"; masknext=0; continue; fi
    case $a in
      --password) args+=" $a"; masknext=1 ;;
      --password=*) args+=" --password=********" ;;
      --_run-dir) skipnext=1 ;;
      --_daemon|--_run-dir=*|--background) ;;
      *) args+=" $a" ;;
    esac
  done
  meta_add collector version "$SCRIPT_VERSION"
  meta_add collector start_time "$(now_str)"
  meta_add collector utc_offset "$(date +%z)"
  meta_add collector tz "${TZ:-(container default)}"
  meta_add collector interval_sec "$INTERVAL"
  meta_add collector warn_pct "$WARN_PCT"
  meta_add collector bucket_min "$BUCKET_MIN"
  meta_add collector cli_mode "$CLI_MODE"
  meta_add collector ds_filter "$DS_FILTER"
  meta_add collector args "${args# }"
  meta_add collector host "$HOST_LABEL"
  meta_add collector run_dir "$RUN_DIR"
  meta_add server jboss_home "$JBOSS_HOME"
  meta_add server server_pid "${SERVER_PID:-unknown}"
  meta_add server cli_java "$CLI_JAVA"
  meta_add server controller "${CONTROLLER:-default (localhost:9990)}"
  ecs_meta
}

snapshot_init() {  # 1: first time (meta も記録)
  local first=$1 seq raw="$WORK_DIR/init.raw"
  SEQ=$((SEQ + 1)); seq=$SEQ
  build_init_block "$WORK_DIR/init.cli"
  cli_exchange "$seq" "$WORK_DIR/init.cli" "$raw" $((CLI_CMD_TIMEOUT * 2)) || return 1
  awk_run -f "$AWK_DIR/init.awk" -v seq="$seq" -v off="$(date +%z)" \
    -v meta_out="$WORK_DIR/meta_server.csv" -v cfg_out="$WORK_DIR/config.csv" -v dslist_out="$WORK_DIR/dslist.init" \
    "$raw" || return 1
  (( first )) && cat "$WORK_DIR/meta_server.csv" >> "$RUN_DIR/$F_META"
  mv -f "$WORK_DIR/config.csv" "$RUN_DIR/$F_CONFIG"
  mv -f "$WORK_DIR/dslist.init" "$DSLIST_FILE"
  return 0
}

stats_admin() {  # enable / clear  [reapply]
  local what=$1 again=${2:-} f="$WORK_DIR/admin.cli" seq i type name addr
  [[ -s $DSLIST_FILE ]] || return 0
  {
    while IFS=$'\t' read -r i type name; do
      [[ -n $name ]] || continue
      ds_selected "$name" || continue
      addr="/subsystem=datasources/$type=$(cli_quote "$name")"
      if [[ $what == enable ]]; then
        q_block "en.$i.pool" "$addr/statistics=pool:write-attribute(name=statistics-enabled,value=true)"
        q_block "en.$i.jdbc" "$addr/statistics=jdbc:write-attribute(name=statistics-enabled,value=true)"
      else
        q_block "cl.$i.pool" "$addr/statistics=pool:clear-statistics"
        q_block "cl.$i.jdbc" "$addr/statistics=jdbc:clear-statistics"
      fi
    done < "$DSLIST_FILE"
  } > "$f"
  SEQ=$((SEQ + 1)); seq=$SEQ
  if cli_exchange "$seq" "$f" "$WORK_DIR/admin.raw" "$CLI_CMD_TIMEOUT"; then
    if grep -q '^DSPOOL_F ' "$WORK_DIR/admin.raw"; then
      warn "一部のデータソースで統計の${what}に失敗しました: $(grep '^DSPOOL_F ' "$WORK_DIR/admin.raw" | tr '\n' ' ')"
    fi
    if [[ $what == enable && -n $again ]]; then
      info "統計を再度有効化しました"
    elif [[ $what == enable ]]; then
      info "統計を実行時に有効化しました（設定ファイルは変更していません。再起動で元に戻ります）"
      meta_add collector enable_stats "applied"
    else
      info "プール統計をクリアしました"
      meta_add collector clear_stats "applied $(now_str)"
    fi
  else
    warn "統計の${what}を実行できませんでした"
  fi
}

#------------------------------------------------------------------------------
# サンプリング
#------------------------------------------------------------------------------
save_debug_raw() {
  mkdir -p "$RUN_DIR/debug"
  sed -E 's/("(password|recovery-password|clear-text)" => ")[^"]*"/\1********"/' "$1" > "$RUN_DIR/debug/raw_$(printf '%06d' "$2").txt"
}

take_sample() {
  local seq stamp ts epoch off tsc t0 t1 ok=0 raw="$WORK_DIR/raw.txt" res="$WORK_DIR/result.txt" line exh=0 soff=0
  SEQ=$((SEQ + 1)); seq=$SEQ
  stamp=$(date '+%Y-%m-%d_%H:%M:%S %s %z %Y%m%d_%H%M%S')
  read -r ts epoch off tsc <<< "$stamp"
  ts=${ts/_/ }
  t0=$(date +%s%N)
  if cli_exchange "$seq" "$WORK_DIR/sample.cli" "$raw" "$CLI_CMD_TIMEOUT"; then ok=1; fi
  t1=$(date +%s%N)
  (( DEBUG )) && save_debug_raw "$raw" "$seq"
  awk_run -f "$AWK_DIR/sample.awk" -v seq="$seq" -v ts="$ts" -v epoch="$epoch" -v off="$off" -v tsc="$tsc" \
    -v host="$HOST_LABEL" -v warn="$WARN_PCT" -v complete="$ok" -v cli_ms="$(( (t1 - t0) / 1000000 ))" \
    -v statefile="$WORK_DIR/state.tsv" -v dslistfile="$DSLIST_FILE" -v dslistnew="$WORK_DIR/dslist.new" \
    -v ts_csv="$RUN_DIR/$F_TS" -v ctx_csv="$RUN_DIR/$F_CTX" -v waiters_csv="$RUN_DIR/$F_WAITRAW" \
    -v qdir="$RUN_DIR/queued_threads" -v dump_queued="$DO_QUEUED" -v qmin="$QDUMP_MIN_INTERVAL" \
    -v do_ctx="$DO_CONTEXT" -v dsfilter="$DS_FILTER" \
    "$raw" > "$res" 2>>"$CLI_ERR_LOG"
  [[ -f $WORK_DIR/state.tsv.new ]] && mv -f "$WORK_DIR/state.tsv.new" "$WORK_DIR/state.tsv"
  while IFS= read -r line; do
    case $line in
      "CON "*) printf '%s\n' "${line#CON }" ;;
      EXH) exh=1 ;;
      OFF) soff=1 ;;
    esac
  done < "$res"
  (( ok )) || warn "サンプル #$seq の取得に失敗しました（ERROR として記録）"
  if (( ok )) && [[ -s $WORK_DIR/dslist.new ]]; then
    if [[ "$(< "$WORK_DIR/dslist.new")" != "$(< "$DSLIST_FILE")" ]]; then
      info "データソース構成の変化を検出しました。取得対象と設定スナップショットを更新します"
      mv -f "$WORK_DIR/dslist.new" "$DSLIST_FILE"
      snapshot_init 0 || warn "設定スナップショットの更新に失敗しました"
      build_sample_block
    fi
  fi
  # サーバーのリロード等で実行時の統計有効化が元に戻った場合は再度有効化する（60秒に1回まで）
  if (( ok && soff && ENABLE_STATS )) && (( epoch - STATS_REENABLE_LAST >= 60 )); then
    STATS_REENABLE_LAST=$epoch
    info "統計が無効のデータソースを検出しました（サーバーのリロード等）。統計を再度有効化します"
    stats_admin enable reapply
  fi
  if (( exh && DO_TDUMP )); then maybe_thread_dump "$tsc"; fi
  return 0
}

maybe_thread_dump() {
  local tsc=$1 now out raw
  now=$(date +%s)
  (( TDUMP_COUNT >= TDUMP_MAX )) && return 0
  (( now - TDUMP_LAST < TDUMP_MIN_INTERVAL )) && return 0
  if [[ -n $TDUMP_PID ]] && kill -0 "$TDUMP_PID" 2>/dev/null; then return 0; fi
  TDUMP_LAST=$now; TDUMP_COUNT=$((TDUMP_COUNT + 1))
  mkdir -p "$RUN_DIR/thread_dumps"
  out="$RUN_DIR/thread_dumps/threaddump_${tsc}.txt"
  raw="$WORK_DIR/tdump_${tsc}.raw"
  info "枯渇を検知したためスレッドダンプを取得します（$TDUMP_COUNT/$TDUMP_MAX）: $out"
  (
    trap '' INT HUP
    close_cli_fds
    cli_exec_env
    JAVA_OPTS=${JAVA_OPTS/-Xmx$CLI_HEAP/-Xmx256m}; export JAVA_OPTS
    "$JBOSS_CLI" "${CLI_ARGS[@]}" "--command=/core-service=platform-mbean/type=threading:dump-all-threads(locked-monitors=true,locked-synchronizers=true)" > "$raw" 2>>"$CLI_ERR_LOG" </dev/null
    awk -v ts="$(date '+%Y-%m-%d %H:%M:%S')" -f "$AWK_DIR/common.awk" -f "$AWK_DIR/tdump.awk" "$raw" > "$out" 2>/dev/null
    rm -f "$raw"
  ) &
  TDUMP_PID=$!
}

isleep() {
  (( $1 > 0 )) || return 0
  sleep "$1" &
  SLEEP_PID=$!
  wait "$SLEEP_PID" 2>/dev/null
  SLEEP_PID=""
}

on_stop_signal() {
  STOP_REQ=1
  [[ -n $SLEEP_PID ]] && kill "$SLEEP_PID" 2>/dev/null
}

collect_loop() {
  local now next start end_ep=0 last_report=$SECONDS
  start=$(date +%s)
  (( DURATION_SEC > 0 )) && end_ep=$((start + DURATION_SEC))
  if (( UNTIL_EPOCH > 0 )) && (( end_ep == 0 || UNTIL_EPOCH < end_ep )); then end_ep=$UNTIL_EPOCH; fi
  while :; do
    (( STOP_REQ )) && break
    now=$(date +%s)
    if (( end_ep > 0 && now >= end_ep )); then info "指定の収集時間に達しました"; break; fi
    take_sample
    SAMPLES=$((SAMPLES + 1))
    if (( MAX_COUNT > 0 && SAMPLES >= MAX_COUNT )); then info "指定の取得回数に達しました"; break; fi
    if (( SECONDS - last_report >= REPORT_EVERY )); then
      make_report "$RUN_DIR" >/dev/null 2>&1
      last_report=$SECONDS
    fi
    (( STOP_REQ )) && break
    now=$(date +%s)
    next=$(( (now / INTERVAL + 1) * INTERVAL ))
    (( end_ep > 0 && next > end_ep )) && next=$end_ep
    isleep $((next - now))
  done
}

#------------------------------------------------------------------------------
# レポート・バンドル
#------------------------------------------------------------------------------
make_report() {  # dir
  local dir=$1 ivl warnp bmin files f
  [[ -s $dir/$F_TS ]] || { warn "時系列CSVがありません: $dir/$F_TS"; return 1; }
  ivl=$(meta_get "$dir" collector interval_sec); is_uint "$ivl" || ivl=$INTERVAL
  warnp=$WARN_PCT; bmin=$BUCKET_MIN
  if (( ! WARN_SET )); then f=$(meta_get "$dir" collector warn_pct); is_uint "$f" && warnp=$f; fi
  if (( ! BUCKET_SET )); then f=$(meta_get "$dir" collector bucket_min); is_uint "$f" && bmin=$f; fi
  files=("$dir/$F_TS")
  [[ -s $dir/$F_WAITRAW ]] && files+=("$dir/$F_WAITRAW")
  awk_run -f "$AWK_DIR/report.awk" -v warn="$warnp" -v bucket=$((bmin * 60)) -v def_interval="$ivl" \
    -v out_summary="$dir/$F_SUMMARY.tmp" -v out_hourly="$dir/$F_HOURLY.tmp" \
    -v out_events="$dir/$F_EVENTS.tmp" -v out_waiters="$dir/$F_WAITERS.tmp" "${files[@]}" || return 1
  for f in "$F_SUMMARY" "$F_HOURLY" "$F_EVENTS" "$F_WAITERS"; do mv -f "$dir/$f.tmp" "$dir/$f"; done
  return 0
}

write_bundle() {  # dir
  local dir=$1 f
  printf '#DSPOOL-BUNDLE v1 %s\n' "${dir##*/}"
  for f in "$F_META" "$F_SUMMARY" "$F_HOURLY" "$F_EVENTS" "$F_WAITERS" "$F_TS" "$F_CTX" "$F_CONFIG"; do
    [[ -f $dir/$f ]] || continue
    printf '#DSPOOL-FILE %s\n' "$f"
    awk '{ print }' "$dir/$f"
  done
  if (( EXPORT_ALL )); then
    for f in "$dir"/queued_threads/*.txt "$dir"/thread_dumps/*.txt "$dir/$F_WAITRAW" "$dir/collector.log"; do
      [[ -f $f ]] || continue
      printf '#DSPOOL-FILE %s\n' "${f#"$dir"/}"
      awk '{ print }' "$f"
    done
  fi
  printf '#DSPOOL-END\n'
}

print_summary() {
  [[ -s $1/$F_SUMMARY ]] || return 0
  awk_run -f "$AWK_DIR/print_summary.awk" "$1/$F_SUMMARY"
}

latest_run_dir() {
  local d pf="$BASE_DIR/collector.pid" pid rdir
  if [[ -f $pf ]]; then read -r pid rdir < "$pf"; [[ -n $rdir && -d $rdir ]] && { printf '%s' "$rdir"; return 0; }; fi
  d=$(ls -1dt "$BASE_DIR"/dspool_* 2>/dev/null | head -n 1)
  [[ -n $d ]] && printf '%s' "$d"
}

#------------------------------------------------------------------------------
# 各モード
#------------------------------------------------------------------------------
cleanup() {
  [[ -n $TDUMP_PID ]] && wait "$TDUMP_PID" 2>/dev/null
  cli_p_stop
  if [[ -n $WORK_DIR && -d $WORK_DIR ]]; then
    case $WORK_DIR in */dspool_work.*|*/.work) rm -rf "$WORK_DIR" ;; esac
  fi
  if (( OWN_PID_FILE )) && [[ -f $PID_FILE ]]; then
    local pid; read -r pid _ < "$PID_FILE"
    [[ $pid == "$$" ]] && rm -f "$PID_FILE"
  fi
}

make_work_dir() {
  WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/dspool_work.XXXXXX" 2>/dev/null) || WORK_DIR=""
  if [[ -z $WORK_DIR ]]; then
    WORK_DIR="${RUN_DIR:-$BASE_DIR}/.work"
    mkdir -p "$WORK_DIR" || die "作業ディレクトリを作成できません: $WORK_DIR"
  fi
  AWK_DIR="$WORK_DIR/awk"
  write_awk_files "$AWK_DIR"
  DSLIST_FILE="$WORK_DIR/dslist.tsv"
  : > "$DSLIST_FILE"
}

new_run_dir() {
  local h=${HOST_LABEL%%.*}
  h=${h//[^A-Za-z0-9_.-]/_}
  printf '%s/dspool_%s_%s' "$BASE_DIR" "${h:-host}" "$(date +%Y%m%d_%H%M%S)"
}

check_running() {
  local pid rdir
  PID_FILE="$BASE_DIR/collector.pid"
  [[ -f $PID_FILE ]] || return 0
  read -r pid rdir < "$PID_FILE"
  if [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null && grep -q ds_pool_collector "/proc/$pid/cmdline" 2>/dev/null; then
    die "既に収集が実行中です（pid=$pid, $rdir）。--status / --stop を使用してください"
  fi
  return 0
}

start_cli_and_init() {
  if [[ $CLI_MODE == persistent ]]; then
    if cli_p_start && snapshot_init 1; then return 0; fi
    warn "常駐セッションで初期情報を取得できませんでした。oneshot モードで再試行します"
    cli_p_stop
    CLI_MODE=oneshot
  fi
  snapshot_init 1 && return 0
  return 1
}

write_headers() {
  awk_run -f "$AWK_DIR/hdr.awk" -v which=ts > "$RUN_DIR/$F_TS"
  (( DO_CONTEXT )) && awk_run -f "$AWK_DIR/hdr.awk" -v which=ctx > "$RUN_DIR/$F_CTX"
  awk_run -f "$AWK_DIR/hdr.awk" -v which=wait > "$RUN_DIR/$F_WAITRAW"
  mkdir -p "$RUN_DIR/queued_threads"
}

start_daemon() {
  local self pid a args=() i
  self=$0; [[ $self == /* ]] || self="$PWD/$self"
  [[ -f $self ]] || die "バックグラウンド実行にはスクリプトをファイルとして保存してから実行してください"
  mkdir -p "$BASE_DIR" || die "出力先を作成できません: $BASE_DIR"
  check_running
  [[ -n $HOST_LABEL ]] || HOST_LABEL=$(cat /proc/sys/kernel/hostname 2>/dev/null)
  RUN_DIR=$(new_run_dir)
  mkdir -p "$RUN_DIR" || die "出力先を作成できません: $RUN_DIR"
  for a in "${ORIG_ARGS[@]}"; do [[ $a == --background ]] || args+=("$a"); done
  if command -v setsid >/dev/null 2>&1; then
    setsid nohup bash "$self" "${args[@]}" --_daemon --_run-dir "$RUN_DIR" >> "$RUN_DIR/collector.log" 2>&1 < /dev/null &
  else
    nohup bash "$self" "${args[@]}" --_daemon --_run-dir "$RUN_DIR" >> "$RUN_DIR/collector.log" 2>&1 < /dev/null &
  fi
  pid=$!
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    sleep 1
    kill -0 "$pid" 2>/dev/null || break
    [[ -s $RUN_DIR/$F_TS ]] && (( $(wc -l < "$RUN_DIR/$F_TS") > 1 )) && break
  done
  if kill -0 "$pid" 2>/dev/null; then
    local oopt=""
    [[ $BASE_DIR != /tmp/dspool ]] && oopt=" -o $BASE_DIR"
    echo "バックグラウンドで収集を開始しました (pid=$pid)"
    echo "  出力先 : $RUN_DIR"
    echo "  ログ   : $RUN_DIR/collector.log   （tail -f で進捗を確認できます）"
    echo "  状況   : $self$oopt --status"
    echo "  停止   : $self$oopt --stop"
  else
    echo "起動に失敗しました。ログを確認してください: $RUN_DIR/collector.log" >&2
    tail -n 20 "$RUN_DIR/collector.log" >&2
    exit 1
  fi
}

mode_run() {
  if (( BACKGROUND && ! IS_DAEMON )); then start_daemon; return; fi
  mkdir -p "$BASE_DIR" || die "出力先を作成できません: $BASE_DIR"
  check_running
  [[ -n $HOST_LABEL ]] || HOST_LABEL=$(cat /proc/sys/kernel/hostname 2>/dev/null)
  [[ -n $RUN_DIR ]] || RUN_DIR=$(new_run_dir)
  mkdir -p "$RUN_DIR" || die "出力先を作成できません: $RUN_DIR"
  [[ -w $RUN_DIR ]] || die "出力先に書き込めません: $RUN_DIR（-o で書き込み可能なディレクトリを指定してください）"
  if (( IS_DAEMON )); then LOG_FILE=""; trap '' HUP; else LOG_FILE="$RUN_DIR/collector.log"; fi
  CLI_ERR_LOG="$RUN_DIR/jboss-cli.err"
  printf '%s %s\n' "$$" "$RUN_DIR" > "$PID_FILE"
  OWN_PID_FILE=1
  trap cleanup EXIT
  trap on_stop_signal TERM INT
  info "ds_pool_collector.sh $SCRIPT_VERSION を開始します（間隔 ${INTERVAL}秒, CLIモード $CLI_MODE）"
  detect_env
  info "JBOSS_HOME=$JBOSS_HOME  jboss-cli=$JBOSS_CLI  java=$CLI_JAVA  サーバーPID=${SERVER_PID:-不明}  controller=${CONTROLLER:-既定}"
  make_work_dir
  awk_run -f "$AWK_DIR/hdr.awk" -v which=meta > "$RUN_DIR/$F_META"
  write_collector_meta
  start_cli_and_init || die "jboss-cli で管理インターフェースに接続できません。$CLI_ERR_LOG を確認してください（認証が必要な場合は --user/--password）"
  info "データソース: $(awk -F'\t' '{ printf "%s%s(%s)", (NR > 1 ? ", " : ""), $3, $2 }' "$DSLIST_FILE")"
  [[ -s $DSLIST_FILE ]] || warn "データソースが見つかりません（収集は継続します）"
  (( ENABLE_STATS )) && stats_admin enable
  (( CLEAR_STATS )) && stats_admin clear
  build_sample_block
  write_headers
  info "出力先: $RUN_DIR"
  if (( ! IS_DAEMON )); then info "Ctrl+C で停止します（長時間の収集は --background を推奨）"; fi
  collect_loop
  [[ -n $TDUMP_PID ]] && wait "$TDUMP_PID" 2>/dev/null
  cli_p_stop
  meta_add collector end_time "$(now_str)"
  meta_add collector samples "$SAMPLES"
  info "最終レポートを作成しています..."
  make_report "$RUN_DIR"
  write_bundle "$RUN_DIR" > "$RUN_DIR/$F_BUNDLE"
  if command -v tar >/dev/null 2>&1 && command -v gzip >/dev/null 2>&1; then
    tar -czf "$RUN_DIR.tar.gz" -C "$(dirname "$RUN_DIR")" "$(basename "$RUN_DIR")" 2>/dev/null && info "アーカイブ: $RUN_DIR.tar.gz"
  fi
  print_summary "$RUN_DIR"
  info "完了しました（サンプル数 $SAMPLES）: $RUN_DIR"
  info "Excel 変換の入力: $RUN_DIR/$F_BUNDLE （または $RUN_DIR ディレクトリ）"
}

mode_check() {
  local rc
  detect_env
  make_work_dir
  RUN_DIR="$WORK_DIR/check"; mkdir -p "$RUN_DIR"
  CLI_ERR_LOG="$WORK_DIR/jboss-cli.err"
  trap cleanup EXIT
  echo "=== ds_pool_collector.sh $SCRIPT_VERSION 環境チェック ==="
  echo "JBOSS_HOME    : $JBOSS_HOME"
  echo "jboss-cli     : $JBOSS_CLI"
  echo "java(CLI用)   : $CLI_JAVA"
  echo "サーバーPID   : ${SERVER_PID:-検出できません（コンテナ外または権限不足）}"
  echo "controller    : ${CONTROLLER:-既定（localhost:9990）}"
  echo "CLI モード    : $CLI_MODE"
  echo "出力先(既定)  : $BASE_DIR"
  awk_run -f "$AWK_DIR/hdr.awk" -v which=meta > "$RUN_DIR/$F_META"
  if ! start_cli_and_init; then
    echo "jboss-cli で接続できませんでした。エラー出力:" >&2
    tail -n 20 "$CLI_ERR_LOG" >&2
    exit 1
  fi
  awk -F, 'NR > 1 && $1 == "server" && ($2 == "product-name" || $2 == "product-version" || $2 == "server-state") { gsub(/"/, "", $3); printf "%-14s: %s\n", $2, $3 }' "$RUN_DIR/$F_META"
  build_sample_block
  write_headers
  take_sample > /dev/null
  echo ""
  echo "--- データソース（現在値）---"
  awk_run -f "$AWK_DIR/print_check.awk" "$RUN_DIR/$F_TS" > "$WORK_DIR/check.txt"
  grep -v '^OFF=' "$WORK_DIR/check.txt"
  rc=$(grep -c '^OFF=' "$WORK_DIR/check.txt")
  if (( rc > 0 )); then
    echo ""
    echo "※ プール統計が無効（STATS_OFF）のデータソースがあります。"
    echo "   --enable-stats を付けて収集すると、実行時に統計を有効化します（設定ファイルは変更しません）。"
  fi
  echo ""
  echo "接続確認 OK。収集例: $0 -i 10 -d 24h --background"
}

mode_status() {
  local pf="$BASE_DIR/collector.pid" pid="" rdir="" dir n
  if [[ -f $pf ]]; then read -r pid rdir < "$pf"; fi
  if [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null; then
    echo "状態     : 実行中 (pid=$pid)"
  else
    echo "状態     : 停止中"
  fi
  dir=${TARGET_DIR:-$(latest_run_dir)}
  [[ -n $dir && -d $dir ]] || { echo "収集結果が見つかりません（$BASE_DIR）"; return 0; }
  echo "出力先   : $dir"
  if [[ -f $dir/$F_TS ]]; then
    n=$(( $(wc -l < "$dir/$F_TS") - 1 ))
    echo "記録行数 : $n 行（サンプル×データソース）"
    echo "--- 最新サンプル ---"
    awk -F, 'NR == 1 { next } { last = $1 } END { print "時刻: " last }' "$dir/$F_TS"
    tail -n 50 "$dir/$F_TS" | awk -F, -v l="$(tail -n 1 "$dir/$F_TS" | cut -d, -f1)" '$1 == l { printf "  %-22s %-9s in_use %s/%s (%s%%) idle %s avail %s queued %s\n", $2, $3, $4, $8, $9, $6, $7, $11 }'
  fi
  if [[ -f $dir/collector.log ]]; then
    echo "--- ログ（末尾）---"
    grep -v '^[0-9][0-9]:[0-9][0-9]:[0-9][0-9] ' "$dir/collector.log" | tail -n 5
  fi
}

mode_stop() {
  local pf="$BASE_DIR/collector.pid" pid rdir i
  [[ -f $pf ]] || die "実行中の収集が見つかりません（$pf がありません）"
  read -r pid rdir < "$pf"
  if [[ -z $pid ]] || ! kill -0 "$pid" 2>/dev/null; then
    warn "プロセス ${pid:-?} は存在しません（PIDファイルを削除します）"
    rm -f "$pf"
    return 0
  fi
  kill -TERM "$pid"
  echo "停止要求を送信しました (pid=$pid)。最終レポートの作成を待っています..."
  for ((i = 0; i < 180; i++)); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  if kill -0 "$pid" 2>/dev/null; then
    echo "まだ終了していません。しばらくしてから --status で確認してください"
  else
    echo "停止しました。出力先: $rdir"
    ls -l "$rdir" 2>/dev/null
  fi
}

mode_report() {
  local dir=$TARGET_DIR
  [[ -d $dir ]] || die "ディレクトリがありません: $dir"
  make_work_dir
  trap cleanup EXIT
  make_report "$dir" || die "レポートを作成できませんでした"
  write_bundle "$dir" > "$dir/$F_BUNDLE"
  print_summary "$dir"
  echo "再作成しました: $dir/$F_SUMMARY, $F_HOURLY, $F_EVENTS, $F_WAITERS, $F_BUNDLE"
}

mode_export() {
  local dir=${TARGET_DIR:-$(latest_run_dir)}
  [[ -n $dir && -d $dir ]] || die "収集結果のディレクトリが見つかりません"
  make_work_dir
  trap cleanup EXIT
  [[ -s $dir/$F_TS ]] && make_report "$dir" >/dev/null 2>&1
  if (( EXPORT_GZ )) && command -v gzip >/dev/null 2>&1 && command -v base64 >/dev/null 2>&1; then
    printf '#DSPOOL-BUNDLE-GZB64 v1 %s\n' "${dir##*/}"
    write_bundle "$dir" | gzip -c | base64 -w 76
    printf '#DSPOOL-END-GZB64\n'
  else
    (( EXPORT_GZ )) && warn "gzip/base64 が無いため非圧縮で出力します"
    write_bundle "$dir"
  fi
}

#------------------------------------------------------------------------------
# main
#------------------------------------------------------------------------------
main() {
  parse_args "$@"
  validate_args
  setup_tz
  check_deps
  PID_FILE="$BASE_DIR/collector.pid"
  case $MODE in
    run) mode_run ;;
    check) mode_check ;;
    status) mode_status ;;
    stop) mode_stop ;;
    report) mode_report ;;
    export) mode_export ;;
  esac
}

main "$@"
