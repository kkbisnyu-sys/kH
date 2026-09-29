--[[
=========================================================================
kicia_ragebot_complete.lua — 全民自由 (place 129604661913557)
完整 1:1 KI 主版本 (module iq) 移植 + 14 份分析文件全部對齊
=========================================================================
架構順序 (依 KI R L108494 主 Ragebot 依賴序):
   §0  Services + executor primitives (含 clonefunction 三件套)
   §1  Enum encoding (EnumLibrary)
   §2  FFlag helpers (SetEnabled 用)
   §3  Config defaults (K L61200 逐字)
   §4  ShootLock / FireLock (K L65174)
   §5  CFrameCodec (K L6673 - encode CFrame → {\0..\5})
   §6  RotationCodec (R L37618 - 8-bit per axis camera rotation)
   §7  PartGlue (K L149969 + R L83836 — 完整實作)
   §8  CFrameDesync (K L144260 + R L37592 — Heartbeat/RenderStep)
   §9  StateHook (K L11584 + R L88397 — newproxy dummy)
   §10 ViewAngleDriver (R L37696 — slot 20 + JointsHook + ReplicationHook)
   §11 CharacterController wrapper (R L37963)
   §12 Defense (K L150875 — getDefensiveCFrame + ViewAngles)
   §13 RandomEvasion (K L131635 — 2^30 axis banish)
   §14 TranslocateTarget (K L141948 — kill part)
   §15 ProjectileBreakerTeleport (K L91196 — surface tuck)
   §16 SpatialLimitGate (K L141857 — 2^22 threshold)
   §17 TargetSelection (K L91975 + R L107366)
   §18 ActionPlanner (K L121678 + R L108368)
   §19 GunItem / MeleeItem (R L39674 + K L87924)
   §20 HeadGlueShotPlanner (K L265576 + R L107519)
   §21 BackstabPlanner (K L40109 + R L107783)
   §22 Ragebot 主類 (K L62943 + R L108494)
   §23 Fighter registry stub (Madium: 用 FighterController._player_to_fighter)
   §24 GameLoop (Heartbeat → HeartbeatUpdate)
   §25 UI (Obsidian)
   §26 卸載

修正 (跟目前 kicia_ragebot.lua 對照):
   * PartGlue 每 tick Acquire (檔 06 §2.2, 07 §3.1)
   * Backstab window 0.625s / cooldown 1.25s (檔 08 §17.5)
   * Defense pitch = (Equipped == isAbove) ? -90 : +90 (檔 09 §4)
   * ViewAngleDriver 完整實作 (檔 09 §3)
   * RotationCodec utf8.char(byte) 公式 (檔 09 §2)
   * hitData 是 head 物件空間點 (0, 1, 0) — head 表面上方 1 stud
   * MeleeItem 走 AttackAnimation1 / HeavyAttackAnimation1 (檔 05 §1)
   * SpatialLimitGate BOUND = 2^22 (檔 12 §1.1)
   * -9e37 sentinel 保留原封 (檔 05 §2, 07 §3.3)
=========================================================================
]]

if _G.__kicia_ragebot_stop then _G.__kicia_ragebot_stop() end

--=========================================================================
-- §0  Services + executor primitives
--=========================================================================
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")
local Workspace         = game:GetService("Workspace")
local LocalPlayer       = Players.LocalPlayer

-- Executor primitives (載入時複製一次, 之後被 hook 也攔不到 - 檔 10 §3)
local rawGetMt   = getrawmetatable
local rawNewIdx  = clonefunction and clonefunction(rawGetMt(game).__newindex)
                                  or  rawGetMt(game).__newindex
local rawSetHP   = clonefunction and clonefunction(sethiddenproperty) or sethiddenproperty
local setTID     = setthreadidentity
local getTID     = getthreadidentity
local setFF      = setfflag

-- rawSetCFrame — 檔 14 §2.1: rawNewIndex(root, "CFrame", cf)
local function rawSetCFrame(part, cf)
    if not part or not cf then return end
    pcall(rawNewIdx, part, "CFrame", cf)
end

-- rawFireServer — 檔 11: 載入時複製 FireServer, 避開 __namecall hook
local dummyRemote = Instance.new("RemoteEvent")
local dummyUnreliable = Instance.new("UnreliableRemoteEvent")
local rawFireServer         = dummyRemote.FireServer
local rawFireServerUnreliable = dummyUnreliable.FireServer
dummyRemote:Destroy()
dummyUnreliable:Destroy()

-- ★ v7 新增 (檔 11 §3): 驗證 FireServer 沒被 hook 過, 如失敗就 warn (不卡死, 讓 Ragebot 還能跑)
local function verifyFireServer(fs, label)
    local reasons = {}
    if type(fs) ~= "function" then table.insert(reasons, "not function") end
    if debug and debug.info then
        local ok, src = pcall(debug.info, fs, "s")
        if ok and src ~= "[C]" then table.insert(reasons, "src=" .. tostring(src) .. " (should be [C])") end
    end
    if _G.islclosure and _G.islclosure(fs) then table.insert(reasons, "islclosure=true (被 hookfunction 換成 Lua)") end
    if _G.isfunctionhooked and _G.isfunctionhooked(fs) then table.insert(reasons, "isfunctionhooked=true") end
    if _G.isnewcclosure and _G.isnewcclosure(fs) then table.insert(reasons, "isnewcclosure=true (被 newcclosure 包過)") end
    -- Identity 檢查
    local fresh, freshFs
    if label == "FireServer" then
        fresh = Instance.new("RemoteEvent"); freshFs = fresh.FireServer; fresh:Destroy()
    else
        fresh = Instance.new("UnreliableRemoteEvent"); freshFs = fresh.FireServer; fresh:Destroy()
    end
    if fs ~= freshFs then table.insert(reasons, "identity mismatch (別的外掛動了 FireServer)") end
    if #reasons > 0 then
        warn("[kicia] " .. label .. " 驗證失敗: " .. table.concat(reasons, "; "))
        return false
    end
    return true
end
verifyFireServer(rawFireServer, "FireServer")
verifyFireServer(rawFireServerUnreliable, "FireServerUnreliable")

--=========================================================================
-- §1  EnumLibrary (遊戲內建 enum → byte 編碼)
--=========================================================================
local EnumLibrary = require(ReplicatedStorage.Modules.EnumLibrary)
local function encode(name)
    local v = EnumLibrary._to_enum[name]
    if not v then error("[kicia] EnumLibrary missing: " .. tostring(name)) end
    return v
end
-- 試多個名字, 第一個存在的就用 (RIVALS 用 AttackAnimation1, 全民自由用 Attack1)
local function encodeAny(...)
    for _, name in ipairs({...}) do
        local v = EnumLibrary._to_enum[name]
        if v then return v, name end
    end
    error("[kicia] EnumLibrary missing all of: " .. table.concat({...}, ", "))
end

local TOK_START_SHOOTING       = encode("StartShooting")
local TOK_START_AIMING         = encode("StartAiming")
local TOK_START_RELOADING      = encode("StartReloading")
local TOK_RELOAD               = encode("Reload")
local TOK_ATTACK_ANIM_1, _n1   = encodeAny("AttackAnimation1", "Attack1")
local TOK_HEAVY_ATTACK_ANIM_1, _n2 = encodeAny("HeavyAttackAnimation1", "HeavyAttack1")
local TOK_IS_CROUCHING         = encode("IsCrouching")
print(("[kicia] melee tokens: attack=%s, heavy=%s"):format(_n1, _n2))

-- Remotes
local Remotes = ReplicatedStorage.Remotes.Replication.Fighter
local UseItemRemote              = Remotes.UseItem
local UpdateStateRemote          = Remotes.UpdateState
local UpdateCameraRotationRemote = Remotes.UpdateCameraRotation

--=========================================================================
-- §2  FFlag helpers (檔 08 §2.5)
--=========================================================================
local DEFAULT_FALLEN_H = Workspace.FallenPartsDestroyHeight
local function applyFFlags(on)
    pcall(rawSetHP, Workspace, "FallenPartsDestroyHeight", on and 0/0 or DEFAULT_FALLEN_H)
    -- 三個 FFlag: 檔 08 §2.5, 檔 14 §4
    if setFF then
        pcall(setFF, "DFIntS2PhysicsSenderRate",       on and "120"        or "15")
        pcall(setFF, "DFIntAssemblyHistoryBufferSize", on and "2147483648" or "15")
        pcall(setFF, "DFIntAssemblyHistorySkipSize",   on and "0"          or "8")
    end
end

--=========================================================================
-- §3  Config defaults (K L61200 逐字, 檔 08 §14.1)
--=========================================================================
local Config = { data = {
    Ragebot = {
        Enabled = false,
        Keybind = { State = false, Kind = "Always", Bind = nil, ShowInList = true, Invisible = false },
        Stability          = 0.15,
        ShootFrames        = 1,
        PrioritizeHackers  = false,
        Weapons = {
            Priority = { "Primary", "Secondary", "Melee" },
            Enabled  = { Primary = true, Secondary = true, Melee = true },
            OnEmpty  = "SwapOrReload",
        },
        Evasion = {
            Mode = "Random",
            Random = { AnchorFromCharacter = false, BaseRadius = 100, RadiusRandomFactor = 0.5 },
            ProjectileBreaker = {
                DepthForward = { Min = 0, Max = 4 }, DepthForwardFrequency = 5,
                DepthUp      = { Min = 0, Max = 5.5 }, DepthUpFrequency = 5,
                RepositionInterval = 0.3,
                FallbackAnchorFromCharacter = false,
                FallbackBaseRadius = 100, FallbackRadiusRandomFactor = 0.5,
            },
            Translocate = { Offset = -5 },
        },
        -- 檔 08 §14.1 標 dead: HitscanOffsets / MeleeOffsets 沒有任何地方讀取, 保留欄位對齊 UI
        HitscanOffsets = { Down = 1.75, Up = -0.25 },
        MeleeOffsets   = { Down = 4,    Up = -4 },
    },
}}

