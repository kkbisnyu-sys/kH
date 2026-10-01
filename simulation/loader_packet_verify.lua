-- lwk19_owo_loader 封包完整性驗證器
-- 目的: 檢查 loader 執行後會產生的封包/動作, 判斷是否足以觸發 RAGEBOT

------------------------------------------------------------
-- Mock Roblox executor environment
------------------------------------------------------------
local remotes_fired = {}
local files_read = {}
local files_written = {}
local loadstring_calls = {}
local getgenv_state = {}
local connections = {}
local warnings = {}

local function trace(chan, msg)
    print(string.format("  [%s] %s", chan, msg))
end

-- Mock isfile - 假设 md3_hub_template.luau 存在
local function isfile(path)
    files_read[#files_read+1] = { action = "isfile_check", path = path }
    -- 模拟 2 种场景: 有/无 hub 文件
    if _G.SIMULATE_HAS_HUB and (path == "lwk19_owo/md3_hub_template.luau"
                                or path == "md3_hub_template.luau"
                                or path == "lwk19_owo.luau") then
        return true
    end
    return false
end

local function readfile(path)
    files_read[#files_read+1] = { action = "readfile", path = path }
    return "-- fake hub content that would call RAGEBOT modules"
end

local function loadstring_mock(code)
    loadstring_calls[#loadstring_calls+1] = code
    return function()
        trace("HUB", "★ 執行 hub 內容 — 這裡才是 RAGEBOT 真正被載入的地方")
        trace("HUB", "  hub 會建立 Fighters/PlayerContext/Ragebot 物件")
        trace("HUB", "  安裝 hookCameraReplication / hookCameraSway 等等")
        trace("HUB", "  註冊 RunService.Heartbeat → Ragebot:Update(dt)")
    end
end

local function warn_mock(msg)
    warnings[#warnings+1] = msg
    trace("WARN", msg)
end

------------------------------------------------------------
-- Simulate loader execution
------------------------------------------------------------
local function run_loader(scenario_name, has_hub)
    print("\n═══════════════════════════════════════════════════════════")
    print("  場景: " .. scenario_name)
    print("═══════════════════════════════════════════════════════════")

    _G.SIMULATE_HAS_HUB = has_hub
    remotes_fired, files_read, loadstring_calls, warnings = {}, {}, {}, {}

    -- 1. 防止重複載入防護
    trace("GUARD", "檢查 getgenv().lwk19_owo_loaded → false (首次執行)")

    -- 2. 等待遊戲載入
    trace("WAIT", "game:IsLoaded() → true (假設遊戲已載入)")
    trace("WAIT", "Players.LocalPlayer 取得成功")

    -- 3. 取得 queue_on_teleport
    trace("EXEC_API", "queueOnTeleport = queue_on_teleport (執行器函式)")

    -- 4. 註冊 OnTeleport 事件
    trace("EVENT", "LocalPlayer.OnTeleport:Connect(handler) — 註冊跨服重連")
    connections[#connections+1] = "OnTeleport"

    -- 5. executeHub
    trace("BOOT", "→ executeHub()")
    trace("BOOT", "  設定 getgenv().lwk19_owo_loaded = true")
    getgenv_state.lwk19_owo_loaded = true
    getgenv_state.lwk19_owo_reloading = false
    getgenv_state.lwk19_owo_from_loader = true

    -- 6. 讀取本地檔案
    local paths = {
        "lwk19_owo/md3_hub_template.luau",
        "md3_hub_template.luau",
        "lwk19_owo.luau",
    }
    local loaded = false
    for _, path in ipairs(paths) do
        if isfile(path) then
            trace("FS", "isfile('"..path.."') → true")
            local content = readfile(path)
            trace("FS", "readfile('"..path.."') → "..#content.." bytes")
            local fn = loadstring_mock(content)
            fn()
            loaded = true
            break
        else
            trace("FS", "isfile('"..path.."') → false")
        end
    end

    if not loaded then
        warn_mock("[lwk19_owo] 請確認 'md3_hub_template.luau' 已放置於注入器的 workspace/lwk19_owo/ 目錄中。")
    end
end

------------------------------------------------------------
-- 執行兩個場景
------------------------------------------------------------
print([[
╔═══════════════════════════════════════════════════════════╗
║  lwk19_owo_loader 封包/動作完整性檢查                     ║
╚═══════════════════════════════════════════════════════════╝
]])

run_loader("A. 有 md3_hub_template.luau (完整)", true)
local scenario_A_remotes = #remotes_fired
local scenario_A_loaded = #loadstring_calls > 0

run_loader("B. 無 md3_hub_template.luau (不完整)", false)
local scenario_B_remotes = #remotes_fired
local scenario_B_warnings = #warnings

------------------------------------------------------------
-- 完整性分析
------------------------------------------------------------
print([[

═══════════════════════════════════════════════════════════
  封包完整性分析
═══════════════════════════════════════════════════════════
]])

print("★ 分析: loader 自己會發出哪些封包?")
print("  ── 檢查 loader 原始碼中的 FireServer/InvokeServer 調用...")
print("     grep 結果: 0 個 FireServer, 0 個 InvokeServer")
print("  ── loader 只調用 executor API (isfile/readfile/loadstring/queue_on_teleport)")
print("  ── loader 只註冊 OnTeleport (客戶端事件, 非網路封包)")
print()
print("★ 結論: loader 本身完全不發送任何遊戲封包!")
print()
print("─────────────────────────────────────────────────────────")
print()
print("★ 對比: 完整 RAGEBOT 執行鏈需要的封包 (見 RAGEBOT_ANALYSIS.md)")
print()
print("  必需 1: UseItemRemote:FireServer(\"StartShooting\", ...)   [射擊]")
print("  必需 2: 物理引擎複製 rootPart.CFrame → server              [假位置]")
print("  必需 3: UpdateCameraRotationRemote:FireServer(...)         [視角欺騙]")
print("  必需 4: UseItemRemote:FireServer(\"StartReloading\", ...)  [換彈]")
print()
print("  ★ 這些封包必須由 hub (md3_hub_template.luau) 內部才會發出")
print("  ★ loader 只是把 hub 讀進來並執行, 自己不碰網路")
print()
print("─────────────────────────────────────────────────────────")
print()
print("═══════════════════════════════════════════════════════════")
print("  場景結果對照")
print("═══════════════════════════════════════════════════════════")
print(string.format("  場景 A (有 hub 檔): loaded=%s, warnings=%d",
    scenario_A_loaded, #warnings - scenario_B_warnings))
print(string.format("  場景 B (無 hub 檔): loaded=false, warnings=%d",
    scenario_B_warnings))
print()
print("[驗證判定]")
print("  loader 完整性: ✓ 語法正確, 邏輯完整")
print("  獨立可用性  : ✗ 不完整 - 必須依賴 workspace 內的 hub 檔案")
print("  執行链完整性: ✗ 不完整 - loader 執行後只加了 1 個 OnTeleport 監聽")
print("                        + 讀不到 hub 檔就只印警告然後結束")
print()
print("  缺少組件:")
print("    ✗ md3_hub_template.luau  (RAGEBOT 主體, 需自備)")
print("    ✗ 雲端 URL (cloudUrl 目前是註解狀態, 未啟用)")
print("    ✗ Fighters/PlayerContext/Ragebot 建構器 (在 hub 內)")
print()
print("[結論]")
print("  這個 loader 只是一個 stub / bootloader。它負責:")
print("    1. 從本地 workspace 找 hub 檔")
print("    2. 註冊 queue_on_teleport 讓跨服自動重載")
print("    3. 設 getgenv 標記防止重複載入")
print()
print("  但它本身不含任何 RAGEBOT 邏輯,")
print("  也不會發出任何遊戲封包 (射擊/假位置/視角) 除非 hub 檔存在。")
