<#
.SYNOPSIS
    ds_pool_collector.sh が出力した CSV を Excel レポート (.xlsx) に変換します（Windows 11 / PowerShell 5.1・7）。

.DESCRIPTION
    ・フォント Meiryo UI、モノトーン（黒・グレー）配色
    ・日時/数値/割合/時間の表示形式、列幅、ウィンドウ枠の固定、オートフィルター、
      判定に応じた濃淡（条件付き書式）、詳細列のグループ化、印刷設定（A4 横・見出し行の繰り返し）
    ・グラフ: 接続数の推移 / 時間別 最大・平均・最小 / 時間別 待ち・取得失敗 / ワーカースレッド
    ・Excel のインストールは不要です（Office Open XML を直接生成します）
    ・RHEL 版（ds_pool_csv2xlsx.sh）と同じレイアウトのブックを作成します

    ※ 保存時の文字コードは UTF-8（BOM 付き・なしのどちらでも可）または ANSI(Shift_JIS) で動作します。
      メモ帳に貼り付けて「名前を付けて保存」した場合もそのまま実行できます。

.PARAMETER InputPath
    次のいずれか
      ・収集結果ディレクトリ（ds_pool_*.csv を含む）
      ・ds_pool_bundle.txt（収集終了時に作成されるバンドル）
      ・ds_pool_collector.sh --export / --export-gz の出力を保存したファイル（前後に余計な行があっても可）
      ・ds_pool_timeseries.csv（同じディレクトリの他の CSV も使用）

.PARAMETER OutputPath
    出力する .xlsx。省略時は <入力名>.xlsx をカレントディレクトリに作成します。

.PARAMETER Title
    レポートのタイトル（既定: データソース接続プール 使用状況レポート）。

.PARAMETER MaxRows
    時系列シートの最大行数（既定: 1000000）。

.PARAMETER Open
    作成後に既定のアプリケーション（Excel）で開きます。

.PARAMETER PurePowerShell
    大きな表の出力に C#（Add-Type）を使わず、PowerShell だけで処理します（低速。通常は不要）。
    Add-Type が禁止されている環境では、指定しなくても自動でこの方式になります。

.EXAMPLE
    .\Convert-DsPoolCsvToXlsx.ps1 -InputPath .\ds_pool_bundle.txt

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Convert-DsPoolCsvToXlsx.ps1 .\dspool_host_20261019_090000 -OutputPath .\report.xlsx -Open
#>
#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$InputPath,
    [Parameter(Position = 1)][string]$OutputPath = '',
    [string]$Title = '',
    [int]$MaxRows = 1000000,
    [switch]$Open,
    [switch]$PurePowerShell
)

#------------------------------------------------------------------------------
# Bootstrap (ASCII only).
# Windows PowerShell 5.1 reads a .ps1 saved without a BOM in the ANSI code page
# (CP932 on Japanese Windows) and the Japanese text in the program would break it.
# The program is therefore kept in the block comment below and is read back from
# this file with the right encoding: UTF-8 (with or without BOM), otherwise ANSI.
#------------------------------------------------------------------------------
if (-not $PSCommandPath) { throw 'Run this script from a saved .ps1 file (e.g. powershell -ExecutionPolicy Bypass -File .\Convert-DsPoolCsvToXlsx.ps1 ...).' }
try {
    $BootText = [IO.File]::ReadAllText($PSCommandPath, (New-Object System.Text.UTF8Encoding($false, $true)))
} catch {
    $BootText = [IO.File]::ReadAllText($PSCommandPath, [System.Text.Encoding]::Default)
}
$BootMain = [regex]::Match($BootText, '(?s)<#DSPOOL-MAIN\r?\n(.*?)\r?\nDSPOOL-MAIN#>')
if (-not $BootMain.Success) { throw 'The program block (<#DSPOOL-MAIN ... DSPOOL-MAIN#>) was not found. Copy the whole script again.' }
& ([ScriptBlock]::Create($BootMain.Groups[1].Value)) @PSBoundParameters
return

<#DSPOOL-MAIN
[CmdletBinding()]
param(
    [string]$InputPath,
    [string]$OutputPath = '',
    [string]$Title = '',
    [int]$MaxRows = 1000000,
    [switch]$Open,
    [switch]$PurePowerShell
)
if (-not $Title) { $Title = 'データソース接続プール 使用状況レポート' }
$ErrorActionPreference = 'Stop'
$Version = '1.0.0'
Add-Type -AssemblyName System.IO.Compression

$Inv = [Globalization.CultureInfo]::InvariantCulture
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$NumRe = [regex]'^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$'
$DateRe = [regex]'^[0-9]{4}-[0-9]{2}-[0-9]{2}'
$XmlNeedRe = [regex]'[&<>"\x01-\x08\x0B\x0C\x0E-\x1F]'
$CtlRe = [regex]'[\x01-\x08\x0B\x0C\x0E-\x1F]'

function Write-Info([string]$Message) { Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message) }

#------------------------------------------------------------------------------
# 共通定義（列の表示名・書式、所見テンプレート、凡例）※ RHEL 版と同一
#------------------------------------------------------------------------------
$DefsText = @'
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
'@

$StylesXml = @'
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
'@

#------------------------------------------------------------------------------
# スタイル番号（styles.xml の cellXfs の並び）
#------------------------------------------------------------------------------
$S_TITLE = 1; $S_NOTE = 2; $S_SEC = 3; $S_HDR = 4; $S_BAND = 5; $S_KEY = 6; $S_TEXT = 7; $S_TEXTC = 8
$S_INT = 9; $S_DEC1 = 10; $S_PCT = 11; $S_DT = 12; $S_DTM = 13; $S_DUR = 14; $S_NUM = 15; $S_LABEL = 16; $S_SECROW = 17
$S_V4 = 18; $S_V3 = 19; $S_V2 = 20; $S_V1 = 21; $S_V0 = 22; $S_VM = 23; $S_WRAP = 24; $S_NOTE2 = 25; $S_HEAD = 26; $S_MUTED = 27; $S_TEXTW = 28
$FMTS = @{ text = $S_TEXT; int = $S_INT; dec1 = $S_DEC1; pct = $S_PCT; dt = $S_DT; dtm = $S_DTM; dur = $S_DUR; num = $S_NUM; bool = $S_TEXTC; status = $S_TEXTC; auto = $S_TEXT }
$SL = @{ OK = '正常'; HIGH = '高使用率'; WAIT = '待ち発生'; EXHAUSTED = '枯渇'; FAILURE = '取得失敗'; STATS_OFF = '統計無効'; DISABLED = 'DS無効'; NO_POOL = 'プール未取得'; ERROR = '取得エラー'; NO_DATA = 'データなし' }
$ValidStatus = @{ OK = 1; HIGH = 1; WAIT = 1; EXHAUSTED = 1; FAILURE = 1 }
$NS = 'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"'
$FONT = '<a:latin typeface="Meiryo UI"/><a:ea typeface="Meiryo UI"/><a:cs typeface="Meiryo UI"/>'

$COLN = New-Object 'string[]' 729
for ($i = 1; $i -le 728; $i++) {
    $n = $i; $s = ''
    while ($n -gt 0) { $rem = ($n - 1) % 26; $s = [string][char](65 + $rem) + $s; $n = [int][Math]::Floor(($n - 1) / 26) }
    $COLN[$i] = $s
}

#------------------------------------------------------------------------------
# 定義の読み込み
#------------------------------------------------------------------------------
$CD = @{}
$SUMO = New-Object System.Collections.Generic.List[object]
$SUMV = New-Object System.Collections.Generic.List[object]
$INFO = New-Object System.Collections.Generic.List[object]
$TM = @{}
$LEG = New-Object System.Collections.Generic.List[string]
foreach ($ln in ($DefsText -split "`r?`n")) {
    if ($ln -eq '' -or $ln.StartsWith('#')) { continue }
    $a = $ln.Split('|')
    if ($a[0] -eq 'sumo' -or $a[0] -eq 'sumv') {
        $item = @($a[1], $a[2], $a[4])
        if ($a[0] -eq 'sumo') { $SUMO.Add($item) } else { $SUMV.Add($item) }
        continue
    }
    if ($a[0] -eq 'info') { $INFO.Add(@($a[1], $ln.Substring($a[0].Length + $a[1].Length + 2))); continue }
    if ($a[0] -eq 'tmpl') { $TM[$a[1]] = $ln.Substring($a[0].Length + $a[1].Length + 2); continue }
    if ($a[0] -eq 'legend') { $LEG.Add($ln.Substring(7)); continue }
    if ($a.Length -ge 6) {
        $grp = 0; if ($a.Length -ge 7 -and $a[6] -ne '') { $grp = [int]$a[6] }
        $CD[$a[0] + '|' + $a[1]] = @($a[2], $a[3], $a[4], $a[5], $grp)
    }
}

