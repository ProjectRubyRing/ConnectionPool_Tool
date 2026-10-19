#!/bin/bash
#==============================================================================
# ds_pool_csv2xlsx.sh  v1.0.0
#
#   ds_pool_collector.sh が出力した CSV を Excel レポート (.xlsx) に変換します（RHEL 9.x 用）
#
#   ・フォント Meiryo UI、モノトーン（黒・グレー）配色
#   ・日時/数値/割合/時間の表示形式、列幅、ウィンドウ枠の固定、オートフィルター、
#     判定に応じた濃淡（条件付き書式）、詳細列のグループ化、印刷設定（A4 横・見出し行の繰り返し）
#   ・グラフ: 接続数の推移 / 時間別 最大・平均・最小 / 時間別 待ち・取得失敗 / ワーカースレッド
#   ・追加パッケージ不要: bash + gawk で XML を生成し、zip → python3 → gzip の順に
#     使えるもので xlsx(zip) を作成します（RHEL 9 標準構成で動作）
#
#   使い方:
#     ./ds_pool_csv2xlsx.sh -i <入力> [-o <出力.xlsx>]
#       入力: 収集結果ディレクトリ / ds_pool_bundle.txt / --export・--export-gz の出力
#             / ds_pool_timeseries.csv（同じディレクトリの他の CSV も使用）
#==============================================================================

VERSION="1.0.0"
export LC_ALL=C
set -o pipefail

INPUT=""
OUTPUT=""
TITLE="データソース接続プール 使用状況レポート"
MAX_ROWS=1000000
ZIP_METHOD="auto"
KEEP_WORK=0
WORK=""

usage() {
  cat <<'USAGE'
使い方: ds_pool_csv2xlsx.sh -i <入力> [-o <出力.xlsx>] [オプション]

  -i, --input PATH     入力（次のいずれか）
                         ・収集結果ディレクトリ（ds_pool_*.csv を含む）
                         ・ds_pool_bundle.txt（収集終了時に作成されるバンドル）
                         ・ds_pool_collector.sh --export / --export-gz の出力を保存したファイル
                           （ECS Exec のログ等、前後に余計な行があっても可）
                         ・ds_pool_timeseries.csv（同じディレクトリの他の CSV も使用）
  -o, --output FILE    出力する .xlsx（既定: <入力名>.xlsx をカレントディレクトリに作成）
      --title TEXT     レポートのタイトル
      --max-rows N     時系列シートの最大行数（既定: 1000000）
      --zip METHOD     auto | zip | python | shell（xlsx の圧縮方法。既定: auto）
      --keep-work      作業ディレクトリを削除しない（調査用）
  -h, --help           このヘルプ
USAGE
}

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[$(date '+%H:%M:%S')] $*" >&2; }

while (( $# > 0 )); do
  case $1 in
    -i|--input) INPUT=${2-}; shift ;;
    -o|--output) OUTPUT=${2-}; shift ;;
    --title) TITLE=${2-}; shift ;;
    --max-rows) MAX_ROWS=${2-}; shift ;;
    --zip) ZIP_METHOD=${2-}; shift ;;
    --keep-work) KEEP_WORK=1 ;;
    -h|--help) usage; exit 0 ;;
    --input=*) INPUT=${1#*=} ;;
    --output=*) OUTPUT=${1#*=} ;;
    --title=*) TITLE=${1#*=} ;;
    *) if [[ -z $INPUT && $1 != -* ]]; then INPUT=$1; else usage >&2; die "不明な引数です: $1"; fi ;;
  esac
  shift
done
[[ -n $INPUT ]] || { usage >&2; exit 1; }
[[ -e $INPUT ]] || die "入力が見つかりません: $INPUT"
[[ $MAX_ROWS =~ ^[0-9]+$ ]] || die "--max-rows は整数で指定してください"
case $ZIP_METHOD in auto|zip|python|shell) ;; *) die "--zip は auto | zip | python | shell を指定してください" ;; esac
command -v awk >/dev/null 2>&1 || die "awk (gawk) が必要です"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/dspool_xlsx.XXXXXX") || die "作業ディレクトリを作成できません"
cleanup() { if (( KEEP_WORK )); then info "作業ディレクトリ: $WORK"; else rm -rf "$WORK"; fi; }
trap cleanup EXIT

#------------------------------------------------------------------------------
# 入力の解決（ディレクトリ / バンドル / CSV）
#------------------------------------------------------------------------------
SRC=""
SRC_NAME=""
split_bundle() {  # bundle_text outdir
  awk -v out="$2" '
    { sub(/\r$/, "") }
    /^#DSPOOL-FILE / { if (f != "") close(f); n = substr($0, 14); gsub(/[^A-Za-z0-9._-]/, "_", n); f = out "/" n; printf "" > f; next }
    /^#DSPOOL-END/ { if (f != "") close(f); f = ""; next }
    /^#DSPOOL-BUNDLE / { next }
    f != "" { print > f }
  ' "$1"
}
resolve_input() {
  local in=$1 b64
  if [[ -d $in ]]; then
    SRC=$in
    SRC_NAME=$(basename "$(cd "$in" && pwd)")
    return
  fi
  if grep -q '^#DSPOOL-BUNDLE-GZB64' "$in" 2>/dev/null; then
    command -v base64 >/dev/null 2>&1 || die "base64 コマンドが必要です"
    command -v gzip >/dev/null 2>&1 || die "gzip コマンドが必要です"
    b64="$WORK/bundle.b64"
    awk '{ sub(/\r$/, "") } /^#DSPOOL-BUNDLE-GZB64/ { f = 1; next } /^#DSPOOL-END-GZB64/ { f = 0 } f { gsub(/[^A-Za-z0-9+\/=]/, ""); print }' "$in" > "$b64"
    base64 -d < "$b64" | gzip -dc > "$WORK/bundle.txt" || die "圧縮バンドルを展開できません: $in"
    in="$WORK/bundle.txt"
  fi
  if grep -q '^#DSPOOL-BUNDLE ' "$in" 2>/dev/null; then
    mkdir -p "$WORK/in"
    split_bundle "$in" "$WORK/in"
    SRC="$WORK/in"
    SRC_NAME=$(awk '{ sub(/\r$/, "") } /^#DSPOOL-BUNDLE / { print $3; exit }' "$in")
    [[ -n $SRC_NAME ]] || SRC_NAME=$(basename "$1")
    return
  fi
  if [[ $in == *.csv ]]; then
    SRC=$(dirname "$in")
    SRC_NAME=$(basename "$(cd "$SRC" && pwd)")
    return
  fi
  die "入力形式を判別できません: $1（ディレクトリ・バンドル・CSV のいずれかを指定してください）"
}
resolve_input "$INPUT"
[[ -f $SRC/ds_pool_timeseries.csv ]] || die "ds_pool_timeseries.csv が見つかりません（入力: $INPUT）"
for f in ds_pool_summary.csv ds_pool_hourly.csv ds_pool_events.csv; do
  [[ -f $SRC/$f ]] || info "注意: $f がありません。ds_pool_collector.sh --report-only <ディレクトリ> で作成できます"
