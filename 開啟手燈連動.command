#!/bin/zsh
set -u
cd -- "${0:A:h}" || exit 1

app_path=""
if [[ -d "$PWD/PenlightSync.app" ]]; then
    app_path="$PWD/PenlightSync.app"
elif [[ -d "/Applications/PenlightSync.app" ]]; then
    app_path="/Applications/PenlightSync.app"
fi

if [[ -z "$app_path" ]]; then
    print -u2 '找不到 PenlightSync.app。請確認此檔案與 PenlightSync.app 放在同一個資料夾，或已拖曳至「應用程式」。'
    print -u2 'PenlightSync.app not found. Keep this script next to PenlightSync.app or move the app to /Applications.'
    if [[ -t 0 ]]; then
        read -r '?按 Return 鍵結束…'
    fi
    exit 1
fi

print "正在解除 macOS 隔離標記並開啟：$app_path"
/usr/bin/xattr -dr com.apple.quarantine "$app_path" 2>/dev/null || true
for item in "$PWD/PenlightSync" "$PWD/開始連動.command" "$PWD/開啟手燈連動.command"; do
    [[ -e "$item" ]] && /usr/bin/xattr -d com.apple.quarantine "$item" 2>/dev/null || true
done

open_bin="${PENLIGHT_OPEN_BIN:-/usr/bin/open}"
if ! "$open_bin" "$app_path"; then
    print -u2 "無法開啟 $app_path。"
    if [[ -t 0 ]]; then
        read -r '?按 Return 鍵結束…'
    fi
    exit 1
fi