#------------------------------------------------------------------------------
# 共通関数
#------------------------------------------------------------------------------
function X([string]$s) {
    if ([string]::IsNullOrEmpty($s) -or -not $XmlNeedRe.IsMatch($s)) { return $s }
    $s = $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
    return $CtlRe.Replace($s, '')
}
function Split-Csv([string]$line) {
    if ($line.IndexOf([char]34) -lt 0) { return , $line.Split(',') }
    $list = New-Object System.Collections.Generic.List[string]
    $sb = New-Object System.Text.StringBuilder
    $inq = $false; $n = $line.Length
    for ($i = 0; $i -lt $n; $i++) {
        $ch = $line[$i]
        if ($inq) {
            if ($ch -eq [char]34) {
                if ($i + 1 -lt $n -and $line[$i + 1] -eq [char]34) { [void]$sb.Append([char]34); $i++ } else { $inq = $false }
            } else { [void]$sb.Append($ch) }
        } elseif ($ch -eq [char]34) { $inq = $true }
        elseif ($ch -eq [char]44) { $list.Add($sb.ToString()); [void]$sb.Clear() }
        else { [void]$sb.Append($ch) }
    }
    $list.Add($sb.ToString())
    return , $list.ToArray()
}
function F10([double]$d) { return $d.ToString('F10', $Inv) }
function SubNum([string]$s, [int]$start, [int]$len) {
    if ($s.Length -le $start) { return 0 }
    if ($start + $len -gt $s.Length) { $len = $s.Length - $start }
    $t = $s.Substring($start, $len)
    $m = [regex]::Match($t, '^\s*[0-9]+')
    if ($m.Success) { return [int]$m.Value.Trim() } else { return 0 }
}
function DaysCivil([long]$y, [long]$m, [long]$d) {
    if ($m -le 2) { $y -= 1 }
    $era = $(if ($y -ge 0) { $y } else { $y - 399 }); $era = [long][Math]::Truncate($era / 400)
    $yoe = $y - $era * 400
    $mp = $(if ($m -gt 2) { $m - 3 } else { $m + 9 })
    $doy = [long][Math]::Truncate((153 * $mp + 2) / 5) + $d - 1
    $doe = $yoe * 365 + [long][Math]::Truncate($yoe / 4) - [long][Math]::Truncate($yoe / 100) + $doy
    return $era * 146097 + $doe - 719468
}
function XDate([string]$s) {
    if ($null -eq $s -or -not $DateRe.IsMatch($s)) { return '' }
    $days = DaysCivil (SubNum $s 0 4) (SubNum $s 5 2) (SubNum $s 8 2)
    $sec = (SubNum $s 11 2) * 3600 + (SubNum $s 14 2) * 60 + (SubNum $s 17 2)
    return F10 ([double]$days + 25569 + $sec / 86400.0)
}
function StrC([string]$ref, [string]$s, [int]$st) { return '<c r="' + $ref + '" s="' + $st + '" t="inlineStr"><is><t xml:space="preserve">' + (X $s) + '</t></is></c>' }
function NumC([string]$ref, [string]$v, [int]$st) { return '<c r="' + $ref + '" s="' + $st + '"><v>' + $v + '</v></c>' }
function EmptyC([string]$ref, [int]$st) { return '<c r="' + $ref + '" s="' + $st + '"/>' }
function SLabel([string]$v) { if ($SL.ContainsKey($v)) { return $SL[$v] } return $v }
function VStyle([string]$v) {
    switch -CaseSensitive ($v) { 'FAILURE' { return $S_V4 } 'EXHAUSTED' { return $S_V3 } 'WAIT' { return $S_V2 } 'HIGH' { return $S_V1 } 'OK' { return $S_V0 } }
    return $S_VM
}
function CellX([string]$ref, [string]$fmt, [string]$v) {
    if ($fmt -eq 'verdict') { if ($v -eq '') { return EmptyC $ref $S_V0 }; return StrC $ref (SLabel $v) (VStyle $v) }
    if ($v -eq '') { if ($FMTS.ContainsKey($fmt)) { return EmptyC $ref $FMTS[$fmt] }; return EmptyC $ref $S_TEXT }
    switch -CaseSensitive ($fmt) {
        { $_ -eq 'dt' -or $_ -eq 'dtm' } { $x = XDate $v; if ($x -ne '') { return NumC $ref $x $FMTS[$fmt] }; return StrC $ref $v $S_TEXT }
        { $_ -eq 'int' -or $_ -eq 'dec1' -or $_ -eq 'num' } { if ($NumRe.IsMatch($v)) { return NumC $ref $v $FMTS[$fmt] }; return StrC $ref $v $S_TEXT }
        'pct' { if ($NumRe.IsMatch($v)) { return NumC $ref (([double]::Parse($v, $Inv) / 100).ToString('F6', $Inv)) $S_PCT }; return StrC $ref $v $S_TEXT }
        'dur' { if ($NumRe.IsMatch($v)) { return NumC $ref (F10 ([double]::Parse($v, $Inv) / 86400)) $S_DUR }; return StrC $ref $v $S_TEXT }
        'bool' { $b = $v; if ($v -ceq 'true') { $b = '有効' } elseif ($v -ceq 'false') { $b = '無効' }; return StrC $ref $b $S_TEXTC }
        'status' { return StrC $ref (SLabel $v) $S_TEXTC }
        'auto' { if ($NumRe.IsMatch($v)) { return NumC $ref $v $S_TEXT }; return StrC $ref $v $S_TEXT }
    }
    return StrC $ref $v $S_TEXT
}
function Row([int]$r, [string]$cells, [double]$ht) {
    if ($ht -gt 0) { return '<row r="' + $r + '" ht="' + $ht.ToString($Inv) + '" customHeight="1">' + $cells + '</row>' }
    return '<row r="' + $r + '">' + $cells + '</row>'
}
function Units([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return 0.0 }
    $nb = $Utf8.GetByteCount($s); $asc = 0
    foreach ($ch in $s.ToCharArray()) { if ([int]$ch -lt 128) { $asc++ } }
    $na = $nb - $asc
    return ($nb - $na) + $na / 3 * 2
}
function WrapHt([string]$s, [double]$width) { $l = [Math]::Truncate((Units $s) / ($width * 0.95)) + 1; return $l * 15 + 3 }
function Ws-Begin([string]$tab, [bool]$fit, [bool]$outline, [int]$xs, [int]$ys, [int]$sheetIdx) {
    $s = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + "`n" + '<worksheet ' + $NS + '>'
    $s += '<sheetPr><tabColor rgb="' + $tab + '"/><outlinePr summaryBelow="0" summaryRight="0"/>' + $(if ($fit) { '<pageSetUpPr fitToPage="1"/>' } else { '' }) + '</sheetPr>'
    $s += '<sheetViews><sheetView' + $(if ($sheetIdx -eq 1) { ' tabSelected="1"' } else { '' }) + ' zoomScale="90" zoomScaleNormal="90" workbookViewId="0">'
    if ($xs -gt 0 -or $ys -gt 0) {
        $tl = $COLN[$xs + 1] + ($ys + 1)
        $pane = $(if ($xs -gt 0 -and $ys -gt 0) { 'bottomRight' } elseif ($ys -gt 0) { 'bottomLeft' } else { 'topRight' })
        $s += '<pane' + $(if ($xs -gt 0) { ' xSplit="' + $xs + '"' } else { '' }) + $(if ($ys -gt 0) { ' ySplit="' + $ys + '"' } else { '' }) + ' topLeftCell="' + $tl + '" activePane="' + $pane + '" state="frozen"/>'
        $s += '<selection pane="' + $pane + '" activeCell="' + $tl + '" sqref="' + $tl + '"/>'
    } else { $s += '<selection activeCell="A1" sqref="A1"/>' }
    $s += '</sheetView></sheetViews><sheetFormatPr defaultRowHeight="15"' + $(if ($outline) { ' outlineLevelCol="1"' } else { '' }) + '/>'
    return $s
}
function Ws-End([string]$orient, [bool]$fit, [bool]$drawing, [int]$scale, [string]$brks, [string]$repTitle) {
    $s = '<pageMargins left="0.4" right="0.4" top="0.6" bottom="0.6" header="0.3" footer="0.3"/>'
    $s += '<pageSetup paperSize="9"' + $(if ($scale -gt 0) { ' scale="' + $scale + '"' } else { '' }) + ' orientation="' + $orient + '"' + $(if ($fit) { ' fitToWidth="1" fitToHeight="0"' } else { '' }) + '/>'
    $hf = '&L&"Meiryo UI,Regular"&9' + $repTitle + '&R&"Meiryo UI,Regular"&9&A'
    $s += '<headerFooter><oddHeader>' + (X $hf) + '</oddHeader><oddFooter>' + (X '&C&"Meiryo UI,Regular"&9&P / &N') + '</oddFooter></headerFooter>'
    if ($brks -ne '') { $s += $brks }
    if ($drawing) { $s += '<drawing r:id="rId1"/>' }
    return $s + '</worksheet>'
}
function Cf-Rules([string]$sq, [string]$ref) {
    $s = '<conditionalFormatting sqref="' + $sq + '">'
    $s += '<cfRule type="expression" dxfId="0" priority="1" stopIfTrue="1"><formula>' + (X ($ref + '="' + $SL['FAILURE'] + '"')) + '</formula></cfRule>'
    $s += '<cfRule type="expression" dxfId="1" priority="2" stopIfTrue="1"><formula>' + (X ($ref + '="' + $SL['EXHAUSTED'] + '"')) + '</formula></cfRule>'
    $s += '<cfRule type="expression" dxfId="2" priority="3" stopIfTrue="1"><formula>' + (X ($ref + '="' + $SL['WAIT'] + '"')) + '</formula></cfRule>'
    $s += '<cfRule type="expression" dxfId="3" priority="4" stopIfTrue="1"><formula>' + (X ($ref + '="' + $SL['HIGH'] + '"')) + '</formula></cfRule>'
    $r = 'OR(' + $ref + '="' + $SL['STATS_OFF'] + '",' + $ref + '="' + $SL['DISABLED'] + '",' + $ref + '="' + $SL['NO_POOL'] + '",' + $ref + '="' + $SL['ERROR'] + '")'
    $s += '<cfRule type="expression" dxfId="4" priority="5" stopIfTrue="1"><formula>' + (X $r) + '</formula></cfRule>'
    return $s + '</conditionalFormatting>'
}
#------------------------------------------------------------------------------
# 時系列など大きな表の行出力（高速化）: C# で同じ処理を行う。Add-Type が使えない環境では
# PowerShell の処理に自動で切り替わる（出力内容は同一）
#------------------------------------------------------------------------------
$RowWriterCs = @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

public sealed class DsPoolRowResultV1 { public int LastRow; public int Valid; public string Fx = ""; public string Lx = ""; public bool Truncated; }