--=========================================================================
-- §4  FireLock / ShootLock (K L65174 + 檔 12 §2 — locked or fire)
--=========================================================================
local FireLock = {}
FireLock.__index = FireLock
function FireLock.new() return setmetatable({ _lockedUntil = nil }, FireLock) end
function FireLock:ShouldFire(canFire, duration)
    local now = os.clock()
    local stillLocked = self._lockedUntil ~= nil and now < self._lockedUntil
    if canFire then self._lockedUntil = now + duration end
    return stillLocked or canFire
end
function FireLock:Reset() self._lockedUntil = nil end

--=========================================================================
-- §5  CFrameCodec (K L6673 — CFrame → {\0..\5})
--=========================================================================
local CFrameCodec = {}
function CFrameCodec.encode(cf)
    local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
    return {
        ["\0"] = x, ["\1"] = y, ["\2"] = z,
        ["\3"] = math.atan2(-r12, r22),   -- pitch
        ["\4"] = math.asin(r02),           -- yaw
        ["\5"] = math.atan2(-r01, r00),    -- roll
    }
end

--=========================================================================
-- §6  RotationCodec (R L37618 — 8-bit per axis, 檔 09 §2)
--=========================================================================
local RotationCodec = {}
function RotationCodec.encodeSingle(rad)
    if rad ~= rad then return utf8.char(0) end   -- NaN → 0
    local normalized = rad % (2 * math.pi)
    local byte = math.clamp(math.floor(normalized / (2 * math.pi) * 256 + 0.5), 0, 255)
    return utf8.char(byte)
end
function RotationCodec.encodeCameraRotation(v)
    return RotationCodec.encodeSingle(v.X) .. RotationCodec.encodeSingle(v.Y)
end
function RotationCodec.decodeSingle(byte)
    return byte * 2 * math.pi / 256
end
function RotationCodec.fromXYToCameraRotation(x, y)
    return Vector2.new(x, y) * (2 * math.pi / 256)
end

--=========================================================================
-- §7  PartGlue (K L149969 + R L83836 — 檔 07 §3 完整)
--=========================================================================
-- farCF 在模組載入時「只抽一次」— 檔 07 §3.1
local PG_FAR_CF = CFrame.new(
    math.random(-100000, -10000),
    100000,
    math.random(-100000,  10000)
)

local PartGlue = {}
PartGlue.__index = PartGlue

function PartGlue.new()
    return setmetatable({
        _bindings    = {},   -- ourPart -> targetPart
        _gluedParts  = {},   -- targetPart -> { refCount, weld, originalPart1 }
    }, PartGlue)
end

-- 檔 07 §1: 用 identity 8 寫 PhysicsRepRootPart
local function setPhysicsRoot(part, root)
    local id = getTID and getTID() or nil
    if setTID then pcall(setTID, 8) end
    pcall(rawSetHP, part, "PhysicsRepRootPart", root)
    if setTID and id then pcall(setTID, id) end
end

function PartGlue:_SetupGlue(targetPart)
    local e = self._gluedParts[targetPart]
    if e then e.refCount = e.refCount + 1; return end
    -- 第一次綁定: 拆頭上的 WeldConstraint, 錨定 (檔 07 §3.1 step 2)
    local weld = targetPart:FindFirstChildOfClass("WeldConstraint")
    local origPart1 = weld and weld.Part1 or nil
    if weld then pcall(rawSetHP, weld, "Part1", nil) end
    pcall(rawSetHP, targetPart, "Anchored", true)
    self._gluedParts[targetPart] = { refCount = 1, weld = weld, originalPart1 = origPart1 }
end

function PartGlue:_ReleaseGlue(targetPart)
    local e = self._gluedParts[targetPart]
    if not e then return end
    e.refCount = e.refCount - 1
    if e.refCount > 0 then return end
    if e.weld and e.originalPart1 then
        pcall(rawSetHP, e.weld, "Part1", e.originalPart1)
        pcall(rawSetHP, e.originalPart1, "Anchored", false)
    end
    self._gluedParts[targetPart] = nil
end

-- 每 fire tick 呼叫 (檔 07 §3.1)
function PartGlue:Acquire(ourPart, targetPart)
    setPhysicsRoot(ourPart, targetPart)
    local prev = self._bindings[ourPart]
    if prev ~= targetPart then
        if prev then self:_ReleaseGlue(prev) end
        self:_SetupGlue(targetPart)
        self._bindings[ourPart] = targetPart
    end
    -- 本地把頭搬到 farCF, 旋轉歸零 (檔 07 §3.1 step 3)
    rawSetCFrame(targetPart, CFrame.new(PG_FAR_CF.Position))
    return PG_FAR_CF
end

function PartGlue:Free(ourPart)
    local tgt = self._bindings[ourPart]
    if not tgt then return end
    self._bindings[ourPart] = nil
    self:_ReleaseGlue(tgt)
end

function PartGlue:Destroy()
    for our in pairs(self._bindings) do self:Free(our) end
end

--=========================================================================
-- §8  CFrameDesync (K L144260 + R L37592 — 檔 14 §2)
--=========================================================================
local CFrameDesync = {}
CFrameDesync.__index = CFrameDesync

function CFrameDesync.new(rootPart)
    local self = setmetatable({
        _rootPart  = rootPart,
        _cframe    = nil,
        _oldCFrame = rootPart.CFrame,
        _boundId   = HttpService:GenerateGUID(false),
    }, CFrameDesync)
    -- RenderStep(First): 還原真實位置 (檔 14 §2.1)
    RunService:BindToRenderStep(self._boundId, Enum.RenderPriority.First.Value, function()
        self:_RenderStepUpdate()
    end)
    return self
end

function CFrameDesync:SetServerCFrame(cf) self._cframe = cf end
function CFrameDesync:GetServerCFrame()   return self._cframe or self._rootPart.CFrame end
function CFrameDesync:GetClientCFrame()   return self._oldCFrame or self._rootPart.CFrame end

-- 每 Heartbeat 呼叫 (檔 14 §2.1)
function CFrameDesync:HeartbeatUpdate()
    local root, cf = self._rootPart, self._cframe
    if cf and root and root.Parent then
        self._oldCFrame = root.CFrame
        rawSetCFrame(root, cf)
    end
end

function CFrameDesync:_RenderStepUpdate()
    if self._oldCFrame == nil then return end
    local root = self._rootPart
    if root and root.Parent then
        rawSetCFrame(root, self._oldCFrame)
    end
    self._oldCFrame = nil
end

function CFrameDesync:Destroy()
    pcall(RunService.UnbindFromRenderStep, RunService, self._boundId)
    -- 還原最後一次
    if self._oldCFrame and self._rootPart and self._rootPart.Parent then
        rawSetCFrame(self._rootPart, self._oldCFrame)
    end
end

--=========================================================================
-- §9  StateHook (K L11584 + R L88397 — 檔 09 §11, 檔 11)
--=========================================================================
local StateHook = {}
StateHook.__index = StateHook

function StateHook.new()
    return setmetatable({
        _forced    = {},
        _dummy     = nil,
        _restore   = nil,
        _installed = false,
    }, StateHook)
end

function StateHook:_Load()
    if self._installed then return true end
    if self._loadFailed then return false end          -- 之前試過失敗就別再試
    local ok, mc = pcall(require, LocalPlayer.PlayerScripts.Controllers.MechanicsController)
    if not ok or type(mc) ~= "table" then
        self._loadFailed = true; return false
    end
    self._mcRef = mc
    local mt = getmetatable(mc)
    local uss = mt and mt.__index and mt.__index._UpdateServerState
    if type(uss) ~= "function" then self._loadFailed = true; return false end

    -- 找 RS upvalue
    local rs = ReplicatedStorage
    local upIdx, upOrig
    for i = 1, 30 do
        local ok2, name, val = pcall(debug.getupvalue, uss, i)
        if not ok2 or name == nil then break end
        if val == rs then upIdx, upOrig = i, val; break end
    end
    if not upIdx then
        -- Luraph 混淆 → fakeFireServer install 失敗
        -- Layer A (SetForced 直接送封包) 還是有效, 不影響蹲下功能
        self._loadFailed = true
        warn("[kicia] StateHook: RS upvalue not found (Luraph). fakeFireServer skipped. Layer A (direct send) 仍運作.")
        return false
    end

    -- fakeFireServer: 檢查 _forced, 有就丟棄, 沒有 pass through (檔 09 §11)
    local hook = self
    local function fakeFireServer(_, key, value)
        if hook._forced[key] ~= nil then return end
        return rawFireServer(UpdateStateRemote, key, value)
    end
    local fakeUpdateState = { FireServer = fakeFireServer }
    local fakeFighter     = { UpdateState = fakeUpdateState }
    local fakeReplication = { Fighter = fakeFighter }
    local fakeRemotes     = { Replication = fakeReplication }

    -- dummy: newproxy(true) userdata (KH MCP 實測)
    self._dummy = newproxy(true)
    local dummyMt = getmetatable(self._dummy)
    dummyMt.__index = function(_, k)
        if k == "Remotes" then return fakeRemotes end
        return rs[k]   -- fallback 真 RS
    end

    local okSet = pcall(debug.setupvalue, uss, upIdx, self._dummy)
    if not okSet then return false end

    self._restore = { fn = uss, index = upIdx, original = upOrig }
    self._installed = true
    return true
end

-- ★ Layer A: SetForced 主動送封包 (KI line 11633)
-- ★ Layer B: fakeFireServer 攔遊戲自己送的 (KI line 11600-11604) - Luraph 時失敗
-- ★ Layer C (v4.4 補): IsCrouching 專用 - 額外呼叫 MC:SetCrouching(v) 觸發完整 client state
-- ★ Layer D (v5 補): 每 tick 都重送 - 徹底覆蓋遊戲自己送的 (Luraph 下 Layer B 失效時的救命方案)
function StateHook:SetForced(stateName, value)
    self:_Load()   -- 靜默嘗試 install Layer B
    local encoded = encode(stateName)
    local changed = self._forced[encoded] ~= value
    self._forced[encoded] = value
    -- Layer A: 直接送 packet
    pcall(rawFireServer, UpdateStateRemote, encoded, value)
    -- Layer C: IsCrouching 專用, 觸發 client state pipeline (只在狀態變化時, 避免重複觸發 walkspeed reset)
    if changed and stateName == "IsCrouching" and self._mcRef then
        local setCrouch = self._mcRef.SetCrouching
        if type(setCrouch) == "function" then
            pcall(setCrouch, self._mcRef, value and true or false)
        end
    end
