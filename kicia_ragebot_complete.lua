--[[
=========================================================================
kicia_ragebot_complete.lua — Light Ragebot 移植 (LegitRagebot 模式)
=========================================================================
基於 KI R L73620 (LegitRagebot 模組) + HeadShotPlanner (K L13683) +
HeadPlanner (K L51894) — 簡易但穩定的命中方式.

★ 核心策略: 把自己 TP 到目標頭上 0.5 studs, 用 weapon:ShootAt 正常打
★ 小刀支援: HeadPlanner 內建 weapon.name=="Knife" 分支, 呼叫 HeavyAttack
            並送 targetRoot 對齊視角 (背刺姿勢)

架構 (只有 19 段, 主 Ragebot 版是 26 段):
   §0  Services + executor primitives (原始 FireServer, rawSetCFrame)
   §1  EnumLibrary tokens
   §2  FFlag helpers (SetEnabled 用)
   §3  Config defaults
   §4  ShootLock (fire rate throttle)
   §5  CFrameDesync (位置 desync)
   §6  RotationCodec (視角編碼, Knife backstab 需要)
   §7  ViewAngleDriver (只有 Knife 會用)
   §8  CharacterController wrapper
   §9  RandomEvasion (只支援這一種閃避)
   §10 SpatialLimitGate (防追蹤同類外掛)
   §11 TargetSelection
   §12 ActionPlanner (Swap/Reload/Attack)
   §13 GunItem / MeleeItem 送封包
   §14 HeadShotPlanner (Gun 策略) - weapon:ShootAt(aim, aim, {part=head})
   §15 HeadPlanner (Melee 策略 + Knife HeavyAttack)
   §16 LightRagebot 主類別
   §17 Fighter registry
   §18 GameLoop + UI + Cleanup

Light 版跟主版差異:
   * 無 PartGlue (不綁頭)
   * 無 Defense (不看敵方盾)
   * 無 StateHook / 強制蹲
   * 無 ProjectileBreaker / Translocate 閃避
   * 用 weapon:ShootAt (真實 encodeShot) 而不是 -9e37 極端座標
   * 站位 = head + 0.5Y (Above) 或 head + -3Y (Below), 不是 farCF
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
local HttpService       = game:GetService("HttpService")
local Workspace         = game:GetService("Workspace")
local LocalPlayer       = Players.LocalPlayer

-- Executor primitives (載入時複製, 避開後續 hook)
local rawGetMt   = getrawmetatable
local rawNewIdx  = clonefunction and clonefunction(rawGetMt(game).__newindex)
                                  or  rawGetMt(game).__newindex
local rawSetHP   = clonefunction and clonefunction(sethiddenproperty) or sethiddenproperty
local setTID     = setthreadidentity
local getTID     = getthreadidentity
local setFF      = setfflag

local function rawSetCFrame(part, cf)
    if not part or not cf then return end
    pcall(rawNewIdx, part, "CFrame", cf)
end

-- 原始 FireServer 引用 (載入時抽取一次)
local dummyRE = Instance.new("RemoteEvent")
local dummyURE = Instance.new("UnreliableRemoteEvent")
local rawFireServer           = dummyRE.FireServer
local rawFireServerUnreliable = dummyURE.FireServer
dummyRE:Destroy(); dummyURE:Destroy()

--=========================================================================
-- §1  EnumLibrary tokens
--=========================================================================
local EnumLibrary = require(ReplicatedStorage.Modules.EnumLibrary)
local function encode(name)
    local v = EnumLibrary._to_enum[name]
    if not v then error("[kicia] EnumLibrary missing: " .. tostring(name)) end
    return v
end
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
print(("[kicia_light] melee tokens: attack=%s, heavy=%s"):format(_n1, _n2))

local Remotes = ReplicatedStorage.Remotes.Replication.Fighter
local UseItemRemote              = Remotes.UseItem
local UpdateCameraRotationRemote = Remotes.UpdateCameraRotation

--=========================================================================
-- §2  FFlag helpers (跟主版共用同一組)
--=========================================================================
local DEFAULT_FALLEN_H = Workspace.FallenPartsDestroyHeight
local function applyFFlags(on)
    pcall(rawSetHP, Workspace, "FallenPartsDestroyHeight", on and 0/0 or DEFAULT_FALLEN_H)
    if setFF then
        pcall(setFF, "DFIntS2PhysicsSenderRate",       on and "120"        or "15")
        pcall(setFF, "DFIntAssemblyHistoryBufferSize", on and "2147483648" or "15")
        pcall(setFF, "DFIntAssemblyHistorySkipSize",   on and "0"          or "8")
    end
end

--=========================================================================
-- §3  Config defaults
--=========================================================================
local Config = { data = {
    Ragebot = {
        Enabled = false,
        Keybind = { State = false, Kind = "Always", Bind = nil, ShowInList = true, Invisible = false },
        Stability   = 0.15,
        ShootFrames = 1,
        LeadTime    = 0.05,   -- ★ v5: 移動目標預測補償 (秒). 0=關閉, 0.05=補50ms 網路延遲
        PrioritizeHackers = false,
        Weapons = {
            Priority = { "Primary", "Secondary", "Melee" },
            Enabled  = { Primary = true, Secondary = true, Melee = true },
            OnEmpty  = "SwapOrReload",
            MeleeOnly = false,   -- ★ v4: 強制只用近戰 (方便 Knife 測試)
        },
        Evasion = {
            Mode = "Random",   -- Light 版只支援 "Random" 和 "Off"
            Random = { AnchorFromCharacter = false, BaseRadius = 100, RadiusRandomFactor = 0.5 },
        },
    },
}}

--=========================================================================
-- §4  ShootLock (真正的節流)
-- ★ v6 修 Bug 1: 舊版邏輯 `stillLocked or canFire` 在冷卻中永遠 return true,
--   每 frame 都射 → 60 packets/sec 洗頻. 改成真節流: 冷卻中拒射.
--=========================================================================
local ShootLock = {}
ShootLock.__index = ShootLock
function ShootLock.new() return setmetatable({ _lockedUntil = nil }, ShootLock) end
function ShootLock:ShouldFire(canFire, duration)
    local now = os.clock()
    if self._lockedUntil ~= nil and now < self._lockedUntil then
        return false   -- 冷卻中, 拒絕開火
    end
    if canFire then
        self._lockedUntil = now + duration
        return true
    end
    return false
end
function ShootLock:Reset() self._lockedUntil = nil end

--=========================================================================
-- §4.5  極端座標常量 + CFrameCodec (K L107476-107510 主版 HeadGlue)
-- ★ v4 修正: 用主 Ragebot 的 -9e37/-9e7 極端 CFrame 常量, 讓 server
--   的距離/射線檢查因為 float overflow 而 fail-open. HIT_DATA 常數 (0,1,0)
--   表示命中 head 的正上方 1 stud.
--=========================================================================
local PI = math.pi

-- 從上方打的極端座標 (K L107476-107486)
local ABOVE_ORIGIN = { ["\0"] = -9e37, ["\1"] = 0,     ["\2"] = 0, ["\3"] = -PI/2, ["\4"] = PI, ["\5"] = PI }
local ABOVE_DIR    = { ["\0"] = 0,     ["\1"] = -9e7,  ["\2"] = 0, ["\3"] = -PI/2, ["\4"] = PI, ["\5"] = PI }
-- 從下方打
local BELOW_ORIGIN = { ["\0"] = -9e37, ["\1"] = 0,     ["\2"] = 0, ["\3"] =  PI/2, ["\4"] = PI, ["\5"] = PI }
local BELOW_DIR    = { ["\0"] = 0,     ["\1"] =  9e7,  ["\2"] = 0, ["\3"] =  PI/2, ["\4"] = PI, ["\5"] = PI }
-- 命中資料 (head 物件空間點 (0, 1, 0) — head 表面上方 1 stud)
local HIT_DATA     = { ["\0"] = 0,     ["\1"] = 1,     ["\2"] = 0, ["\3"] = 0,     ["\4"] = 0,  ["\5"] = 0 }

-- 給 Melee 用: 用 target rootPart 的 yaw/roll 覆蓋 base 的角度 (背刺姿勢)
local function withRotation(base, rx, ry, rz)
    return {
        ["\0"] = base["\0"], ["\1"] = base["\1"], ["\2"] = base["\2"],
        ["\3"] = rx, ["\4"] = ry, ["\5"] = rz,
    }
end

-- CFrameCodec 保留 (只有 viewAngles 用得到, 例如 defense 產生的 defensive CFrame)
local CFrameCodec = {}
function CFrameCodec.encode(cf)
    local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
    return {
        ["\0"] = x, ["\1"] = y, ["\2"] = z,
        ["\3"] = math.atan2(-r12, r22),
        ["\4"] = math.asin(r02),
        ["\5"] = math.atan2(-r01, r00),
    }
end

--=========================================================================
-- §5  CFrameDesync (K L144260 + R L37592) — 位置 desync 核心
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
    RunService:BindToRenderStep(self._boundId, Enum.RenderPriority.First.Value, function()
        self:_RenderStepUpdate()
    end)
    return self
end

function CFrameDesync:SetServerCFrame(cf) self._cframe = cf end
function CFrameDesync:GetServerCFrame()   return self._cframe or self._rootPart.CFrame end
function CFrameDesync:GetClientCFrame()   return self._oldCFrame or self._rootPart.CFrame end

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
    if root and root.Parent then rawSetCFrame(root, self._oldCFrame) end
    self._oldCFrame = nil
end

function CFrameDesync:Destroy()
    pcall(RunService.UnbindFromRenderStep, RunService, self._boundId)
    if self._oldCFrame and self._rootPart and self._rootPart.Parent then
        rawSetCFrame(self._rootPart, self._oldCFrame)
    end
end

--=========================================================================
-- §6  RotationCodec (R L37618) — 8-bit per axis
--=========================================================================
local RotationCodec = {}
function RotationCodec.encodeSingle(rad)
    if rad ~= rad then return utf8.char(0) end
    local normalized = rad % (2 * math.pi)
    local byte = math.clamp(math.floor(normalized / (2 * math.pi) * 256 + 0.5), 0, 255)
    return utf8.char(byte)
end
function RotationCodec.encodeCameraRotation(v)
    return RotationCodec.encodeSingle(v.X) .. RotationCodec.encodeSingle(v.Y)
end
function RotationCodec.fromXYToCameraRotation(x, y)
    return Vector2.new(x, y) * (2 * math.pi / 256)
end

local function encodeAngles(angles)
    if angles.kind == "Normalized" then
        return RotationCodec.encodeSingle(math.rad(angles.pitch))
            .. RotationCodec.encodeSingle(math.rad(angles.yaw))
    end
    return string.char(math.clamp(math.floor(angles.pitch), 0, 255))
        .. string.char(math.clamp(math.floor(angles.yaw), 0, 255))
end

-- 09 §3.3: 轉換為 CameraRotation Vector2, 先量化再回轉 (讓本地和送出去的值一致)
local function anglesToCameraRotation(angles)
    if angles.kind == "Normalized" then
        -- 先 encode 再 decode → 走 1.40625° 的格子 (跟 Flush 送出去的一致)
        local pByte = string.byte(RotationCodec.encodeSingle(math.rad(angles.pitch)))
        local yByte = string.byte(RotationCodec.encodeSingle(math.rad(angles.yaw)))
        return RotationCodec.fromXYToCameraRotation(pByte, yByte)
    else
        return RotationCodec.fromXYToCameraRotation(
            math.clamp(angles.pitch, 0, 255),
            math.clamp(angles.yaw, 0, 255)
        )
    end
end

--=========================================================================
-- §7  ViewAngleDriver + JointsHook + ReplicationHook (R L37696-37945)
--=========================================================================
local ViewAngleDriver = {}
ViewAngleDriver.__index = ViewAngleDriver

function ViewAngleDriver.new()
    return setmetatable({
        _slots                = {},
        _winning              = nil,
        _fullySuppressed      = false,
        _dirty                = false,
        _jointsInstalled      = false,
        _replicationInstalled = false,
        _jointsRestore        = nil,
        _replicationRestore   = nil,
    }, ViewAngleDriver)
end

function ViewAngleDriver:_Resolve()
    local maxSlot, winning = -1, nil
    for slot, angles in pairs(self._slots) do
        if type(slot) == "number" and slot > maxSlot and angles ~= nil then
            maxSlot, winning = slot, angles
        end
    end
    self._winning = winning
end

-- ★ Hook A: JointsHook (R L37738) — 本地角色關節照假視角擺
function ViewAngleDriver:_InstallJointsHook()
    if self._jointsInstalled then return end
    local ok, joints = pcall(function()
        return require(ReplicatedStorage.Modules.ClientFighterCharacterJoints)
    end)
    if not ok or type(joints) ~= "table" then
        warn("[kicia_light] JointsHook: ClientFighterCharacterJoints not found")
        return
    end
    local origUpdate = joints.Update or (getmetatable(joints) and getmetatable(joints).__index and getmetatable(joints).__index.Update)
    if type(origUpdate) ~= "function" then
        warn("[kicia_light] JointsHook: Update method not found")
        return
    end
    local driver = self
    local function jointsUpdateHook(j, dt, state)
        local w = driver._winning
        if w ~= nil then
            local fighter = j and j.ClientFighterCharacter and j.ClientFighterCharacter.ClientFighter
            if fighter and fighter.IsLocalPlayer then
                pcall(rawset, state, "CameraRotationRaw", anglesToCameraRotation(w))
            end
        end
        return origUpdate(j, dt, state)
    end
    pcall(rawset, joints, "Update", jointsUpdateHook)
    self._jointsRestore = { target = joints, orig = origUpdate }
    self._jointsInstalled = true
    print("[kicia_light] JointsHook 已安裝")
end

-- ★ Hook B: ReplicationHook (R L37775) — 阻止遊戲送真實視角
function ViewAngleDriver:_InstallReplicationHook()
    if self._replicationInstalled then return end
    local ok, fc = pcall(require, LocalPlayer.PlayerScripts.Controllers.FighterController)
    if not ok then
        warn("[kicia_light] ReplicationHook: FighterController not found")
        return
    end
    local mt = getmetatable(fc)
    local proto = mt and mt.__index
    local loop = proto and (proto._CameraReplicationLoop or proto.CameraReplicationLoop)
    if type(loop) ~= "function" then
        warn("[kicia_light] ReplicationHook: _CameraReplicationLoop not found")
        return
    end
    -- 找 EncodeCameraRotation upvalue (是個帶 metatable.__index 的 table)
    local upIdx, upOrig
    for i = 1, 30 do
        local ok2, name, val = pcall(debug.getupvalue, loop, i)
        if not ok2 or name == nil then break end
        if type(val) == "table" then
            local mtx = getmetatable(val)
            local idx = mtx and mtx.__index
            if type(idx) == "table" and idx.EncodeCameraRotation then
                upIdx, upOrig = i, val
                break
            end
        end
    end
    if not upIdx then
        warn("[kicia_light] ReplicationHook: Utility upvalue not found (可能 Luraph)")
        return
    end
    local driver = self
    -- ★ v6 修 Bug 3: proxy 必須 __index 指向原 Utility, 否則遊戲 loop 呼叫其他
    --   方法 (CompressVector / PackAngle 等) 會 index 到 nil → 本地視角同步崩潰.
    local proxy = setmetatable({}, { __index = upOrig })
    -- 同時處理 . 與 : 兩種呼叫 (a1 可能是 self 或 rot, 依原呼叫方式)
    function proxy.EncodeCameraRotation(a1, a2)
        local rot = (typeof(a1) == "Vector2") and a1 or a2
        if next(driver._slots) == nil and not driver._fullySuppressed then
            return RotationCodec.encodeCameraRotation(rot)   -- 沒 slot → 正常編碼
        end
        pcall(rawset, fc, "_replication_stopped", false)     -- 讓 loop 繼續跑
        return fc._last_encoded_camera_rotation or RotationCodec.encodeCameraRotation(rot)
    end
    local okSet = pcall(debug.setupvalue, loop, upIdx, proxy)
    if not okSet then
        warn("[kicia_light] ReplicationHook: setupvalue failed")
        return
    end
    self._replicationRestore = { loop = loop, idx = upIdx, orig = upOrig }
    self._replicationInstalled = true
    print("[kicia_light] ReplicationHook 已安裝")
end

function ViewAngleDriver:SendViewAngles(slot, angles)
    if self._slots[slot] == angles then return end
    self._slots[slot] = angles
    self._dirty = true
    self:_Resolve()
    -- 第一次有 winning 時 lazy install 兩個 hook
    if self._winning ~= nil then
        self:_InstallJointsHook()
        self:_InstallReplicationHook()
    end
end

function ViewAngleDriver:Flush()
    if not self._dirty or self._fullySuppressed then return end
    if self._winning == nil then self._dirty = false; return end
    self._dirty = false
    -- ★ v6 修 Bug 2: UpdateCameraRotation 可能是 RemoteEvent 或 UnreliableRemoteEvent.
    --   對 RemoteEvent 呼叫 UnreliableRemoteEvent.FireServer 會觸發 C++ 型別驗證失敗.
    --   動態選對應方法.
    local fireMethod = UpdateCameraRotationRemote:IsA("UnreliableRemoteEvent")
        and rawFireServerUnreliable
        or  rawFireServer
    pcall(fireMethod, UpdateCameraRotationRemote, encodeAngles(self._winning), nil)
end

function ViewAngleDriver:ClearAll()
    for k in pairs(self._slots) do self._slots[k] = nil end
    self._winning = nil
    self._dirty = true
end

function ViewAngleDriver:_RevertHooks()
    if self._jointsRestore then
        pcall(rawset, self._jointsRestore.target, "Update", self._jointsRestore.orig)
        self._jointsRestore = nil
    end
    if self._replicationRestore then
        pcall(debug.setupvalue, self._replicationRestore.loop,
              self._replicationRestore.idx, self._replicationRestore.orig)
        self._replicationRestore = nil
    end
    self._jointsInstalled      = false
    self._replicationInstalled = false
end

function ViewAngleDriver:Destroy()
    self:ClearAll()
    self:_RevertHooks()
end

-- ★ 提前 require FighterController, 讓 Defense 能引用
local FighterController = require(LocalPlayer.PlayerScripts.Controllers.FighterController)

--=========================================================================
-- §8  CharacterController wrapper
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
-- §8.5  Defense (K L150875 + 09 §4) — Riot Shield 防禦計算
--=========================================================================
local Defense = {}
local rngDef = Random.new()

-- getRiotShieldSide (R L107176) — 判斷目標盾牌暴露面
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

-- 讀我方 shield 狀態
local function getMyShieldState()
    local lf = FighterController.LocalFighter
    if not lf then return "None" end
    local eq = lf.EquippedItem
    if eq and eq.Info then
        if eq.Info.Name == "Riot Shield" then return "Equipped" end
    end
    for _, it in pairs(lf.Items or {}) do
        if it.Info and it.Info.Name == "Riot Shield" then
            return "Unequipped"   -- 有盾但沒裝備 (背在背上)
        end
    end
    return "None"
end

-- 防禦性 CFrame (旋轉)
function Defense.getDefensiveCFrame(cf, myShield, targetFS, targetRoot)
    if myShield == "Equipped" then
        -- 有盾裝備 → 面向目標 (盾在前面擋)
        return CFrame.new(cf.Position, targetRoot.Position)
    elseif myShield == "Unequipped" then
        -- 有盾在背上 → 背對目標 (盾在後面擋)
        return CFrame.new(cf.Position, cf.Position + (cf.Position - targetRoot.Position))
    elseif myShield == "None" then
        -- 沒盾, 目標拿刀 → 隨機轉, 讓對方無法預測背刺角度
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

-- 防禦性視角 (09 §4.2 pitch table)
function Defense.getDefensiveViewAngles(myShield, targetFS)
    if myShield == "None" then return nil end
    local isAbove = getRiotShieldSide(targetFS) ~= "Below"
    local equipped = myShield == "Equipped"
    -- 表: Equipped+Above → -90 (低頭, 盾朝下)
    --     Equipped+Below → +90 (抬頭, 盾朝上)
    --     Unequipped+Above → +90 (抬頭, 背朝下)
    --     Unequipped+Below → -90 (低頭, 背朝上)
    local pitch = (equipped == isAbove) and -90 or 90
    return { kind = "Normalized", pitch = pitch, yaw = rngDef:NextNumber(0, 360) }
end

--=========================================================================
-- §9  RandomEvasion (K L131635) — 只保留這一種閃避
--=========================================================================
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

local RandomEvasion = {}
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
-- §10  SpatialLimitGate (K L141857)
--=========================================================================
local SLG_BOUND = 4194304  -- 2^22
local function exceedsThreshold(v)
    return math.abs(v.X) >= SLG_BOUND
        or math.abs(v.Y) >= SLG_BOUND
        or math.abs(v.Z) >= SLG_BOUND
end

local SpatialLimitGate = {}
SpatialLimitGate.__index = SpatialLimitGate

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
-- §11  TargetSelection (跟主版一樣)
--=========================================================================
local FighterRegistry = { enemies = {}, byPlayer = {} }

local function isEnemyOf(myF, other)
    if not myF or not other then return false end
    if not myF.Data or not other.Data then return true end
    if myF.Data.EnvironmentID ~= other.Data.EnvironmentID then return false end
    if myF.Data.EnvironmentID == nil then return false end
    if myF.Data.TeamID and other.Data.TeamID then
        return myF.Data.TeamID ~= other.Data.TeamID
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

local PlayerTagsStub = {
    _tags = {},
    Has = function(self, p, t) return self._tags[p] and self._tags[p][t] or false end,
    GetPlayersWith = function(self, t)
        local out = {}
        for p, tags in pairs(self._tags) do if tags[t] then table.insert(out, p) end end
        return out
    end,
}

local function isValidTarget(f)
    if not f then return false end
    if f.Entity and type(f.Entity.Get) == "function" then
        local ok, inv = pcall(f.Entity.Get, f.Entity, "IsInvincible")
        if ok and inv then return false end
    end
    if f.Entity and type(f.Entity.IsAlive) == "function" then
        local ok, alive = pcall(f.Entity.IsAlive, f.Entity)
        if ok and not alive then return false end
    end
    local eq = f.EquippedItem
    if eq and eq.Info and eq.Info.DeflectDuration and type(eq._attack_cooldown) == "number" then
        if tick() < eq._attack_cooldown then return false end
    end
    return true
end

local function toTarget(f, player)
    local char = player and player.Character
    local head = char and (char:FindFirstChild("HitboxHead") or char:FindFirstChild("Head"))
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not (head and root) then return nil end
    return {
        fighterState = f,
        aliveState = { rootPart = root, hitboxHead = head, alive = true },
        player = player,
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

--=========================================================================
-- §12  ActionPlanner (跟主版一樣, 已修 KI reload bug)
--=========================================================================
local ActionPlanner = {}

-- K L121684: 背包 index 1/2/3 對應 Primary/Secondary/Melee
local function slotOfItem(item)
    local idx = item.index or (item.Data and item.Data.ItemIndex)
    if not idx and item.Info then idx = item.Info.ItemIndex end
    if     idx == 1 then return "Primary"
    elseif idx == 2 then return "Secondary"
    elseif idx == 3 then return "Melee"
    end
    -- Fallback: 用 Info.Type 判斷 (Melee/Gun)
    if item.Info and item.Info.Type == "Melee" then return "Melee" end
    if item.Info and item.Info.Class then return item.Info.Class end
    return nil
end

function ActionPlanner.getAction(ctx)
    local lf = ctx.itemBehaviors
    if not lf then return nil end
    local W = Config.data.Ragebot.Weapons
    local best, bestP       = nil, math.huge
    local emptyBest, emptyP = nil, math.huge
    local anyEnabled = false

    -- ★ v4: MeleeOnly 模式強制只選 Melee
    local meleeOnly = W.MeleeOnly

    for idx, item in pairs(lf.Items or {}) do
        -- 傳 idx 給 slotOfItem 當 fallback (pairs 迭代 numeric table 通常給 index)
        local slot = slotOfItem(item)
        if not slot and type(idx) == "number" then
            if idx == 1 then slot = "Primary"
            elseif idx == 2 then slot = "Secondary"
            elseif idx == 3 then slot = "Melee" end
        end
        if slot and W.Enabled[slot] and (not meleeOnly or slot == "Melee") then
            anyEnabled = true
            local p = table.find(W.Priority, slot) or math.huge
            if item.Info and item.Info.Type == "Gun" and (item.Data.Ammo or 0) == 0 then
                if (item.Data.AmmoReserve or 0) > 0 and p < emptyP then
                    emptyBest, emptyP = { item = item, type = "Gun" }, p
                end
            elseif best == nil or p < bestP then
                best, bestP = { item = item, type = (item.Info and item.Info.Type) or "Melee" }, p
            end
        end
    end
    if not anyEnabled then return nil end
    if W.OnEmpty == "Reload" then
        if best then
            if not best.item.IsEquipped then return { type = "Swap", itemEnum = best } end
            return { type = "Attack", itemEnum = best }
        end
        if emptyBest == nil then return nil end
        if emptyBest.item.IsEquipped then return { type = "Reload", itemEnum = emptyBest } end
        return { type = "Swap", itemEnum = emptyBest }
    end
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
-- §13  Gun / Melee 封包發送 (主版 -9e37 極端座標)
-- ★ v4 修正:
--   舊版用真實 CFrame + encodeHitPart → server 距離檢查可能 reject.
--   改用主 Ragebot 的極端座標常量 (-9e37 位置, -9e7 方向), 讓 server 的
--   float 檢查 overflow → fail-open → 命中判定通過.
--   Melee 額外用 target rootPart 的 yaw/roll 讓姿勢像背刺.
--=========================================================================

-- Gun 開火 (K L107561): UseItemRemote:StartShooting
local function gunShoot(item, isAbove, hitboxHead)
    local objectId = item.Data and item.Data.ObjectID
    if not objectId then return false end
    local origin = isAbove and ABOVE_ORIGIN or BELOW_ORIGIN
    local dir    = isAbove and ABOVE_DIR    or BELOW_DIR
    local shotArgs = {
        ["\0"] = origin,
        ["\1"] = dir,
        ["\2"] = hitboxHead,
        ["\3"] = HIT_DATA,
    }
    local isRaycast = item.Info and item.Info.IsRaycast
    local payload = isRaycast
        and { ["\1"] = shotArgs, ["\2"] = true }
        or  { ["\1"] = shotArgs }
    return pcall(rawFireServer, UseItemRemote, objectId, TOK_START_SHOOTING, payload, nil)
end

-- Melee 普通攻擊 (K L40170): UseItemRemote:StartShooting + AttackAnimation1
-- 用 target rootPart 的旋轉當攻擊角度 (背後刺入的姿勢)
local function meleeAttack(item, isAbove, targetRoot, hitboxHead)
    local objectId = item.Data and item.Data.ObjectID
    if not objectId then return false end
    local pitch, yaw, roll = targetRoot.CFrame:ToOrientation()
    local atkPitch = isAbove and -PI/2 or PI/2
    local fromBase = isAbove and ABOVE_ORIGIN or BELOW_ORIGIN
    local toBase   = isAbove and ABOVE_DIR    or BELOW_DIR
    local from = withRotation(fromBase, atkPitch, yaw, roll)
    local to   = withRotation(toBase,   atkPitch, yaw, roll)
    local attackArgs = {
        ["\0"] = from,
        ["\1"] = to,
        ["\2"] = hitboxHead,
        ["\3"] = HIT_DATA,
    }
    local payload = { ["\1"] = attackArgs, ["\2"] = TOK_ATTACK_ANIM_1 }
    return pcall(rawFireServer, UseItemRemote, objectId, TOK_START_SHOOTING, payload, nil)
end

-- Melee 重擊 (Knife 背刺秒殺, K L40179): UseItemRemote:StartAiming + HeavyAttackAnimation1
local function meleeHeavyAttack(item, isAbove, targetRoot, hitboxHead)
    local objectId = item.Data and item.Data.ObjectID
    if not objectId then return false end
    local pitch, yaw, roll = targetRoot.CFrame:ToOrientation()
    local atkPitch = isAbove and -PI/2 or PI/2
    local fromBase = isAbove and ABOVE_ORIGIN or BELOW_ORIGIN
    local toBase   = isAbove and ABOVE_DIR    or BELOW_DIR
    local from = withRotation(fromBase, atkPitch, yaw, roll)
    local to   = withRotation(toBase,   atkPitch, yaw, roll)
    local attackArgs = {
        ["\0"] = from,
        ["\1"] = to,
        ["\2"] = hitboxHead,
        ["\3"] = HIT_DATA,
    }
    local payload = { ["\1"] = attackArgs, ["\2"] = TOK_HEAVY_ATTACK_ANIM_1 }
    return pcall(rawFireServer, UseItemRemote, objectId, TOK_START_AIMING, payload, nil)
end

-- Reload: UseItemRemote:StartReloading
-- ★ v6 修 Bug 4: 加雙層節流避免每 frame 送 Reload 封包
--   1. 檢查 gun 自身 _reload_cooldown (換彈中不重送)
--   2. 我方自維護 _last_reload_at (每把槍 0.5s 冷卻)
local _lastReloadAt = setmetatable({}, { __mode = "k" })
local function itemReload(item)
    local objectId = item.Data and item.Data.ObjectID
    if not objectId then return false end
    local now = tick()
    -- 檢查遊戲自己的 reload cooldown
    local rc = item._reload_cooldown
    if type(rc) == "number" and now < rc then return false end
    -- 我方節流: 同一把槍 0.5s 只送一次
    local last = _lastReloadAt[item]
    if last and (now - last) < 0.5 then return false end
    _lastReloadAt[item] = now
    return pcall(rawFireServer, UseItemRemote, objectId, TOK_START_RELOADING,
                 { ["\1"] = TOK_RELOAD, ["\2"] = TOK_RELOAD }, nil)
end

-- Equip: 呼叫遊戲的 ClientFighter:EquipItem (identity 2)
local function itemEquip(item)
    if item.IsEquipped then return end
    local cf = item.ClientFighter or FighterController.LocalFighter
    local idx = (item.Data and item.Data.ItemIndex) or item.index
    if not cf or not idx or type(cf.EquipItem) ~= "function" then return end
    if setTID then pcall(setTID, 2) end
    pcall(cf.EquipItem, cf, idx)
    if setTID then pcall(setTID, 8) end
end

--=========================================================================
-- §14  HeadShotPlanner (K L13683) — Gun 策略 + v5 移動預測
--=========================================================================
local HeadShotPlanner = {}
HeadShotPlanner.__index = HeadShotPlanner

local HSP_ABOVE_OFFSET = Vector3.new(0, 0.5, 0)
local HSP_BELOW_OFFSET = Vector3.new(0, -3, 0)
local HSP_ATTACK_DELAY = 0.06666666666666667

local function lookAtFrom(origin, focus)
    local dir = focus - origin
    dir = Vector3.new(dir.X, 0, dir.Z)
    if dir.Magnitude < 1e-3 then dir = Vector3.new(0, 0, -1) end
    return CFrame.lookAt(origin, origin + dir, Vector3.new(0, -1, 0))
end

-- ★ v7 修「有目標時 _EvadePlan 從未被呼叫」問題:
--   舊版內嵌 randomFarCFrame 只給 (±1e6, 5000-10000, ±1e6) 位置,
--   不受 Config.Evasion.Mode 控制. 現在改成走 RandomEvasion (2^30 遠)
--   或 fallback 到 1e6, 讓對戰時每個「沒開火幀」都真正閃避.
local function evasionFarCFrame(clientCF)
    if clientCF and Config.data.Ragebot.Evasion.Mode == "Random" then
        local ok, cf = pcall(RandomEvasion.compute, clientCF)
        if ok and cf then return cf end
    end
    -- Fallback: 舊 1e6 遠處 (Off mode 或 RandomEvasion 失敗時)
    return CFrame.new(
        math.random(-1000000, 1000000),
        math.random(5000, 10000),
        math.random(-1000000, 1000000))
end

local function getVerticalSideStub() return "Above" end

-- ★ v5: 預測 target 未來位置
-- 讀 rootPart / hitboxHead 的 AssemblyLinearVelocity, 加上 leadTime 補償網路延遲
local function predictHeadPosition(target, leadTime)
    local head = target.aliveState.hitboxHead
    local root = target.aliveState.rootPart
    -- 優先讀 AssemblyLinearVelocity (整個 assembly 的速度, 較穩), fallback Velocity
    local vel = nil
    local function safeVel(p)
        if not p then return nil end
        local ok, v = pcall(function() return p.AssemblyLinearVelocity end)
        if ok and v then return v end
        ok, v = pcall(function() return p.Velocity end)
        if ok and v then return v end
        return nil
    end
    vel = safeVel(root) or safeVel(head) or Vector3.new()
    -- 限制預測距離避免過度 (跑步 ~16 studs/s, jump ~50 studs/s)
    if vel.Magnitude > 100 then vel = vel.Unit * 100 end
    return head.Position + vel * leadTime
end

function HeadShotPlanner.new()
    return setmetatable({ _shootLock = ShootLock.new(), _attackStart = nil }, HeadShotPlanner)
end

function HeadShotPlanner:Plan(dt, target, gun, gated, clientCF)
    local hitboxHead = target.aliveState.hitboxHead
    local isAbove = getVerticalSideStub() ~= "Below"
    local offset = isAbove and HSP_ABOVE_OFFSET or HSP_BELOW_OFFSET

    local leadTime = Config.data.Ragebot.LeadTime or 0.05
    local headPosition = predictHeadPosition(target, leadTime)

    local standCFrame
    if isAbove then
        standCFrame = CFrame.new(headPosition + offset)
    else
        standCFrame = lookAtFrom(headPosition + offset, headPosition)
    end

    -- ★ v7: 沒開火幀走 evasionFarCFrame → 若 Mode=Random 用 2^30, 否則 1e6
    if not self._shootLock:ShouldFire(gated, dt * Config.data.Ragebot.ShootFrames) then
        self._attackStart = nil
        return evasionFarCFrame(clientCF), nil
    end

    local now2 = os.clock()
    local attackStart = self._attackStart or now2
    self._attackStart = attackStart
    if now2 - attackStart < HSP_ATTACK_DELAY then
        return standCFrame, nil
    end

    local shoot = function()
        gunShoot(gun, isAbove, hitboxHead)
    end
    return standCFrame, shoot
end

function HeadShotPlanner:ResetState()
    self._attackStart = nil
    self._shootLock:Reset()
end

--=========================================================================
-- §15  HeadPlanner (K L51894) — Melee 策略 (含 Knife HeavyAttack)
--=========================================================================
local HeadPlanner = {}
HeadPlanner.__index = HeadPlanner

local HP_ABOVE_OFFSET = Vector3.new(0, 0, 0)      -- 直接站頭上
local HP_BELOW_OFFSET = Vector3.new(0, -3, 0)

local function cameraAngles(part)
    local pitch, yaw = part.CFrame:ToOrientation()
    return { kind = "Normalized", pitch = math.deg(pitch), yaw = math.deg(yaw) }
end

function HeadPlanner.new()
    return setmetatable({ _shootLock = ShootLock.new(), _attackStart = nil }, HeadPlanner)
end

function HeadPlanner:Plan(dt, target, weapon, gated, clientCF)
    local rootPart = target.aliveState.rootPart
    local hitboxHead = target.aliveState.hitboxHead
    local leadTime = Config.data.Ragebot.LeadTime or 0.05
    local headPosition = predictHeadPosition(target, leadTime)
    local isAbove = getVerticalSideStub() ~= "Below"
    local offset = isAbove and HP_ABOVE_OFFSET or HP_BELOW_OFFSET

    local standCFrame
    if isAbove then
        standCFrame = CFrame.new(headPosition + offset)
    else
        standCFrame = lookAtFrom(headPosition + offset, headPosition)
    end

    if not self._shootLock:ShouldFire(gated, dt * Config.data.Ragebot.ShootFrames) then
        self._attackStart = nil
        return evasionFarCFrame(clientCF), nil, nil
    end

    local now2 = os.clock()
    local attackStart = self._attackStart or now2
    self._attackStart = attackStart
    if now2 - attackStart < HSP_ATTACK_DELAY then
        return standCFrame, nil, nil
    end

    -- ★ v4: 用極端座標 + target rootPart 旋轉 (背刺姿勢)

    -- ★ Knife 分支: HeavyAttack (背刺秒殺) + 對齊目標朝向的 viewAngles
    if weapon.Info and weapon.Info.Name == "Knife" then
        return standCFrame, cameraAngles(rootPart), function()
            meleeHeavyAttack(weapon, isAbove, rootPart, hitboxHead)
        end
    end

    -- 其他近戰: 普通 Attack
    return standCFrame, nil, function()
        meleeAttack(weapon, isAbove, rootPart, hitboxHead)
    end
end

function HeadPlanner:ResetState()
    self._attackStart = nil
    self._shootLock:Reset()
end

--=========================================================================
-- §16  LightRagebot 主類別 (K L73620 LegitRagebot 模式)
--=========================================================================
local LightRagebot = {}
LightRagebot.__index = LightRagebot

local VIEW_ANGLES_SLOT = 20

function LightRagebot.new()
    return setmetatable({
        _enabled                 = false,
        _spatialLimitGate        = SpatialLimitGate.new(FighterRegistry),
        _targetSelection         = TargetSelection.new(FighterRegistry, PlayerTagsStub),
        _hitscanStrategy         = HeadShotPlanner.new(),
        _meleeStrategy           = HeadPlanner.new(),
        _characterController     = nil,
        _fireCount               = 0,
        _diagnostic              = false,
        _lastDefensiveViewAngles = nil,   -- ★ Defense 記憶最後一次角度
    }, LightRagebot)
end

function LightRagebot:_EnsureCharacterController()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return nil end
    if not self._characterController or self._characterController._rootPart ~= root then
        if self._characterController then self._characterController:Destroy() end
        self._characterController = CharacterController.new(root)
    end
    return self._characterController
end

function LightRagebot:SetEnabled(v)
    if self._enabled == v then return end
    self._enabled = v
    applyFFlags(v)
    if not v then self:_Reset() end
    print(("[kicia_light] %s (fired %d)"):format(v and "ON" or "OFF", self._fireCount))
end

function LightRagebot:_Reset()
    self._meleeStrategy:ResetState()
    self._hitscanStrategy:ResetState()
    self._lastDefensiveViewAngles = nil
    local cc = self._characterController
    if cc then
        cc:SetServerCFrame(nil)
        cc:SendViewAngles(VIEW_ANGLES_SLOT, nil)
    end
end

function LightRagebot:_EvadePlan(clientCF, mode)
    if mode ~= "Random" then return {} end
    return { cframe = RandomEvasion.compute(clientCF) }
end

function LightRagebot:_Plan(dt, action, target, clientCF, evadeMode)
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
        -- ★ v6 修 Bug 4: 換彈中就別再送 Reload 封包 (itemReload 內部也節流)
        local rc = item._reload_cooldown
        if type(rc) == "number" and tick() < rc then
            plan._isReloadOrSwap = true   -- 純閃避, 不送封包
            return plan
        end
        plan.weaponAction = function() itemReload(item) end
        plan._isReloadOrSwap = true
        return plan
    end
    if target == nil then return self:_EvadePlan(clientCF, evadeMode) end
    local ie = action.itemEnum
    if ie.type == "Gun" then
        local gun = ie.item
        -- 檢查是否正在 reload
        -- 遊戲原生 item 用 _reload_cooldown / _shoot_cooldown_no_ammo 判斷 reload
        local now = tick()
        local rc = gun._reload_cooldown
        local sc = gun._shoot_cooldown_no_ammo
        if (type(rc) == "number" and now < rc) or (type(sc) == "number" and now < sc) then
            return self:_EvadePlan(clientCF, evadeMode)
        end
        local cf, act = self._hitscanStrategy:Plan(dt, target, gun, gated, clientCF)
        -- ★ Gun 需要 Defense (isAimPose 為 true 才會算 defensive viewAngles)
        return { cframe = cf, weaponAction = act, isAttack = true, isAimPose = act ~= nil }
    end
    if ie.type == "Melee" then
        local cf, va, act = self._meleeStrategy:Plan(dt, target, ie.item, gated, clientCF)
        -- Melee 用自己的 viewAngles (Knife 對齊目標), 跳過 Defense
        return { cframe = cf, viewAngles = va, weaponAction = act, isAttack = true,
                 shouldSkipDefense = true }
    end
    return {}
end

function LightRagebot:_ApplyPlan(plan, target, cc)
    local cframe = plan.cframe
    local viewAngles = plan.viewAngles
    -- 無目標 / 無 cframe / melee 跳過 defense
    if cframe == nil or target == nil or plan.shouldSkipDefense then
        cc:SetServerCFrame(cframe)
        cc:SendViewAngles(VIEW_ANGLES_SLOT, viewAngles)
        return
    end
    -- ★ Defense: 根據我方 shield 狀態改 CFrame + viewAngles
    local myShield = getMyShieldState()
    local defCFrame = Defense.getDefensiveCFrame(cframe, myShield,
                        target.fighterState, target.aliveState.rootPart)
    cc:SetServerCFrame(defCFrame)
    if plan.isAimPose then
        self._lastDefensiveViewAngles = Defense.getDefensiveViewAngles(myShield, target.fighterState)
    end
    cc:SendViewAngles(VIEW_ANGLES_SLOT, viewAngles or self._lastDefensiveViewAngles)
end

function LightRagebot:Update(dt)
    if not self._enabled then self:_Reset(); return end
    local myF = FighterController.LocalFighter
    if not myF or not myF.Data or not myF.Data.EnvironmentID then self:_Reset(); return end
    if myF.Entity and myF.Entity.IsAlive then
        local ok, alive = pcall(myF.Entity.IsAlive, myF.Entity)
        if ok and not alive then self:_Reset(); return end
    end
    local cc = self:_EnsureCharacterController()
    if not cc then return end
    local clientCF = cc:GetClientCFrame()
    local mode = Config.data.Ragebot.Evasion.Mode

    local target = self._targetSelection:GetTarget()
    local action = ActionPlanner.getAction({ itemBehaviors = myF })
    local plan = self:_Plan(dt, action, target, clientCF, mode)
    self:_ApplyPlan(plan, target, cc)

    if plan.weaponAction then
        if not plan._isReloadOrSwap then
            self._fireCount = self._fireCount + 1
        end
        plan.weaponAction()

        -- Diagnostic
        if self._diagnostic and target then
            local serverPos = cc:GetServerCFrame() and cc:GetServerCFrame().Position
            local headPos = target.aliveState.hitboxHead.Position
            print(string.format("[kicia_light] shoot #%d pos=%s → head=%s",
                self._fireCount, tostring(serverPos), tostring(headPos)))
        end
    end
end

function LightRagebot:Destroy()
    self:_Reset()
    if self._characterController then self._characterController:Destroy() end
end

--=========================================================================
-- §17-18  GameLoop + UI + Cleanup
--=========================================================================
local ragebot = LightRagebot.new()
_G.__kicia_ragebot = ragebot   -- 保持相容原 API 名

-- 主 Update
local hbConn = RunService.Heartbeat:Connect(function(dt)
    local ok, err = pcall(function() ragebot:Update(dt) end)
    if not ok then warn("[kicia_light] Update err: " .. tostring(err)) end
end)

-- Heartbeat: 把假位置寫進 rootPart, flush 視角封包
local hbPostConn = RunService.Heartbeat:Connect(function()
    local cc = ragebot._characterController
    if cc then
        pcall(function() cc:HeartbeatUpdate() end)
        pcall(function() cc:FlushViewAngles() end)
    end
end)

-- UI (Obsidian)
local Library
do
    local ok, res = pcall(function()
        return loadstring(game:HttpGet("https://raw.githubusercontent.com/deividcomsono/Obsidian/main/Library.lua"))()
    end)
    if ok then Library = res end
end

if Library then
    local Window = Library:CreateWindow({
        Title = "kicia (light)",
        Footer = "LegitRagebot 模式 · 支援小刀",
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
    gBox:AddSlider("RB_LeadTime", {
        Text = "Lead Time (跑動預測)", Default = 0.05, Min = 0, Max = 0.3, Rounding = 3,
        Tooltip = "預測目標未來位置補償網路延遲. 0=關閉, 0.05=50ms (推薦), 高延遲用更大值.",
        Callback = function(v) Config.data.Ragebot.LeadTime = v end,
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
        Values = { "Off", "Random" },   -- Light 版只支援這兩個
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

    sBox:AddToggle("RB_Diag", {
        Text = "Diagnostic Print", Default = false,
        Callback = function(v) ragebot._diagnostic = v end,
    })

    local settingsTab = Window:AddTab("Settings", "settings")
    local ui = settingsTab:AddLeftGroupbox("UI")
    ui:AddButton({ Text = "Unload", Func = function()
        if _G.__kicia_ragebot_stop then _G.__kicia_ragebot_stop() end
    end })
end

--=========================================================================
-- Cleanup
--=========================================================================
_G.__kicia_ragebot_stop = function()
    hbConn:Disconnect()
    hbPostConn:Disconnect()
    ragebot:Destroy()
    if Library and Library.Unload then Library:Unload() end
    _G.__kicia_ragebot = nil
    _G.__kicia_ragebot_stop = nil
    print("[kicia_light] 已卸載")
end

print("[kicia_light] Light Ragebot loaded (LegitRagebot 模式, 支援小刀)")
return ragebot