public static class DsPoolRowWriterV1 {
    static readonly Regex NumRe = new Regex("^-?[0-9]+(\\.[0-9]+)?([eE][-+]?[0-9]+)?$", RegexOptions.Compiled);
    static readonly Regex DateRe = new Regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}", RegexOptions.Compiled);
    static readonly Regex NumPrefix = new Regex("^\\s*[0-9]+", RegexOptions.Compiled);
    static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    static bool IsCtl(char ch) { return (ch >= 1 && ch <= 8) || ch == 11 || ch == 12 || (ch >= 14 && ch <= 31); }
    public static string Esc(string s) {
        if (string.IsNullOrEmpty(s)) return s;
        bool need = false;
        foreach (char ch in s) { if (ch == '&' || ch == '<' || ch == '>' || ch == '"' || IsCtl(ch)) { need = true; break; } }
        if (!need) return s;
        StringBuilder sb = new StringBuilder(s.Length + 16);
        foreach (char ch in s) {
            if (ch == '&') sb.Append("&amp;");
            else if (ch == '<') sb.Append("&lt;");
            else if (ch == '>') sb.Append("&gt;");
            else if (ch == '"') sb.Append("&quot;");
            else if (!IsCtl(ch)) sb.Append(ch);
        }
        return sb.ToString();
    }
    public static string[] SplitCsv(string line) {
        if (line.IndexOf('"') < 0) return line.Split(',');
        List<string> list = new List<string>();
        StringBuilder sb = new StringBuilder();
        bool inq = false; int n = line.Length;
        for (int i = 0; i < n; i++) {
            char ch = line[i];
            if (inq) {
                if (ch == '"') { if (i + 1 < n && line[i + 1] == '"') { sb.Append('"'); i++; } else inq = false; }
                else sb.Append(ch);
            } else if (ch == '"') inq = true;
            else if (ch == ',') { list.Add(sb.ToString()); sb.Length = 0; }
            else sb.Append(ch);
        }
        list.Add(sb.ToString());
        return list.ToArray();
    }
    static int SubNum(string s, int start, int len) {
        if (s.Length <= start) return 0;
        if (start + len > s.Length) len = s.Length - start;
        Match m = NumPrefix.Match(s.Substring(start, len));
        return m.Success ? int.Parse(m.Value.Trim(), Inv) : 0;
    }
    static long DaysCivil(long y, long m, long d) {
        if (m <= 2) y -= 1;
        long era = y >= 0 ? y : y - 399; era = (long)Math.Truncate(era / 400.0);
        long yoe = y - era * 400;
        long mp = m > 2 ? m - 3 : m + 9;
        long doy = (long)Math.Truncate((153 * mp + 2) / 5.0) + d - 1;
        long doe = yoe * 365 + (long)Math.Truncate(yoe / 4.0) - (long)Math.Truncate(yoe / 100.0) + doy;
        return era * 146097 + doe - 719468;
    }
    public static string XDate(string s) {
        if (s == null || !DateRe.IsMatch(s)) return "";
        long days = DaysCivil(SubNum(s, 0, 4), SubNum(s, 5, 2), SubNum(s, 8, 2));
        int sec = SubNum(s, 11, 2) * 3600 + SubNum(s, 14, 2) * 60 + SubNum(s, 17, 2);
        return ((double)days + 25569 + sec / 86400.0).ToString("F10", Inv);
    }
    static void StrC(StringBuilder sb, string r, string v, int st) { sb.Append("<c r=\"").Append(r).Append("\" s=\"").Append(st).Append("\" t=\"inlineStr\"><is><t xml:space=\"preserve\">").Append(Esc(v)).Append("</t></is></c>"); }
    static void NumC(StringBuilder sb, string r, string v, int st) { sb.Append("<c r=\"").Append(r).Append("\" s=\"").Append(st).Append("\"><v>").Append(v).Append("</v></c>"); }
    static string Label(IDictionary<string, string> labels, string v) { string s; return labels.TryGetValue(v, out s) ? s : v; }
    // st: 0=TEXT 1=TEXTC 2=PCT 3=DUR 4=V0 5=V4 6=V3 7=V2 8=V1 9=VM
    static int VStyle(string v, int[] st) { return v == "FAILURE" ? st[5] : v == "EXHAUSTED" ? st[6] : v == "WAIT" ? st[7] : v == "HIGH" ? st[8] : v == "OK" ? st[4] : st[9]; }
    // code: 0 text 1 int/dec1/num 2 pct 3 dt/dtm 4 dur 5 bool 6 status 7 auto 8 verdict
    public static DsPoolRowResultV1 WriteRows(TextWriter w, IList<string> rows, int r, int maxRows, string[] coln, int nc, int[] code, int[] est, int[] nst, int sc, int tc, IDictionary<string, string> labels, IDictionary<string, int> validSet, string boolTrue, string boolFalse, int[] st) {
        DsPoolRowResultV1 res = new DsPoolRowResultV1();
        StringBuilder sb = new StringBuilder(8192);
        foreach (string ln in rows) {
            if (r - 6 >= maxRows) { res.Truncated = true; break; }
            r++;
            string[] F = ln.IndexOf('"') < 0 ? ln.Split(',') : SplitCsv(ln);
            int nf = F.Length;
            if (sc > 0 && sc <= nf && validSet.ContainsKey(F[sc - 1])) res.Valid++;
            if (tc > 0) { res.Lx = XDate(tc <= nf ? F[tc - 1] : ""); if (res.Fx.Length == 0) res.Fx = res.Lx; }
            sb.Length = 0;
            string rs = r.ToString(Inv);
            sb.Append("<row r=\"").Append(rs).Append("\">");
            for (int c = 1; c <= nc; c++) {
                string v = c <= nf ? F[c - 1] : "";
                string rf = coln[c] + rs;
                if (v.Length == 0) { sb.Append("<c r=\"").Append(rf).Append("\" s=\"").Append(code[c] == 8 ? st[4] : est[c]).Append("\"/>"); continue; }
                switch (code[c]) {
                    case 1: if (NumRe.IsMatch(v)) NumC(sb, rf, v, nst[c]); else StrC(sb, rf, v, st[0]); break;
                    case 6: StrC(sb, rf, Label(labels, v), st[1]); break;
                    case 3: { string x = XDate(v); if (x.Length > 0) NumC(sb, rf, x, nst[c]); else StrC(sb, rf, v, st[0]); break; }
                    case 2: if (NumRe.IsMatch(v)) NumC(sb, rf, (double.Parse(v, Inv) / 100).ToString("F6", Inv), st[2]); else StrC(sb, rf, v, st[0]); break;
                    case 4: if (NumRe.IsMatch(v)) NumC(sb, rf, (double.Parse(v, Inv) / 86400).ToString("F10", Inv), st[3]); else StrC(sb, rf, v, st[0]); break;
                    case 5: StrC(sb, rf, v == "true" ? boolTrue : v == "false" ? boolFalse : v, st[1]); break;
                    case 7: if (NumRe.IsMatch(v)) NumC(sb, rf, v, st[0]); else StrC(sb, rf, v, st[0]); break;
                    case 8: StrC(sb, rf, Label(labels, v), VStyle(v, st)); break;
                    default: StrC(sb, rf, v, st[0]); break;
                }
            }
            sb.Append("</row>");
            w.Write(sb.ToString());
        }
        res.LastRow = r;
        return res;
    }
}
'@
$FastRows = $false
if (-not $PurePowerShell) {
    try {
        if (-not ('DsPoolRowWriterV1' -as [type])) { Add-Type -TypeDefinition $RowWriterCs -Language CSharp }
        $LabelDict = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($k in $SL.Keys) { $LabelDict[$k] = $SL[$k] }
        $ValidDict = New-Object 'System.Collections.Generic.Dictionary[string,int]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($k in $ValidStatus.Keys) { $ValidDict[$k] = 1 }
        $StArr = [int[]]@($S_TEXT, $S_TEXTC, $S_PCT, $S_DUR, $S_V0, $S_V4, $S_V3, $S_V2, $S_V1, $S_VM)
        $FastRows = $true
    } catch {
        Write-Warning ('高速化モジュールを使用できないため PowerShell で処理します（時間がかかります）: ' + $_.Exception.Message)
    }
}

$DefNames = New-Object System.Collections.Generic.List[object]
function Add-DefName([int]$sheetIdx, [string]$name, [string]$ref) { $DefNames.Add(@(($sheetIdx - 1), $name, $ref)) }
$ColMap = @{}
$Ranges = New-Object System.Collections.Generic.List[object]

#------------------------------------------------------------------------------
# 入力の解決（ディレクトリ / バンドル / CSV）
#------------------------------------------------------------------------------
$CsvNames = @('ds_pool_meta.csv', 'ds_pool_summary.csv', 'ds_pool_hourly.csv', 'ds_pool_events.csv', 'ds_pool_waiters.csv', 'ds_pool_timeseries.csv', 'ds_pool_context.csv', 'ds_pool_config.csv')
function Get-BundleFiles([string[]]$lines) {
    $files = @{}; $cur = $null; $buf = $null
    foreach ($raw in $lines) {
        $ln = $raw.TrimEnd("`r")
        if ($ln.StartsWith('#DSPOOL-FILE ')) {
            if ($null -ne $cur) { $files[$cur] = $buf.ToArray() }
            $cur = [regex]::Replace($ln.Substring(13), '[^A-Za-z0-9._-]', '_'); $buf = New-Object System.Collections.Generic.List[string]; continue
        }
        if ($ln.StartsWith('#DSPOOL-END')) { if ($null -ne $cur) { $files[$cur] = $buf.ToArray() }; $cur = $null; continue }
        if ($ln.StartsWith('#DSPOOL-BUNDLE ')) { continue }
        if ($null -ne $cur) { $buf.Add($ln) }
    }
    if ($null -ne $cur) { $files[$cur] = $buf.ToArray() }
    return $files
}
function Resolve-Source([string]$path) {
    $full = (Resolve-Path -LiteralPath $path).ProviderPath
    if (Test-Path -LiteralPath $full -PathType Container) {
        $files = @{}
        foreach ($n in $CsvNames) { $p = Join-Path $full $n; if (Test-Path -LiteralPath $p -PathType Leaf) { $files[$n] = [IO.File]::ReadAllLines($p, $Utf8) } }
        return @{ Files = $files; Name = (Split-Path -Leaf $full); Path = $full }
    }
    $lines = [IO.File]::ReadAllLines($full, $Utf8)
    $isGz = $false; $isBundle = $false
    foreach ($l in $lines) { if ($l.StartsWith('#DSPOOL-BUNDLE-GZB64')) { $isGz = $true; break }; if ($l.StartsWith('#DSPOOL-BUNDLE ')) { $isBundle = $true; break } }
    if ($isGz) {
        $b64 = New-Object System.Text.StringBuilder; $on = $false
        foreach ($raw in $lines) {
            $l = $raw.TrimEnd("`r")
            if ($l.StartsWith('#DSPOOL-BUNDLE-GZB64')) { $on = $true; continue }
            if ($l.StartsWith('#DSPOOL-END-GZB64')) { $on = $false; continue }
            if ($on) { [void]$b64.Append(($l -replace '[^A-Za-z0-9+/=]', '')) }
        }
        $ms = New-Object IO.MemoryStream(, [Convert]::FromBase64String($b64.ToString()))
        $gz = New-Object IO.Compression.GZipStream($ms, [IO.Compression.CompressionMode]::Decompress)
        $sr = New-Object IO.StreamReader($gz, $Utf8)
        $text = $sr.ReadToEnd(); $sr.Dispose()
        $lines = $text -split "`n"
        $isBundle = $true
    }
    if ($isBundle) {
        $name = ''
        foreach ($l in $lines) { $t = $l.TrimEnd("`r"); if ($t.StartsWith('#DSPOOL-BUNDLE ')) { $p = $t.Split(' '); if ($p.Length -ge 3) { $name = $p[2] }; break } }
        if ($name -eq '') { $name = [IO.Path]::GetFileNameWithoutExtension($full) }
        return @{ Files = (Get-BundleFiles $lines); Name = $name; Path = $full }
    }
    if ($full.EndsWith('.csv', [StringComparison]::OrdinalIgnoreCase)) { return Resolve-Source (Split-Path -Parent $full) }
    throw "入力形式を判別できません: $path （ディレクトリ・バンドル・CSV のいずれかを指定してください）"
}