end

function StateHook:ClearForced(stateName)
    local encoded = encode(stateName)
    if self._forced[encoded] == nil then return end
    self._forced[encoded] = nil
    -- Layer C 先跑, 讓 mc 狀態變成 false
    if stateName == "IsCrouching" and self._mcRef then
        local setCrouch = self._mcRef.SetCrouching
        if type(setCrouch) == "function" then
            pcall(setCrouch, self._mcRef, false)
        end
    end
    -- 然後送真實值 (現在應該是 false 了)
    local realVal = false
    if self._mcRef then
        local v = self._mcRef[stateName]
        if v ~= nil then realVal = v end
    end
    pcall(rawFireServer, UpdateStateRemote, encoded, realVal)
end

-- ★ Layer D: 每 tick 重送 forced 值, 蓋掉遊戲自己的 _UpdateServerState
function StateHook:Tick()
    for encoded, value in pairs(self._forced) do
        pcall(rawFireServer, UpdateStateRemote, encoded, value)
    end
end

function StateHook:Destroy()
    -- 先把所有 forced 值 clear 掉 (送真實值給 server)
    for key in pairs(self._forced) do
        -- 反查 stateName (encoded 是 byte)
        for name, enc in pairs(EnumLibrary._to_enum) do
            if enc == key then
                pcall(function() self:ClearForced(name) end)
                break
            end
        end
    end
    -- 拆 fakeFireServer hook (如果有裝)
    if self._restore then
        pcall(debug.setupvalue, self._restore.fn, self._restore.index, self._restore.original)
    end
    self._installed = false
    self._forced    = {}
    self._restore   = nil
end

--=========================================================================
-- §9.5  CameraSwayDisabler (R L82070 — 檔 09 §CameraSwayDisabler)
--   ★ v6 補: hook GetCameraSway 讓 CameraController:GetPublicState 回傳
--   "ThirdPerson" — 讓遊戲以為玩家在第三人稱, 停用相機晃動 + 讓 view angle
--   spoof 更可靠 (第一人稱下相機同步比較嚴)
--=========================================================================
local CameraSwayDisabler = {}
CameraSwayDisabler.__index = CameraSwayDisabler

function CameraSwayDisabler.new() return setmetatable({ _installed = false }, CameraSwayDisabler) end

function CameraSwayDisabler:SetDisabled(disabled)
    if disabled then self:_Install() else self:_Revert() end
end

function CameraSwayDisabler:_Install()
    if self._installed then return end
    local ok, fc = pcall(require, LocalPlayer.PlayerScripts.Controllers.FighterController)
    if not ok then return end
    local mt = getmetatable(fc)
    local proto = mt and mt.__index
    local getSway = proto and (proto.GetCameraSway or rawget(proto, "GetCameraSway"))
    if type(getSway) ~= "function" then return end
    -- 找 CameraController upvalue
    local okCam, cameraController = pcall(function()
        return require(LocalPlayer.PlayerScripts.Controllers.CameraController)
    end)
    if not okCam or not cameraController then return end
    for i = 1, 30 do
        local ok2, name, val = pcall(debug.getupvalue, getSway, i)
        if not ok2 or name == nil then break end
        if type(val) == "table" then
            for k, v in pairs(val) do
                if v == cameraController then
                    local proxy = {}
                    function proxy.GetPublicState() return "ThirdPerson" end
                    val[k] = setmetatable(proxy, { __index = v })
                    self._restore = { container = val, index = k, original = v }
                    self._installed = true
                    return
                end
            end
        end
    end
end

function CameraSwayDisabler:_Revert()
    if not self._installed or not self._restore then return end
    self._restore.container[self._restore.index] = self._restore.original
    self._installed = false
    self._restore = nil
end

function CameraSwayDisabler:Destroy() self:_Revert() end

--=========================================================================
-- §10  ViewAngleDriver (R L37696 — 檔 09 §3 完整)
--=========================================================================
local ViewAngleDriver = {}
ViewAngleDriver.__index = ViewAngleDriver

local function angles_toCameraRotation(angles)
    -- 檔 09 §3.3: 走 encodeSingle 再 decodeSingle 量化, 確保和送出去一致
    if angles.kind == "Normalized" then
        local pRad = math.rad(angles.pitch)
        local yRad = math.rad(angles.yaw)
        return Vector2.new(pRad, yRad)
    else
        return RotationCodec.fromXYToCameraRotation(
            math.clamp(angles.pitch, 0, 255),
            math.clamp(angles.yaw, 0, 255)
        )
    end
end

local function encodeAngles(angles)
    if angles.kind == "Normalized" then
        return RotationCodec.encodeSingle(math.rad(angles.pitch))
            .. RotationCodec.encodeSingle(math.rad(angles.yaw))
    else
        return string.char(math.clamp(math.floor(angles.pitch), 0, 255))
            .. string.char(math.clamp(math.floor(angles.yaw), 0, 255))
    end
end

function ViewAngleDriver.new()
    return setmetatable({
        _slots            = {},
        _winning          = nil,
        _fullySuppressed  = false,
        _dirty            = false,
        _jointsInstalled     = false,
        _replicationInstalled= false,
    }, ViewAngleDriver)
end

function ViewAngleDriver:_Resolve()
    -- 檔 08 §15: 推測取 slot 編號最大的
    local maxSlot, winning = -1, nil
    for slot, angles in pairs(self._slots) do
        if type(slot) == "number" and slot > maxSlot and angles ~= nil then
            maxSlot, winning = slot, angles
        end
    end
    self._winning = winning
end

function ViewAngleDriver:_InstallJointsHook()
    if self._jointsInstalled then return end
    local ok, joints = pcall(function()
        return require(ReplicatedStorage.Modules.ClientFighterCharacterJoints)
    end)
    if not ok or type(joints) ~= "table" then return end
    local origUpdate = joints.Update
    if type(origUpdate) ~= "function" then return end
    local driver = self
    rawset(joints, "Update", function(j, dt, state)
        local w = driver._winning
        local fighter = j and j.ClientFighterCharacter and j.ClientFighterCharacter.ClientFighter
        if w and fighter and fighter.IsLocalPlayer then
            pcall(rawset, state, "CameraRotationRaw", angles_toCameraRotation(w))
        end
        return origUpdate(j, dt, state)
    end)
    self._jointsRestore = { target = joints, orig = origUpdate }
    self._jointsInstalled = true
end

function ViewAngleDriver:_InstallReplicationHook()
    if self._replicationInstalled then return end
    local ok, fc = pcall(require, LocalPlayer.PlayerScripts.Controllers.FighterController)
    if not ok then return end
    local mt = getmetatable(fc)
    local proto = mt and mt.__index
    local loop = proto and (proto._CameraReplicationLoop or proto.CameraReplicationLoop)
    if type(loop) ~= "function" then return end

    -- 找帶 EncodeCameraRotation 的 upvalue
    local upIdx, upOrig
    for i = 1, 30 do
        local ok2, name, val = pcall(debug.getupvalue, loop, i)
        if not ok2 or name == nil then break end
        if type(val) == "table" and getmetatable(val) then
            local mtx = getmetatable(val)
            local idx = mtx and mtx.__index
            if type(idx) == "table" and idx.EncodeCameraRotation then
                upIdx, upOrig = i, val; break
            end
        end
    end
    if not upIdx then return end

    local driver = self
    local proxy = {}
    function proxy.EncodeCameraRotation(_, rot)
        if next(driver._slots) == nil and not driver._fullySuppressed then
            return RotationCodec.encodeCameraRotation(rot)
        end
        pcall(rawset, fc, "_replication_stopped", false)
        return fc._last_encoded_camera_rotation or RotationCodec.encodeCameraRotation(rot)
    end

    pcall(debug.setupvalue, loop, upIdx, proxy)
    self._replicationRestore = { loop = loop, idx = upIdx, orig = upOrig }
    self._replicationInstalled = true
end

function ViewAngleDriver:SendViewAngles(slot, angles)
    if self._slots[slot] == angles then return end
    self._slots[slot] = angles
    self._dirty = true
    self:_Resolve()
    if self._winning ~= nil then
        self:_InstallJointsHook()
        self:_InstallReplicationHook()
    end
end

function ViewAngleDriver:Flush()
    if not self._dirty or self._fullySuppressed then return end
    if self._winning == nil then self._dirty = false; return end
    self._dirty = false
    pcall(rawFireServerUnreliable, UpdateCameraRotationRemote, encodeAngles(self._winning), nil)
end

function ViewAngleDriver:ClearAll()
    for k in pairs(self._slots) do self._slots[k] = nil end
    self._winning = nil
    self._dirty = true
end

function ViewAngleDriver:Destroy()
    if self._jointsRestore then
        pcall(rawset, self._jointsRestore.target, "Update", self._jointsRestore.orig)
    end
    if self._replicationRestore then
        pcall(debug.setupvalue, self._replicationRestore.loop,
              self._replicationRestore.idx, self._replicationRestore.orig)
    end
    self._jointsInstalled = false
    self._replicationInstalled = false
end

--=========================================================================
-- §11  CharacterController wrapper (R L37963)
--=========================================================================
local CharacterController = {}
CharacterController.__index = CharacterController

function CharacterController.new(rootPart)
    return setmetatable({
        _rootPart        = rootPart,
        _rootDesync      = CFrameDesync.new(rootPart),
        _viewAngleDriver = ViewAngleDriver.new(),
    }, CharacterController)
end

