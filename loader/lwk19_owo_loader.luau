--[[
    ========================================================================
    lwk19_owo — 自動載入腳本 (Auto-Load & Auto-Execute Script)
    ========================================================================
    參考來源：KiciaHook / Luarmor 混淆腳本之 AutoExecuteScript 與 queue_on_teleport 機制

    【使用方式】：
    1. 【手動執行】：直接將此腳本複製到注入器 (Synapse, Wave, Solara, Celery, Delta 等) 執行。
    2. 【進遊戲自動執行 (Auto-Execute)】：
       將此檔案命名為 `lwk19_owo_loader.luau` 並放入注入器目錄下的 `autoexec/` 資料夾中。
       每次開啟 Roblox 或進入任何伺服器時，注入器將全自動執行本腳本！
    3. 【跨伺服器 / 傳送自動重連 (Teleport Persistence)】：
       當你在遊戲中換服、進入競技匹配 (如 Rivals 匹配排隊) 或傳送地圖時，
       本腳本會自動調用 `queue_on_teleport`，在新伺服器自動無縫重新載入。
    ========================================================================
--]]

-- 防止重複載入防護 (Anti-Duplicate Guard)
if getgenv().lwk19_owo_loaded and not getgenv().lwk19_owo_reloading then
    warn("[lwk19_owo] 腳本已在運行中，略過重複載入。")
    return
end

-- 1. 等待遊戲與本地玩家實例完全載入 (Game Load Waiter)
if not game:IsLoaded() then
    game.Loaded:Wait()
end

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer or Players.PlayerAdded:Wait()

-- 2. 獲取跨服佇列函式 (支援所有主要注入器相容性)
local queueOnTeleport = (syn and syn.queue_on_teleport)
    or (fluxus and fluxus.queue_on_teleport)
    or queue_on_teleport
    or queueonteleport

-- 3. 自動跨服重連註冊 (Auto Execute on Teleport - 參考混淆腳本 AutoExecuteScript 實作)
if queueOnTeleport then
    local teleportConnection
    teleportConnection = LocalPlayer.OnTeleport:Connect(function(teleportState)
        -- 避免多次觸發
        if teleportConnection then
            teleportConnection:Disconnect()
            teleportConnection = nil
        end

        -- 將載入器自身寫入傳送佇列
        queueOnTeleport([[
            -- lwk19_owo 換服自動重新載入
            getgenv().lwk19_owo_reloading = true
            getgenv().lwk19_owo_from_loader = true
            repeat task.wait(0.2) until game:IsLoaded() and game:GetService("Players").LocalPlayer

            -- 若本機已有儲存腳本
            if isfile and isfile("lwk19_owo/md3_hub_template.luau") then
                loadstring(readfile("lwk19_owo/md3_hub_template.luau"))()
            elseif isfile and isfile("lwk19_owo_loader.luau") then
                loadstring(readfile("lwk19_owo_loader.luau"))()
            else
                print("[lwk19_owo] Teleport auto-load queued successfully.")
            end
        ]])
    end)
end

-- 4. 載入主 UI 腳本 (支援本機 workspace 讀取與雲端讀取)
local function executeHub()
    -- 標記已載入與來源為載入器 (Loader Protection bypass)
    getgenv().lwk19_owo_loaded = true
    getgenv().lwk19_owo_reloading = false
    getgenv().lwk19_owo_from_loader = true

    -- 優先從本地 executor workspace 讀取
    local localPaths = {
        "lwk19_owo/md3_hub_template.luau",
        "md3_hub_template.luau",
        "lwk19_owo.luau",
    }

    if typeof(isfile) == "function" and typeof(readfile) == "function" then
        for _, path in ipairs(localPaths) do
            if isfile(path) then
                local content = readfile(path)
                if content and content ~= "" then
                    local runFn, err = loadstring(content)
                    if runFn then
                        print("[lwk19_owo] 成功從本地檔案載入: " .. path)
                        return runFn()
                    else
                        warn("[lwk19_owo] 本地代碼解析錯誤: " .. tostring(err))
                    end
                end
            end
        end
    end

    -- 若本地未找到檔案，提供雲端 Raw 載入範例 (若您已上傳到 GitHub Raw 或 Pastebin)：
    --[[
    local cloudUrl = "https://raw.githubusercontent.com/YOUR_USERNAME/lwk19_owo/main/md3_hub_template.luau"
    local success, scriptContent = pcall(function()
        return game:HttpGet(cloudUrl)
    end)
    if success and scriptContent and scriptContent ~= "" then
        local runFn, err = loadstring(scriptContent)
        if runFn then
            return runFn()
        end
    end
    --]]

    warn("[lwk19_owo] 請確認 'md3_hub_template.luau' 已放置於注入器的 workspace/lwk19_owo/ 目錄中。")
end

-- 執行啟動
local success, err = pcall(executeHub)
if not success then
    warn("[lwk19_owo] 自動載入失敗: " .. tostring(err))
    getgenv().lwk19_owo_loaded = false
end