#------------------------------------------------------------------------------
# データ表シート（時系列 / 時間別 / イベント / 待機スレッド / JVM）
#------------------------------------------------------------------------------
function Write-TableSheet([IO.TextWriter]$w, [string[]]$lines, [string]$table, [int]$sheetIdx, [string]$sheetName, [string]$title, [string]$note, [string]$groupKey, [string]$statusKey, [int]$freeze) {
    $nc = 0; $K = @()
    $li = 0
    if ($null -ne $lines -and $lines.Length -gt 0) { $hdr = $lines[0].TrimEnd("`r"); if ($hdr -ne '') { $K = Split-Csv $hdr; $nc = $K.Length }; $li = 1 }
    $CL = New-Object 'string[]' ($nc + 1); $CC = New-Object 'string[]' ($nc + 2); $CF = New-Object 'string[]' ($nc + 1); $CW = New-Object 'string[]' ($nc + 1); $CG = New-Object 'int[]' ($nc + 1)
    $gi = 0; $sc = 0; $tc = 0; $anyg = $false
    for ($c = 1; $c -le $nc; $c++) {
        $key = $K[$c - 1]
        $d = $CD[$table + '|' + $key]
        if ($null -ne $d) { $CL[$c] = $d[0]; $CC[$c] = $d[1]; $CF[$c] = $d[2]; $CW[$c] = $d[3]; $CG[$c] = $d[4] }
        else { $CL[$c] = $key; $CC[$c] = 'その他'; $CF[$c] = 'auto'; $CW[$c] = '12'; $CG[$c] = 1 }
        if ($CG[$c]) { $anyg = $true }
        if ($key -ceq $groupKey) { $gi = $c }
        if ($key -ceq $statusKey) { $sc = $c }
        if ($key -ceq 'timestamp') { $tc = $c }
        $ColMap[$table + '|' + $key] = $COLN[$c]
    }
    $groups = New-Object System.Collections.Generic.List[string]
    $grows = @{}
    $nrows = 0
    if ($nc -gt 0) {
        for ($i = $li; $i -lt $lines.Length; $i++) {
            $ln = $lines[$i].TrimEnd("`r"); if ($ln -eq '') { continue }
            $g = ''
            if ($gi) { $F = Split-Csv $ln; if ($gi -le $F.Length) { $g = $F[$gi - 1] } }
            if (-not $grows.ContainsKey($g)) { $groups.Add($g); $grows[$g] = New-Object System.Collections.Generic.List[string] }
            $grows[$g].Add($ln)
            $nrows++
        }
    }
    $fit = ($nc -gt 0 -and $nc -le 20)
    $w.Write((Ws-Begin 'FF404040' $fit $anyg $(if ($nrows -gt 0) { $freeze } else { 0 }) $(if ($nrows -gt 0) { 6 } else { 0 }) $sheetIdx))
    if ($nc -gt 0) {
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('<cols>')
        for ($c = 1; $c -le $nc; $c++) { [void]$sb.Append('<col min="' + $c + '" max="' + $c + '" width="' + $CW[$c] + '" customWidth="1"' + $(if ($CG[$c]) { ' outlineLevel="1"' } else { '' }) + '/>') }
        [void]$sb.Append('</cols>')
        $w.Write($sb.ToString())
    }
    $w.Write('<sheetData>')
    $w.Write((Row 1 (StrC 'A1' $title $S_TITLE) 24))
    $w.Write((Row 2 (StrC 'A2' $note $S_NOTE2) 0))
    $nodata = $false; $merges = ''; $nm = 0; $lastr = 4; $trunc = $false
    if ($nc -eq 0) {
        $w.Write((Row 4 (StrC 'A4' '（データがありません）' $S_NOTE2) 0)); $nodata = $true; $lastr = 4
    } else {
        $out = ''; $c = 1
        while ($c -le $nc) {
            $j = $c; while ($j -lt $nc -and $CC[$j + 1] -ceq $CC[$c]) { $j++ }
            $out += StrC ($COLN[$c] + '4') $CC[$c] $S_BAND
            for ($i = $c + 1; $i -le $j; $i++) { $out += EmptyC ($COLN[$i] + '4') $S_BAND }
            if ($j -gt $c) { $merges += '<mergeCell ref="' + $COLN[$c] + '4:' + $COLN[$j] + '4"/>'; $nm++ }
            $c = $j + 1
        }
        $w.Write((Row 4 $out 18))
        $out = ''; for ($c = 1; $c -le $nc; $c++) { $out += StrC ($COLN[$c] + '5') $CL[$c] $S_HDR }
        $w.Write((Row 5 $out 30))
        $out = ''; for ($c = 1; $c -le $nc; $c++) { $out += StrC ($COLN[$c] + '6') $K[$c - 1] $S_KEY }
        $w.Write((Row 6 $out 14.4))
        # 書式コード（高速化のため数値化）: 0 text 1 int/dec1/num 2 pct 3 dt/dtm 4 dur 5 bool 6 status 7 auto 8 verdict
        $code = New-Object 'int[]' ($nc + 1); $est = New-Object 'int[]' ($nc + 1); $nst = New-Object 'int[]' ($nc + 1)
        for ($c = 1; $c -le $nc; $c++) {
            $fmtName = $CF[$c]
            $code[$c] = switch -CaseSensitive ($fmtName) { 'int' { 1 } 'dec1' { 1 } 'num' { 1 } 'pct' { 2 } 'dt' { 3 } 'dtm' { 3 } 'dur' { 4 } 'bool' { 5 } 'status' { 6 } 'auto' { 7 } 'verdict' { 8 } default { 0 } }
            $est[$c] = $(if ($FMTS.ContainsKey($fmtName)) { $FMTS[$fmtName] } else { $S_TEXT })
            $nst[$c] = $est[$c]
        }
        $r = 6
        $sb = New-Object System.Text.StringBuilder
        foreach ($g in $groups) {
            $first = $r + 1; $valid = 0; $fx = ''; $lx = ''
            if ($FastRows) {
                $res = [DsPoolRowWriterV1]::WriteRows($w, $grows[$g], $r, $MaxRows, $COLN, $nc, $code, $est, $nst, $sc, $tc, $LabelDict, $ValidDict, '有効', '無効', $StArr)
                $r = $res.LastRow; $valid = $res.Valid; $fx = $res.Fx; $lx = $res.Lx; if ($res.Truncated) { $trunc = $true }
                if ($r -ge $first) { $Ranges.Add(@($table, $g, $first, $r, $valid, $fx, $lx)) }
                if ($trunc) { break }
                continue
            }
            foreach ($ln in $grows[$g]) {
                if ($r - 6 -ge $MaxRows) { $trunc = $true; break }
                $r++
                [string[]]$F = if ($ln.IndexOf([char]34) -lt 0) { $ln.Split(',') } else { Split-Csv $ln }
                $nf = $F.Length
                if ($sc -and $sc -le $nf -and $ValidStatus.ContainsKey($F[$sc - 1])) { $valid++ }
                if ($tc) { $lx = XDate $(if ($tc -le $nf) { $F[$tc - 1] } else { '' }); if ($fx -eq '') { $fx = $lx } }
                [void]$sb.Clear()
                [void]$sb.Append('<row r="').Append($r).Append('">')
                $rs = [string]$r
                for ($c = 1; $c -le $nc; $c++) {
                    $v = $(if ($c -le $nf) { $F[$c - 1] } else { '' })
                    $ref = $COLN[$c] + $rs
                    if ($v.Length -eq 0) {
                        if ($code[$c] -eq 8) { [void]$sb.Append('<c r="').Append($ref).Append('" s="').Append($S_V0).Append('"/>') }
                        else { [void]$sb.Append('<c r="').Append($ref).Append('" s="').Append($est[$c]).Append('"/>') }
                        continue
                    }
                    switch ($code[$c]) {
                        1 { if ($NumRe.IsMatch($v)) { [void]$sb.Append('<c r="').Append($ref).Append('" s="').Append($nst[$c]).Append('"><v>').Append($v).Append('</v></c>') } else { [void]$sb.Append((StrC $ref $v $S_TEXT)) } }
                        6 { [void]$sb.Append((StrC $ref (SLabel $v) $S_TEXTC)) }
                        3 { $x = XDate $v; if ($x -ne '') { [void]$sb.Append('<c r="').Append($ref).Append('" s="').Append($nst[$c]).Append('"><v>').Append($x).Append('</v></c>') } else { [void]$sb.Append((StrC $ref $v $S_TEXT)) } }
                        0 { [void]$sb.Append((StrC $ref $v $S_TEXT)) }
                        default { [void]$sb.Append((CellX $ref $CF[$c] $v)) }
                    }
                }
                [void]$sb.Append('</row>')
                $w.Write($sb.ToString())
            }
            if ($r -ge $first) { $Ranges.Add(@($table, $g, $first, $r, $valid, $fx, $lx)) }
            if ($trunc) { break }
        }
        if ($r -eq 6) { $r = 7; $w.Write((Row 7 (StrC 'A7' '（データがありません）' $S_NOTE2) 0)); $nodata = $true }
        $lastr = $r
    }
    $w.Write('</sheetData>')
    if (-not $nodata) { $w.Write('<autoFilter ref="A6:' + $COLN[$nc] + $lastr + '"/>') }
    if ($nm) { $w.Write('<mergeCells count="' + $nm + '">' + $merges + '</mergeCells>') }
    if ($sc -and -not $nodata) { $w.Write((Cf-Rules ('A7:' + $COLN[$nc] + $lastr) ('$' + $COLN[$sc] + '7'))) }
    $w.Write((Ws-End 'landscape' $fit $false 0 '' $title))
    if (-not $nodata) {
        Add-DefName $sheetIdx '_xlnm._FilterDatabase' ("'" + $sheetName + "'!`$A`$6:`$" + $COLN[$nc] + '$' + $lastr)
        Add-DefName $sheetIdx '_xlnm.Print_Titles' ($(if ($freeze -gt 0) { "'" + $sheetName + "'!`$A:`$" + $COLN[$freeze] + ',' } else { '' }) + "'" + $sheetName + "'!`$4:`$6")
    }
    if ($trunc) { Write-Warning "$sheetName は $MaxRows 行で打ち切りました" }
}