function CharacterController:SetServerCFrame(cf)  self._rootDesync:SetServerCFrame(cf) end
function CharacterController:GetServerCFrame()    return self._rootDesync:GetServerCFrame() end
function CharacterController:GetClientCFrame()    return self._rootDesync:GetClientCFrame() end
function CharacterController:GetServerHeadOrigin()return self:GetServerCFrame() + Vector3.new(0, 1.75, 0) end
function CharacterController:HeartbeatUpdate()    self._rootDesync:HeartbeatUpdate() end
function CharacterController:SendViewAngles(slot, angles)
    self._viewAngleDriver:SendViewAngles(slot, angles)
end
function CharacterController:FlushViewAngles()    self._viewAngleDriver:Flush() end
function CharacterController:Destroy()
    self._rootDesync:Destroy()
    self._viewAngleDriver:Destroy()
end

--=========================================================================
-- §12  Defense (K L150875, 檔 09 §4 修正 pitch 符號)
--=========================================================================
local Defense = {}
local rngDef = Random.new()

-- 讀我方 shield 狀態
local function getMyShieldState()
    local fc = require(LocalPlayer.PlayerScripts.Controllers.FighterController)
    local lf = fc.LocalFighter
    if not lf then return "None" end
    local eq = lf.EquippedItem
    if eq and eq.Info then
        if eq.Info.Name == "Riot Shield" then return "Equipped" end
        if eq.Info.Name == "Knife" then return "Knife" end
    end
    for _, it in pairs(lf.Items or {}) do
        if it.Info and it.Info.Name == "Riot Shield" then return "Unequipped" end
    end
    return "None"
end

-- 讀目標 shield 側 (K L150804, 檔 08 §7.1)
local function getRiotShieldSide(fighter)
    if not fighter then return "None" end
    local ok, rot = pcall(function() return fighter:GetCameraRotation() end)
    if not ok or not rot then return "None" end
    local pitch = math.deg(rot.X)
    local eq = fighter.EquippedItem
    if eq and eq.Info and eq.Info.Name == "Riot Shield" then
        if 22 < pitch and pitch < 91 then return "Below" end
        return "Above"
    end
    if type(fighter.Items) == "table" then
        for _, it in pairs(fighter.Items) do
            if it.Info and it.Info.Name == "Riot Shield" then
                if (315 < pitch and pitch < 360) or (0 < pitch and pitch < 91) then
                    return "Above"
                end
                return "Below"
            end
        end
    end
    return "None"
end

function Defense.getDefensiveCFrame(cf, myShield, targetFS, targetRoot)
    if myShield == "Equipped" then
        return CFrame.new(cf.Position, targetRoot.Position)
    elseif myShield == "Unequipped" then
        return CFrame.new(cf.Position, cf.Position + (cf.Position - targetRoot.Position))
    elseif myShield == "None" then
        -- 目標拿 Knife → 隨機轉
        local tgtEq = targetFS and targetFS.EquippedItem
        if tgtEq and tgtEq.Info and tgtEq.Info.Name == "Knife" then
            return CFrame.new(cf.Position) * CFrame.fromOrientation(
                rngDef:NextNumber(0, 2*math.pi),
                rngDef:NextNumber(0, 2*math.pi),
                rngDef:NextNumber(0, 2*math.pi))
        end
    end
    return cf
end

-- 檔 09 §4.2 完整 pitch table
function Defense.getDefensiveViewAngles(myShield, targetFS)
    if myShield == "None" then return nil end
    local isAbove = getRiotShieldSide(targetFS) ~= "Below"
    local equipped = myShield == "Equipped"
    -- 表: Equipped+Above → -90, Equipped+Below → +90, Unequipped+Above → +90, Unequipped+Below → -90
    local pitch = (equipped == isAbove) and -90 or 90
    return { kind = "Normalized", pitch = pitch, yaw = rngDef:NextNumber(0, 360) }
end

--=========================================================================
-- §13  RandomEvasion (K L131635)
--=========================================================================
local RandomEvasion = {}
local RE_FAR = 1073741824  -- 2^30
local rngRE = Random.new()

local function randomPointInShell(center, minR, maxR)
    local TAU = math.pi * 2
    local angle  = rngRE:NextNumber(0, TAU)
    local radius = rngRE:NextNumber(minR, maxR)
    return CFrame.new(center + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius))
        * CFrame.fromOrientation(
            rngRE:NextNumber(0, TAU),
            rngRE:NextNumber(0, TAU),
            rngRE:NextNumber(0, TAU))
end

function RandomEvasion.compute(clientCF)
    local cfg = Config.data.Ragebot.Evasion.Random
    local baseR = cfg.BaseRadius
    local extraR = baseR * cfg.RadiusRandomFactor
    local pos = clientCF.Position
    local anchor = cfg.AnchorFromCharacter and pos or Vector3.new(0, pos.Y, 0)
    local cf = randomPointInShell(anchor, baseR, baseR + extraR)
    local p = cf.Position
    local x, y, z = p.X, p.Y, p.Z
    local axis = rngRE:NextInteger(1, 3)
    if     axis == 1 then x = RE_FAR
    elseif axis == 2 then y = RE_FAR
    else                  z = RE_FAR end
    return cf - p + Vector3.new(x, y, z)
end

--=========================================================================
-- §14  TranslocateTarget (K L141948)
--=========================================================================
local Translocate = {}
function Translocate.compute(clientCF, hasTargets)
    if not hasTargets then
        return randomPointInShell(clientCF.Position, 10000, 1000000000)
    end
    local killPart
    for _, p in CollectionService:GetTagged("OutOfBoundsPart") do
        if p:GetAttribute("KillDelay") == 0 then killPart = p; break end
    end
    if not killPart then
        return randomPointInShell(clientCF.Position, 10000, 1000000000)
    end
    return killPart.CFrame * CFrame.new(0,
        -killPart.Size.Y / 2 + Config.data.Ragebot.Evasion.Translocate.Offset, 0)
end

--=========================================================================
-- §15  ProjectileBreakerTeleport (K L91196, 檔 08 §8)
--=========================================================================
local PBT = {}
PBT.__index = PBT

local pbRng = Random.new()
local PB_SCAN_BUDGET, PB_POOL_TARGET = 64, 30
local SURF_MIN_AREA, SURF_MIN_EDGE, SURF_UP_DOT = 25, 5, 0.98

local HAZARD_TAGS = { "OutOfBoundsPart", "KillBrick" }
local HAZARD_PROBE = OverlapParams.new()
HAZARD_PROBE.FilterType = Enum.RaycastFilterType.Include
HAZARD_PROBE.FilterDescendantsInstances = { Workspace }
local HAZARD_BOX = Vector3.new(5, 5, 5)

local function isHazardPart(inst)
    if inst.Name == "Barriers" then return true end
    for _, tag in ipairs(HAZARD_TAGS) do
        if CollectionService:HasTag(inst, tag) then return true end
    end
    return false
end

local function isNearHazard(pos)
    for _, p in Workspace:GetPartBoundsInBox(CFrame.new(pos), HAZARD_BOX, HAZARD_PROBE) do
        if isHazardPart(p) then return true end
    end
    return false
end

local function findSurface(part)
    if not part:IsA("BasePart") then return nil end
    local size, cf = part.Size, part.CFrame
    local best
    for _, axis in ipairs({
        { n = cf.RightVector, d1 = size.Y, d2 = size.Z, ext = size.X, tan = cf.UpVector },
        { n = cf.UpVector,    d1 = size.X, d2 = size.Z, ext = size.Y, tan = cf.LookVector },
        { n = cf.LookVector,  d1 = size.X, d2 = size.Y, ext = size.Z, tan = cf.UpVector },
    }) do
        local area = axis.d1 * axis.d2
        if area >= SURF_MIN_AREA and math.min(axis.d1, axis.d2) >= SURF_MIN_EDGE then
            for _, sign in ipairs({1, -1}) do
                local n = axis.n * sign
                if n.Y >= SURF_UP_DOT then
                    if not best or area > best.area then
                        best = { n = n, area = area, half = axis.ext / 2, tan = axis.tan, cf = cf }
                    end
                end
            end
        end
    end
    if not best then return nil end
    local up = best.n
    local fwd = best.tan - up * best.tan:Dot(up)
    if fwd.Magnitude < 1e-3 then return nil end
    fwd = fwd.Unit
    return {
        surfacePosition = cf.Position + up * best.half,
        up = up,
        forward = fwd,
        right = fwd:Cross(up).Unit,
    }
end

local function surfaceCFrame(s, depthUp, depthFwd)
    return CFrame.fromMatrix(
        s.surfacePosition - s.up * 0.01 - s.up * depthUp + s.forward * depthFwd,
        s.right, s.up, -s.forward)
end

local function oscillate(range, freq)
    return range.Min + (range.Max - range.Min)
        * ((math.sin(os.clock() * 2 * math.pi * freq) + 1) * 0.5)
end
local function depthUp()      local c = Config.data.Ragebot.Evasion.ProjectileBreaker; return oscillate(c.DepthUp, c.DepthUpFrequency) end
local function depthForward() local c = Config.data.Ragebot.Evasion.ProjectileBreaker; return oscillate(c.DepthForward, c.DepthForwardFrequency) end

local function pbFallback(clientCF)
    local c = Config.data.Ragebot.Evasion.ProjectileBreaker
    local baseR = c.FallbackBaseRadius
    local extraR = baseR * c.FallbackRadiusRandomFactor
    local pos = clientCF.Position
    local anchor = c.FallbackAnchorFromCharacter and pos or Vector3.new(0, pos.Y, 0)
    local cf = randomPointInShell(anchor, baseR, baseR + extraR)
    local p = cf.Position
    local x, y, z = p.X, p.Y, p.Z
    local axis = pbRng:NextInteger(1, 3)
    if     axis == 1 then x = RE_FAR
    elseif axis == 2 then y = RE_FAR
    else                  z = RE_FAR end
    return cf - p + Vector3.new(x, y, z)
end

