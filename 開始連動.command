#!/bin/zsh
set -u
umask 077
cd -- "${0:A:h}" || exit 1
log_dir="${PENLIGHT_LOG_DIR:-${TMPDIR:-/tmp}/ado-penlight-sync}"
mkdir -p -- "$log_dir" || exit 1
log_file="$log_dir/latest.log"
print 'Ado 手燈螢幕連動'
print '請關閉手機上的 Ado App，並長按手燈背面按鈕至藍燈閃爍。'
print '連上後會跟隨主螢幕的主色。按 Control-C 停止；最長執行一小時。'
print '若系統要求權限，請允許藍牙與螢幕錄製。'
print "執行記錄：$log_file"
print "啟動時間：$(/bin/date '+%Y-%m-%d %H:%M:%S %z')" >> "$log_file"
# The CoreBluetooth identifier is per-Mac, so it lives in an untracked local file.
device_id=""
[[ -r device-id.txt ]] && device_id="$(/usr/bin/tr -d '[:space:]' < device-id.txt)"
if [[ -z "$device_id" ]]; then
    print '找不到手燈裝置 ID。請先執行 ./PenlightSync --probe，把 PROBE_OK 後的 identifier 存成本資料夾的 device-id.txt；或改用視窗版 App。'
    exit_code=2
else
    ./PenlightSync --sync --device "$device_id" --duration 3600 2>&1 | /usr/bin/tee -a "$log_file"
    exit_code=${pipestatus[1]}
fi
if (( exit_code == 0 )); then
    print '連動已結束。'
elif (( exit_code == 130 )); then
    print '已停止連動。'
else
    print "連動因錯誤停止（代碼 $exit_code）。請查看上方原因，記錄已保留於：$log_file"
fi
if [[ -t 0 ]]; then
    read -r '?按 Return 鍵結束…'
fi
exit "$exit_code"