#------------------------------------------------------------------------------
# サマリーシート
#------------------------------------------------------------------------------
function JDur($v) {
    $s = [long][Math]::Truncate((ToNum $v)); $h = [long][Math]::Truncate($s / 3600); $m = [long][Math]::Truncate(($s % 3600) / 60); $s = $s % 60
    return $(if ($h -gt 0) { [string]$h + '時間' } else { '' }) + $(if ($h -gt 0 -or $m -gt 0) { [string]$m + '分' } else { '' }) + [string]$s + '秒'
}
function ToNum($v) {
    if ($null -eq $v) { return 0.0 }
    $m = [regex]::Match([string]$v, '^\s*[-+]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][-+]?[0-9]+)?')
    if ($m.Success) { return [double]::Parse($m.Value.Trim(), $Inv) }
    return 0.0
}
function Write-SummarySheet([hashtable]$files, [int]$sheetIdx, [string]$sheetName, [string]$srcName, [string]$nowStr) {
    $META = @{}
    $ml = $files['ds_pool_meta.csv']
    if ($null -ne $ml) { for ($i = 1; $i -lt $ml.Length; $i++) { $F = Split-Csv ($ml[$i].TrimEnd("`r")); if ($F.Length -ge 3) { $META[$F[0] + '.' + $F[1]] = $F[2] } } }
    $SV = New-Object System.Collections.Generic.List[hashtable]
    $sumLines = $files['ds_pool_summary.csv']
    if ($null -ne $sumLines -and $sumLines.Length -gt 0) {
        $H = Split-Csv ($sumLines[0].TrimEnd("`r"))
        for ($i = 1; $i -lt $sumLines.Length; $i++) {
            $ln = $sumLines[$i].TrimEnd("`r"); if ($ln -eq '') { continue }
            $F = Split-Csv $ln; $rowMap = @{}
            for ($j = 0; $j -lt $H.Length; $j++) { $rowMap[$H[$j]] = $(if ($j -lt $F.Length) { $F[$j] } else { '' }) }
            $SV.Add($rowMap)
        }
    }
    $nds = $SV.Count
    $script:WARN = $(if ($META['collector.warn_pct']) { $META['collector.warn_pct'] } else { '80' })
    $BUCKET = $(if ($META['collector.bucket_min']) { $META['collector.bucket_min'] } else { '60' })
    $ps = ''; $pe = ''; $maxdur = 0.0
    foreach ($d in $SV) {
        if ($d['period_start'] -and ($ps -eq '' -or [string]::CompareOrdinal($d['period_start'], $ps) -lt 0)) { $ps = $d['period_start'] }
        if ([string]::CompareOrdinal([string]$d['period_end'], $pe) -gt 0) { $pe = $d['period_end'] }
        if ((ToNum $d['duration_sec']) -gt $maxdur) { $maxdur = ToNum $d['duration_sec'] }
    }
    $PERIOD = $(if ($ps -ne '') { $ps + ' ～ ' + $pe + '（' + (JDur $maxdur) + '）' } else { [string]$META['collector.start_time'] + ' ～ ' + [string]$META['collector.end_time'] })
    $infoVal = {
        param([string]$src)
        switch -CaseSensitive ($src) {
            '@period' { return $PERIOD }
            '@interval' { if ($META['collector.interval_sec']) { return $META['collector.interval_sec'] + ' 秒' }; return '' }
            '@warn' { return '使用率 ' + $script:WARN + '% 以上を「高使用率」と判定' }
            '@bucket' { return $BUCKET + ' 分' }
            '@mode' { return 'jboss-cli（' + $(if ($META['collector.cli_mode']) { $META['collector.cli_mode'] } else { '-' }) + '）／ ds_pool_collector.sh ' + [string]$META['collector.version'] }
            '@source' { return $srcName }
            '@now' { return $nowStr }
        }
        $out = ''; $any = $false
        foreach ($p in $src.Split('|')) {
            if ($p.StartsWith('meta:')) { $v = [string]$META[$p.Substring(5)]; if ($v -ne '') { $any = $true }; $out += $v } else { $out += $p }
        }
        if ($any) { return $out }; return ''
    }
    $render = {
        param([string]$t, [hashtable]$d)
        $out = ''
        while (($p = $t.IndexOf('{')) -ge 0) {
            $q = $t.IndexOf('}', $p); if ($q -lt 0) { break }
            $tok = $t.Substring($p + 1, $q - $p - 1); $out += $t.Substring(0, $p); $t = $t.Substring($q + 1)
            $f = ''; $ci = $tok.IndexOf(':'); if ($ci -ge 0) { $f = $tok.Substring($ci + 1); $tok = $tok.Substring(0, $ci) }
            if ($tok -eq 'warn') { $v = $script:WARN }
            elseif ($tok -eq 'churn') { $v = [string][long]((ToNum $d['destroyed_total']) - (ToNum $d['timed_out_total'])) }
            else { $v = [string]$d[$tok] }
            if ($f -eq 'dur') { $v = JDur $v }
            $out += $v
        }
        return $out + $t
    }
    $ncols = $(if ($nds + 1 -gt 12) { $nds + 1 } else { 12 })
    $lastc = $COLN[$ncols]
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append((Ws-Begin 'FF000000' $true $false 0 0 $sheetIdx))
    [void]$sb.Append('<cols><col min="1" max="1" width="40" customWidth="1"/><col min="2" max="' + $ncols + '" width="20" customWidth="1"/></cols><sheetData>')
    [void]$sb.Append((Row 1 (StrC 'A1' $Title $S_TITLE) 27))
    [void]$sb.Append((Row 2 (StrC 'A2' ('JBoss EAP / IronJacamar データソース接続プール統計（jboss-cli により収集）　作成: ' + $nowStr) $S_NOTE2) 0))
    $r = 4; $merges = ''; $nm = 0
    [void]$sb.Append((Row $r (StrC ('A' + $r) '■ 収集情報' $S_SEC) 21))
    foreach ($it in $INFO) {
        $v = & $infoVal $it[1]; if ($v -eq '') { continue }
        $r++
        $out = (StrC ('A' + $r) $it[0] $S_LABEL) + (StrC ('B' + $r) $v $S_TEXT)
        for ($c = 3; $c -le 8; $c++) { $out += EmptyC ($COLN[$c] + $r) $S_TEXT }
        [void]$sb.Append((Row $r $out 0))
        $merges += '<mergeCell ref="B' + $r + ':H' + $r + '"/>'; $nm++
    }
    $r += 2
    [void]$sb.Append((Row $r (StrC ('A' + $r) '■ 総合判定' $S_SEC) 21))
    $r++
    $out = ''; for ($c = 1; $c -le $SUMO.Count; $c++) { $out += StrC ($COLN[$c] + $r) $SUMO[$c - 1][1] $S_HDR }
    [void]$sb.Append((Row $r $out 30))
    if ($nds -eq 0) { $r++; [void]$sb.Append((Row $r (StrC ('A' + $r) '（サマリーがありません。ds_pool_collector.sh --report-only で作成してください）' $S_NOTE2) 0)) }
    foreach ($d in $SV) {
        $r++; $out = ''
        for ($c = 1; $c -le $SUMO.Count; $c++) { $out += CellX ($COLN[$c] + $r) $SUMO[$c - 1][2] ([string]$d[$SUMO[$c - 1][0]]) }
        [void]$sb.Append((Row $r $out 0))
    }
    if ($nds -gt 0) {
        $r += 2
        [void]$sb.Append((Row $r (StrC ('A' + $r) '■ データソース別 詳細' $S_SEC) 21))
        $r++
        $out = StrC ('A' + $r) '項目' $S_HDR
        for ($d = 1; $d -le $nds; $d++) { $out += StrC ($COLN[$d + 1] + $r) $SV[$d - 1]['ds_name'] $S_HDR }
        [void]$sb.Append((Row $r $out 30))
        foreach ($it in $SUMV) {
            $r++
            if ($it[0] -eq '#') {
                $out = StrC ('A' + $r) $it[1] $S_SECROW
                for ($d = 1; $d -le $nds; $d++) { $out += EmptyC ($COLN[$d + 1] + $r) $S_SECROW }
                [void]$sb.Append((Row $r $out 0))
                $merges += '<mergeCell ref="A' + $r + ':' + $COLN[$nds + 1] + $r + '"/>'; $nm++
                continue
            }
            $out = StrC ('A' + $r) $it[1] $S_LABEL
            $ht = 0; $DV = @()
            for ($d = 1; $d -le $nds; $d++) {
                $cellVal = [string]$SV[$d - 1][$it[0]]
                if ($it[0] -eq 'notes') { $cellVal = $cellVal.Replace(';', '; ') }
                $DV += , $cellVal
                if ($it[2] -eq 'text') { $hv = WrapHt $cellVal 20; if ($hv -gt $ht) { $ht = $hv } }
            }
            if ($ht -le 18) { $ht = 0 }
            for ($d = 1; $d -le $nds; $d++) {
                if ($ht -gt 0 -and $DV[$d - 1] -ne '') { $out += StrC ($COLN[$d + 1] + $r) $DV[$d - 1] $S_TEXTW }
                else { $out += CellX ($COLN[$d + 1] + $r) $it[2] $DV[$d - 1] }
            }
            [void]$sb.Append((Row $r $out $ht))
        }
        $r += 2
        [void]$sb.Append((Row $r (StrC ('A' + $r) '■ 所見' $S_SEC) 21))
        foreach ($d in $SV) {
            $r++
            [void]$sb.Append((Row $r (StrC ('A' + $r) ('◆ ' + $d['ds_name'] + '（判定: ' + (SLabel ([string]$d['verdict'])) + '）') $S_HEAD) 20))
            $NT = New-Object System.Collections.Generic.List[string]
            $NT2 = ([string]$d['notes']).Split(';')
            if ((ToNum $d['valid_samples']) -eq 0) {
                $NT.Add('_NODATA')
                foreach ($x in $NT2) { if ($x -ceq 'STATS_OFF' -or $x -ceq 'ERRORS') { $NT.Add($x) } }
            } else {
                foreach ($x in $NT2) { if ($x -ne '') { $NT.Add($x) } }
                if ($d['verdict'] -ceq 'OK') { $NT.Add('_OK') }
                if ($d['verdict'] -ceq 'FAILURE' -or $d['verdict'] -ceq 'EXHAUSTED' -or $d['verdict'] -ceq 'WAIT') { $NT.Add('_RECOMMEND') }
            }
            foreach ($code in $NT) {
                if (-not $TM.ContainsKey($code)) { continue }
                $txt = '・' + (& $render $TM[$code] $d)
                $r++
                $out = StrC ('A' + $r) $txt $S_WRAP; for ($c = 2; $c -le 8; $c++) { $out += EmptyC ($COLN[$c] + $r) $S_WRAP }
                [void]$sb.Append((Row $r $out (WrapHt $txt (40 + 7 * 17))))
                $merges += '<mergeCell ref="A' + $r + ':H' + $r + '"/>'; $nm++
            }
        }
    }
    [void]$sb.Append('</sheetData>')
    if ($nm) { [void]$sb.Append('<mergeCells count="' + $nm + '">' + $merges + '</mergeCells>') }
    [void]$sb.Append((Ws-End 'landscape' $true $false 0 '' $Title))
    Add-DefName $sheetIdx '_xlnm.Print_Area' ("'" + $sheetName + "'!`$A`$1:`$" + $lastc + '$' + $r)
    $script:SummaryRows = $SV
    return $sb.ToString()
}

#------------------------------------------------------------------------------
# 設定情報シート
#------------------------------------------------------------------------------
function Write-ConfigSheet([string[]]$lines, [int]$sheetIdx, [string]$sheetName, [string]$title, [string]$note) {
    $EN = New-Object System.Collections.Generic.List[string]; $ET = @{}; $AN = New-Object System.Collections.Generic.List[string]
    $EIX = @{}; $AIX = @{}; $VAL = @{}; $NOTES = @{}
    $OTH = New-Object System.Collections.Generic.List[object]
    if ($null -ne $lines -and $lines.Length -gt 0) {
        for ($i = 1; $i -lt $lines.Length; $i++) {
            $ln = $lines[$i].TrimEnd("`r"); if ($ln -eq '') { continue }
            $F = Split-Csv $ln; while ($F.Length -lt 5) { $F += '' }
            if (-not ($F[1] -ceq 'data-source' -or $F[1] -ceq 'xa-data-source')) { $OTH.Add(@($F[1], $F[0], $F[2], $F[3])); continue }
            if (-not $EIX.ContainsKey($F[0])) { $EN.Add($F[0]); $EIX[$F[0]] = $EN.Count; $ET[$F[0]] = $F[1] }
            if (-not $AIX.ContainsKey($F[2])) { $AN.Add($F[2]); $AIX[$F[2]] = $AN.Count }
            $key = [string]$EIX[$F[0]] + '|' + [string]$AIX[$F[2]]
            $VAL[$key] = $F[3]; $NOTES[$key] = $F[4]
        }
    }
    $ne = $EN.Count
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append((Ws-Begin 'FF7F7F7F' ($ne -le 3) $false $(if ($ne -gt 0) { 1 } else { 0 }) $(if ($ne -gt 0) { 5 } else { 0 }) $sheetIdx))
    [void]$sb.Append('<cols><col min="1" max="1" width="40" customWidth="1"/><col min="2" max="' + $(if ($ne + 1 -gt 4) { $ne + 1 } else { 4 }) + '" width="42" customWidth="1"/></cols><sheetData>')
    [void]$sb.Append((Row 1 (StrC 'A1' $title $S_TITLE) 24))
    [void]$sb.Append((Row 2 (StrC 'A2' $note $S_NOTE2) 0))
    $r = 4
    if ($ne -eq 0) { [void]$sb.Append((Row $r (StrC ('A' + $r) '（データソースの設定情報がありません）' $S_NOTE2) 0)) }
    else {
        $out = StrC 'A4' '属性' $S_HDR; for ($e = 1; $e -le $ne; $e++) { $out += StrC ($COLN[$e + 1] + '4') $EN[$e - 1] $S_HDR }
        [void]$sb.Append((Row 4 $out 22))
        $out = StrC 'A5' '種別' $S_LABEL; for ($e = 1; $e -le $ne; $e++) { $out += StrC ($COLN[$e + 1] + '5') $ET[$EN[$e - 1]] $S_TEXTC }
        [void]$sb.Append((Row 5 $out 0))
        $r = 5
        for ($a = 1; $a -le $AN.Count; $a++) {
            $r++
            $out = StrC ('A' + $r) $AN[$a - 1] $S_LABEL
            for ($e = 1; $e -le $ne; $e++) {
                $key = [string]$e + '|' + [string]$a
                if (-not $VAL.ContainsKey($key)) { $out += EmptyC ($COLN[$e + 1] + $r) $S_TEXT; continue }
                $v = $VAL[$key]; $nt = $NOTES[$key]
                if ($nt -ceq 'default') { $out += StrC ($COLN[$e + 1] + $r) ($v + '（既定値）') $S_MUTED }
                elseif ($nt -ceq 'undefined') { $out += StrC ($COLN[$e + 1] + $r) '－' $S_MUTED }
                else { $out += StrC ($COLN[$e + 1] + $r) $v $S_TEXT }
            }
            [void]$sb.Append((Row $r $out 0))
        }
    }
    if ($OTH.Count -gt 0) {
        $r += 2
        [void]$sb.Append((Row $r (StrC ('A' + $r) '■ JDBC ドライバー／JCA（キャッシュ接続マネージャー）' $S_SEC) 21))
        $r++
        [void]$sb.Append((Row $r ((StrC ('A' + $r) '種別：名前' $S_HDR) + (StrC ('B' + $r) '属性' $S_HDR) + (StrC ('C' + $r) '値' $S_HDR)) 22))
        foreach ($o in $OTH) { $r++; [void]$sb.Append((Row $r ((StrC ('A' + $r) ($o[0] + '：' + $o[1]) $S_TEXT) + (StrC ('B' + $r) $o[2] $S_LABEL) + (StrC ('C' + $r) $o[3] $S_TEXT)) 0)) }
    }
    [void]$sb.Append('</sheetData>')
    [void]$sb.Append((Ws-End 'landscape' ($ne -le 3) $false 0 '' $title))
    if ($ne -gt 0) { Add-DefName $sheetIdx '_xlnm.Print_Titles' ("'" + $sheetName + "'!`$A:`$A,'" + $sheetName + "'!`$4:`$4") }
    return $sb.ToString()
}