done
SRC_NAME=${SRC_NAME//[^A-Za-z0-9._-]/_}
[[ -n $OUTPUT ]] || OUTPUT="./${SRC_NAME:-dspool_report}.xlsx"
[[ $OUTPUT == *.xlsx ]] || OUTPUT="$OUTPUT.xlsx"
OUT_DIR=$(dirname "$OUTPUT")
[[ -d $OUT_DIR ]] || die "出力先ディレクトリがありません: $OUT_DIR"
OUTPUT_ABS="$(cd "$OUT_DIR" && pwd)/$(basename "$OUTPUT")"

#------------------------------------------------------------------------------
# 共通定義（列の表示名・書式、所見テンプレート、凡例）
#   ※ Windows 版（Convert-DsPoolCsvToXlsx.ps1）と同じ内容です
#------------------------------------------------------------------------------
cat > "$WORK/defs.txt" <<'DEFS'
# table|key|表示名|分類|書式|列幅|グループ化(1=詳細列)
ts|timestamp|日時|基本|dt|20|0
ts|ds_name|データソース|基本|text|20|0
ts|status|判定|基本|status|10|0
ts|in_use_count|使用中|接続数|int|8|0
ts|active_count|アクティブ|接続数|int|9|0
ts|idle_count|アイドル|接続数|int|8|0
ts|available_count|取得可能|接続数|int|8|0
ts|max_pool_size|最大プール|接続数|int|9|0
ts|usage_pct|使用率|接続数|pct|8|0
ts|active_pct|確保率|接続数|pct|8|0
ts|queued_threads|待機スレッド|枯渇・待ち|int|9|0
ts|d_wait_count|待ち発生(区間)|枯渇・待ち|int|10|0
ts|d_blocking_failure_count|取得失敗(区間)|枯渇・待ち|int|10|0
ts|max_used_count|最大使用数(累計)|枯渇・待ち|int|10|0
ts|max_wait_count|最大同時待ち(累計)|枯渇・待ち|int|11|0
ts|status_detail|判定詳細|枯渇・待ち|text|26|0
ts|min_pool_size|最小プール|設定|int|8|1
ts|blocking_timeout_ms|取得タイムアウト(ms)|設定|int|11|1
ts|jndi_name|JNDI名|設定|text|34|1
ts|ds_type|種別|設定|text|13|1
ts|ds_enabled|DS|設定|bool|6|1
ts|stats_enabled|統計|設定|bool|6|1
ts|interval_sec|間隔(秒)|区間差分|int|7|1
ts|d_created_count|作成|区間差分|int|7|1
ts|d_destroyed_count|破棄|区間差分|int|7|1
ts|d_timed_out|アイドル破棄|区間差分|int|8|1
ts|d_total_get_time_ms|取得時間計(ms)|区間差分|int|10|1
ts|d_total_blocking_time_ms|ブロック時間計(ms)|区間差分|int|11|1
ts|wait_count|待ち発生|累計カウンタ|int|9|1
ts|blocking_failure_count|取得失敗|累計カウンタ|int|9|1
ts|created_count|作成|累計カウンタ|int|9|1
ts|destroyed_count|破棄|累計カウンタ|int|9|1
ts|timed_out|アイドル破棄|累計カウンタ|int|9|1
ts|avg_get_time_ms|取得 平均|時間(ms)|int|8|1
ts|max_get_time_ms|取得 最大|時間(ms)|int|8|1
ts|total_get_time_ms|取得 合計|時間(ms)|int|11|1
ts|avg_usage_time_ms|使用 平均|時間(ms)|int|8|1
ts|max_usage_time_ms|使用 最大|時間(ms)|int|9|1
ts|total_usage_time_ms|使用 合計|時間(ms)|int|11|1
ts|avg_blocking_time_ms|ブロック 平均|時間(ms)|int|9|1
ts|max_wait_time_ms|待ち 最大|時間(ms)|int|8|1
ts|total_blocking_time_ms|ブロック 合計|時間(ms)|int|11|1
ts|avg_creation_time_ms|作成 平均|時間(ms)|int|8|1
ts|max_creation_time_ms|作成 最大|時間(ms)|int|8|1
ts|total_creation_time_ms|作成 合計|時間(ms)|int|10|1
ts|avg_pool_time_ms|プール滞在 平均|時間(ms)|int|10|1
ts|max_pool_time_ms|プール滞在 最大|時間(ms)|int|10|1
ts|total_pool_time_ms|プール滞在 合計|時間(ms)|int|12|1
ts|jdbc_stats_enabled|統計|JDBC 文キャッシュ|bool|6|1
ts|ps_cache_access|参照|JDBC 文キャッシュ|int|8|1
ts|ps_cache_hit|ヒット|JDBC 文キャッシュ|int|8|1
ts|ps_cache_miss|ミス|JDBC 文キャッシュ|int|8|1
ts|ps_cache_hit_pct|ヒット率|JDBC 文キャッシュ|pct|8|1
ts|ps_cache_add|追加|JDBC 文キャッシュ|int|8|1
ts|ps_cache_delete|削除|JDBC 文キャッシュ|int|8|1
ts|ps_cache_size|現在数|JDBC 文キャッシュ|int|8|1
ts|xa_commit_count|commit 回数|XA|int|9|1
ts|xa_commit_avg_ms|commit 平均ms|XA|int|9|1
ts|xa_commit_max_ms|commit 最大ms|XA|int|9|1
ts|xa_commit_total_ms|commit 合計ms|XA|int|10|1
ts|xa_prepare_count|prepare 回数|XA|int|9|1
ts|xa_prepare_avg_ms|prepare 平均ms|XA|int|9|1
ts|xa_prepare_max_ms|prepare 最大ms|XA|int|9|1
ts|xa_prepare_total_ms|prepare 合計ms|XA|int|10|1
ts|xa_rollback_count|rollback 回数|XA|int|9|1
ts|xa_rollback_avg_ms|rollback 平均ms|XA|int|9|1
ts|xa_rollback_max_ms|rollback 最大ms|XA|int|9|1
ts|xa_rollback_total_ms|rollback 合計ms|XA|int|10|1
ts|xa_start_count|start 回数|XA|int|9|1
ts|xa_start_avg_ms|start 平均ms|XA|int|9|1
ts|xa_start_max_ms|start 最大ms|XA|int|9|1
ts|xa_start_total_ms|start 合計ms|XA|int|10|1
ts|xa_end_count|end 回数|XA|int|9|1
ts|xa_end_avg_ms|end 平均ms|XA|int|9|1
ts|xa_end_max_ms|end 最大ms|XA|int|9|1
ts|xa_end_total_ms|end 合計ms|XA|int|10|1
ts|xa_recover_count|recover 回数|XA|int|9|1
ts|xa_recover_avg_ms|recover 平均ms|XA|int|9|1
ts|xa_recover_max_ms|recover 最大ms|XA|int|9|1
ts|xa_recover_total_ms|recover 合計ms|XA|int|10|1
ts|xa_forget_count|forget 回数|XA|int|9|1
ts|xa_forget_avg_ms|forget 平均ms|XA|int|9|1
ts|xa_forget_max_ms|forget 最大ms|XA|int|9|1
ts|xa_forget_total_ms|forget 合計ms|XA|int|10|1
ts|epoch|UNIX時刻|その他|num|11|1
ts|utc_offset|UTC差|その他|text|7|1
ts|host|ホスト|その他|text|24|1
hourly|ds_name|データソース|基本|text|20|0
hourly|bucket_start|開始|基本|dtm|17|0
hourly|bucket_end|終了|基本|dtm|17|0
hourly|samples|サンプル|基本|int|8|0
hourly|valid_samples|有効|基本|int|6|0
hourly|worst_status|最悪判定|基本|status|10|0
hourly|in_use_min|最小|使用中|int|7|0
hourly|in_use_avg|平均|使用中|dec1|7|0
hourly|in_use_max|最大|使用中|int|7|0
hourly|active_min|最小|アクティブ|int|7|0
hourly|active_avg|平均|アクティブ|dec1|7|0
hourly|active_max|最大|アクティブ|int|7|0
hourly|idle_min|最小|アイドル|int|7|0
hourly|idle_avg|平均|アイドル|dec1|7|0
hourly|idle_max|最大|アイドル|int|7|0
hourly|available_min|取得可能 最小|プール|int|9|0
hourly|usage_pct_avg|使用率 平均|プール|pct|9|0
hourly|usage_pct_max|使用率 最大|プール|pct|9|0
hourly|max_pool_size|最大プール|プール|int|9|0
hourly|high_samples|高使用率|枯渇・待ち|int|8|0
hourly|exhausted_samples|枯渇|枯渇・待ち|int|7|0
hourly|wait_delta|待ち発生|枯渇・待ち|int|8|0
hourly|blocking_failure_delta|取得失敗|枯渇・待ち|int|8|0
hourly|queued_threads_max|待機スレッド 最大|枯渇・待ち|int|10|0
hourly|created_delta|作成|作成・破棄|int|7|1
hourly|destroyed_delta|破棄|作成・破棄|int|7|1
hourly|timed_out_delta|アイドル破棄|作成・破棄|int|8|1
hourly|max_used_count_end|MaxUsedCount|サーバー記録値|int|11|1
hourly|max_get_time_ms_end|最大取得時間(ms)|サーバー記録値|int|11|1
events|event_id|No.|イベント|int|5|0
events|ds_name|データソース|イベント|text|20|0
events|severity|重大度|イベント|status|10|0
events|start_time|開始|イベント|dt|20|0
events|end_time|終了|イベント|dt|20|0
events|duration_sec|継続時間(概算)|イベント|dur|11|0
events|samples|サンプル|イベント|int|8|0
events|in_use_max|使用中 最大|状況|int|9|0
events|available_min|取得可能 最小|状況|int|9|0
events|usage_pct_max|使用率 最大|状況|pct|9|0
events|queued_threads_max|待機スレッド 最大|状況|int|10|0
events|wait_delta|待ち発生|状況|int|8|0
events|blocking_failure_delta|取得失敗|状況|int|8|0
events|max_get_time_ms_end|最大取得時間(ms)|サーバー記録値|int|11|0
events|max_wait_count_end|最大同時待ち|サーバー記録値|int|10|0
events|top_waiter_frame|主な待機元（アプリケーションのフレーム）|待機元|text|62|0
waiters|ds_name|データソース|待機元|text|20|0
waiters|app_frame|アプリケーションのフレーム（クラス:メソッド:行）|待機元|text|72|0
waiters|occurrences|観測回数(延べスレッド)|待機元|int|12|0
waiters|samples|観測サンプル数|待機元|int|11|0
waiters|first_seen|初回|待機元|dt|20|0
waiters|last_seen|最終|待機元|dt|20|0
waiters|example_thread|スレッド名(例)|待機元|text|24|0
ctx|timestamp|日時|基本|dt|20|0
ctx|cli_ms|取得応答(ms)|基本|int|9|0
ctx|thread_count|スレッド数|JVM スレッド|int|9|0
ctx|peak_thread_count|ピーク|JVM スレッド|int|8|0
ctx|daemon_thread_count|デーモン|JVM スレッド|int|8|0
ctx|heap_used_mb|使用(MB)|ヒープ|dec1|9|0
ctx|heap_committed_mb|確保(MB)|ヒープ|dec1|9|0
ctx|heap_max_mb|最大(MB)|ヒープ|dec1|9|0
ctx|heap_used_pct|使用率|ヒープ|pct|8|0
ctx|io_busy_task_threads|処理中|IO ワーカー（リクエスト処理スレッド）|int|8|0
ctx|io_max_task_threads|最大|IO ワーカー（リクエスト処理スレッド）|int|8|0
ctx|io_busy_pct|使用率|IO ワーカー（リクエスト処理スレッド）|pct|8|0
ctx|io_queue_size|キュー|IO ワーカー（リクエスト処理スレッド）|int|8|0
ctx|tx_inflight|実行中|トランザクション|int|8|0
ctx|tx_timed_out|タイムアウト累計|トランザクション|int|11|0
ctx|d_tx_timed_out|タイムアウト(区間)|トランザクション|int|11|0
ctx|ds_in_use_total|使用中 合計|接続プール（全データソース）|int|10|0
ctx|ds_exhausted|枯渇DS数|接続プール（全データソース）|int|9|0
ctx|epoch|UNIX時刻|その他|num|11|1
ctx|utc_offset|UTC差|その他|text|7|1
ctx|host|ホスト|その他|text|24|1
# サマリー: 総合判定（横）
sumo|ds_name|データソース||text|0|0
sumo|ds_type|種別||text|0|0
sumo|verdict|判定||verdict|0|0
sumo|usage_pct_max|使用率 最大||pct|0|0
sumo|in_use_max|使用中 最大||int|0|0
sumo|in_use_avg|使用中 平均||dec1|0|0
sumo|max_pool_size|最大プール||int|0|0
sumo|exhausted_samples|枯渇サンプル||int|0|0
sumo|wait_total|待ち発生||int|0|0
sumo|blocking_failure_total|取得失敗||int|0|0
sumo|queued_threads_max|最大待機スレッド||int|0|0
sumo|max_used_count|MaxUsedCount||int|0|0
# サマリー: データソース別 詳細（縦）  # は見出し行
sumv|#|基本情報||||
sumv|ds_type|種別||text||
sumv|jndi_name|JNDI 名||text||
sumv|verdict|判定||verdict||
sumv|period_start|収集開始||dt||
sumv|period_end|収集終了||dt||
sumv|duration_sec|収集時間||dur||
sumv|samples|サンプル数||int||
sumv|valid_samples|有効サンプル数||int||
sumv|interval_sec|収集間隔（秒）||int||
sumv|#|プール設定||||
sumv|min_pool_size|最小プールサイズ（min-pool-size）||int||
sumv|max_pool_size|最大プールサイズ（max-pool-size）||int||
sumv|blocking_timeout_ms|取得タイムアウト ms（blocking-timeout-wait-millis）||int||
sumv|#|使用中接続数（InUseCount）||||
sumv|in_use_min|最小||int||
sumv|in_use_avg|平均||dec1||
sumv|in_use_p95|95 パーセンタイル||int||
sumv|in_use_max|最大||int||
sumv|in_use_max_at|最大を記録した日時||dt||
sumv|#|アクティブ／アイドル／取得可能||||
sumv|active_min|アクティブ 最小（ActiveCount）||int||
sumv|active_avg|アクティブ 平均||dec1||
sumv|active_max|アクティブ 最大||int||
sumv|idle_min|アイドル 最小（IdleCount）||int||
sumv|idle_avg|アイドル 平均||dec1||
sumv|idle_max|アイドル 最大||int||
sumv|available_min|取得可能 最小（AvailableCount）||int||
sumv|available_avg|取得可能 平均||dec1||
sumv|#|使用率（使用中 ÷ 最大プール）||||
sumv|usage_pct_avg|平均||pct||
sumv|usage_pct_p95|95 パーセンタイル||pct||
sumv|usage_pct_max|最大||pct||
sumv|#|サーバー記録の最大値（統計の有効化・クリア以降）||||
sumv|max_used_count|最大使用数（MaxUsedCount）||int||
sumv|max_used_pct|最大使用率（MaxUsedCount ÷ 最大プール）||pct||
sumv|max_wait_count|最大同時待ち数（MaxWaitCount）||int||
sumv|queued_threads_max|最大待機スレッド数（観測値）||int||
sumv|#|枯渇・待ち（収集期間中）||||
sumv|high_samples|高使用率サンプル数||int||
sumv|exhausted_samples|枯渇サンプル数||int||
sumv|exhausted_pct|枯渇サンプル率||pct||
sumv|exhausted_time_sec|枯渇時間（概算）||dur||
sumv|exhaustion_events|枯渇・待ちイベント数||int||
sumv|longest_event_sec|最長イベントの継続時間||dur||
sumv|first_exhausted_at|最初の枯渇||dt||
sumv|last_exhausted_at|最後の枯渇||dt||
sumv|wait_total|待ち発生回数||int||
sumv|blocking_failure_total|取得失敗回数（タイムアウト）||int||
sumv|#|接続の作成・破棄（収集期間中）||||
sumv|created_total|作成数||int||
sumv|destroyed_total|破棄数||int||
sumv|timed_out_total|アイドルタイムアウトによる破棄||int||
sumv|#|時間（サーバー累計値、ミリ秒）||||
sumv|avg_get_time_ms|平均取得時間||int||
sumv|max_get_time_ms|最大取得時間||int||
sumv|avg_usage_time_ms|平均使用時間||int||
sumv|max_usage_time_ms|最大使用時間||int||
sumv|avg_creation_time_ms|平均作成時間||int||
sumv|max_creation_time_ms|最大作成時間||int||
sumv|avg_blocking_time_ms|平均ブロック時間||int||
sumv|max_wait_time_ms|最大待ち時間||int||
sumv|#|データ品質||||
sumv|stats_off_samples|統計無効サンプル数||int||
sumv|error_samples|取得エラーサンプル数||int||
sumv|counter_resets|カウンタリセット検出数||int||
sumv|notes|所見コード||text||
# サマリー: 収集情報（meta:カテゴリ.キー を値に置換して連結、@ は計算値）
info|対象ホスト|meta:collector.host
info|製品|meta:server.product-name| |meta:server.product-version
info|JBOSS_HOME|meta:server.jboss_home
info|JVM|meta:jvm.vm-name| |meta:jvm.vm-version
info|CPU 数（JVM から見た値）|meta:jvm.available-processors
info|最大ヒープ（MB）|meta:jvm.heap-max-mb
info|ECS クラスター|meta:ecs.Cluster
info|ECS タスク|meta:ecs.TaskARN
info|タスク定義|meta:ecs.Family|:|meta:ecs.Revision
info|起動タイプ|meta:ecs.LaunchType
info|収集期間|@period
info|収集間隔|@interval
info|判定閾値|@warn
info|時間別推移の集計単位|@bucket
info|収集方式|@mode
info|入力データ|@source
info|レポート作成日時|@now
# 所見テンプレート（{列名} {列名:dur} {warn} {churn} を置換）
tmpl|FAILURES|接続取得のタイムアウト（取得失敗）が {blocking_failure_total} 件発生しました。アプリケーションでは IJ000453（Unable to get managed connection）等のエラーになった可能性があります。
tmpl|EXHAUSTED|プールの枯渇（取得可能数 0、または待機スレッドあり）を {exhausted_samples} サンプル観測しました（約 {exhausted_time_sec:dur}／最初 {first_exhausted_at}／最後 {last_exhausted_at}）。
tmpl|WAITS|空き接続の待ちが {wait_total} 回発生しました（サーバー記録の最大同時待ち数 {max_wait_count}）。
tmpl|HIGH_USAGE|使用率が {warn}% 以上のサンプルが {high_samples} 件あります（最大 {usage_pct_max}%、95 パーセンタイル {usage_pct_p95}%）。
tmpl|PEAK_AT_MAX|サーバー記録の最大使用数 MaxUsedCount（{max_used_count}）が最大プールサイズ（{max_pool_size}）に達しています。サンプリングの間に枯渇していた可能性があります。
tmpl|LONG_HOLD|接続の最大使用時間（MaxUsageTime）が {max_usage_time_ms} ms です。長時間のトランザクション・SQL、または close 漏れ（接続リーク）の可能性を確認してください。
tmpl|SLOW_GET|接続取得の最大時間（MaxGetTime）が {max_get_time_ms} ms です（取得タイムアウト {blocking_timeout_ms} ms）。
tmpl|SLOW_CREATE|物理接続の作成に最大 {max_creation_time_ms} ms かかっています。DB・ネットワーク側の応答を確認してください。
tmpl|CHURN|アイドルタイムアウト以外の理由で破棄された接続が {churn} 件あります（接続検証の失敗、例外、フラッシュ等）。
tmpl|IDLE_TIMEOUT|アイドルタイムアウトにより {timed_out_total} 件の接続が破棄されました（通常の動作です）。
tmpl|NEVER_IDLE|収集期間中、使用中接続数が 0 になりませんでした（最小 {in_use_min}）。常時負荷、または接続リークの可能性があります。
tmpl|POOL_RESIZED|収集期間中に最大プールサイズが変更されました（現在 {max_pool_size}）。
tmpl|COUNTER_RESET|統計カウンタのリセット（サーバー再起動または clear-statistics）を {counter_resets} 回検出しました。
tmpl|STATS_OFF|プール統計が無効のサンプルが {stats_off_samples} 件あります。statistics-enabled=true を設定するか、収集時に --enable-stats を指定してください。
tmpl|ERRORS|統計を取得できなかったサンプルが {error_samples} 件あります（サーバー停止、管理インターフェースの無応答など）。
tmpl|_OK|収集期間中、接続プールの枯渇・待ちは観測されませんでした（使用率 最大 {usage_pct_max}%）。
tmpl|_RECOMMEND|推奨: ①「枯渇イベント」「待機スレッド」シートで発生時刻と待機元の処理を確認 ②接続の close 漏れ（リーク）、長時間 SQL・ロック待ちを確認 ③必要に応じて max-pool-size と DB 側の最大接続数を見直し
tmpl|_NODATA|有効な統計データがありません（統計無効・取得エラー等）。
# 凡例シート（H=見出し TH=表見出し T=表 P=文 B=空行）
legend|H|判定（ステータス）の定義
legend|TH|判定|条件|意味・対応
legend|T|正常|下記のいずれにも該当しない|－
legend|T|高使用率|使用率（使用中 ÷ 最大プール）が閾値以上（既定 80%）|余裕が少ない状態。ピーク時間帯の推移を確認
legend|T|待ち発生|前回サンプルから WaitCount が増加|サンプルの間に一時的な枯渇があり、空き接続を待った要求があった
legend|T|枯渇|AvailableCount = 0、使用中 ≧ 最大プール、または待機スレッドあり|サンプル時点でプールが枯渇していた
legend|T|取得失敗|前回サンプルから BlockingFailureCount が増加|取得タイムアウト（blocking-timeout-wait-millis 超過）が発生。アプリでは IJ000453 等の例外
legend|T|統計無効|プール統計（statistics-enabled）が無効|値は使用できません。--enable-stats または設定で有効化
legend|T|DS無効|データソースが無効（enabled=false）|－
legend|T|プール未取得|プール統計リソースを取得できない|データソースが未起動など
legend|T|取得エラー|jboss-cli による取得に失敗|サーバー停止・無応答など。グラフでは欠損として表示
legend|B|
legend|H|主な項目（IronJacamar プール統計）
legend|TH|項目|属性名|説明
legend|T|使用中|InUseCount|アプリケーションが使用中（貸出中）の接続数
legend|T|アクティブ|ActiveCount|プールに作成済みの物理接続数（使用中＋アイドル）
legend|T|アイドル|IdleCount|プール内で待機中（未使用）の接続数
legend|T|取得可能|AvailableCount|新たに取得できる接続数（最大プール － 使用中）。0 は枯渇
legend|T|最大使用数|MaxUsedCount|使用中接続数の最大値（統計の有効化・クリア以降）
legend|T|待ち発生|WaitCount|空き接続を待つ必要があった取得要求の累計
legend|T|最大同時待ち|MaxWaitCount|同時に接続を待ったスレッド数の最大値
legend|T|取得失敗|BlockingFailureCount|接続の取得に失敗（タイムアウト）した回数の累計
legend|T|待機スレッド|dump-queued-threads-in-pool|サンプル時点で接続を待っていたスレッド数（収集スクリプトが取得）
legend|T|作成／破棄|CreatedCount／DestroyedCount|物理接続の作成数・破棄数の累計
legend|T|アイドル破棄|TimedOut|アイドルタイムアウトで破棄された接続数の累計
legend|T|取得時間|Average／Max／TotalGetTime|接続の取得に要した時間（ミリ秒）。待ち時間を含む
legend|T|使用時間|Average／Max／TotalUsageTime|接続を使用（保持）していた時間（ミリ秒）
legend|T|ブロック時間|AverageBlockingTime／TotalBlockingTime／MaxWaitTime|プールの空きを待った時間（ミリ秒）
legend|T|作成時間|Average／Max／TotalCreationTime|物理接続の作成に要した時間（ミリ秒）
legend|T|プール滞在|Average／Max／TotalPoolTime|接続がアイドルとしてプールに滞在した時間（ミリ秒）
legend|B|
legend|H|所見コード（サマリーシート）
legend|TH|コード|内容|判定基準
legend|T|FAILURES|取得失敗（タイムアウト）あり|期間中の BlockingFailureCount 増分 > 0
legend|T|EXHAUSTED|枯渇あり|枯渇サンプル > 0
legend|T|WAITS|待ち発生あり|期間中の WaitCount 増分 > 0
legend|T|HIGH_USAGE|高使用率あり|使用率 ≧ 閾値のサンプルあり
legend|T|PEAK_AT_MAX|最大使用数が上限に到達|MaxUsedCount ≧ 最大プールサイズ
legend|T|LONG_HOLD|接続の長時間保持|MaxUsageTime ≧ 60 秒
legend|T|SLOW_GET|取得に時間がかかっている|MaxGetTime ≧ 1 秒
legend|T|SLOW_CREATE|物理接続の作成が遅い|MaxCreationTime ≧ 1 秒
legend|T|CHURN|接続の破棄が多い|破棄数 － アイドル破棄数 ≧ 10
legend|T|IDLE_TIMEOUT|アイドルタイムアウトによる破棄|TimedOut 増分 > 0（通常動作）
legend|T|NEVER_IDLE|使用中が 0 にならない|1 時間以上の収集で使用中の最小 ≧ 1
legend|T|POOL_RESIZED|最大プールサイズの変更|期間中に max-pool-size が変化
legend|T|COUNTER_RESET|統計カウンタのリセット|累計カウンタの減少を検出
legend|T|STATS_OFF|統計無効のサンプルあり|statistics-enabled=false
legend|T|ERRORS|取得エラーのサンプルあり|jboss-cli の取得失敗
legend|B|
legend|H|注意事項
legend|P|・「使用中」「アイドル」等はサンプル時点の値です。サンプルの間に起きた短時間の枯渇は「待ち発生」「取得失敗」（累計カウンタの増分）と MaxUsedCount で検出します。
legend|P|・累計カウンタ・最大値（Max*／Total*／Average*）は、統計の有効化またはクリア（clear-statistics）以降、サーバー再起動まで累積されます。
legend|P|・統計を実行時に有効化した直後は、有効化前から使用中だった接続が計上されず、値が実際と異なる場合があります。
legend|P|・時間別推移の「平均」は有効サンプルの単純平均です。枯渇時間・イベントの継続時間はサンプル間隔から概算しています。
legend|P|・グラフはモノトーンのため、線の種類（実線・破線・点線・長破線）で系列を区別しています。
DEFS

#------------------------------------------------------------------------------
# styles.xml（Meiryo UI・モノトーン）  ※ Windows 版と同一
#------------------------------------------------------------------------------
write_styles() {
  cat > "$1" <<'XML'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><numFmts count="6">
<numFmt numFmtId="164" formatCode="yyyy/mm/dd hh:mm:ss"/>
<numFmt numFmtId="165" formatCode="yyyy/mm/dd hh:mm"/>
<numFmt numFmtId="166" formatCode="#,##0.0"/>
<numFmt numFmtId="167" formatCode="0.0%"/>
<numFmt numFmtId="168" formatCode="[h]:mm:ss"/>
<numFmt numFmtId="169" formatCode="0"/>
</numFmts>
<fonts count="8">
<font><sz val="10"/><color rgb="FF000000"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font>
<font><b/><sz val="10"/><color rgb="FF000000"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font>
<font><b/><sz val="10"/><color rgb="FFFFFFFF"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font>
<font><b/><sz val="16"/><color rgb="FF000000"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font>
<font><sz val="9"/><color rgb="FF595959"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font>
<font><b/><sz val="11"/><color rgb="FF000000"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font>
<font><sz val="8"/><color rgb="FF595959"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font>
<font><i/><sz val="10"/><color rgb="FF808080"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font>
</fonts>
<fills count="9">
<fill><patternFill patternType="none"/></fill>
<fill><patternFill patternType="gray125"/></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FF404040"/><bgColor indexed="64"/></patternFill></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FFD9D9D9"/><bgColor indexed="64"/></patternFill></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FFF2F2F2"/><bgColor indexed="64"/></patternFill></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FF262626"/><bgColor indexed="64"/></patternFill></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FF7F7F7F"/><bgColor indexed="64"/></patternFill></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FFBFBFBF"/><bgColor indexed="64"/></patternFill></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FFE7E7E7"/><bgColor indexed="64"/></patternFill></fill>
</fills>
<borders count="4">
<border><left/><right/><top/><bottom/><diagonal/></border>
<border><left style="thin"><color rgb="FFBFBFBF"/></left><right style="thin"><color rgb="FFBFBFBF"/></right><top style="thin"><color rgb="FFBFBFBF"/></top><bottom style="thin"><color rgb="FFBFBFBF"/></bottom><diagonal/></border>
<border><left style="thin"><color rgb="FF808080"/></left><right style="thin"><color rgb="FF808080"/></right><top style="thin"><color rgb="FF808080"/></top><bottom style="thin"><color rgb="FF808080"/></bottom><diagonal/></border>
<border><left/><right/><top/><bottom style="medium"><color rgb="FF000000"/></bottom><diagonal/></border>
</borders>
<cellStyleXfs count="1">
<xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
<cellXfs count="29">
<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
<xf numFmtId="0" fontId="3" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1"><alignment vertical="center"/></xf>
<xf numFmtId="0" fontId="4" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1"><alignment vertical="center"/></xf>
<xf numFmtId="0" fontId="5" fillId="0" borderId="3" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1"><alignment vertical="center"/></xf>
<xf numFmtId="0" fontId="2" fillId="2" borderId="2" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf>
<xf numFmtId="0" fontId="1" fillId="3" borderId="2" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>
<xf numFmtId="0" fontId="6" fillId="4" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center" shrinkToFit="1"/></xf>
<xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1"><alignment vertical="center"/></xf>
<xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>
<xf numFmtId="3" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1" applyAlignment="1"><alignment vertical="center"/></xf>
<xf numFmtId="166" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1" applyAlignment="1"><alignment vertical="center"/></xf>
<xf numFmtId="167" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1" applyAlignment="1"><alignment vertical="center"/></xf>
<xf numFmtId="164" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>
<xf numFmtId="165" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>
<xf numFmtId="168" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1" applyAlignment="1"><alignment horizontal="right" vertical="center"/></xf>
<xf numFmtId="169" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1" applyAlignment="1"><alignment vertical="center"/></xf>
<xf numFmtId="0" fontId="0" fillId="4" borderId="1" xfId="0" applyFill="1" applyBorder="1" applyAlignment="1"><alignment vertical="center"/></xf>
<xf numFmtId="0" fontId="1" fillId="3" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment vertical="center"/></xf>
<xf numFmtId="0" fontId="2" fillId="5" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>
<xf numFmtId="0" fontId="2" fillId="6" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>
<xf numFmtId="0" fontId="1" fillId="7" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>
<xf numFmtId="0" fontId="1" fillId="8" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>
<xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>
<xf numFmtId="0" fontId="7" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>
<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>
<xf numFmtId="0" fontId="4" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1"><alignment vertical="center"/></xf>
<xf numFmtId="0" fontId="5" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1"><alignment vertical="center"/></xf>
<xf numFmtId="0" fontId="7" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1"><alignment vertical="center"/></xf>
<xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>
</cellXfs>
<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
<dxfs count="5">
<dxf><font><color rgb="FFFFFFFF"/></font>
<fill><patternFill patternType="solid"><fgColor rgb="FF404040"/><bgColor rgb="FF404040"/></patternFill></fill>
</dxf>
<dxf><font><color rgb="FFFFFFFF"/></font>
<fill><patternFill patternType="solid"><fgColor rgb="FF808080"/><bgColor rgb="FF808080"/></patternFill></fill>
</dxf>
<dxf><fill><patternFill patternType="solid"><fgColor rgb="FFBFBFBF"/><bgColor rgb="FFBFBFBF"/></patternFill></fill>
</dxf>
<dxf><fill><patternFill patternType="solid"><fgColor rgb="FFEDEDED"/><bgColor rgb="FFEDEDED"/></patternFill></fill>
</dxf>
<dxf><font><i/><color rgb="FF8C8C8C"/></font>
</dxf>
</dxfs>
<tableStyles count="0" defaultTableStyle="TableStyleMedium2" defaultPivotStyle="PivotStyleLight16"/></styleSheet>
XML
}

#------------------------------------------------------------------------------
# XML 生成（awk）
#------------------------------------------------------------------------------
cat > "$WORK/xl.awk" <<'AWK'
# ---- 共通 ----
function trim(s) { sub(/^[ \t\r\n]+/, "", s); sub(/[ \t\r\n]+$/, "", s); return s }
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
function xesc(s) {
  gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s)
  gsub(/[\001-\010\013\014\016-\037]/, "", s)
  return s
}
function colname(n,    s, r) { s = ""; while (n > 0) { r = (n - 1) % 26; s = substr("ABCDEFGHIJKLMNOPQRSTUVWXYZ", r + 1, 1) s; n = int((n - 1) / 26) }; return s }
function days_civil(y, m, d,    era, yoe, doy, doe) {
  y -= (m <= 2) ? 1 : 0
  era = (y >= 0) ? y : y - 399; era = int(era / 400)
  yoe = y - era * 400
  doy = int((153 * ((m > 2) ? m - 3 : m + 9) + 2) / 5) + d - 1
  doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
  return era * 146097 + doe - 719468
}
function xdate(s) {
  if (s !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) return ""
  return sprintf("%.10f", days_civil(substr(s, 1, 4) + 0, substr(s, 6, 2) + 0, substr(s, 9, 2) + 0) + 25569 + (substr(s, 12, 2) * 3600 + substr(s, 15, 2) * 60 + substr(s, 18, 2)) / 86400)
}
function isnum(v) { return (v ~ /^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$/) }
function strc(ref, s, st) { return "<c r=\"" ref "\" s=\"" st "\" t=\"inlineStr\"><is><t xml:space=\"preserve\">" xesc(s) "</t></is></c>" }
function numc(ref, v, st) { return "<c r=\"" ref "\" s=\"" st "\"><v>" v "</v></c>" }
function emptyc(ref, st) { return "<c r=\"" ref "\" s=\"" st "\"/>" }
function slabel(v) { return (v in SL) ? SL[v] : v }
function vstyle(v) { return (v == "FAILURE") ? S_V4 : (v == "EXHAUSTED") ? S_V3 : (v == "WAIT") ? S_V2 : (v == "HIGH") ? S_V1 : (v == "OK") ? S_V0 : S_VM }
function cellx(ref, fmt, v,    x) {
  if (fmt == "verdict") return (v == "") ? emptyc(ref, S_V0) : strc(ref, slabel(v), vstyle(v))
  if (v == "") return emptyc(ref, (fmt in FMTS) ? FMTS[fmt] : S_TEXT)
  if (fmt == "dt" || fmt == "dtm") { x = xdate(v); return (x != "") ? numc(ref, x, FMTS[fmt]) : strc(ref, v, S_TEXT) }
  if (fmt == "int" || fmt == "dec1" || fmt == "num") return isnum(v) ? numc(ref, v, FMTS[fmt]) : strc(ref, v, S_TEXT)
  if (fmt == "pct") return isnum(v) ? numc(ref, sprintf("%.6f", v / 100), S_PCT) : strc(ref, v, S_TEXT)
  if (fmt == "dur") return isnum(v) ? numc(ref, sprintf("%.10f", v / 86400), S_DUR) : strc(ref, v, S_TEXT)
  if (fmt == "bool") return strc(ref, (v == "true") ? "有効" : (v == "false") ? "無効" : v, S_TEXTC)
  if (fmt == "status") return strc(ref, slabel(v), S_TEXTC)
  if (fmt == "auto") return isnum(v) ? numc(ref, v, S_TEXT) : strc(ref, v, S_TEXT)
  return strc(ref, v, S_TEXT)
}
function row(r, cells, ht) { return "<row r=\"" r "\"" (ht > 0 ? " ht=\"" ht "\" customHeight=\"1\"" : "") ">" cells "</row>" }
function units(s,    t, nb, na) { t = s; nb = length(s); na = gsub(/[\200-\377]/, "", t); return (nb - na) + na / 3 * 2 }
function wrapht(s, width,    l) { l = int(units(s) / (width * 0.95)) + 1; return l * 15 + 3 }
function loaddefs(f,    ln, a, n) {
  while ((getline ln < f) > 0) {
    if (ln ~ /^#/ || ln == "") continue
    n = split(ln, a, "|")
    if (a[1] == "sumo" || a[1] == "sumv") { DEFS_N[a[1]]++; DK[a[1], DEFS_N[a[1]]] = a[2]; DL[a[1], DEFS_N[a[1]]] = a[3]; DFM[a[1], DEFS_N[a[1]]] = a[5]; continue }
    if (a[1] == "info") { NINFO++; INFO_L[NINFO] = a[2]; INFO_S[NINFO] = substr(ln, length(a[1]) + length(a[2]) + 3); continue }
    if (a[1] == "tmpl") { TM[a[2]] = substr(ln, length(a[1]) + length(a[2]) + 3); continue }
    if (a[1] == "legend") { NLEG++; LEG[NLEG] = substr(ln, 8); continue }
    if (n >= 6) { CDL[a[1], a[2]] = a[3]; CDC[a[1], a[2]] = a[4]; CDF[a[1], a[2]] = a[5]; CDW[a[1], a[2]] = a[6]; CDG[a[1], a[2]] = (n >= 7) ? a[7] + 0 : 0 }
  }
  close(f)
}
function ws_begin(tab, fit, outline, xs, ys,    s, tl, pane) {
  s = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<worksheet " NS ">"
  s = s "<sheetPr><tabColor rgb=\"" tab "\"/><outlinePr summaryBelow=\"0\" summaryRight=\"0\"/>" (fit ? "<pageSetUpPr fitToPage=\"1\"/>" : "") "</sheetPr>"
  s = s "<sheetViews><sheetView" (sheetidx == 1 ? " tabSelected=\"1\"" : "") " zoomScale=\"90\" zoomScaleNormal=\"90\" workbookViewId=\"0\">"
  if (xs > 0 || ys > 0) {
    tl = COLN[xs + 1] (ys + 1)
    pane = (xs > 0 && ys > 0) ? "bottomRight" : (ys > 0) ? "bottomLeft" : "topRight"
    s = s "<pane" (xs > 0 ? " xSplit=\"" xs "\"" : "") (ys > 0 ? " ySplit=\"" ys "\"" : "") " topLeftCell=\"" tl "\" activePane=\"" pane "\" state=\"frozen\"/>"
    s = s "<selection pane=\"" pane "\" activeCell=\"" tl "\" sqref=\"" tl "\"/>"
  } else s = s "<selection activeCell=\"A1\" sqref=\"A1\"/>"
  s = s "</sheetView></sheetViews><sheetFormatPr defaultRowHeight=\"15\"" (outline ? " outlineLevelCol=\"1\"" : "") "/>"
  return s
}
function ws_end(orient, fit, drawing, scale, brks,    s, hf) {
  s = "<pageMargins left=\"0.4\" right=\"0.4\" top=\"0.6\" bottom=\"0.6\" header=\"0.3\" footer=\"0.3\"/>"
  s = s "<pageSetup paperSize=\"9\"" (scale > 0 ? " scale=\"" scale "\"" : "") " orientation=\"" orient "\"" (fit ? " fitToWidth=\"1\" fitToHeight=\"0\"" : "") "/>"
  hf = "&L&\"Meiryo UI,Regular\"&9" reptitle "&R&\"Meiryo UI,Regular\"&9&A"
  s = s "<headerFooter><oddHeader>" xesc(hf) "</oddHeader><oddFooter>" xesc("&C&\"Meiryo UI,Regular\"&9&P / &N") "</oddFooter></headerFooter>"
  if (brks != "") s = s brks
  if (drawing) s = s "<drawing r:id=\"rId1\"/>"
  return s "</worksheet>"
}
function cf_rules(sq, ref,    s, r) {
  s = "<conditionalFormatting sqref=\"" sq "\">"
  s = s "<cfRule type=\"expression\" dxfId=\"0\" priority=\"1\" stopIfTrue=\"1\"><formula>" xesc(ref "=\"" SL["FAILURE"] "\"") "</formula></cfRule>"
  s = s "<cfRule type=\"expression\" dxfId=\"1\" priority=\"2\" stopIfTrue=\"1\"><formula>" xesc(ref "=\"" SL["EXHAUSTED"] "\"") "</formula></cfRule>"
  s = s "<cfRule type=\"expression\" dxfId=\"2\" priority=\"3\" stopIfTrue=\"1\"><formula>" xesc(ref "=\"" SL["WAIT"] "\"") "</formula></cfRule>"
  s = s "<cfRule type=\"expression\" dxfId=\"3\" priority=\"4\" stopIfTrue=\"1\"><formula>" xesc(ref "=\"" SL["HIGH"] "\"") "</formula></cfRule>"
  r = "OR(" ref "=\"" SL["STATS_OFF"] "\"," ref "=\"" SL["DISABLED"] "\"," ref "=\"" SL["NO_POOL"] "\"," ref "=\"" SL["ERROR"] "\")"
  s = s "<cfRule type=\"expression\" dxfId=\"4\" priority=\"5\" stopIfTrue=\"1\"><formula>" xesc(r) "</formula></cfRule>"
  return s "</conditionalFormatting>"
}
function defname(name, ref) { print (sheetidx - 1) "\t" name "\t" ref >> (aux "/defnames.txt") }
BEGIN {
  S_TITLE = 1; S_NOTE = 2; S_SEC = 3; S_HDR = 4; S_BAND = 5; S_KEY = 6; S_TEXT = 7; S_TEXTC = 8
  S_INT = 9; S_DEC1 = 10; S_PCT = 11; S_DT = 12; S_DTM = 13; S_DUR = 14; S_NUM = 15; S_LABEL = 16; S_SECROW = 17
  S_V4 = 18; S_V3 = 19; S_V2 = 20; S_V1 = 21; S_V0 = 22; S_VM = 23; S_WRAP = 24; S_NOTE2 = 25; S_HEAD = 26; S_MUTED = 27; S_TEXTW = 28
  FMTS["text"] = S_TEXT; FMTS["int"] = S_INT; FMTS["dec1"] = S_DEC1; FMTS["pct"] = S_PCT; FMTS["dt"] = S_DT; FMTS["dtm"] = S_DTM
  FMTS["dur"] = S_DUR; FMTS["num"] = S_NUM; FMTS["bool"] = S_TEXTC; FMTS["status"] = S_TEXTC; FMTS["auto"] = S_TEXT
  SL["OK"] = "正常"; SL["HIGH"] = "高使用率"; SL["WAIT"] = "待ち発生"; SL["EXHAUSTED"] = "枯渇"; SL["FAILURE"] = "取得失敗"
  SL["STATS_OFF"] = "統計無効"; SL["DISABLED"] = "DS無効"; SL["NO_POOL"] = "プール未取得"; SL["ERROR"] = "取得エラー"; SL["NO_DATA"] = "データなし"
  VALID["OK"] = 1; VALID["HIGH"] = 1; VALID["WAIT"] = 1; VALID["EXHAUSTED"] = 1; VALID["FAILURE"] = 1
  for (i = 1; i <= 728; i++) COLN[i] = colname(i)
  NS = "xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\""
  FONT = "<a:latin typeface=\"Meiryo UI\"/><a:ea typeface=\"Meiryo UI\"/><a:cs typeface=\"Meiryo UI\"/>"
  loaddefs(defs)
  if (mode == "table") table_sheet()
  else if (mode == "summary") summary_sheet()
  else if (mode == "config") config_sheet()
  else if (mode == "legend") legend_sheet()
  else if (mode == "charts") charts_sheet()
  exit
}

# ---- データ表シート（時系列 / 時間別 / イベント / 待機スレッド / JVM） ----
function table_sheet(    hdr, nc, c, k, gi, sc, tc, ln, g, ng, j, i, r, out, merges, nm, first, valid, n, nodata, lastr, anyg, trunc, nrows, fx, lx) {
  nc = 0
  if ((getline hdr < infile) > 0) { sub(/\r$/, "", hdr); nc = csvsplit(hdr, K) }
  gi = 0; sc = 0; tc = 0; anyg = 0
  for (c = 1; c <= nc; c++) {
    k = K[c]
    if ((table, k) in CDL) { CL[c] = CDL[table, k]; CC[c] = CDC[table, k]; CF[c] = CDF[table, k]; CW[c] = CDW[table, k]; CG[c] = CDG[table, k] }
    else { CL[c] = k; CC[c] = "その他"; CF[c] = "auto"; CW[c] = 12; CG[c] = 1 }
    if (CG[c]) anyg = 1
    if (k == groupkey) gi = c
    if (k == statuskey) sc = c
    if (k == "timestamp") tc = c
    print table "\t" k "\t" COLN[c] >> (aux "/colmap.txt")
  }
  ng = 0; nrows = 0
  if (nc > 0) {
    while ((getline ln < infile) > 0) {
      sub(/\r$/, "", ln); if (ln == "") continue
      g = ""
      if (gi) { csvsplit(ln, F); g = F[gi] }
      if (!(g in GIX)) { GIX[g] = ++ng; GNAME[ng] = g; GCNT[ng] = 0 }
      j = GIX[g]; GROW[j, ++GCNT[j]] = ln
      nrows++
    }
    close(infile)
  }
  reptitle = title
  printf "%s", ws_begin("FF404040", (nc > 0 && nc <= 20), anyg, (nrows > 0 ? freeze : 0), (nrows > 0 ? 6 : 0))
  if (nc > 0) {
    printf "<cols>"
    for (c = 1; c <= nc; c++) printf "<col min=\"%d\" max=\"%d\" width=\"%s\" customWidth=\"1\"%s/>", c, c, CW[c], (CG[c] ? " outlineLevel=\"1\"" : "")
    printf "</cols>"
  }
  printf "<sheetData>"
  printf "%s", row(1, strc("A1", title, S_TITLE), 24)
  printf "%s", row(2, strc("A2", note, S_NOTE2), 0)
  nodata = 0; merges = ""; nm = 0
  if (nc == 0) {
    printf "%s", row(4, strc("A4", "（データがありません）", S_NOTE2), 0)
    nodata = 1; lastr = 4
  } else {
    out = ""; c = 1
    while (c <= nc) {
      j = c; while (j < nc && CC[j + 1] == CC[c]) j++
      out = out strc(COLN[c] 4, CC[c], S_BAND)
      for (i = c + 1; i <= j; i++) out = out emptyc(COLN[i] 4, S_BAND)
      if (j > c) { merges = merges "<mergeCell ref=\"" COLN[c] "4:" COLN[j] "4\"/>"; nm++ }
      c = j + 1
    }
    printf "%s", row(4, out, 18)
    out = ""; for (c = 1; c <= nc; c++) out = out strc(COLN[c] 5, CL[c], S_HDR)
    printf "%s", row(5, out, 30)
    out = ""; for (c = 1; c <= nc; c++) out = out strc(COLN[c] 6, K[c], S_KEY)
    printf "%s", row(6, out, 14.4)
    r = 6; trunc = 0
    for (g = 1; g <= ng; g++) {
      first = r + 1; valid = 0; fx = ""; lx = ""
      for (i = 1; i <= GCNT[g]; i++) {
        if (r - 6 >= maxrows) { trunc = 1; break }
        r++
        n = csvsplit(GROW[g, i], F)
        if (sc && (F[sc] in VALID)) valid++
        if (tc) { lx = xdate(F[tc]); if (fx == "") fx = lx }
        out = ""
        for (c = 1; c <= nc; c++) out = out cellx(COLN[c] r, CF[c], F[c])
        printf "<row r=\"%d\">%s</row>", r, out
      }
      if (r >= first) print table "\t" GNAME[g] "\t" first "\t" r "\t" valid "\t" fx "\t" lx >> (aux "/ranges.txt")
      if (trunc) break
    }
    if (r == 6) { r = 7; printf "%s", row(7, strc("A7", "（データがありません）", S_NOTE2), 0); nodata = 1 }
    lastr = r
  }
  printf "</sheetData>"
  if (!nodata) printf "<autoFilter ref=\"A6:%s%d\"/>", COLN[nc], lastr
  if (nm) printf "<mergeCells count=\"%d\">%s</mergeCells>", nm, merges
  if (sc && !nodata) printf "%s", cf_rules("A7:" COLN[nc] lastr, "$" COLN[sc] "7")
  printf "%s", ws_end("landscape", (nc > 0 && nc <= 20), 0)
  if (!nodata) {
    defname("_xlnm._FilterDatabase", "'" sheetname "'!$A$6:$" COLN[nc] "$" lastr)
    defname("_xlnm.Print_Titles", (freeze > 0 ? "'" sheetname "'!$A:$" COLN[freeze] "," : "") "'" sheetname "'!$4:$6")
  }
  if (trunc) print "WARN: " sheetname " は " maxrows " 行で打ち切りました" > "/dev/stderr"
}

# ---- サマリーシート ----
function jdur(s,    h, m) { s = int(s + 0); h = int(s / 3600); m = int((s % 3600) / 60); s = s % 60; return (h > 0 ? h "時間" : "") ((h > 0 || m > 0) ? m "分" : "") s "秒" }
function render(t, d,    out, p, q, tok, f, v) {
  out = ""
  while ((p = index(t, "{")) > 0) {
    q = index(substr(t, p), "}"); if (q == 0) break
    tok = substr(t, p + 1, q - 2); out = out substr(t, 1, p - 1); t = substr(t, p + q)
    f = ""; if (index(tok, ":")) { f = substr(tok, index(tok, ":") + 1); tok = substr(tok, 1, index(tok, ":") - 1) }
    if (tok == "warn") v = WARN
    else if (tok == "churn") v = SV[d, "destroyed_total"] - SV[d, "timed_out_total"]
    else v = SV[d, tok]
    if (f == "dur") v = jdur(v)
    out = out v
  }
  return out t
}
function infoval(src,    n, a, i, v, out, any) {
  if (src == "@period") return PERIOD
  if (src == "@interval") return (META["collector.interval_sec"] != "") ? META["collector.interval_sec"] " 秒" : ""
  if (src == "@warn") return "使用率 " WARN "% 以上を「高使用率」と判定"
  if (src == "@bucket") return BUCKET " 分"
  if (src == "@mode") return "jboss-cli（" (META["collector.cli_mode"] != "" ? META["collector.cli_mode"] : "-") "）／ ds_pool_collector.sh " META["collector.version"]
  if (src == "@source") return srcname
  if (src == "@now") return nowstr
  n = split(src, a, "|"); out = ""; any = 0
  for (i = 1; i <= n; i++) {
    if (substr(a[i], 1, 5) == "meta:") { v = META[substr(a[i], 6)]; if (v != "") any = 1; out = out v }
    else out = out a[i]
  }
  return any ? out : ""
}
function summary_sheet(    ln, mn, n, nh, H, i, d, nds, ncols, r, out, k, c, f, v, notes, nn, NT, NT2, m, ht, merges, nm, ps, pe, maxdur, txt, lastc) {
  mn = 0
  while ((getline ln < metafile) > 0) { sub(/\r$/, "", ln); if (++mn == 1) continue; n = csvsplit(ln, F); if (n >= 3) META[F[1] "." F[2]] = F[3] }
  close(metafile)
  nds = 0
  if ((getline ln < sumfile) > 0) {
    sub(/\r$/, "", ln); nh = csvsplit(ln, H)
    while ((getline ln < sumfile) > 0) { sub(/\r$/, "", ln); if (ln == "") continue; csvsplit(ln, F); nds++; for (i = 1; i <= nh; i++) SV[nds, H[i]] = F[i] }
  }
  close(sumfile)
  WARN = (META["collector.warn_pct"] != "") ? META["collector.warn_pct"] : 80
  BUCKET = (META["collector.bucket_min"] != "") ? META["collector.bucket_min"] : 60
  ps = ""; pe = ""; maxdur = 0
  for (d = 1; d <= nds; d++) {
    if (SV[d, "period_start"] != "" && (ps == "" || SV[d, "period_start"] < ps)) ps = SV[d, "period_start"]
    if (SV[d, "period_end"] > pe) pe = SV[d, "period_end"]
    if (SV[d, "duration_sec"] + 0 > maxdur) maxdur = SV[d, "duration_sec"] + 0
  }
  PERIOD = (ps != "") ? ps " ～ " pe "（" jdur(maxdur) "）" : META["collector.start_time"] " ～ " META["collector.end_time"]
  reptitle = title
  ncols = (nds + 1 > 12) ? nds + 1 : 12
  lastc = COLN[ncols]
  printf "%s", ws_begin("FF000000", 1, 0, 0, 0)
  printf "<cols><col min=\"1\" max=\"1\" width=\"40\" customWidth=\"1\"/><col min=\"2\" max=\"%d\" width=\"20\" customWidth=\"1\"/></cols><sheetData>", ncols
  printf "%s", row(1, strc("A1", title, S_TITLE), 27)
  printf "%s", row(2, strc("A2", "JBoss EAP / IronJacamar データソース接続プール統計（jboss-cli により収集）　作成: " nowstr, S_NOTE2), 0)
  r = 4; merges = ""; nm = 0
  printf "%s", row(r, strc("A" r, "■ 収集情報", S_SEC), 21)
  for (i = 1; i <= NINFO; i++) {
    v = infoval(INFO_S[i]); if (v == "") continue
    r++
    out = strc("A" r, INFO_L[i], S_LABEL) strc("B" r, v, S_TEXT)
    for (c = 3; c <= 8; c++) out = out emptyc(COLN[c] r, S_TEXT)
    printf "%s", row(r, out, 0)
    merges = merges "<mergeCell ref=\"B" r ":H" r "\"/>"; nm++
  }
  r += 2
  printf "%s", row(r, strc("A" r, "■ 総合判定", S_SEC), 21)
  r++
  out = ""
  for (c = 1; c <= DEFS_N["sumo"]; c++) out = out strc(COLN[c] r, DL["sumo", c], S_HDR)
  printf "%s", row(r, out, 30)
  if (nds == 0) { r++; printf "%s", row(r, strc("A" r, "（サマリーがありません。ds_pool_collector.sh --report-only で作成してください）", S_NOTE2), 0) }
  for (d = 1; d <= nds; d++) {
    r++; out = ""
    for (c = 1; c <= DEFS_N["sumo"]; c++) out = out cellx(COLN[c] r, DFM["sumo", c], SV[d, DK["sumo", c]])
    printf "%s", row(r, out, 0)
  }
  if (nds > 0) {
    r += 2
    printf "%s", row(r, strc("A" r, "■ データソース別 詳細", S_SEC), 21)
    r++
    out = strc("A" r, "項目", S_HDR)
    for (d = 1; d <= nds; d++) out = out strc(COLN[d + 1] r, SV[d, "ds_name"], S_HDR)
    printf "%s", row(r, out, 30)
    for (i = 1; i <= DEFS_N["sumv"]; i++) {
      r++
      if (DK["sumv", i] == "#") {
        out = strc("A" r, DL["sumv", i], S_SECROW)
        for (d = 1; d <= nds; d++) out = out emptyc(COLN[d + 1] r, S_SECROW)
        printf "%s", row(r, out, 0)
        if (nds > 0) { merges = merges "<mergeCell ref=\"A" r ":" COLN[nds + 1] r "\"/>"; nm++ }
        continue
      }
      out = strc("A" r, DL["sumv", i], S_LABEL)
      ht = 0
      for (d = 1; d <= nds; d++) {
        DV[d] = SV[d, DK["sumv", i]]
        if (DK["sumv", i] == "notes") gsub(/;/, "; ", DV[d])
        if (DFM["sumv", i] == "text") { v = wrapht(DV[d], 20); if (v > ht) ht = v }
      }
      if (ht <= 18) ht = 0
      for (d = 1; d <= nds; d++) {
        if (ht > 0 && DV[d] != "") out = out strc(COLN[d + 1] r, DV[d], S_TEXTW)
        else out = out cellx(COLN[d + 1] r, DFM["sumv", i], DV[d])
      }
      printf "%s", row(r, out, ht)
    }
    r += 2
    printf "%s", row(r, strc("A" r, "■ 所見", S_SEC), 21)
    for (d = 1; d <= nds; d++) {
      r++
      printf "%s", row(r, strc("A" r, "◆ " SV[d, "ds_name"] "（判定: " slabel(SV[d, "verdict"]) "）", S_HEAD), 20)
      split("", NT); nn = 0
      m = split(SV[d, "notes"], NT2, ";")
      if (SV[d, "valid_samples"] + 0 == 0) {
        NT[++nn] = "_NODATA"
        for (f = 1; f <= m; f++) if (NT2[f] == "STATS_OFF" || NT2[f] == "ERRORS") NT[++nn] = NT2[f]
      } else {
        for (f = 1; f <= m; f++) if (NT2[f] != "") NT[++nn] = NT2[f]
        if (SV[d, "verdict"] == "OK") NT[++nn] = "_OK"
        if (SV[d, "verdict"] == "FAILURE" || SV[d, "verdict"] == "EXHAUSTED" || SV[d, "verdict"] == "WAIT") NT[++nn] = "_RECOMMEND"
      }
      for (f = 1; f <= nn; f++) {
        if (!(NT[f] in TM)) continue
        txt = "・" render(TM[NT[f]], d)
        r++
        out = strc("A" r, txt, S_WRAP); for (c = 2; c <= 8; c++) out = out emptyc(COLN[c] r, S_WRAP)
        printf "%s", row(r, out, wrapht(txt, 40 + 7 * 17))
        merges = merges "<mergeCell ref=\"A" r ":H" r "\"/>"; nm++
      }
    }
  }
  printf "</sheetData>"
  if (nm) printf "<mergeCells count=\"%d\">%s</mergeCells>", nm, merges
  printf "%s", ws_end("landscape", 1, 0, 0, "")
  defname("_xlnm.Print_Area", "'" sheetname "'!$A$1:$" lastc "$" r)
}

# ---- 設定情報シート ----
function config_sheet(    ln, n, nh, H, e, k, a, ne, na, no, r, out, c, merges, nm, v, nt, st, isds, i) {
  ne = 0; na = 0; no = 0
  if ((getline ln < infile) > 0) {
    sub(/\r$/, "", ln); nh = csvsplit(ln, H)
    while ((getline ln < infile) > 0) {
      sub(/\r$/, "", ln); if (ln == "") continue
      csvsplit(ln, F)
      isds = (F[2] == "data-source" || F[2] == "xa-data-source")
      if (!isds) { no++; OT[no] = F[2]; ON[no] = F[1]; OA[no] = F[3]; OV[no] = F[4]; continue }
      e = F[1]
      if (!(e in EIX)) { EIX[e] = ++ne; EN[ne] = e; ET[ne] = F[2] }
      if (!(F[3] in AIX)) { AIX[F[3]] = ++na; AN[na] = F[3] }
      VAL[EIX[e], AIX[F[3]]] = F[4]; NOTE[EIX[e], AIX[F[3]]] = F[5]; HAS[EIX[e], AIX[F[3]]] = 1
    }
  }
  close(infile)
  reptitle = title
  printf "%s", ws_begin("FF7F7F7F", (ne <= 3), 0, (ne > 0 ? 1 : 0), (ne > 0 ? 5 : 0))
  printf "<cols><col min=\"1\" max=\"1\" width=\"40\" customWidth=\"1\"/><col min=\"2\" max=\"%d\" width=\"42\" customWidth=\"1\"/></cols><sheetData>", (ne + 1 > 4 ? ne + 1 : 4)
  printf "%s", row(1, strc("A1", title, S_TITLE), 24)
  printf "%s", row(2, strc("A2", note, S_NOTE2), 0)
  r = 4; merges = ""; nm = 0
  if (ne == 0) { printf "%s", row(r, strc("A" r, "（データソースの設定情報がありません）", S_NOTE2), 0) }
  else {
    out = strc("A4", "属性", S_HDR); for (e = 1; e <= ne; e++) out = out strc(COLN[e + 1] "4", EN[e], S_HDR)
    printf "%s", row(4, out, 22)
    out = strc("A5", "種別", S_LABEL); for (e = 1; e <= ne; e++) out = out strc(COLN[e + 1] "5", ET[e], S_TEXTC)
    printf "%s", row(5, out, 0)
    r = 5
    for (a = 1; a <= na; a++) {
      r++
      out = strc("A" r, AN[a], S_LABEL)
      for (e = 1; e <= ne; e++) {
        if (!((e, a) in HAS)) { out = out emptyc(COLN[e + 1] r, S_TEXT); continue }
        v = VAL[e, a]; nt = NOTE[e, a]
        if (nt == "default") out = out strc(COLN[e + 1] r, v "（既定値）", S_MUTED)
        else if (nt == "undefined") out = out strc(COLN[e + 1] r, "－", S_MUTED)
        else out = out strc(COLN[e + 1] r, v, S_TEXT)
      }
      printf "%s", row(r, out, 0)
    }
  }
  if (no > 0) {
    r += 2
    printf "%s", row(r, strc("A" r, "■ JDBC ドライバー／JCA（キャッシュ接続マネージャー）", S_SEC), 21)
    r++
    printf "%s", row(r, strc("A" r, "種別：名前", S_HDR) strc("B" r, "属性", S_HDR) strc("C" r, "値", S_HDR), 22)
    for (i = 1; i <= no; i++) { r++; printf "%s", row(r, strc("A" r, OT[i] "：" ON[i], S_TEXT) strc("B" r, OA[i], S_LABEL) strc("C" r, OV[i], S_TEXT), 0) }
  }
  printf "</sheetData>"
  printf "%s", ws_end("landscape", (ne <= 3), 0)
  if (ne > 0) defname("_xlnm.Print_Titles", "'" sheetname "'!$A:$A,'" sheetname "'!$4:$4")
}

# ---- 凡例シート ----
function legend_sheet(    i, n, a, r, out, merges, nm, ht) {
  reptitle = title
  printf "%s", ws_begin("FFBFBFBF", 1, 0, 0, 0)
  printf "<cols><col min=\"1\" max=\"1\" width=\"20\" customWidth=\"1\"/><col min=\"2\" max=\"2\" width=\"52\" customWidth=\"1\"/><col min=\"3\" max=\"3\" width=\"62\" customWidth=\"1\"/></cols><sheetData>"
  printf "%s", row(1, strc("A1", title, S_TITLE), 24)
  printf "%s", row(2, strc("A2", note, S_NOTE2), 0)
  r = 3; merges = ""; nm = 0
  for (i = 1; i <= NLEG; i++) {
    n = split(LEG[i], a, "|")
    r++
    if (a[1] == "H") printf "%s", row(r, strc("A" r, "■ " a[2], S_SEC), 21)
    else if (a[1] == "TH") printf "%s", row(r, strc("A" r, a[2], S_HDR) strc("B" r, a[3], S_HDR) strc("C" r, a[4], S_HDR), 20)
    else if (a[1] == "T") {
      ht = wrapht(a[3], 52); if (wrapht(a[4], 62) > ht) ht = wrapht(a[4], 62)
      printf "%s", row(r, strc("A" r, a[2], S_LABEL) strc("B" r, a[3], S_TEXTW) strc("C" r, a[4], S_TEXTW), (ht > 18 ? ht : 0))
    } else if (a[1] == "P") {
      printf "%s", row(r, strc("A" r, a[2], S_WRAP) emptyc("B" r, S_WRAP) emptyc("C" r, S_WRAP), wrapht(a[2], 134))
      merges = merges "<mergeCell ref=\"A" r ":C" r "\"/>"; nm++
    }
  }
  printf "</sheetData>"
  if (nm) printf "<mergeCells count=\"%d\">%s</mergeCells>", nm, merges
  printf "%s", ws_end("portrait", 1, 0)
}

# ---- グラフシート（DrawingML チャート） ----
function ctitle(t, sz) {
  return "<c:title><c:tx><c:rich><a:bodyPr/><a:lstStyle/><a:p><a:pPr><a:defRPr sz=\"" sz "\" b=\"1\"><a:solidFill><a:srgbClr val=\"000000\"/></a:solidFill>" FONT "</a:defRPr></a:pPr><a:r><a:rPr lang=\"ja-JP\" altLang=\"en-US\" sz=\"" sz "\" b=\"1\"><a:solidFill><a:srgbClr val=\"000000\"/></a:solidFill>" FONT "</a:rPr><a:t>" xesc(t) "</a:t></a:r></a:p></c:rich></c:tx><c:overlay val=\"0\"/></c:title>"
}
function axtitle(t, rot) {
  return "<c:title><c:tx><c:rich><a:bodyPr" (rot != "" ? " rot=\"" rot "\" vert=\"horz\"" : "") "/><a:lstStyle/><a:p><a:pPr><a:defRPr sz=\"800\" b=\"0\"><a:solidFill><a:srgbClr val=\"404040\"/></a:solidFill>" FONT "</a:defRPr></a:pPr><a:r><a:rPr lang=\"ja-JP\" altLang=\"en-US\" sz=\"800\" b=\"0\"><a:solidFill><a:srgbClr val=\"404040\"/></a:solidFill>" FONT "</a:rPr><a:t>" xesc(t) "</a:t></a:r></a:p></c:rich></c:tx><c:overlay val=\"0\"/></c:title>"
}
function txpr(sz, rot) {
  return "<c:txPr><a:bodyPr" (rot != "" ? " rot=\"" rot "\" vert=\"horz\"" : "") "/><a:lstStyle/><a:p><a:pPr><a:defRPr sz=\"" sz "\"><a:solidFill><a:srgbClr val=\"404040\"/></a:solidFill>" FONT "</a:defRPr></a:pPr><a:endParaRPr lang=\"ja-JP\"/></a:p></c:txPr>"
}
function lnsp(color, w, dash) { return "<c:spPr><a:ln w=\"" w "\" cap=\"rnd\"><a:solidFill><a:srgbClr val=\"" color "\"/></a:solidFill><a:prstDash val=\"" dash "\"/><a:round/></a:ln></c:spPr>" }
function axln() { return "<c:spPr><a:ln w=\"9525\"><a:solidFill><a:srgbClr val=\"808080\"/></a:solidFill></a:ln></c:spPr>" }
function grid() { return "<c:majorGridlines><c:spPr><a:ln w=\"6350\"><a:solidFill><a:srgbClr val=\"D9D9D9\"/></a:solidFill></a:ln></c:spPr></c:majorGridlines>" }
function ser_sc(i, name, xr, yr, color, w, dash) {
  return "<c:ser><c:idx val=\"" i "\"/><c:order val=\"" i "\"/><c:tx><c:v>" xesc(name) "</c:v></c:tx>" lnsp(color, w, dash) "<c:marker><c:symbol val=\"none\"/></c:marker><c:xVal><c:numRef><c:f>" xesc(xr) "</c:f></c:numRef></c:xVal><c:yVal><c:numRef><c:f>" xesc(yr) "</c:f></c:numRef></c:yVal><c:smooth val=\"0\"/></c:ser>"
}
function ser_ln(i, name, cr, vr, color, w, dash, mk) {
  return "<c:ser><c:idx val=\"" i "\"/><c:order val=\"" i "\"/><c:tx><c:v>" xesc(name) "</c:v></c:tx>" lnsp(color, w, dash) (mk ? "<c:marker><c:symbol val=\"circle\"/><c:size val=\"4\"/><c:spPr><a:solidFill><a:srgbClr val=\"" color "\"/></a:solidFill><a:ln><a:noFill/></a:ln></c:spPr></c:marker>" : "<c:marker><c:symbol val=\"none\"/></c:marker>") "<c:cat><c:numRef><c:f>" xesc(cr) "</c:f></c:numRef></c:cat><c:val><c:numRef><c:f>" xesc(vr) "</c:f></c:numRef></c:val><c:smooth val=\"0\"/></c:ser>"
}
function ser_bar(i, name, cr, vr, fill, line) {
  return "<c:ser><c:idx val=\"" i "\"/><c:order val=\"" i "\"/><c:tx><c:v>" xesc(name) "</c:v></c:tx><c:spPr><a:solidFill><a:srgbClr val=\"" fill "\"/></a:solidFill><a:ln w=\"6350\"><a:solidFill><a:srgbClr val=\"" line "\"/></a:solidFill></a:ln></c:spPr><c:invertIfNegative val=\"0\"/><c:cat><c:numRef><c:f>" xesc(cr) "</c:f></c:numRef></c:cat><c:val><c:numRef><c:f>" xesc(vr) "</c:f></c:numRef></c:val></c:ser>"
}
function valax(id, cross, pos, fmt, ttl, isy, between, scl, maj) {
  return "<c:valAx><c:axId val=\"" id "\"/><c:scaling><c:orientation val=\"minMax\"/>" (isy ? "<c:min val=\"0\"/>" : scl) "</c:scaling><c:delete val=\"0\"/><c:axPos val=\"" pos "\"/>" (isy ? grid() : "") (ttl != "" ? axtitle(ttl, (isy ? "-5400000" : "")) : "") "<c:numFmt formatCode=\"" xesc(fmt) "\" sourceLinked=\"0\"/><c:majorTickMark val=\"out\"/><c:minorTickMark val=\"none\"/><c:tickLblPos val=\"" (isy ? "nextTo" : "low") "\"/>" axln() txpr(800, (isy ? "" : "-2700000")) "<c:crossAx val=\"" cross "\"/><c:crosses val=\"" (isy ? "autoZero" : "min") "\"/><c:crossBetween val=\"" between "\"/>" (maj != "" ? "<c:majorUnit val=\"" maj "\"/>" : "") "</c:valAx>"
}
# 時間軸（シリアル値）の範囲と目盛間隔: 目盛が 12 個以下になる最小の間隔（1分～7日）
function xscale(x1, x2,    span, n, i, u, c) {
  XSCL = ""; XMAJ = ""; XFMT = "m/d hh:mm"
  if (x1 == "" || x2 == "") return
  x1 += 0; x2 += 0; span = x2 - x1
  if (span <= 0) span = 0.000694444444444444
  n = split("0.000694444444444444 0.00138888888888889 0.00347222222222222 0.00694444444444444 0.0104166666666667 0.0208333333333333 0.0416666666666667 0.0833333333333333 0.125 0.25 0.5 1 2 7", U, " ")
  for (i = 1; i <= n; i++) { u = U[i] + 0; if (span / u <= 12) break }
  if (i > n) u = U[n] + 0
  c = int(x2 / u - 1e-9); if (c * u < x2 - 1e-9) c++
  XSCL = "<c:max val=\"" sprintf("%.10f", c * u) "\"/><c:min val=\"" sprintf("%.10f", int(x1 / u + 1e-9) * u) "\"/>"
  XMAJ = sprintf("%.10f", u)
  if (u >= 1) XFMT = "m/d"
}
function catax(id, cross, fmt) {
  return "<c:catAx><c:axId val=\"" id "\"/><c:scaling><c:orientation val=\"minMax\"/></c:scaling><c:delete val=\"0\"/><c:axPos val=\"b\"/><c:numFmt formatCode=\"" xesc(fmt) "\" sourceLinked=\"0\"/><c:majorTickMark val=\"out\"/><c:minorTickMark val=\"none\"/><c:tickLblPos val=\"low\"/>" axln() txpr(800, "-2700000") "<c:crossAx val=\"" cross "\"/><c:crosses val=\"autoZero\"/><c:auto val=\"0\"/><c:lblAlgn val=\"ctr\"/><c:lblOffset val=\"100\"/><c:noMultiLvlLbl val=\"0\"/></c:catAx>"
}
function chart_doc(ttl, plot) {
  return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<c:chartSpace xmlns:c=\"http://schemas.openxmlformats.org/drawingml/2006/chart\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><c:date1904 val=\"0\"/><c:lang val=\"ja-JP\"/><c:roundedCorners val=\"0\"/><c:chart>" ctitle(ttl, 1000) "<c:autoTitleDeleted val=\"0\"/><c:plotArea><c:layout/>" plot "<c:spPr><a:noFill/><a:ln><a:noFill/></a:ln></c:spPr></c:plotArea><c:legend><c:legendPos val=\"b\"/><c:overlay val=\"0\"/>" txpr(800, "") "</c:legend><c:plotVisOnly val=\"1\"/><c:dispBlanksAs val=\"gap\"/></c:chart><c:spPr><a:solidFill><a:srgbClr val=\"FFFFFF\"/></a:solidFill><a:ln w=\"9525\"><a:solidFill><a:srgbClr val=\"A6A6A6\"/></a:solidFill></a:ln></c:spPr><c:txPr><a:bodyPr/><a:lstStyle/><a:p><a:pPr><a:defRPr sz=\"900\">" FONT "</a:defRPr></a:pPr><a:endParaRPr lang=\"ja-JP\"/></a:p></c:txPr></c:chartSpace>"
}
function add_chart(xml, c1, r1, c2, r2,    f) {
  NCH++
  f = outdir "/charts/chart" NCH ".xml"
  printf "%s", xml > f; close(f)
  ANCH = ANCH "<xdr:twoCellAnchor editAs=\"oneCell\"><xdr:from><xdr:col>" c1 "</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>" r1 "</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from><xdr:to><xdr:col>" c2 "</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>" r2 "</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:to><xdr:graphicFrame macro=\"\"><xdr:nvGraphicFramePr><xdr:cNvPr id=\"" (NCH + 1) "\" name=\"Chart " NCH "\"/><xdr:cNvGraphicFramePr/></xdr:nvGraphicFramePr><xdr:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/></xdr:xfrm><a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/chart\"><c:chart xmlns:c=\"http://schemas.openxmlformats.org/drawingml/2006/chart\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" r:id=\"rId" NCH "\"/></a:graphicData></a:graphic></xdr:graphicFrame><xdr:clientData/></xdr:twoCellAnchor>"
  RELS = RELS "<Relationship Id=\"rId" NCH "\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/chart\" Target=\"../charts/chart" NCH ".xml\"/>"
}
function rng(sheet, col, r1, r2) { return "'" sheet "'!$" col "$" r1 ":$" col "$" r2 }
function charts_sheet(    ln, a, n, d, nds, ds, r, out, x, h1, h2, base, f, plot, rows, ctxok) {
  while ((getline ln < colmap) > 0) { split(ln, a, "\t"); CM[a[1], a[2]] = a[3] }
  close(colmap)
  while ((getline ln < ranges) > 0) {
    n = split(ln, a, "\t")
    if (a[1] == "ts") { TF[a[2]] = a[3]; TL[a[2]] = a[4]; TV[a[2]] = a[5]; TX1[a[2]] = a[6]; TX2[a[2]] = a[7]; if (!(a[2] in DSX)) { DSX[a[2]] = ++nds; DSO[nds] = a[2] } }
    else if (a[1] == "hourly") { HF[a[2]] = a[3]; HL[a[2]] = a[4]; HV[a[2]] = a[5] }
    else if (a[1] == "ctx") { XF = a[3]; XL = a[4]; XX1 = a[6]; XX2 = a[7] }
  }
  close(ranges)
  if ((getline ln < sumfile) > 0) {
    n = csvsplit(ln, H); for (i = 1; i <= n; i++) HI[H[i]] = i
    while ((getline ln < sumfile) > 0) { sub(/\r$/, "", ln); csvsplit(ln, F); VERD[F[HI["ds_name"]]] = F[HI["verdict"]] }
  }
  close(sumfile)
  reptitle = title
  NCH = 0; ANCH = ""; RELS = ""; BRK = ""; NBRK = 0
  printf "%s", ws_begin("FF262626", 0, 0, 0, 0)
  printf "<sheetData>"
  printf "%s", row(1, strc("A1", title, S_TITLE), 24)
  printf "%s", row(2, strc("A2", note, S_NOTE2), 0)
  # 1 データソース = 39 行（見出し + 推移グラフ 18 行 + 時間別グラフ 18 行 + 余白）。印刷は 1 ブロック 1 ページ
  base = 4
  for (d = 1; d <= nds; d++) {
    ds = DSO[d]
    if (d > 1) { BRK = BRK "<brk id=\"" (base - 1) "\" max=\"16383\" man=\"1\"/>"; NBRK++ }
    printf "%s", row(base, strc("A" base, "■ " ds (ds in VERD ? "（判定: " slabel(VERD[ds]) "）" : ""), S_HEAD), 21)
    if (TV[ds] + 0 > 0) {
      x = rng(tsname, CM["ts", "timestamp"], TF[ds], TL[ds])
      plot = "<c:scatterChart><c:scatterStyle val=\"lineMarker\"/><c:varyColors val=\"0\"/>"
      plot = plot ser_sc(0, "使用中", x, rng(tsname, CM["ts", "in_use_count"], TF[ds], TL[ds]), "000000", 22225, "solid")
      plot = plot ser_sc(1, "アクティブ", x, rng(tsname, CM["ts", "active_count"], TF[ds], TL[ds]), "595959", 15875, "dash")
      plot = plot ser_sc(2, "アイドル", x, rng(tsname, CM["ts", "idle_count"], TF[ds], TL[ds]), "A6A6A6", 15875, "sysDot")
      plot = plot ser_sc(3, "最大プールサイズ", x, rng(tsname, CM["ts", "max_pool_size"], TF[ds], TL[ds]), "000000", 12700, "lgDash")
      plot = plot "<c:axId val=\"" (100000 + d * 10 + 1) "\"/><c:axId val=\"" (100000 + d * 10 + 2) "\"/></c:scatterChart>"
      xscale(TX1[ds], TX2[ds])
      plot = plot valax(100000 + d * 10 + 1, 100000 + d * 10 + 2, "b", XFMT, "", 0, "midCat", XSCL, XMAJ) valax(100000 + d * 10 + 2, 100000 + d * 10 + 1, "l", "General", "接続数", 1, "midCat")
      add_chart(chart_doc(ds " ― 接続数の推移（使用中・アクティブ・アイドル・最大プール）", plot), 0, base, 16, base + 18)
      if ((ds in HF) && HV[ds] + 0 > 0) {
        h1 = HF[ds]; h2 = HL[ds]; x = rng(hrname, CM["hourly", "bucket_start"], h1, h2)
        plot = "<c:lineChart><c:grouping val=\"standard\"/><c:varyColors val=\"0\"/>"
        plot = plot ser_ln(0, "使用中 最大", x, rng(hrname, CM["hourly", "in_use_max"], h1, h2), "000000", 22225, "solid", 1)
        plot = plot ser_ln(1, "使用中 平均", x, rng(hrname, CM["hourly", "in_use_avg"], h1, h2), "595959", 15875, "dash", 0)
        plot = plot ser_ln(2, "使用中 最小", x, rng(hrname, CM["hourly", "in_use_min"], h1, h2), "A6A6A6", 15875, "sysDot", 0)
        plot = plot ser_ln(3, "最大プールサイズ", x, rng(hrname, CM["hourly", "max_pool_size"], h1, h2), "000000", 12700, "lgDash", 0)
        plot = plot "<c:marker val=\"1\"/><c:axId val=\"" (200000 + d * 10 + 1) "\"/><c:axId val=\"" (200000 + d * 10 + 2) "\"/></c:lineChart>"
        plot = plot catax(200000 + d * 10 + 1, 200000 + d * 10 + 2, "m/d hh:mm") valax(200000 + d * 10 + 2, 200000 + d * 10 + 1, "l", "General", "接続数", 1, "between")
        add_chart(chart_doc(ds " ― 時間別 使用中接続数（最大・平均・最小）", plot), 0, base + 19, 8, base + 37)
        plot = "<c:barChart><c:barDir val=\"col\"/><c:grouping val=\"clustered\"/><c:varyColors val=\"0\"/>"
        plot = plot ser_bar(0, "待ち発生", x, rng(hrname, CM["hourly", "wait_delta"], h1, h2), "A6A6A6", "7F7F7F")
        plot = plot ser_bar(1, "取得失敗", x, rng(hrname, CM["hourly", "blocking_failure_delta"], h1, h2), "262626", "000000")
        plot = plot ser_bar(2, "枯渇サンプル", x, rng(hrname, CM["hourly", "exhausted_samples"], h1, h2), "E0E0E0", "7F7F7F")
        plot = plot "<c:gapWidth val=\"60\"/><c:axId val=\"" (300000 + d * 10 + 1) "\"/><c:axId val=\"" (300000 + d * 10 + 2) "\"/></c:barChart>"
        plot = plot catax(300000 + d * 10 + 1, 300000 + d * 10 + 2, "m/d hh:mm") valax(300000 + d * 10 + 2, 300000 + d * 10 + 1, "l", "General", "回数／サンプル数", 1, "between")
        add_chart(chart_doc(ds " ― 時間別 待ち発生・取得失敗・枯渇", plot), 8, base + 19, 16, base + 37)
      }
      base += 39
    } else {
      printf "%s", row(base + 1, strc("A" (base + 1), "有効な統計データがないため、グラフは作成していません。", S_NOTE2), 0)
      base += 3
    }
  }
  if (XL + 0 > XF + 0 && CM["ctx", "io_busy_task_threads"] != "") {
    if (nds > 0) { BRK = BRK "<brk id=\"" (base - 1) "\" max=\"16383\" man=\"1\"/>"; NBRK++ }
    printf "%s", row(base, strc("A" base, "■ JVM・リクエスト処理スレッド", S_HEAD), 21)
    x = rng(cxname, CM["ctx", "timestamp"], XF, XL)
    plot = "<c:scatterChart><c:scatterStyle val=\"lineMarker\"/><c:varyColors val=\"0\"/>"
    plot = plot ser_sc(0, "IO ワーカー 処理中", x, rng(cxname, CM["ctx", "io_busy_task_threads"], XF, XL), "000000", 19050, "solid")
    plot = plot ser_sc(1, "IO ワーカー 最大", x, rng(cxname, CM["ctx", "io_max_task_threads"], XF, XL), "000000", 12700, "lgDash")
    if (CM["ctx", "ds_in_use_total"] != "") plot = plot ser_sc(2, "接続 使用中（全データソース）", x, rng(cxname, CM["ctx", "ds_in_use_total"], XF, XL), "7F7F7F", 15875, "dash")
    plot = plot "<c:axId val=\"900001\"/><c:axId val=\"900002\"/></c:scatterChart>"
    xscale(XX1, XX2)
    plot = plot valax(900001, 900002, "b", XFMT, "", 0, "midCat", XSCL, XMAJ) valax(900002, 900001, "l", "General", "スレッド数／接続数", 1, "midCat")
    add_chart(chart_doc("リクエスト処理スレッド（IO ワーカー）と接続使用数", plot), 0, base, 16, base + 18)
    base += 20
  }
  if (nds == 0) printf "%s", row(4, strc("A4", "（グラフに使用できる時系列データがありません）", S_NOTE2), 0)
  printf "</sheetData>"
  printf "%s", ws_end("landscape", 0, (NCH > 0), 75, (NBRK > 0 ? "<rowBreaks count=\"" NBRK "\" manualBreakCount=\"" NBRK "\">" BRK "</rowBreaks>" : ""))
  if (NCH > 0) {
    f = outdir "/drawings/drawing1.xml"
    printf "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<xdr:wsDr xmlns:xdr=\"http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\">%s</xdr:wsDr>", ANCH > f
    close(f)
    f = outdir "/drawings/_rels/drawing1.xml.rels"
    printf "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">%s</Relationships>", RELS > f
    close(f)
  }
  print NCH > (aux "/charts.txt")
  defname("_xlnm.Print_Area", "'" sheetname "'!$A$1:$P$" (base > 4 ? base - 1 : 4))
}
AWK

#------------------------------------------------------------------------------
# シート生成
#------------------------------------------------------------------------------
PKG="$WORK/pkg"
mkdir -p "$PKG/_rels" "$PKG/docProps" "$PKG/xl/_rels" "$PKG/xl/worksheets/_rels" "$PKG/xl/drawings/_rels" "$PKG/xl/charts" || die "作業ディレクトリを作成できません"
: > "$WORK/colmap.txt"; : > "$WORK/ranges.txt"; : > "$WORK/defnames.txt"

SHEET_NAMES=("サマリー" "グラフ" "時間別推移" "枯渇イベント" "待機スレッド" "時系列データ" "JVM・スレッド" "設定情報" "凡例")
NOW_STR=$(date '+%Y-%m-%d %H:%M')

xl() { awk -f "$WORK/xl.awk" -v defs="$WORK/defs.txt" -v aux="$WORK" -v nowstr="$NOW_STR" -v reptitle="$TITLE" "$@"; }

table() {  # idx table csv title note groupkey statuskey freeze
  local idx=$1
  xl -v mode=table -v sheetidx="$idx" -v sheetname="${SHEET_NAMES[idx-1]}" -v table="$2" -v infile="$3" \
     -v title="$4" -v note="$5" -v groupkey="$6" -v statuskey="$7" -v freeze="$8" -v maxrows="$MAX_ROWS" \
     > "$PKG/xl/worksheets/sheet$idx.xml" || die "シート ${SHEET_NAMES[idx-1]} の作成に失敗しました"
}

info "入力: $SRC"
info "時系列データを変換しています..."
table 6 ts "$SRC/ds_pool_timeseries.csv" "時系列データ（サンプル × データソース）" \
  "データソースごとに時刻順で並べています。判定に応じて行を濃淡表示（高使用率→待ち発生→枯渇→取得失敗の順に濃く）。詳細列は列見出し上部の［＋］で展開できます。" \
  ds_name status 3
table 3 hourly "$SRC/ds_pool_hourly.csv" "時間別推移（集計単位ごとの 最大・平均・最小）" \
  "使用中・アクティブ・アイドルの推移と、各時間帯の枯渇・待ち・取得失敗の件数です。「最悪判定」はその時間帯で最も重い判定です。" \
  ds_name worst_status 2
table 7 ctx "$SRC/ds_pool_context.csv" "JVM・スレッド・トランザクション" \
  "接続枯渇時はリクエスト処理スレッド（IO ワーカー）が接続待ちで滞留しやすくなります。接続プールの推移と合わせて確認してください。" \
  "" "" 1
table 4 events "$SRC/ds_pool_events.csv" "枯渇・待ちイベント（連続区間）" \
  "待ち発生・枯渇・取得失敗が連続したサンプルを 1 イベントとしています。継続時間はサンプル間隔からの概算です。" \
  "" severity 0
table 5 waiters "$SRC/ds_pool_waiters.csv" "接続待ちスレッドの待機元（アプリケーションのフレーム）" \
  "dump-queued-threads-in-pool で取得した、接続を待っていたスレッドのスタックから、最初に現れるアプリケーションのフレームを集計しています（スタック全体は queued_threads/ を参照）。" \
  "" "" 0
xl -v mode=summary -v sheetidx=1 -v sheetname="${SHEET_NAMES[0]}" -v title="$TITLE" -v srcname="$SRC_NAME" \
   -v sumfile="$SRC/ds_pool_summary.csv" -v metafile="$SRC/ds_pool_meta.csv" > "$PKG/xl/worksheets/sheet1.xml" || die "サマリーシートの作成に失敗しました"
xl -v mode=config -v sheetidx=8 -v sheetname="${SHEET_NAMES[7]}" -v title="設定情報（データソース・JDBC ドライバー・JCA）" \
   -v note="収集開始時点の設定です。パスワード等はマスクしています。「（既定値）」はサーバーで未設定（IronJacamar の既定値が適用）の項目、「－」は未設定です。" \
   -v infile="$SRC/ds_pool_config.csv" > "$PKG/xl/worksheets/sheet8.xml" || die "設定情報シートの作成に失敗しました"
xl -v mode=legend -v sheetidx=9 -v sheetname="${SHEET_NAMES[8]}" -v title="凡例・用語の説明" \
   -v note="判定・項目・所見コードの定義です。" > "$PKG/xl/worksheets/sheet9.xml" || die "凡例シートの作成に失敗しました"
info "グラフを作成しています..."
xl -v mode=charts -v sheetidx=2 -v sheetname="${SHEET_NAMES[1]}" -v title="グラフ（接続プールの推移）" \
   -v note="モノトーン表示のため線の種類で区別しています（実線＝使用中／最大、破線＝アクティブ／平均、点線＝アイドル／最小、長破線＝最大プールサイズ）。" \
   -v colmap="$WORK/colmap.txt" -v ranges="$WORK/ranges.txt" -v sumfile="$SRC/ds_pool_summary.csv" -v outdir="$PKG/xl" \
   -v tsname="${SHEET_NAMES[5]}" -v hrname="${SHEET_NAMES[2]}" -v cxname="${SHEET_NAMES[6]}" \
   > "$PKG/xl/worksheets/sheet2.xml" || die "グラフシートの作成に失敗しました"
NCHART=$(cat "$WORK/charts.txt" 2>/dev/null); [[ $NCHART =~ ^[0-9]+$ ]] || NCHART=0
write_styles "$PKG/xl/styles.xml"

#------------------------------------------------------------------------------
# パッケージ部品（workbook / rels / content types / docProps）
#------------------------------------------------------------------------------
xml_esc() { local s=$1; s=${s//&/&amp;}; s=${s//</&lt;}; s=${s//>/&gt;}; s=${s//\"/&quot;}; printf '%s' "$s"; }
{
  printf '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
  printf '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
  printf '<workbookPr/><bookViews><workbookView xWindow="0" yWindow="0" windowWidth="28800" windowHeight="15600" tabRatio="850" activeTab="0"/></bookViews><sheets>'
  for i in "${!SHEET_NAMES[@]}"; do
    printf '<sheet name="%s" sheetId="%d" r:id="rId%d"/>' "$(xml_esc "${SHEET_NAMES[i]}")" $((i + 1)) $((i + 1))
  done
  printf '</sheets>'
  if [[ -s $WORK/defnames.txt ]]; then
    printf '<definedNames>'
    sort -t "$(printf '\t')" -k2,2 -k1,1n "$WORK/defnames.txt" | while IFS=$'\t' read -r sid nm ref; do
      if [[ $nm == _xlnm._FilterDatabase ]]; then
        printf '<definedName name="%s" localSheetId="%s" hidden="1">%s</definedName>' "$nm" "$sid" "$(xml_esc "$ref")"
      else
        printf '<definedName name="%s" localSheetId="%s">%s</definedName>' "$nm" "$sid" "$(xml_esc "$ref")"
      fi
    done
    printf '</definedNames>'
  fi
  printf '<calcPr calcId="191029"/></workbook>'
} > "$PKG/xl/workbook.xml"

{
  printf '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
  for i in "${!SHEET_NAMES[@]}"; do
    printf '<Relationship Id="rId%d" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet%d.xml"/>' $((i + 1)) $((i + 1))
  done
  printf '<Relationship Id="rId%d" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>' $(( ${#SHEET_NAMES[@]} + 1 ))
  printf '</Relationships>'
} > "$PKG/xl/_rels/workbook.xml.rels"

if (( NCHART > 0 )); then
  printf '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/drawing" Target="../drawings/drawing1.xml"/></Relationships>' > "$PKG/xl/worksheets/_rels/sheet2.xml.rels"
fi

{
  printf '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
  printf '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>'
  printf '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
  for i in "${!SHEET_NAMES[@]}"; do
    printf '<Override PartName="/xl/worksheets/sheet%d.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' $((i + 1))
  done
  printf '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
  if (( NCHART > 0 )); then
    printf '<Override PartName="/xl/drawings/drawing1.xml" ContentType="application/vnd.openxmlformats-officedocument.drawing+xml"/>'
    for ((i = 1; i <= NCHART; i++)); do
      printf '<Override PartName="/xl/charts/chart%d.xml" ContentType="application/vnd.openxmlformats-officedocument.drawingml.chart+xml"/>' "$i"
    done
  fi
  printf '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
  printf '<Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>'
  printf '</Types>'
} > "$PKG/[Content_Types].xml"

printf '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>' > "$PKG/_rels/.rels"

W3C=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
printf '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>%s</dc:title><dc:subject>%s</dc:subject><dc:creator>ds_pool_csv2xlsx.sh</dc:creator><cp:lastModifiedBy>ds_pool_csv2xlsx.sh</cp:lastModifiedBy><dcterms:created xsi:type="dcterms:W3CDTF">%s</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">%s</dcterms:modified></cp:coreProperties>' \
  "$(xml_esc "$TITLE")" "$(xml_esc "$SRC_NAME")" "$W3C" "$W3C" > "$PKG/docProps/core.xml"
printf '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Application>ds_pool_csv2xlsx.sh %s</Application></Properties>' "$VERSION" > "$PKG/docProps/app.xml"

#------------------------------------------------------------------------------
# xlsx（zip）の作成: zip → python3 → gzip（シェルのみ）の順に利用
#------------------------------------------------------------------------------
PARTS=("[Content_Types].xml" "_rels/.rels" "docProps/core.xml" "docProps/app.xml" "xl/workbook.xml" "xl/_rels/workbook.xml.rels" "xl/styles.xml")
for i in "${!SHEET_NAMES[@]}"; do PARTS+=("xl/worksheets/sheet$((i + 1)).xml"); done
if (( NCHART > 0 )); then
  PARTS+=("xl/worksheets/_rels/sheet2.xml.rels" "xl/drawings/drawing1.xml" "xl/drawings/_rels/drawing1.xml.rels")
  for ((i = 1; i <= NCHART; i++)); do PARTS+=("xl/charts/chart$i.xml"); done
fi

le16() { printf "\\x$(printf %02x $(( $1 & 255 )))\\x$(printf %02x $(( ($1 >> 8) & 255 )))"; }
le32() { le16 $(( $1 & 65535 )); le16 $(( ($1 >> 16) & 65535 )); }
zip_shell() {  # out
  local out=$1 f usize gsize csize crc off=0 n=0 cdsize b tmp="$WORK/z.gz" cd="$WORK/z.cd" dt dd
  command -v gzip >/dev/null 2>&1 || return 1
  dt=$(( (10#$(date +%H) << 11) | (10#$(date +%M) << 5) | (10#$(date +%S) / 2) ))
  dd=$(( ((10#$(date +%Y) - 1980) << 9) | (10#$(date +%m) << 5) | 10#$(date +%d) ))
  : > "$out"; : > "$cd"
  for f in "${PARTS[@]}"; do
    usize=$(wc -c < "$PKG/$f"); usize=${usize//[^0-9]/}
    gzip -c -n -6 < "$PKG/$f" > "$tmp" || return 1
    gsize=$(wc -c < "$tmp"); gsize=${gsize//[^0-9]/}
    csize=$((gsize - 18))
    read -r -a b <<< "$(tail -c 8 "$tmp" | od -An -tu1)"
    crc=$(( b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24) ))
    { le32 $((0x04034b50)); le16 20; le16 0; le16 8; le16 "$dt"; le16 "$dd"; le32 "$crc"; le32 "$csize"; le32 "$usize"; le16 ${#f}; le16 0; printf '%s' "$f"; } >> "$out"
    tail -c +11 "$tmp" | head -c "$csize" >> "$out"
    { le32 $((0x02014b50)); le16 20; le16 20; le16 0; le16 8; le16 "$dt"; le16 "$dd"; le32 "$crc"; le32 "$csize"; le32 "$usize"; le16 ${#f}; le16 0; le16 0; le16 0; le16 0; le32 0; le32 "$off"; printf '%s' "$f"; } >> "$cd"
    off=$((off + 30 + ${#f} + csize))
    n=$((n + 1))
  done
  cdsize=$(wc -c < "$cd"); cdsize=${cdsize//[^0-9]/}
  cat "$cd" >> "$out"
  { le32 $((0x06054b50)); le16 0; le16 0; le16 "$n"; le16 "$n"; le32 "$cdsize"; le32 "$off"; le16 0; } >> "$out"
}
zip_python() {  # out
  local py
  py=$(command -v python3 || command -v python || command -v /usr/libexec/platform-python) || return 1
  "$py" - "$PKG" "$1" "${PARTS[@]}" <<'PY'
import os, sys, zipfile
pkg, out, parts = sys.argv[1], sys.argv[2], sys.argv[3:]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for p in parts:
        z.write(os.path.join(pkg, p), p)
PY
}
zip_cmd() {  # out
  command -v zip >/dev/null 2>&1 || return 1
  (cd "$PKG" && zip -q -X -D "$1" "${PARTS[@]}")
}

TMP_XLSX="$WORK/out.xlsx"
rm -f "$TMP_XLSX"
ok=0
case $ZIP_METHOD in
  zip) zip_cmd "$TMP_XLSX" && ok=1 ;;
  python) zip_python "$TMP_XLSX" && ok=1 ;;
  shell) zip_shell "$TMP_XLSX" && ok=1 ;;
  auto)
    if zip_cmd "$TMP_XLSX"; then ok=1; USED=zip
    elif rm -f "$TMP_XLSX" && zip_python "$TMP_XLSX"; then ok=1; USED=python3
    elif rm -f "$TMP_XLSX" && zip_shell "$TMP_XLSX"; then ok=1; USED=gzip
    fi ;;
esac
(( ok )) || die "xlsx（zip）を作成できませんでした（zip / python3 / gzip のいずれかが必要です）"
mv -f "$TMP_XLSX" "$OUTPUT_ABS" || die "出力ファイルを書き込めません: $OUTPUT_ABS"
info "作成しました: $OUTPUT_ABS （シート ${#SHEET_NAMES[@]}、グラフ $NCHART${USED:+、圧縮: $USED}）"