function PBT.new(fighters)
    return setmetatable({
        _fighters              = fighters,
        _pool                  = {},
        _processedParts        = {},
        _poolEnvironmentID     = nil,
        _nextPositionCooldown  = -1,
        _lastBreakSurface      = nil,
    }, PBT)
end

function PBT:BindEnvironment(envId)
    self._poolEnvironmentID    = envId
    self._pool                 = {}
    self._processedParts       = {}
    self._nextPositionCooldown = -1
    self._lastBreakSurface     = nil
end

-- 檔 08 §8: 只看 Slingshot
function PBT:_HasProjectileThreat()
    for _, enemy in pairs(self._fighters.enemies or {}) do
        local eq = enemy and enemy.EquippedItem
        if eq and eq.Info and eq.Info.Name == "Slingshot" then return true end
    end
    return false
end

function PBT:_ScanBatch(envId)
    local scanned = 0
    local midUp, midFwd =
        (Config.data.Ragebot.Evasion.ProjectileBreaker.DepthUp.Min +
         Config.data.Ragebot.Evasion.ProjectileBreaker.DepthUp.Max) * 0.5,
        (Config.data.Ragebot.Evasion.ProjectileBreaker.DepthForward.Min +
         Config.data.Ragebot.Evasion.ProjectileBreaker.DepthForward.Max) * 0.5

    local function consider(part)
        if not part:IsA("BasePart") or self._processedParts[part] then return end
        self._processedParts[part] = true
        scanned = scanned + 1
        local s = findSurface(part); if not s then return end
        if isNearHazard(surfaceCFrame(s, midUp, midFwd).Position) then return end
        table.insert(self._pool, s)
    end
    for _, root in CollectionService:GetTagged("RaycastWhitelist" .. tostring(envId)) do
        if not isHazardPart(root) then
            consider(root)
            if scanned >= PB_SCAN_BUDGET or #self._pool >= PB_POOL_TARGET then return end
            for _, d in root:GetDescendants() do
                if not isHazardPart(d) then
                    consider(d)
                    if scanned >= PB_SCAN_BUDGET or #self._pool >= PB_POOL_TARGET then return end
                end
            end
        end
    end
end