#------------------------------------------------------------------------------
# 凡例シート
#------------------------------------------------------------------------------
function Write-LegendSheet([int]$sheetIdx, [string]$title, [string]$note) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append((Ws-Begin 'FFBFBFBF' $true $false 0 0 $sheetIdx))
    [void]$sb.Append('<cols><col min="1" max="1" width="20" customWidth="1"/><col min="2" max="2" width="52" customWidth="1"/><col min="3" max="3" width="62" customWidth="1"/></cols><sheetData>')
    [void]$sb.Append((Row 1 (StrC 'A1' $title $S_TITLE) 24))
    [void]$sb.Append((Row 2 (StrC 'A2' $note $S_NOTE2) 0))
    $r = 3; $merges = ''; $nm = 0
    foreach ($l in $LEG) {
        $a = $l.Split('|'); while ($a.Length -lt 4) { $a += '' }
        $r++
        switch -CaseSensitive ($a[0]) {
            'H' { [void]$sb.Append((Row $r (StrC ('A' + $r) ('■ ' + $a[1]) $S_SEC) 21)) }
            'TH' { [void]$sb.Append((Row $r ((StrC ('A' + $r) $a[1] $S_HDR) + (StrC ('B' + $r) $a[2] $S_HDR) + (StrC ('C' + $r) $a[3] $S_HDR)) 20)) }
            'T' {
                $ht = WrapHt $a[2] 52; $h2 = WrapHt $a[3] 62; if ($h2 -gt $ht) { $ht = $h2 }
                [void]$sb.Append((Row $r ((StrC ('A' + $r) $a[1] $S_LABEL) + (StrC ('B' + $r) $a[2] $S_TEXTW) + (StrC ('C' + $r) $a[3] $S_TEXTW)) $(if ($ht -gt 18) { $ht } else { 0 })))
            }
            'P' {
                [void]$sb.Append((Row $r ((StrC ('A' + $r) $a[1] $S_WRAP) + (EmptyC ('B' + $r) $S_WRAP) + (EmptyC ('C' + $r) $S_WRAP)) (WrapHt $a[1] 134)))
                $merges += '<mergeCell ref="A' + $r + ':C' + $r + '"/>'; $nm++
            }
        }
    }
    [void]$sb.Append('</sheetData>')
    if ($nm) { [void]$sb.Append('<mergeCells count="' + $nm + '">' + $merges + '</mergeCells>') }
    [void]$sb.Append((Ws-End 'portrait' $true $false 0 '' $title))
    return $sb.ToString()
}

