# Ado 手燈螢幕連動

在 Mac 上擷取主螢幕主色，透過 BLE 直接控制自己的 Ado Light Stick。原生 Swift，使用系統的 ScreenCaptureKit、CoreBluetooth、CommonCrypto；執行時不需要 Python、網路、iPhone 或官方 App。

## 視窗版（建議）

兩個版本的畫面相同：左右色塊顯示「螢幕主色 → 手燈目前顏色」，下方可掃描並選擇手燈、開始／停止連動，並有執行記錄。上次選的手燈會被記住。

**Mac**：開啟 `dist/PenlightSync.app`（顯示名稱「Ado 手燈連動」，需 macOS 14 以上，Apple 晶片與 Intel 都可用）。

1. 關閉手機上的 Ado App，長按手燈背面按鈕至藍燈閃爍。
2. 第一次開啟時，系統會詢問藍牙權限，請按「允許」。
3. 按「掃描手燈」→ 在清單選手燈 → 按「開始連動」。第一次連動會詢問螢幕錄製權限；允許後請**結束並重新開啟 App**。若「系統設定 › 隱私權與安全性 › 螢幕與系統錄音」清單裡沒有出現 PenlightSync，請按「+」手動加入 `dist/PenlightSync.app` 並打開開關。
4. 按「停止」中斷連線，手燈就能再交給手機 App 使用。

App 是本機自簽（未經 Apple 公證）。若被擋，請在 Finder 對 App 按右鍵 →「打開」。每次重新編譯後，系統會把它當成新 App，需要重新允許藍牙與螢幕錄製權限。

**Windows**：把 `dist/windows/PenlightSync.exe` 複製到 Windows 10（2004 版）或 11 的電腦，直接雙擊執行。檔案已內含 .NET，不需另外安裝。電腦需要支援低功耗藍牙並開啟藍牙。

- 首次執行若出現「Windows 已保護您的電腦」，按「其他資訊」→「仍要執行」（程式沒有付費簽章）。
- 操作與 Mac 相同；不需要先在 Windows 設定裡配對手燈。
- 記錄檔：`%LOCALAPPDATA%\PenlightSync\latest.log`。

## 命令列版

1. 關閉 iPhone 上的 Ado App；讓手燈背面按鈕長按至藍燈閃爍。
2. 雙擊 `開始連動.command`。若系統要求，允許藍牙及螢幕錄製權限。
3. 播放影片，或切換主螢幕內容。讓影片占大部分畫面，主色會比較符合影片內容。
4. 在啟動的終端視窗按 **Control-C** 停止。單次最長執行一小時。

首次從終端機啟動時，請在系統設定允許**終端機的螢幕錄製權限**，再結束並重新開啟終端機。工具會先確認權限，再連線手燈。若啟動失敗，錯誤會保留在視窗，並記錄於 macOS 暫存資料夾的 `ado-penlight-sync/latest.log`。

啟動檔只連線 `device-id.txt` 指定的那支手燈。裝置 ID 每台 Mac 不同，請先執行 `./PenlightSync --probe`，把 `PROBE_OK identifier=` 後面的值存成本資料夾的 `device-id.txt`（此檔不納入版本控制）。主色每秒最多取樣／寫入四次，只送出改變的顏色；不儲存或上傳螢幕影像。

## 已驗證的範圍

2026-10-23，已實際連線自己的手燈，核對服務與控制特徵，重播紅／綠／藍指令，並驗證新生成的白／青／熄滅指令。最後以主螢幕紅→綠→藍→白→黑色塊進行整合測試，五色均取得 BLE 寫入回應，使用者確認手燈順序一致。

這是整個**主螢幕**的主色，包含桌面、字幕與其他視窗；不是單獨的 YouTube 分頁。尚未進行長時間影片與長時間斷線重連測試。連線中斷會停止並顯示錯誤，重新啟動前請讓手燈再次進入配對模式。 螢幕擷取或單筆同步寫入超過八秒沒有完成時，也會明確顯示錯誤並停止，避免程序停住而沒有提示。

## 原始碼與檢查

重新編譯前，先按 Control-C 停止目前的連動程序；開發驗證請輸出到其他檔名，保留執行中版本不變。

在此資料夾內重新編譯：

```sh
swiftc -parse-as-library ScreenColor.swift PenlightProtocol.swift PenlightSync.swift -o PenlightSync
python3 -m unittest discover -s . -p 'test_*.py' -v
swiftc ScreenColor.swift ScreenColorTests.swift -o ScreenColorTests
./ScreenColorTests
```

視窗版：

```sh
./build_mac_app.sh                      # 產生 dist/PenlightSync.app
cd windows && dotnet publish PenlightSyncWin -c Release -r win-x64 --self-contained true \
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true \
  -p:EnableCompressionInSingleFile=true -p:DebugType=none -o ../dist/windows
```

Windows 版需 .NET 8 SDK，可在 Mac 上直接編譯（本機裝在 `~/.dotnet`）。原始碼結構：

- `PenlightApp/`：Mac SwiftUI 視窗與控制邏輯，共用 `ScreenColor.swift`、`PenlightProtocol.swift`。
- `windows/PenlightCore/`：Windows 的加密指令與主色演算法（Swift 版的 C# 移植）；`windows/PenlightCore.Tests/` 用與 Swift 相同的實測向量檢查。
- `windows/PenlightSyncWin/`：WinForms 視窗、Windows 藍牙（WinRT）與螢幕擷取。
- `test_gui_builds.py`：Mac GUI 編譯、Windows 核心測試與交叉編譯。

`--probe` 只讀取服務；`--rgb RRGGBB --device UUID` 送出單色；`--calibrate --device UUID` 接受本機已觀察的十六進位指令，供診斷使用。一般使用只需啟動檔。

## 協議來源

RGB 控色格式參考 [Polyfish0 的公開 Ado 手燈實作](https://github.com/Polyfish0/abo-light-stick-app/blob/master/app/src/main/java/de/polyfish0/adolightstick/LightStickCommandBuilder.kt)，檔案 blob `c11638d25ecf83a6d1eeef6334b42898a6b03ae8`。以獨立 Swift 程式使用系統 AES-128-ECB 編碼，並核對本機實際擷取的紅／綠／藍／熄滅封包。來源專案採 GPL-3.0，來源與作者歸屬見 `NOTICE.md`。

原始 iPhone 診斷檔及其他藍牙裝置資料只保留在本機工作資料夾，沒有包含於這個交付資料夾或上傳。

## 授權

本專案以 [GPL-3.0](LICENSE) 授權發布（協議參考的上游專案同為 GPL-3.0，見 `NOTICE.md`）。這是個人非官方工具，與 Ado 及其官方周邊廠商無關。