function PBT:_BreakLine()
    local envId = self._poolEnvironmentID; if envId == nil then return nil end
    if #self._pool < PB_POOL_TARGET then self:_ScanBatch(envId) end
    if #self._pool < PB_POOL_TARGET then return nil end
    self._nextPositionCooldown = os.clock() + Config.data.Ragebot.Evasion.ProjectileBreaker.RepositionInterval
    return self._pool[pbRng:NextInteger(1, #self._pool)]
end

function PBT:Compute(clientCF)
    if os.clock() < self._nextPositionCooldown and self._lastBreakSurface then
        return surfaceCFrame(self._lastBreakSurface, depthUp(), depthForward())
    end
    if not self:_HasProjectileThreat() then
        self._lastBreakSurface = nil
        return pbFallback(clientCF)
    end
    local s = self:_BreakLine()
    if not s then return pbFallback(clientCF) end
    self._lastBreakSurface = s
    return surfaceCFrame(s, depthUp(), depthForward())
end

function PBT:ResetState()
    self._nextPositionCooldown = -1
    self._lastBreakSurface = nil
end

--=========================================================================
-- §16  SpatialLimitGate (K L141857, 檔 12 §1)
--=========================================================================
local SpatialLimitGate = {}
SpatialLimitGate.__index = SpatialLimitGate

local SLG_BOUND = 4194304  -- 2^22, 檔 12 §1.1

local function exceedsThreshold(v)
    return math.abs(v.X) >= SLG_BOUND
        or math.abs(v.Y) >= SLG_BOUND
        or math.abs(v.Z) >= SLG_BOUND
end

function SpatialLimitGate.new(fighters)
    return setmetatable({ _measurements = {}, _fighters = fighters }, SpatialLimitGate)
end

function SpatialLimitGate:Tick(target)
    local now = os.clock()
    local fs = target.fighterState
    local m = self._measurements[fs]
    if not m then
        m = { expectedDuration = 1, limitEntryTime = nil }
        self._measurements[fs] = m
    end
    -- 檔 08 §6.1: 對方有子彈 = alive
    local hasAmmo = true
    local eq = fs and fs.EquippedItem
    if eq and eq.Info and eq.Info.Type == "Gun" then
        hasAmmo = (eq.Data and eq.Data.Ammo or 0) > 0
    end

    local rootPos = target.aliveState.rootPart.Position
    if not exceedsThreshold(rootPos) then
        if m.limitEntryTime then
            if hasAmmo then m.expectedDuration = now - m.limitEntryTime end
            m.limitEntryTime = nil
        end
        return false
    end
    if m.limitEntryTime == nil then m.limitEntryTime = now end
    if hasAmmo and (now - m.limitEntryTime) >= m.expectedDuration - Config.data.Ragebot.Stability then
        return false
    end
    return true
end

--=========================================================================
-- §23 (先寫) Fighter registry stub — Madium 用 FighterController._player_to_fighter
--=========================================================================
local FighterController = require(LocalPlayer.PlayerScripts.Controllers.FighterController)

local FighterRegistry = { enemies = {}, byPlayer = {}, _connections = {} }

local function isEnemyOf(myFighter, otherFighter)
    if not myFighter or not otherFighter then return false end
    if not myFighter.Data or not otherFighter.Data then return true end
    if myFighter.Data.EnvironmentID ~= otherFighter.Data.EnvironmentID then return false end
    if myFighter.Data.EnvironmentID == nil then return false end
    if myFighter.Data.TeamID and otherFighter.Data.TeamID then
        return myFighter.Data.TeamID ~= otherFighter.Data.TeamID
    end
    return true
end

function FighterRegistry:Refresh()
    self.enemies = {}
    self.byPlayer = {}
    local myF = FighterController.LocalFighter
    for player, fighter in pairs(FighterController._player_to_fighter or {}) do
        if player ~= LocalPlayer and fighter then
            self.byPlayer[player] = fighter
            if isEnemyOf(myF, fighter) then
                self.enemies[player] = fighter
            end
        end
    end
end

--=========================================================================
-- §17  TargetSelection (K L91975, 檔 08 §4.2)
--=========================================================================
local PlayerTagsStub = {
    _tags = {},
    Has = function(self, p, t) return self._tags[p] and self._tags[p][t] or false end,
    GetPlayersWith = function(self, t)
        local out = {}
        for p, tags in pairs(self._tags) do if tags[t] then table.insert(out, p) end end
        return out
    end,
    Add = function(self, p, t)
        self._tags[p] = self._tags[p] or {}
        self._tags[p][t] = true
    end,
}

-- 檔 08 §4.2 isValid
local function isValidTarget(fighter)
    if not fighter then return false end
    -- isEnemy 由 FighterRegistry.enemies 保證
    -- IsInvincible: Entity:Get("IsInvincible") (檔 08 §4.2)
    if fighter.Entity and type(fighter.Entity.Get) == "function" then
        local ok, inv = pcall(fighter.Entity.Get, fighter.Entity, "IsInvincible")
        if ok and inv then return false end
    end
    -- character.state.alive
    if fighter.Entity and type(fighter.Entity.IsAlive) == "function" then
        local ok, alive = pcall(fighter.Entity.IsAlive, fighter.Entity)
        if ok and not alive then return false end
    end
    -- 拿刀 deflect
    local eq = fighter.EquippedItem
    if eq and eq.Info and eq.Info.DeflectDuration and type(eq._attack_cooldown) == "number" then
        if tick() < eq._attack_cooldown then return false end
    end
    return true
end

local function toTarget(fighter, player)
    -- 建 aliveState / fighterState 抽象 (Madium 環境 fighter 已經是 state)
    local char = player and player.Character
    local head = char and char:FindFirstChild("HitboxHead")
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not (head and root) then return nil end
    return {
        fighterState = fighter,
        aliveState   = { rootPart = root, hitboxHead = head, alive = true },
        player       = player,
    }
end

local TargetSelection = {}
TargetSelection.__index = TargetSelection

function TargetSelection.new(fighters, playerTags)
    return setmetatable({ _fighters = fighters, _playerTags = playerTags }, TargetSelection)
end

function TargetSelection:GetTarget()
    self._fighters:Refresh()
    local prio = Config.data.Ragebot.PrioritizeHackers
    if prio then
        for _, player in pairs(self._playerTags:GetPlayersWith("Hacker")) do
            local f = self._fighters.byPlayer[player]
            if f and isValidTarget(f) then
                local t = toTarget(f, player); if t then return t end
            end
        end
    end
    for player, enemy in pairs(self._fighters.enemies) do
        if not (prio and self._playerTags:Has(player, "Hacker")) then
            if isValidTarget(enemy) then
                local t = toTarget(enemy, player); if t then return t end
            end
        end
    end
    return nil
end

function TargetSelection:HasTargets()
    self._fighters:Refresh()
    for _, enemy in pairs(self._fighters.enemies) do
        if isValidTarget(enemy) then return true end
    end
    return false
end

--=========================================================================
-- §18  ActionPlanner (K L121678)
--=========================================================================
local ActionPlanner = {}

local function slotOfItem(item)
    return item.Info and item.Info.Class  -- Primary/Secondary/Melee
end

-- ★ 修 KI 古老 bug (檔 08 §5.2, 檔 13 §I-1):
--   Reload mode 在有多把空槍時, 背包後面的會蓋掉前面 (跳過 priority)
--   → 我方修正: 空槍也要用 priority 排序, 不再直接蓋 best
--   另外 Reload mode 下如果沒 melee 可切, 手上又是空槍在 reload → 直接 EvadePlan 回 nil, 不 spam
function ActionPlanner.getAction(ctx)
    local lf = ctx.itemBehaviors
    if not lf then return nil end
    local W = Config.data.Ragebot.Weapons
    local best, bestP           = nil, math.huge
    local emptyBest, emptyP     = nil, math.huge
    local anyEnabled            = false
    for _, item in pairs(lf.Items or {}) do
        local slot = slotOfItem(item)
        if slot and W.Enabled[slot] then
            anyEnabled = true
            local p = table.find(W.Priority, slot) or math.huge
            if item.Info.Type == "Gun" and (item.Data.Ammo or 0) == 0 then
                -- 空槍 → 存進 emptyBest (照 priority)
                if (item.Data.AmmoReserve or 0) > 0 and p < emptyP then
                    emptyBest, emptyP = { item = item, type = "Gun" }, p
                end
            elseif best == nil or p < bestP then
                -- 有彈藥的槍 or melee → 存進 best
                best, bestP = { item = item, type = item.Info.Type }, p
            end
        end
    end
    if not anyEnabled then return nil end
    -- ★ Reload mode: 手上是空槍 + 還有 melee 可切 → 優先 Swap 到 melee (不是硬 Reload)
    -- ★ Reload mode: 手上是空槍 + 沒別的能打 → 才 Reload
    if W.OnEmpty == "Reload" then
        if best then
            if not best.item.IsEquipped then return { type = "Swap", itemEnum = best } end
            return { type = "Attack", itemEnum = best }
        end
        if emptyBest == nil then return nil end
        if emptyBest.item.IsEquipped then return { type = "Reload", itemEnum = emptyBest } end
        return { type = "Swap", itemEnum = emptyBest }
    end
    -- Swap / SwapOrReload
    if best == nil then
        if W.OnEmpty == "Swap" or emptyBest == nil then return nil end
        return emptyBest.item.IsEquipped
            and { type = "Reload", itemEnum = emptyBest }
            or  { type = "Swap",   itemEnum = emptyBest }
    end
    if not best.item.IsEquipped then return { type = "Swap", itemEnum = best } end
    if best.type == "Gun" and (best.item.Data.Ammo or 0) == 0 then
        return { type = "Reload", itemEnum = best }
    end
    return { type = "Attack", itemEnum = best }
end

--=========================================================================
-- §19  GunItem / MeleeItem (R L39674, K L87924)
--=========================================================================
local pi = math.pi
local ABOVE_ORIGIN = { ["\0"] = -9e37, ["\1"] = 0,     ["\2"] = 0, ["\3"] = -pi/2, ["\4"] = pi, ["\5"] = pi }
local ABOVE_DIR    = { ["\0"] = 0,     ["\1"] = -9e7,  ["\2"] = 0, ["\3"] = -pi/2, ["\4"] = pi, ["\5"] = pi }
local BELOW_ORIGIN = { ["\0"] = -9e37, ["\1"] = 0,     ["\2"] = 0, ["\3"] =  pi/2, ["\4"] = pi, ["\5"] = pi }
local BELOW_DIR    = { ["\0"] = 0,     ["\1"] =  9e7,  ["\2"] = 0, ["\3"] =  pi/2, ["\4"] = pi, ["\5"] = pi }
local HIT_DATA     = { ["\0"] = 0,     ["\1"] = 1,     ["\2"] = 0, ["\3"] = 0,     ["\4"] = 0,  ["\5"] = 0 }

-- 檔 05 §1 payload 格式
local function gunShootEncoded(item, origin, dir, head, hitData)
    local shotArgs = { ["\0"] = origin, ["\1"] = dir, ["\2"] = head, ["\3"] = hitData }
    local payload
    if item.Info.IsRaycast then
        payload = { ["\1"] = shotArgs, ["\2"] = true }
    else
        payload = { ["\1"] = shotArgs }
    end
    rawFireServer(UseItemRemote, item.Data.ObjectID, TOK_START_SHOOTING, payload, nil)
end

local function meleeAttackEncoded(item, origin, dir, head, hitData)
    local shotArgs = { ["\0"] = origin, ["\1"] = dir, ["\2"] = head, ["\3"] = hitData }
    rawFireServer(UseItemRemote, item.Data.ObjectID, TOK_START_SHOOTING,
        { ["\1"] = shotArgs, ["\2"] = TOK_ATTACK_ANIM_1 }, nil)
end

local function meleeHeavyAttackEncoded(item, origin, dir, head, hitData)
    local shotArgs = { ["\0"] = origin, ["\1"] = dir, ["\2"] = head, ["\3"] = hitData }
    rawFireServer(UseItemRemote, item.Data.ObjectID, TOK_START_AIMING,
        { ["\1"] = shotArgs, ["\2"] = TOK_HEAVY_ATTACK_ANIM_1 }, nil)
end

local function gunReload(item)
    -- ★ 已在 reload 中 → 不送
    if itemIsReloading(item) then return end
    -- ★ 節流 (0.5 秒最多送一次同一把槍)
    if not shouldSendReload(item) then return end
    if type(item.Reload) == "function" then pcall(item.Reload, item); return end
    if (item.Data.AmmoReserve or 0) <= 0 then return end
    if (item.Data.Ammo or 0) >= (item.Info.MaxAmmo or 999) then return end
    rawFireServer(UseItemRemote, item.Data.ObjectID, TOK_START_RELOADING,
        { ["\1"] = TOK_RELOAD, ["\2"] = TOK_RELOAD }, nil)
end

local function itemEquip(item)
    if item.IsEquipped then return end
    if type(item.Equip) == "function" then pcall(item.Equip, item); return end
    local cf = item.ClientFighter or FighterController.LocalFighter
    local idx = (item.Data and item.Data.ItemIndex) or item.index
    if not cf or not idx then return end
    if type(cf.EquipItem) == "function" then
        if setTID then pcall(setTID, 2) end
        pcall(cf.EquipItem, cf, idx)
        if setTID then pcall(setTID, 8) end
    end
end

-- ★ 修: 同時檢查 IsReloading() 和 _reload_cooldown / _shoot_cooldown_no_ammo
-- MCP 實測 (槍支遊戲 Sniper): IsReloading() 回 false 但 _reload_cooldown 還有 2 秒
-- KI 原檔 (檔 13 §L) 的 IsReloading 兩者都看, 我方 fallback 補齊
local function itemIsReloading(item)
    local now = tick()
    if type(item.IsReloading) == "function" then
        local ok, r = pcall(item.IsReloading, item)
        if ok and r then return true end
    end
    local rc = item._reload_cooldown
    if type(rc) == "number" and now < rc then return true end
    local sc = item._shoot_cooldown_no_ammo
    if type(sc) == "number" and now < sc then return true end
    return false
end

-- ★ Reload 送包節流: 每把槍最少間隔 0.5 秒送一次 Reload, 避免每 tick spam
local _reloadSentAt = setmetatable({}, { __mode = "k" })
local function shouldSendReload(item)
    local lastSent = _reloadSentAt[item]
    local now = tick()
    if lastSent and (now - lastSent) < 0.5 then return false end
    _reloadSentAt[item] = now
    return true
end

--=========================================================================
-- §20  HeadGlueShotPlanner (K L265576, R L107519)
--=========================================================================
local HeadGlueShotPlanner = {}
HeadGlueShotPlanner.__index = HeadGlueShotPlanner

local ABOVE_OFFSET = Vector3.new(0, -0.7,  0.05)
local BELOW_OFFSET = Vector3.new(0, -3.85, 0.05)

local function lookAtFrom(origin, focus)
    local dir = focus - origin
    dir = Vector3.new(dir.X, 0, dir.Z)
    if dir.Magnitude < 1e-3 then dir = Vector3.new(0, 0, -1) end
    return CFrame.lookAt(origin, origin + dir, Vector3.new(0, -1, 0))
end

local function randomFarGun()
    return CFrame.new(
        math.random(-1000000, 1000000),
        math.random(5000, 10000),
        math.random(-1000000, 1000000))
end

function HeadGlueShotPlanner.new(partGlue)
    return setmetatable({
        _partGlue     = partGlue,
        _shootLock    = FireLock.new(),
        _gluedOurPart = nil,
    }, HeadGlueShotPlanner)
end

function HeadGlueShotPlanner:Plan(dt, target, gun, ourRoot, gated)
    local head = target.aliveState.hitboxHead
    local side = getRiotShieldSide(target.fighterState)
    local isAbove = side ~= "Below"
    -- 檔 07 §3.1: PartGlue.Acquire 每 tick 都做 (在 ShootLock 之前)
    local glued = self._partGlue:Acquire(ourRoot, head)
    self._gluedOurPart = ourRoot
    local offset = isAbove and ABOVE_OFFSET or BELOW_OFFSET
    local stand
    if isAbove then
        stand = glued + offset
    else
        stand = lookAtFrom(glued.Position + offset, head.Position)
    end
    if not self._shootLock:ShouldFire(gated, dt * Config.data.Ragebot.ShootFrames) then
        return randomFarGun(), nil
    end
    return stand, function()
        local origin = isAbove and ABOVE_ORIGIN or BELOW_ORIGIN
        local dir    = isAbove and ABOVE_DIR    or BELOW_DIR
        gunShootEncoded(gun, origin, dir, head, HIT_DATA)
    end
end

function HeadGlueShotPlanner:ResetState()
    self._shootLock:Reset()
    if self._gluedOurPart then
        self._partGlue:Free(self._gluedOurPart)
        self._gluedOurPart = nil
    end
end

--=========================================================================
-- §21  BackstabPlanner (K L40109, 檔 08 §7.4)
--=========================================================================
local BackstabPlanner = {}
BackstabPlanner.__index = BackstabPlanner

local BS_HITBOX_WINDOW = 0.625   -- 檔 08 §7.4 修正
local BS_ATTACK_CD     = 1.25

local function randomFarMelee()
    return CFrame.new(
        math.random(-10000000, -100000),
        math.random(5000, 10000),
        math.random(-10000000, -100000))
end

local function normalizedAngles(pitch, yaw)
    return { kind = "Normalized", pitch = math.deg(pitch), yaw = math.deg(yaw) }
end

local function withRotation(base, rx, ry, rz)
    return {
        ["\0"] = base["\0"], ["\1"] = base["\1"], ["\2"] = base["\2"],
        ["\3"] = rx, ["\4"] = ry, ["\5"] = rz,
    }
end

function BackstabPlanner.new(partGlue)
    return setmetatable({
        _partGlue           = partGlue,
        _shootLock          = FireLock.new(),
        _hitboxWindowUntil  = -1,
        _attackCooldown     = -1,
        _gluedOurPart       = nil,
    }, BackstabPlanner)
end

function BackstabPlanner:_RecordBackstab()
    local now = os.clock()
    self._hitboxWindowUntil = now + BS_HITBOX_WINDOW
    self._attackCooldown    = now + BS_ATTACK_CD
end

function BackstabPlanner:Plan(dt, target, melee, ourRoot, gated)
    local head = target.aliveState.hitboxHead
    local root = target.aliveState.rootPart
    local side = getRiotShieldSide(target.fighterState)
    local isAbove = side ~= "Below"

    local glued = self._partGlue:Acquire(ourRoot, head)
    self._gluedOurPart = ourRoot

    local offset = isAbove and ABOVE_OFFSET or BELOW_OFFSET
    local stand
    if isAbove then
        stand = glued + offset
    else
        stand = lookAtFrom(glued.Position + offset, head.Position)
    end

    local pitch, yaw, roll = root.CFrame:ToOrientation()
    local atkPitch = isAbove and -pi/2 or pi/2
    local fromBase = isAbove and ABOVE_ORIGIN or BELOW_ORIGIN
    local toBase   = isAbove and ABOVE_DIR    or BELOW_DIR
    local from = withRotation(fromBase, atkPitch, yaw, roll)
    local to   = withRotation(toBase,   atkPitch, yaw, roll)

    local now = os.clock()
    -- 檔 08 §7.4: 已在 hitbox window 內 → 每 frame 都送 heavy attack
    if now < self._hitboxWindowUntil then
        return stand, normalizedAngles(pitch, yaw), function()
            meleeHeavyAttackEncoded(melee, from, to, head, HIT_DATA)
        end
    end
    if not self._shootLock:ShouldFire(gated, dt * Config.data.Ragebot.ShootFrames) then
        return randomFarMelee(), nil, nil
    end
    if now < self._attackCooldown then
        return randomFarMelee(), nil, nil
    end
    if melee.Info and melee.Info.Name ~= "Knife" then
        return stand, nil, function()
            meleeAttackEncoded(melee, from, to, head, HIT_DATA)
        end
    end
    -- Knife: 開始 backstab
    self:_RecordBackstab()
    return stand, normalizedAngles(pitch, yaw), function()
        meleeHeavyAttackEncoded(melee, from, to, head, HIT_DATA)
    end
end

function BackstabPlanner:ResetState()
    self._hitboxWindowUntil = -1
    self._attackCooldown    = -1
    self._shootLock:Reset()
    if self._gluedOurPart then
        self._partGlue:Free(self._gluedOurPart)
        self._gluedOurPart = nil
    end
end

--=========================================================================
-- §22  Ragebot 主類 (K L62943, R L108494)
--=========================================================================
local Ragebot = {}
Ragebot.__index = Ragebot

local VIEW_ANGLES_SLOT = 20

function Ragebot.new()
    local partGlue = PartGlue.new()
    return setmetatable({
        _enabled                 = false,
        _partGlue                = partGlue,
        _stateHook               = StateHook.new(),
        _cameraSwayDisabler      = CameraSwayDisabler.new(),  -- ★ v6
        _spatialLimitGate        = SpatialLimitGate.new(FighterRegistry),
        _targetSelection         = TargetSelection.new(FighterRegistry, PlayerTagsStub),
        _projectileBreakerTeleport= PBT.new(FighterRegistry),
        _hitscanStrategy         = HeadGlueShotPlanner.new(partGlue),
        _meleeStrategy           = BackstabPlanner.new(partGlue),
        _characterController     = nil,
        _fireCount               = 0,
        _crouchForced            = false,
        _lastTargetWorld         = nil,
        _lastDefensiveViewAngles = nil,
        _diagnostic              = false,  -- ★ v6: 設 true 印每次射擊
    }, Ragebot)
end

function Ragebot:_EnsureCharacterController()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return nil end
    if not self._characterController or self._characterController._rootPart ~= root then
        if self._characterController then self._characterController:Destroy() end
        self._characterController = CharacterController.new(root)
        -- 綁環境 for ProjectileBreaker
        local myF = FighterController.LocalFighter
        if myF and myF.Data then
            self._projectileBreakerTeleport:BindEnvironment(myF.Data.EnvironmentID)
        end
    end
    return self._characterController
end

function Ragebot:SetEnabled(v)
    if self._enabled == v then return end
    self._enabled = v
    applyFFlags(v)
    self._cameraSwayDisabler:SetDisabled(v)  -- ★ v6: 啟用時 hook 相機晃動 (讓 view spoof 更穩)
    if not v then self:_Reset() end
    print(("[kicia_ragebot] %s (fired %d, setfflag=%s)"):format(
        v and "ON" or "OFF", self._fireCount, tostring(type(setfflag))))
end

function Ragebot:_ApplyForcedCrouch(forced)
    if forced and not self._crouchForced then
        self._stateHook:SetForced("IsCrouching", true)
        self._crouchForced = true
    elseif (not forced) and self._crouchForced then
        self._stateHook:ClearForced("IsCrouching")
        self._crouchForced = false
    end
end

function Ragebot:_Reset()
    self._lastTargetWorld         = nil
    self._lastDefensiveViewAngles = nil
    self:_ApplyForcedCrouch(false)
    self._meleeStrategy:ResetState()
    self._hitscanStrategy:ResetState()
    self._projectileBreakerTeleport:ResetState()
    local cc = self._characterController
    if cc then
        cc:SetServerCFrame(nil)
        cc:SendViewAngles(VIEW_ANGLES_SLOT, nil)
    end
end

function Ragebot:_EvadePlan(clientCF, mode)
    if mode == "Off" then return {} end
    if mode == "ProjectileBreaker" then
        return { cframe = self._projectileBreakerTeleport:Compute(clientCF), shouldSkipDefense = true }
    end
    return { cframe = RandomEvasion.compute(clientCF) }
end

function Ragebot:_Plan(dt, action, target, ourRoot, clientCF, evadeMode)
    local gated = target ~= nil and not self._spatialLimitGate:Tick(target)
    if action == nil then return self:_EvadePlan(clientCF, evadeMode) end
    if action.type == "Swap" then
        local item = action.itemEnum.item
        local plan = self:_EvadePlan(clientCF, evadeMode)
        plan.weaponAction = function() itemEquip(item) end
        plan._isReloadOrSwap = true
        return plan
    end
    if action.type == "Reload" then
        local item = action.itemEnum.item
        local plan = self:_EvadePlan(clientCF, evadeMode)
        plan.weaponAction = function() gunReload(item) end
        plan._isReloadOrSwap = true
        return plan
    end
    if target == nil then return self:_EvadePlan(clientCF, evadeMode) end
    local ie = action.itemEnum
    if ie.type == "Gun" then
        if itemIsReloading(ie.item) then return self:_EvadePlan(clientCF, evadeMode) end
        local cf, act = self._hitscanStrategy:Plan(dt, target, ie.item, ourRoot, gated)
        return { cframe = cf, weaponAction = act, shouldForceCrouch = true, isAimPose = act ~= nil }
    end
    if ie.type == "Melee" then
        local cf, va, act = self._meleeStrategy:Plan(dt, target, ie.item, ourRoot, gated)
        return {
            cframe = cf, viewAngles = va, weaponAction = act,
            shouldSkipDefense = true, shouldForceCrouch = true,
        }
    end
    return {}
end

-- ★ v6 新增: 算出從我方到 target head 的 view angles
-- 用途: 當 gun 沒 viewAngles + 沒 defensive angles 時, 至少送個對準 target 的角度,
-- 這樣 ViewAngleDriver:SendViewAngles 會觸發 hook install → camera replication 被接管
local function computeAimAtTargetViewAngles(cc, target)
    if not target then return nil end
    local myPos = (cc:GetClientCFrame() or CFrame.new()).Position
    local headPos = target.aliveState.hitboxHead.Position
    local dir = headPos - myPos
    if dir.Magnitude < 1e-3 then return nil end
    dir = dir.Unit
    -- Roblox camera: pitch = arcsin(-Y), yaw = atan2(-X, -Z)
    local pitch = math.asin(math.clamp(-dir.Y, -1, 1))
    local yaw   = math.atan2(-dir.X, -dir.Z)
    return { kind = "Normalized", pitch = math.deg(pitch), yaw = math.deg(yaw) }
end

function Ragebot:_ApplyPlan(plan, target, cc)
    local cframe = plan.cframe
    local viewAngles = plan.viewAngles
    if cframe == nil or target == nil or plan.shouldSkipDefense then
        cc:SetServerCFrame(cframe)
        cc:SendViewAngles(VIEW_ANGLES_SLOT, viewAngles)
    else
        local myShield = getMyShieldState()
        cc:SetServerCFrame(Defense.getDefensiveCFrame(
            cframe, myShield, target.fighterState, target.aliveState.rootPart))
        if plan.isAimPose or plan.shouldDefendInPlace then
            self._lastDefensiveViewAngles = Defense.getDefensiveViewAngles(myShield, target.fighterState)
        end
        -- ★ v6: 三層 fallback: plan.viewAngles → defensive → 對準 target
        -- 保證 ViewAngleDriver 有值可送 → replicationHook 會被 install → 相機朝向不會漏
        viewAngles = viewAngles or self._lastDefensiveViewAngles
        if viewAngles == nil and plan.isAimPose then
            viewAngles = computeAimAtTargetViewAngles(cc, target)
        end
        cc:SendViewAngles(VIEW_ANGLES_SLOT, viewAngles)
    end
    -- ★ FIX: 立刻 apply, 讓 rootPart.CFrame 在 weaponAction() 之前就已設定
    cc:HeartbeatUpdate()
    cc:FlushViewAngles()
    -- ★ v6 diagnostic
    if self._diagnostic and target then
        local serverPos = cc:GetServerCFrame() and cc:GetServerCFrame().Position
        local headPos = target.aliveState.hitboxHead.Position
        print(string.format("[kicia] shoot pos=%s → head=%s viewAngles=%s",
            tostring(serverPos), tostring(headPos), viewAngles and "SET" or "nil"))
    end
end

function Ragebot:Update(dt)
    if not self._enabled then self:_Reset(); return end
    local myF = FighterController.LocalFighter
    if not myF or not myF.Data or not myF.Data.EnvironmentID then self:_Reset(); return end
    if myF.Entity and myF.Entity.IsAlive then
        local ok, alive = pcall(myF.Entity.IsAlive, myF.Entity)
        if ok and not alive then self:_Reset(); return end
    end
    local cc = self:_EnsureCharacterController()
    if not cc then return end
    local ourRoot = cc._rootPart
    local clientCF = cc:GetClientCFrame()
    local mode = Config.data.Ragebot.Evasion.Mode

    if mode == "Translocate" then
        self:_ApplyForcedCrouch(false)
        cc:SetServerCFrame(Translocate.compute(clientCF, self._targetSelection:HasTargets()))
        return
    end

    local target = self._targetSelection:GetTarget()
    local action = ActionPlanner.getAction({ itemBehaviors = myF })
    self._lastTargetWorld = target and target.aliveState.rootPart.Position or nil

    local plan = self:_Plan(dt, action, target, ourRoot, clientCF, mode)
    self:_ApplyPlan(plan, target, cc)
    -- ★ FIX v5: 先 crouch, 再 Tick 重送 forced 值 → 讓遊戲下次 _UpdateServerState 送對值
    self:_ApplyForcedCrouch(plan.shouldForceCrouch == true)
    self._stateHook:Tick()  -- Layer D: 每 tick 重送, 蓋掉遊戲自己送的

    if plan.weaponAction then
        -- ★ 只有 fire (不是 Reload/Swap) 才計數
        if not plan._isReloadOrSwap then
            self._fireCount = self._fireCount + 1
        end
        plan.weaponAction()
    end
end

function Ragebot:Destroy()
    self:_Reset()
    self._stateHook:Destroy()
    self._cameraSwayDisabler:Destroy()  -- ★ v6
    self._partGlue:Destroy()
    if self._characterController then self._characterController:Destroy() end
end

-- ★ v6→v7: 更簡單、更直白的 Silent-Aim Ragebot (R L108862 module "ir" 逐字還原)
-- Doc 05 §2 三版比較表: 簡易版用「真實表面點」計算 hitData, 不是主版的常數
-- ★ v7 修正: 用 gun:ShootAt 讓 GunItem 自算 hitData, 不再硬塞主版的常數 HIT_DATA
Ragebot.SilentAimUpdate = function(self)
    if not self._enabled then self:_Reset(); return end
    local myF = FighterController.LocalFighter
    if not myF or not myF.Data or not myF.Data.EnvironmentID then self:_Reset(); return end
    local target = self._targetSelection:GetTarget()
    if target == nil then self:_Reset(); return end
    local cc = self:_EnsureCharacterController()
    if not cc then return end
    -- 簡易版原檔: SetServerCFrame(CFrame.new(target.rootPart.Position))
    cc:SetServerCFrame(CFrame.new(target.aliveState.rootPart.Position))
    -- 找手上有裝備且有彈的槍
    local gun = nil
    if myF.EquippedItem and myF.EquippedItem.Info and myF.EquippedItem.Info.Type == "Gun" then
        if (myF.EquippedItem.Data.Ammo or 0) > 0 then
            gun = myF.EquippedItem   -- 對應原檔 EquippedItemAsGun()
        end
    end
    if gun == nil then return end   -- 原檔: EquippedItemAsGun 回 nil 直接 return (不動 CFrame)
    -- 從 head +50 → head -50, 垂直穿過 hitbox
    local head = target.aliveState.hitboxHead
    local origin = CFrame.new(head.Position + Vector3.new(0, 50, 0))
    local dir    = CFrame.new(head.Position - Vector3.new(0, 50, 0))
    -- ★ v7 關鍵修正: 用 gun:ShootAt 讓 GunItem 內部走 encodeShot 算真實 hitData
    -- 原檔 R L108888: ShootAt6(EquippedItemAsGun15, v12421, v12422, t4792)
    if type(gun.ShootAt) == "function" then
        pcall(gun.ShootAt, gun, origin, dir, { part = head })
    else
        -- fallback: 手工做 encodeShot 之後 ShootEncoded (少數 executor 拿不到 GunItem 方法時)
        gunShootEncoded(gun, CFrameCodec.encode(origin), CFrameCodec.encode(dir), head, HIT_DATA)
    end
    self._fireCount = self._fireCount + 1
end

--=========================================================================
-- §24  GameLoop (Heartbeat + PreCameraRender)
--=========================================================================
local ragebot = Ragebot.new()
_G.__kicia_ragebot = ragebot

-- ★ v5 FIX: 只保留一個 Heartbeat callback
-- HeartbeatUpdate + FlushViewAngles 已經在 _ApplyPlan 裡跑了 (在 weaponAction 之前),
-- 這樣位置封包會先送到 server, 再送 shoot 封包 → 命中判定通過
local hbConn = RunService.Heartbeat:Connect(function(dt)
    local ok, err = pcall(function() ragebot:Update(dt) end)
    if not ok then warn("[kicia_ragebot] Update err: " .. tostring(err)) end
end)

-- Backup: 每 Heartbeat 保底再 flush 一次 (Update 沒跑或提早 return 時)
local hbPostConn = RunService.Heartbeat:Connect(function()
    local cc = ragebot._characterController
    if cc then
        pcall(function() cc:HeartbeatUpdate() end)
        pcall(function() cc:FlushViewAngles() end)
    end
end)

--=========================================================================
-- §25  UI (Obsidian - 簡化版)
--=========================================================================
local Library
do
    local ok, res = pcall(function()
        return loadstring(game:HttpGet("https://raw.githubusercontent.com/deividcomsono/Obsidian/main/Library.lua"))()
    end)
    if ok then Library = res end
end

if Library then
    local Window = Library:CreateWindow({
        Title = "kicia (complete)", Footer = "1:1 KI · 全民自由",
        Center = true, AutoShow = true, MenuFadeTime = 0.2,
    })
    local tab = Window:AddTab("Ragebot", "crosshair")
    local gBox = tab:AddLeftGroupbox("General")
    local sBox = tab:AddRightGroupbox("Strategy")

    local toggle = gBox:AddToggle("RB_Enabled", {
        Text = "Enabled", Default = false,
        Callback = function(v) Config.data.Ragebot.Enabled = v; ragebot:SetEnabled(v) end,
    })
    toggle:AddKeyPicker("RB_Bind", { Default = "None", Mode = "Toggle", Text = "Ragebot", NoUI = false })
    gBox:AddToggle("RB_PrioritizeHackers", {
        Text = "Prioritize Hackers", Default = false,
        Callback = function(v) Config.data.Ragebot.PrioritizeHackers = v end,
    })
    gBox:AddSlider("RB_Stability", {
        Text = "Stability", Default = 0.15, Min = 0, Max = 1.5, Rounding = 3,
        Callback = function(v) Config.data.Ragebot.Stability = v end,
    })
    gBox:AddSlider("RB_ShootFrames", {
        Text = "Shoot Frames", Default = 1, Min = 1, Max = 5, Rounding = 0,
        Callback = function(v) Config.data.Ragebot.ShootFrames = v end,
    })
    gBox:AddDivider()
    gBox:AddLabel("Weapon Priority")
    for _, s in ipairs({ "Primary", "Secondary", "Melee" }) do
        gBox:AddToggle("RB_W_" .. s, {
            Text = s, Default = true,
            Callback = function(v) Config.data.Ragebot.Weapons.Enabled[s] = v end,
        })
    end
    gBox:AddDropdown("RB_OnEmpty", {
        Values = { "Swap", "Reload", "SwapOrReload" },
        Default = "SwapOrReload", Multi = false, Text = "On Empty",
        Callback = function(v) Config.data.Ragebot.Weapons.OnEmpty = v end,
    })

    sBox:AddDropdown("RB_EvasionMode", {
        Values = { "Off", "Random", "ProjectileBreaker", "Translocate" },
        Default = "Random", Multi = false, Text = "Evasion Mode",
        Callback = function(v) Config.data.Ragebot.Evasion.Mode = v end,
    })
    sBox:AddSlider("RB_BaseRadius", {
        Text = "Random Base Radius", Default = 100, Min = 5, Max = 100000000, Rounding = 0,
        Callback = function(v) Config.data.Ragebot.Evasion.Random.BaseRadius = v end,
    })
    sBox:AddSlider("RB_RandomRange", {
        Text = "Random Range", Default = 0.5, Min = 0, Max = 1, Rounding = 2,
        Callback = function(v) Config.data.Ragebot.Evasion.Random.RadiusRandomFactor = v end,
    })
    sBox:AddSlider("RB_Translocate", {
        Text = "Translocate Offset", Default = -5, Min = -5, Max = 5, Rounding = 1,
        Callback = function(v) Config.data.Ragebot.Evasion.Translocate.Offset = v end,
    })

    local settingsTab = Window:AddTab("Settings", "settings")
    local ui = settingsTab:AddLeftGroupbox("UI")
    ui:AddButton({ Text = "Unload", Func = function()
        if _G.__kicia_ragebot_stop then _G.__kicia_ragebot_stop() end
    end })
end

--=========================================================================
-- §26  卸載
--=========================================================================
_G.__kicia_ragebot_stop = function()
    hbConn:Disconnect()
    hbPostConn:Disconnect()
    ragebot:Destroy()
    if Library and Library.Unload then Library:Unload() end
    _G.__kicia_ragebot = nil
    _G.__kicia_ragebot_stop = nil
    print("[kicia_ragebot] 已卸載")
end

print("[kicia_ragebot] v4 complete loaded (14 docs 1:1)")
return ragebot