#------------------------------------------------------------------------------
# グラフシート（DrawingML チャート）
#------------------------------------------------------------------------------
function C-Title([string]$t, [int]$sz) {
    return '<c:title><c:tx><c:rich><a:bodyPr/><a:lstStyle/><a:p><a:pPr><a:defRPr sz="' + $sz + '" b="1"><a:solidFill><a:srgbClr val="000000"/></a:solidFill>' + $FONT + '</a:defRPr></a:pPr><a:r><a:rPr lang="ja-JP" altLang="en-US" sz="' + $sz + '" b="1"><a:solidFill><a:srgbClr val="000000"/></a:solidFill>' + $FONT + '</a:rPr><a:t>' + (X $t) + '</a:t></a:r></a:p></c:rich></c:tx><c:overlay val="0"/></c:title>'
}
function Ax-Title([string]$t, [string]$rot) {
    return '<c:title><c:tx><c:rich><a:bodyPr' + $(if ($rot -ne '') { ' rot="' + $rot + '" vert="horz"' } else { '' }) + '/><a:lstStyle/><a:p><a:pPr><a:defRPr sz="800" b="0"><a:solidFill><a:srgbClr val="404040"/></a:solidFill>' + $FONT + '</a:defRPr></a:pPr><a:r><a:rPr lang="ja-JP" altLang="en-US" sz="800" b="0"><a:solidFill><a:srgbClr val="404040"/></a:solidFill>' + $FONT + '</a:rPr><a:t>' + (X $t) + '</a:t></a:r></a:p></c:rich></c:tx><c:overlay val="0"/></c:title>'
}
function Tx-Pr([int]$sz, [string]$rot) {
    return '<c:txPr><a:bodyPr' + $(if ($rot -ne '') { ' rot="' + $rot + '" vert="horz"' } else { '' }) + '/><a:lstStyle/><a:p><a:pPr><a:defRPr sz="' + $sz + '"><a:solidFill><a:srgbClr val="404040"/></a:solidFill>' + $FONT + '</a:defRPr></a:pPr><a:endParaRPr lang="ja-JP"/></a:p></c:txPr>'
}
function Ln-Sp([string]$color, [int]$w, [string]$dash) { return '<c:spPr><a:ln w="' + $w + '" cap="rnd"><a:solidFill><a:srgbClr val="' + $color + '"/></a:solidFill><a:prstDash val="' + $dash + '"/><a:round/></a:ln></c:spPr>' }
$AXLN = '<c:spPr><a:ln w="9525"><a:solidFill><a:srgbClr val="808080"/></a:solidFill></a:ln></c:spPr>'
$GRID = '<c:majorGridlines><c:spPr><a:ln w="6350"><a:solidFill><a:srgbClr val="D9D9D9"/></a:solidFill></a:ln></c:spPr></c:majorGridlines>'
function Ser-Sc([int]$i, [string]$name, [string]$xr, [string]$yr, [string]$color, [int]$w, [string]$dash) {
    return '<c:ser><c:idx val="' + $i + '"/><c:order val="' + $i + '"/><c:tx><c:v>' + (X $name) + '</c:v></c:tx>' + (Ln-Sp $color $w $dash) + '<c:marker><c:symbol val="none"/></c:marker><c:xVal><c:numRef><c:f>' + (X $xr) + '</c:f></c:numRef></c:xVal><c:yVal><c:numRef><c:f>' + (X $yr) + '</c:f></c:numRef></c:yVal><c:smooth val="0"/></c:ser>'
}
function Ser-Ln([int]$i, [string]$name, [string]$cr, [string]$vr, [string]$color, [int]$w, [string]$dash, [bool]$mk) {
    $m = $(if ($mk) { '<c:marker><c:symbol val="circle"/><c:size val="4"/><c:spPr><a:solidFill><a:srgbClr val="' + $color + '"/></a:solidFill><a:ln><a:noFill/></a:ln></c:spPr></c:marker>' } else { '<c:marker><c:symbol val="none"/></c:marker>' })
    return '<c:ser><c:idx val="' + $i + '"/><c:order val="' + $i + '"/><c:tx><c:v>' + (X $name) + '</c:v></c:tx>' + (Ln-Sp $color $w $dash) + $m + '<c:cat><c:numRef><c:f>' + (X $cr) + '</c:f></c:numRef></c:cat><c:val><c:numRef><c:f>' + (X $vr) + '</c:f></c:numRef></c:val><c:smooth val="0"/></c:ser>'
}
function Ser-Bar([int]$i, [string]$name, [string]$cr, [string]$vr, [string]$fill, [string]$line) {
    return '<c:ser><c:idx val="' + $i + '"/><c:order val="' + $i + '"/><c:tx><c:v>' + (X $name) + '</c:v></c:tx><c:spPr><a:solidFill><a:srgbClr val="' + $fill + '"/></a:solidFill><a:ln w="6350"><a:solidFill><a:srgbClr val="' + $line + '"/></a:solidFill></a:ln></c:spPr><c:invertIfNegative val="0"/><c:cat><c:numRef><c:f>' + (X $cr) + '</c:f></c:numRef></c:cat><c:val><c:numRef><c:f>' + (X $vr) + '</c:f></c:numRef></c:val></c:ser>'
}
function Val-Ax([long]$id, [long]$cross, [string]$pos, [string]$fmt, [string]$ttl, [bool]$isy, [string]$between, [string]$scl, [string]$maj) {
    $s = '<c:valAx><c:axId val="' + $id + '"/><c:scaling><c:orientation val="minMax"/>' + $(if ($isy) { '<c:min val="0"/>' } else { $scl }) + '</c:scaling><c:delete val="0"/><c:axPos val="' + $pos + '"/>'
    if ($isy) { $s += $GRID }
    if ($ttl -ne '') { $s += Ax-Title $ttl $(if ($isy) { '-5400000' } else { '' }) }
    $s += '<c:numFmt formatCode="' + (X $fmt) + '" sourceLinked="0"/><c:majorTickMark val="out"/><c:minorTickMark val="none"/><c:tickLblPos val="' + $(if ($isy) { 'nextTo' } else { 'low' }) + '"/>' + $AXLN + (Tx-Pr 800 $(if ($isy) { '' } else { '-2700000' }))
    $s += '<c:crossAx val="' + $cross + '"/><c:crosses val="' + $(if ($isy) { 'autoZero' } else { 'min' }) + '"/><c:crossBetween val="' + $between + '"/>' + $(if ($maj -ne '') { '<c:majorUnit val="' + $maj + '"/>' } else { '' }) + '</c:valAx>'
    return $s
}
function Cat-Ax([long]$id, [long]$cross, [string]$fmt) {
    return '<c:catAx><c:axId val="' + $id + '"/><c:scaling><c:orientation val="minMax"/></c:scaling><c:delete val="0"/><c:axPos val="b"/><c:numFmt formatCode="' + (X $fmt) + '" sourceLinked="0"/><c:majorTickMark val="out"/><c:minorTickMark val="none"/><c:tickLblPos val="low"/>' + $AXLN + (Tx-Pr 800 '-2700000') + '<c:crossAx val="' + $cross + '"/><c:crosses val="autoZero"/><c:auto val="0"/><c:lblAlgn val="ctr"/><c:lblOffset val="100"/><c:noMultiLvlLbl val="0"/></c:catAx>'
}
function Chart-Doc([string]$ttl, [string]$plot) {
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + "`n" + '<c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><c:date1904 val="0"/><c:lang val="ja-JP"/><c:roundedCorners val="0"/><c:chart>' + (C-Title $ttl 1000) + '<c:autoTitleDeleted val="0"/><c:plotArea><c:layout/>' + $plot + '<c:spPr><a:noFill/><a:ln><a:noFill/></a:ln></c:spPr></c:plotArea><c:legend><c:legendPos val="b"/><c:overlay val="0"/>' + (Tx-Pr 800 '') + '</c:legend><c:plotVisOnly val="1"/><c:dispBlanksAs val="gap"/></c:chart><c:spPr><a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill><a:ln w="9525"><a:solidFill><a:srgbClr val="A6A6A6"/></a:solidFill></a:ln></c:spPr><c:txPr><a:bodyPr/><a:lstStyle/><a:p><a:pPr><a:defRPr sz="900">' + $FONT + '</a:defRPr></a:pPr><a:endParaRPr lang="ja-JP"/></a:p></c:txPr></c:chartSpace>'
}
# 時間軸（シリアル値）の範囲と目盛間隔: 目盛が 12 個以下になる最小の間隔（1分～7日）
function X-Scale([string]$x1s, [string]$x2s) {
    $script:XSCL = ''; $script:XMAJ = ''; $script:XFMT = 'm/d hh:mm'
    if ($x1s -eq '' -or $x2s -eq '') { return }
    $x1 = [double]::Parse($x1s, $Inv); $x2 = [double]::Parse($x2s, $Inv); $span = $x2 - $x1
    if ($span -le 0) { $span = [double]::Parse('0.000694444444444444', $Inv) }
    $units = '0.000694444444444444 0.00138888888888889 0.00347222222222222 0.00694444444444444 0.0104166666666667 0.0208333333333333 0.0416666666666667 0.0833333333333333 0.125 0.25 0.5 1 2 7'.Split(' ') | ForEach-Object { [double]::Parse($_, $Inv) }
    $u = $units[$units.Count - 1]
    foreach ($cand in $units) { if ($span / $cand -le 12) { $u = $cand; break } }
    $c = [Math]::Truncate($x2 / $u - 1e-9); if ($c * $u -lt $x2 - 1e-9) { $c++ }
    $script:XSCL = '<c:max val="' + (F10 ($c * $u)) + '"/><c:min val="' + (F10 ([Math]::Truncate($x1 / $u + 1e-9) * $u)) + '"/>'
    $script:XMAJ = F10 $u
    if ($u -ge 1) { $script:XFMT = 'm/d' }
}
function Rng([string]$sheet, [string]$col, $r1, $r2) { return "'" + $sheet + "'!`$" + $col + '$' + $r1 + ':$' + $col + '$' + $r2 }
function Write-ChartsSheet([System.IO.Compression.ZipArchive]$zip, [int]$sheetIdx, [string]$sheetName, [string]$title, [string]$note, [string]$tsName, [string]$hrName, [string]$cxName) {
    $DSO = New-Object System.Collections.Generic.List[string]
    $T = @{}; $HR = @{}; $CX = $null
    foreach ($rg in $Ranges) {
        if ($rg[0] -eq 'ts') { $T[$rg[1]] = $rg; if (-not $DSO.Contains($rg[1])) { $DSO.Add($rg[1]) } }
        elseif ($rg[0] -eq 'hourly') { $HR[$rg[1]] = $rg }
        elseif ($rg[0] -eq 'ctx') { $CX = $rg }
    }
    $VERD = @{}
    foreach ($d in $script:SummaryRows) { $VERD[$d['ds_name']] = $d['verdict'] }
    $script:NCH = 0; $anch = New-Object System.Text.StringBuilder; $rels = New-Object System.Text.StringBuilder
    $addChart = {
        param([string]$xml, [int]$c1, [int]$r1, [int]$c2, [int]$r2)
        $script:NCH++
        $n = $script:NCH
        $e = $zip.CreateEntry("xl/charts/chart$n.xml", [IO.Compression.CompressionLevel]::Optimal)
        $chartWriter = New-Object IO.StreamWriter($e.Open(), $Utf8); $chartWriter.Write($xml); $chartWriter.Dispose()
        [void]$anch.Append('<xdr:twoCellAnchor editAs="oneCell"><xdr:from><xdr:col>' + $c1 + '</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>' + $r1 + '</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from><xdr:to><xdr:col>' + $c2 + '</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>' + $r2 + '</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:to><xdr:graphicFrame macro=""><xdr:nvGraphicFramePr><xdr:cNvPr id="' + ($n + 1) + '" name="Chart ' + $n + '"/><xdr:cNvGraphicFramePr/></xdr:nvGraphicFramePr><xdr:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/></xdr:xfrm><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/chart"><c:chart xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" r:id="rId' + $n + '"/></a:graphicData></a:graphic></xdr:graphicFrame><xdr:clientData/></xdr:twoCellAnchor>')
        [void]$rels.Append('<Relationship Id="rId' + $n + '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/chart" Target="../charts/chart' + $n + '.xml"/>')
    }
    $brk = ''; $nbrk = 0
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append((Ws-Begin 'FF262626' $false $false 0 0 $sheetIdx))
    [void]$sb.Append('<sheetData>')
    [void]$sb.Append((Row 1 (StrC 'A1' $title $S_TITLE) 24))
    [void]$sb.Append((Row 2 (StrC 'A2' $note $S_NOTE2) 0))
    # 1 データソース = 39 行（見出し + 推移グラフ 18 行 + 時間別グラフ 18 行 + 余白）。印刷は 1 ブロック 1 ページ
    $base = 4; $d = 0
    foreach ($ds in $DSO) {
        $d++
        if ($d -gt 1) { $brk += '<brk id="' + ($base - 1) + '" max="16383" man="1"/>'; $nbrk++ }
        $head = '■ ' + $ds + $(if ($VERD.ContainsKey($ds)) { '（判定: ' + (SLabel ([string]$VERD[$ds])) + '）' } else { '' })
        [void]$sb.Append((Row $base (StrC ('A' + $base) $head $S_HEAD) 21))
        $tr = $T[$ds]
        if ([int]$tr[4] -gt 0) {
            $tf = $tr[2]; $tl = $tr[3]
            $x = Rng $tsName $ColMap['ts|timestamp'] $tf $tl
            $plot = '<c:scatterChart><c:scatterStyle val="lineMarker"/><c:varyColors val="0"/>'
            $plot += Ser-Sc 0 '使用中' $x (Rng $tsName $ColMap['ts|in_use_count'] $tf $tl) '000000' 22225 'solid'
            $plot += Ser-Sc 1 'アクティブ' $x (Rng $tsName $ColMap['ts|active_count'] $tf $tl) '595959' 15875 'dash'
            $plot += Ser-Sc 2 'アイドル' $x (Rng $tsName $ColMap['ts|idle_count'] $tf $tl) 'A6A6A6' 15875 'sysDot'
            $plot += Ser-Sc 3 '最大プールサイズ' $x (Rng $tsName $ColMap['ts|max_pool_size'] $tf $tl) '000000' 12700 'lgDash'
            $plot += '<c:axId val="' + (100000 + $d * 10 + 1) + '"/><c:axId val="' + (100000 + $d * 10 + 2) + '"/></c:scatterChart>'
            X-Scale ([string]$tr[5]) ([string]$tr[6])
            $plot += (Val-Ax (100000 + $d * 10 + 1) (100000 + $d * 10 + 2) 'b' $script:XFMT '' $false 'midCat' $script:XSCL $script:XMAJ) + (Val-Ax (100000 + $d * 10 + 2) (100000 + $d * 10 + 1) 'l' 'General' '接続数' $true 'midCat' '' '')
            & $addChart (Chart-Doc ($ds + ' ― 接続数の推移（使用中・アクティブ・アイドル・最大プール）') $plot) 0 $base 16 ($base + 18)
            if ($HR.ContainsKey($ds) -and [int]$HR[$ds][4] -gt 0) {
                $h1 = $HR[$ds][2]; $h2 = $HR[$ds][3]; $x = Rng $hrName $ColMap['hourly|bucket_start'] $h1 $h2
                $plot = '<c:lineChart><c:grouping val="standard"/><c:varyColors val="0"/>'
                $plot += Ser-Ln 0 '使用中 最大' $x (Rng $hrName $ColMap['hourly|in_use_max'] $h1 $h2) '000000' 22225 'solid' $true
                $plot += Ser-Ln 1 '使用中 平均' $x (Rng $hrName $ColMap['hourly|in_use_avg'] $h1 $h2) '595959' 15875 'dash' $false
                $plot += Ser-Ln 2 '使用中 最小' $x (Rng $hrName $ColMap['hourly|in_use_min'] $h1 $h2) 'A6A6A6' 15875 'sysDot' $false
                $plot += Ser-Ln 3 '最大プールサイズ' $x (Rng $hrName $ColMap['hourly|max_pool_size'] $h1 $h2) '000000' 12700 'lgDash' $false
                $plot += '<c:marker val="1"/><c:axId val="' + (200000 + $d * 10 + 1) + '"/><c:axId val="' + (200000 + $d * 10 + 2) + '"/></c:lineChart>'
                $plot += (Cat-Ax (200000 + $d * 10 + 1) (200000 + $d * 10 + 2) 'm/d hh:mm') + (Val-Ax (200000 + $d * 10 + 2) (200000 + $d * 10 + 1) 'l' 'General' '接続数' $true 'between' '' '')
                & $addChart (Chart-Doc ($ds + ' ― 時間別 使用中接続数（最大・平均・最小）') $plot) 0 ($base + 19) 8 ($base + 37)
                $plot = '<c:barChart><c:barDir val="col"/><c:grouping val="clustered"/><c:varyColors val="0"/>'
                $plot += Ser-Bar 0 '待ち発生' $x (Rng $hrName $ColMap['hourly|wait_delta'] $h1 $h2) 'A6A6A6' '7F7F7F'
                $plot += Ser-Bar 1 '取得失敗' $x (Rng $hrName $ColMap['hourly|blocking_failure_delta'] $h1 $h2) '262626' '000000'
                $plot += Ser-Bar 2 '枯渇サンプル' $x (Rng $hrName $ColMap['hourly|exhausted_samples'] $h1 $h2) 'E0E0E0' '7F7F7F'
                $plot += '<c:gapWidth val="60"/><c:axId val="' + (300000 + $d * 10 + 1) + '"/><c:axId val="' + (300000 + $d * 10 + 2) + '"/></c:barChart>'
                $plot += (Cat-Ax (300000 + $d * 10 + 1) (300000 + $d * 10 + 2) 'm/d hh:mm') + (Val-Ax (300000 + $d * 10 + 2) (300000 + $d * 10 + 1) 'l' 'General' '回数／サンプル数' $true 'between' '' '')
                & $addChart (Chart-Doc ($ds + ' ― 時間別 待ち発生・取得失敗・枯渇') $plot) 8 ($base + 19) 16 ($base + 37)
            }
            $base += 39
        } else {
            [void]$sb.Append((Row ($base + 1) (StrC ('A' + ($base + 1)) '有効な統計データがないため、グラフは作成していません。' $S_NOTE2) 0))
            $base += 3
        }
    }
    if ($null -ne $CX -and [int]$CX[3] -gt [int]$CX[2] -and $ColMap.ContainsKey('ctx|io_busy_task_threads')) {
        if ($DSO.Count -gt 0) { $brk += '<brk id="' + ($base - 1) + '" max="16383" man="1"/>'; $nbrk++ }
        [void]$sb.Append((Row $base (StrC ('A' + $base) '■ JVM・リクエスト処理スレッド' $S_HEAD) 21))
        $xf = $CX[2]; $xl = $CX[3]
        $x = Rng $cxName $ColMap['ctx|timestamp'] $xf $xl
        $plot = '<c:scatterChart><c:scatterStyle val="lineMarker"/><c:varyColors val="0"/>'
        $plot += Ser-Sc 0 'IO ワーカー 処理中' $x (Rng $cxName $ColMap['ctx|io_busy_task_threads'] $xf $xl) '000000' 19050 'solid'
        $plot += Ser-Sc 1 'IO ワーカー 最大' $x (Rng $cxName $ColMap['ctx|io_max_task_threads'] $xf $xl) '000000' 12700 'lgDash'
        if ($ColMap.ContainsKey('ctx|ds_in_use_total')) { $plot += Ser-Sc 2 '接続 使用中（全データソース）' $x (Rng $cxName $ColMap['ctx|ds_in_use_total'] $xf $xl) '7F7F7F' 15875 'dash' }
        $plot += '<c:axId val="900001"/><c:axId val="900002"/></c:scatterChart>'
        X-Scale ([string]$CX[5]) ([string]$CX[6])
        $plot += (Val-Ax 900001 900002 'b' $script:XFMT '' $false 'midCat' $script:XSCL $script:XMAJ) + (Val-Ax 900002 900001 'l' 'General' 'スレッド数／接続数' $true 'midCat' '' '')
        & $addChart (Chart-Doc 'リクエスト処理スレッド（IO ワーカー）と接続使用数' $plot) 0 $base 16 ($base + 18)
        $base += 20
    }
    if ($DSO.Count -eq 0) { [void]$sb.Append((Row 4 (StrC 'A4' '（グラフに使用できる時系列データがありません）' $S_NOTE2) 0)) }
    [void]$sb.Append('</sheetData>')
    [void]$sb.Append((Ws-End 'landscape' $false ($script:NCH -gt 0) 75 $(if ($nbrk -gt 0) { '<rowBreaks count="' + $nbrk + '" manualBreakCount="' + $nbrk + '">' + $brk + '</rowBreaks>' } else { '' }) $title))
    if ($script:NCH -gt 0) {
        $e = $zip.CreateEntry('xl/drawings/drawing1.xml', [IO.Compression.CompressionLevel]::Optimal)
        $dw = New-Object IO.StreamWriter($e.Open(), $Utf8)
        $dw.Write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + "`n" + '<xdr:wsDr xmlns:xdr="http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' + $anch.ToString() + '</xdr:wsDr>'); $dw.Dispose()
        $e = $zip.CreateEntry('xl/drawings/_rels/drawing1.xml.rels', [IO.Compression.CompressionLevel]::Optimal)
        $dw = New-Object IO.StreamWriter($e.Open(), $Utf8)
        $dw.Write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + "`n" + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' + $rels.ToString() + '</Relationships>'); $dw.Dispose()
    }
    Add-DefName $sheetIdx '_xlnm.Print_Area' ("'" + $sheetName + "'!`$A`$1:`$P`$" + $(if ($base -gt 4) { $base - 1 } else { 4 }))
    return $sb.ToString()
}

