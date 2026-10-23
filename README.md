# Ado 手燈螢幕連動

[English](README.en.md) ｜ 中文

擷取主螢幕的平均色，透過藍牙（BLE）直接控制自己的 Ado Light Stick，讓手燈跟著影片變色。提供 Mac 與 Windows 視窗版，以及 Mac 命令列工具。執行時不需要網路、手機或官方 App。

## 下載

到 [Releases](https://github.com/Gcree/penlight-sync/releases) 下載：

- `PenlightSync-macOS.zip`：macOS 14 以上（Apple 晶片與 Intel 都可用）。
- `PenlightSync-Windows-x64.zip`：Windows 10（2004 版）或 11，已內含 .NET，不需另外安裝。

## 視窗版

兩個版本的畫面相同：

- 左右色塊顯示「螢幕平均色 → 手燈目前顏色」（手燈色塊只在手燈回報收到指令後才更新）。
- 掃描並選擇手燈、開始／停止連動、執行記錄；上次選的手燈會被記住。
- **燈光效果**（連動中也能即時調整，設定會被記住）：
  - **漸變時間**（0～2 秒，預設 0.6 秒）：換色時柔和淡入淡出，數值是大約完成 95% 變化所需的時間；設為 0 則立即換色。數值越大越柔和，越小越跟拍。
  - **呼吸律動**（預設關閉）：畫面顏色穩定時，手燈亮度以約 4 秒一次緩慢起伏（最暗約 70%）；畫面一換色就自動退場，不會干擾影片節奏。

### Mac

1. 關閉手機上的 Ado App，長按手燈背面按鈕至藍燈閃爍。
2. 打開「Ado 手燈連動」。第一次開啟時，系統會詢問藍牙權限，請按「允許」。
3. 按「掃描手燈」→ 在清單選手燈 → 按「開始連動」。
4. 第一次連動需要螢幕錄製權限：到「系統設定 › 隱私權與安全性 › 螢幕與系統錄音」允許本 App；清單裡沒出現時，按「+」手動加入 App。允許後請**結束並重新開啟 App**。
5. 按「停止」中斷連線，手燈就能再交給手機 App 使用。

App 是自簽（未經 Apple 公證）。若被擋，請在 Finder 對 App 按右鍵 →「打開」。每次重新編譯後，系統會把它當成新 App，需要重新允許藍牙與螢幕錄製權限。

### Windows

把 `PenlightSync.exe` 放到 Windows 電腦雙擊執行，操作與 Mac 相同。電腦需要支援並開啟藍牙；不需要先在 Windows 設定裡配對手燈。

- 首次執行若出現「Windows 已保護您的電腦」，按「其他資訊」→「仍要執行」（程式沒有付費簽章）。
- 記錄檔：`%LOCALAPPDATA%\PenlightSync\latest.log`。

### 使用建議

- 讓影片全螢幕或占大部分畫面，平均色才會接近影片本身；桌面、字幕與其他視窗也會被算進去。
- 取色範圍是整個**主螢幕**，不是單一瀏覽器分頁。
- 每秒取樣 5 次，燈光以每秒最多 20 格的速度輸出；只送出改變的顏色，不儲存或上傳畫面。

## 命令列版（Mac）

1. 關閉手機上的 Ado App；讓手燈背面按鈕長按至藍燈閃爍。
2. 雙擊 `開始連動.command`。若系統要求，允許藍牙及螢幕錄製權限。
3. 在啟動的終端視窗按 **Control-C** 停止。單次最長執行一小時。

首次從終端機啟動時，請在系統設定允許**終端機的螢幕錄製權限**，再結束並重新開啟終端機。若啟動失敗，錯誤會保留在視窗，並記錄於 macOS 暫存資料夾的 `ado-penlight-sync/latest.log`。

啟動檔只連線 `device-id.txt` 指定的那支手燈。裝置 ID 每台 Mac 不同，請先執行 `./PenlightSync --probe`，把 `PROBE_OK identifier=` 後面的值存成本資料夾的 `device-id.txt`（此檔不納入版本控制）。命令列版使用相同的平均色取樣，每秒最多寫入四次，沒有漸變與呼吸效果。

`--probe` 只讀取服務；`--rgb RRGGBB --device UUID` 送出單色；`--calibrate --device UUID` 接受已觀察的十六進位指令，供診斷使用。

## 已驗證的範圍

- 協議：紅／綠／藍／熄滅指令與實際擷取封包一致；新生成的白／青／熄滅指令經實機確認。
- Mac 命令列版與 Mac 視窗版：以全主螢幕紅→綠→藍→白→黑色塊實測，五色均取得手燈寫入回應，使用者確認手燈實體依序變色。掃描、連動、停止皆經實機驗證。詳見 `驗證紀錄.md`。
- Windows 版：加密指令、平均色與燈光效果的核心邏輯以與 Mac 版相同的測試案例驗證；**尚未在實體 Windows 電腦上執行**。
- 尚未驗證：長時間影片播放與斷線自動重連（目前斷線會停止並顯示錯誤，需重新按「開始連動」）。螢幕擷取或單筆寫入超過 8 秒未完成時，會停止並顯示錯誤。

## 原始碼與檢查

```sh
./build_mac_app.sh                                    # 產生 dist/PenlightSync.app
swiftc -parse-as-library ScreenColor.swift PenlightProtocol.swift PenlightSync.swift -o PenlightSync   # 命令列版
python3 -m unittest discover -s . -p 'test_*.py' -v   # 全部測試
cd windows && dotnet publish PenlightSyncWin -c Release -r win-x64 --self-contained true \
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true \
  -p:EnableCompressionInSingleFile=true -p:DebugType=none -o ../dist/windows
```

Windows 版需 .NET 8 SDK，可在 Mac 上直接交叉編譯。

- `ScreenColor.swift`：主螢幕擷取與平均色；`PenlightProtocol.swift`：RGB 指令加密；`PenlightSync.swift`：命令列工具。
- `PenlightApp/`：Mac SwiftUI 視窗、控制邏輯與 `LightEngine.swift`（漸變／呼吸效果）。
- `windows/PenlightCore/`：上述演算法的 C# 移植；`windows/PenlightCore.Tests/` 用與 Swift 相同的案例檢查。
- `windows/PenlightSyncWin/`：WinForms 視窗、Windows 藍牙（WinRT）與螢幕擷取。
- `test_*.py`：編譯並執行 Swift／C# 自我測試、啟動檔與命令列測試。

## 協議來源

RGB 控色格式參考 [Polyfish0 的公開 Ado 手燈實作](https://github.com/Polyfish0/abo-light-stick-app/blob/master/app/src/main/java/de/polyfish0/adolightstick/LightStickCommandBuilder.kt)，檔案 blob `c11638d25ecf83a6d1eeef6334b42898a6b03ae8`，以獨立程式使用 AES-128-ECB 編碼，並核對實際擷取的紅／綠／藍／熄滅封包。來源與作者歸屬見 `NOTICE.md`。

## 授權

本專案以 [GPL-3.0](LICENSE) 授權發布（協議參考的上游專案同為 GPL-3.0）。這是個人非官方工具，與 Ado 及其官方周邊廠商無關。