#------------------------------------------------------------------------------
# メイン
#------------------------------------------------------------------------------
function Add-TextEntry([System.IO.Compression.ZipArchive]$zip, [string]$name, [string]$content) {
    $e = $zip.CreateEntry($name, [IO.Compression.CompressionLevel]::Optimal)
    $w = New-Object IO.StreamWriter($e.Open(), $Utf8); $w.Write($content); $w.Dispose()
}

$sw = [Diagnostics.Stopwatch]::StartNew()
$src = Resolve-Source $InputPath
$files = $src.Files
if (-not $files.ContainsKey('ds_pool_timeseries.csv')) { throw "ds_pool_timeseries.csv が見つかりません（入力: $InputPath）" }
foreach ($f in @('ds_pool_summary.csv', 'ds_pool_hourly.csv', 'ds_pool_events.csv')) {
    if (-not $files.ContainsKey($f)) { Write-Warning "$f がありません。ds_pool_collector.sh --report-only <ディレクトリ> で作成できます" }
}
$srcName = [regex]::Replace([string]$src.Name, '[^A-Za-z0-9._-]', '_')
if ($OutputPath -eq '') { $OutputPath = Join-Path (Get-Location).ProviderPath ($(if ($srcName) { $srcName } else { 'dspool_report' }) + '.xlsx') }
if (-not $OutputPath.EndsWith('.xlsx', [StringComparison]::OrdinalIgnoreCase)) { $OutputPath += '.xlsx' }
if (-not [IO.Path]::IsPathRooted($OutputPath)) { $OutputPath = Join-Path (Get-Location).ProviderPath $OutputPath }
$outDir = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outDir -PathType Container)) { throw "出力先ディレクトリがありません: $outDir" }

$SheetNames = @('サマリー', 'グラフ', '時間別推移', '枯渇イベント', '待機スレッド', '時系列データ', 'JVM・スレッド', '設定情報', '凡例')
$nowStr = Get-Date -Format 'yyyy-MM-dd HH:mm'
$tmp = Join-Path $outDir ('.' + [IO.Path]::GetFileName($OutputPath) + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
Write-Info "入力: $($src.Path)"
$fs = [IO.File]::Open($tmp, [IO.FileMode]::Create)
$zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
try {
    $tables = @(
        @(6, 'ts', 'ds_pool_timeseries.csv', '時系列データ（サンプル × データソース）', 'データソースごとに時刻順で並べています。判定に応じて行を濃淡表示（高使用率→待ち発生→枯渇→取得失敗の順に濃く）。詳細列は列見出し上部の［＋］で展開できます。', 'ds_name', 'status', 3),
        @(3, 'hourly', 'ds_pool_hourly.csv', '時間別推移（集計単位ごとの 最大・平均・最小）', '使用中・アクティブ・アイドルの推移と、各時間帯の枯渇・待ち・取得失敗の件数です。「最悪判定」はその時間帯で最も重い判定です。', 'ds_name', 'worst_status', 2),
        @(7, 'ctx', 'ds_pool_context.csv', 'JVM・スレッド・トランザクション', '接続枯渇時はリクエスト処理スレッド（IO ワーカー）が接続待ちで滞留しやすくなります。接続プールの推移と合わせて確認してください。', '', '', 1),
        @(4, 'events', 'ds_pool_events.csv', '枯渇・待ちイベント（連続区間）', '待ち発生・枯渇・取得失敗が連続したサンプルを 1 イベントとしています。継続時間はサンプル間隔からの概算です。', '', 'severity', 0),
        @(5, 'waiters', 'ds_pool_waiters.csv', '接続待ちスレッドの待機元（アプリケーションのフレーム）', 'dump-queued-threads-in-pool で取得した、接続を待っていたスレッドのスタックから、最初に現れるアプリケーションのフレームを集計しています（スタック全体は queued_threads/ を参照）。', '', '', 0)
    )
    foreach ($t in $tables) {
        if ($t[0] -eq 6) { Write-Info '時系列データを変換しています...' }
        $e = $zip.CreateEntry("xl/worksheets/sheet$($t[0]).xml", [IO.Compression.CompressionLevel]::Optimal)
        $w = New-Object IO.StreamWriter($e.Open(), $Utf8)
        Write-TableSheet $w $files[$t[2]] $t[1] $t[0] $SheetNames[$t[0] - 1] $t[3] $t[4] $t[5] $t[6] $t[7]
        $w.Dispose()
    }
    Add-TextEntry $zip 'xl/worksheets/sheet1.xml' (Write-SummarySheet $files 1 $SheetNames[0] $srcName $nowStr)
    Add-TextEntry $zip 'xl/worksheets/sheet8.xml' (Write-ConfigSheet $files['ds_pool_config.csv'] 8 $SheetNames[7] '設定情報（データソース・JDBC ドライバー・JCA）' '収集開始時点の設定です。パスワード等はマスクしています。「（既定値）」はサーバーで未設定（IronJacamar の既定値が適用）の項目、「－」は未設定です。')
    Add-TextEntry $zip 'xl/worksheets/sheet9.xml' (Write-LegendSheet 9 '凡例・用語の説明' '判定・項目・所見コードの定義です。')
    Write-Info 'グラフを作成しています...'
    Add-TextEntry $zip 'xl/worksheets/sheet2.xml' (Write-ChartsSheet $zip 2 $SheetNames[1] 'グラフ（接続プールの推移）' 'モノトーン表示のため線の種類で区別しています（実線＝使用中／最大、破線＝アクティブ／平均、点線＝アイドル／最小、長破線＝最大プールサイズ）。' $SheetNames[5] $SheetNames[2] $SheetNames[6])
    $nChart = $script:NCH
    Add-TextEntry $zip 'xl/styles.xml' ($StylesXml.Replace("`r`n", "`n").TrimEnd("`n") + "`n")

    # workbook.xml（定義名は 名前→シート番号 の順。RHEL 版と同じ並び）
    $sorted = @($DefNames.ToArray())
    [Array]::Sort($sorted, [Comparison[object]] { param($p, $q) $c = [string]::CompareOrdinal([string]$p[1], [string]$q[1]); if ($c -ne 0) { return $c }; return ([int]$p[0]).CompareTo([int]$q[0]) })
    $wb = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + "`n" + '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
    $wb += '<workbookPr/><bookViews><workbookView xWindow="0" yWindow="0" windowWidth="28800" windowHeight="15600" tabRatio="850" activeTab="0"/></bookViews><sheets>'
    for ($i = 0; $i -lt $SheetNames.Count; $i++) { $wb += '<sheet name="' + (X $SheetNames[$i]) + '" sheetId="' + ($i + 1) + '" r:id="rId' + ($i + 1) + '"/>' }
    $wb += '</sheets>'
    if ($sorted.Count -gt 0) {
        $wb += '<definedNames>'
        foreach ($dn in $sorted) {
            if ($dn[1] -eq '_xlnm._FilterDatabase') { $wb += '<definedName name="' + $dn[1] + '" localSheetId="' + $dn[0] + '" hidden="1">' + (X $dn[2]) + '</definedName>' }
            else { $wb += '<definedName name="' + $dn[1] + '" localSheetId="' + $dn[0] + '">' + (X $dn[2]) + '</definedName>' }
        }
        $wb += '</definedNames>'
    }
    $wb += '<calcPr calcId="191029"/></workbook>'
    Add-TextEntry $zip 'xl/workbook.xml' $wb

    $rels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + "`n" + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    for ($i = 0; $i -lt $SheetNames.Count; $i++) { $rels += '<Relationship Id="rId' + ($i + 1) + '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet' + ($i + 1) + '.xml"/>' }
    $rels += '<Relationship Id="rId' + ($SheetNames.Count + 1) + '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>'
    Add-TextEntry $zip 'xl/_rels/workbook.xml.rels' $rels
    if ($nChart -gt 0) {
        Add-TextEntry $zip 'xl/worksheets/_rels/sheet2.xml.rels' ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + "`n" + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/drawing" Target="../drawings/drawing1.xml"/></Relationships>')
    }
    $ct = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + "`n" + '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
    $ct += '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>'
    $ct += '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
    for ($i = 1; $i -le $SheetNames.Count; $i++) { $ct += '<Override PartName="/xl/worksheets/sheet' + $i + '.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' }
    $ct += '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
    if ($nChart -gt 0) {
        $ct += '<Override PartName="/xl/drawings/drawing1.xml" ContentType="application/vnd.openxmlformats-officedocument.drawing+xml"/>'
        for ($i = 1; $i -le $nChart; $i++) { $ct += '<Override PartName="/xl/charts/chart' + $i + '.xml" ContentType="application/vnd.openxmlformats-officedocument.drawingml.chart+xml"/>' }
    }
    $ct += '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
    $ct += '<Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/></Types>'
    Add-TextEntry $zip '[Content_Types].xml' $ct
    Add-TextEntry $zip '_rels/.rels' ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + "`n" + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>')
    $w3c = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', $Inv)
    Add-TextEntry $zip 'docProps/core.xml' ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + "`n" + '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>' + (X $Title) + '</dc:title><dc:subject>' + (X $srcName) + '</dc:subject><dc:creator>Convert-DsPoolCsvToXlsx.ps1</dc:creator><cp:lastModifiedBy>Convert-DsPoolCsvToXlsx.ps1</cp:lastModifiedBy><dcterms:created xsi:type="dcterms:W3CDTF">' + $w3c + '</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">' + $w3c + '</dcterms:modified></cp:coreProperties>')
    Add-TextEntry $zip 'docProps/app.xml' ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + "`n" + '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Application>Convert-DsPoolCsvToXlsx.ps1 ' + $Version + '</Application></Properties>')
} catch {
    $zip.Dispose(); $fs.Dispose()
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    throw
}
$zip.Dispose(); $fs.Dispose()
Move-Item -LiteralPath $tmp -Destination $OutputPath -Force
Write-Info ("作成しました: {0} （シート {1}、グラフ {2}、{3:N1} 秒）" -f $OutputPath, $SheetNames.Count, $nChart, $sw.Elapsed.TotalSeconds)
if ($Open) { Invoke-Item -LiteralPath $OutputPath }
DSPOOL-MAIN#>
