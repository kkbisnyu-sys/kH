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
   * 無 StateHook / 強制蹲 (可選 config 開啟)
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
local TOK_IS_CROUCHING         = encode("IsCrouching")
print(("[kicia_light] melee tokens: attack=%s, heavy=%s"):format(_n1, _n2))

local Remotes = ReplicatedStorage.Remotes.Replication.Fighter
local UseItemRemote              = Remotes.UseItem
local UpdateStateRemote          = Remotes.UpdateState
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
        PrioritizeHackers = false,
        ForceCrouch = false,   -- ★ Light 版預設關, 可選啟用
        Weapons = {
            Priority = { "Primary", "Secondary", "Melee" },
            Enabled  = { Primary = true, Secondary = true, Melee = true },
            OnEmpty  = "SwapOrReload",
        },
        Evasion = {
            Mode = "Random",   -- Light 版只支援 "Random" 和 "Off"
            Random = { AnchorFromCharacter = false, BaseRadius = 100, RadiusRandomFactor = 0.5 },
        },
    },
}}

--=========================================================================
-- §4  ShootLock (fire rate throttle)
--=========================================================================
local ShootLock = {}
ShootLock.__index = ShootLock
function ShootLock.new() return setmetatable({ _lockedUntil = nil }, ShootLock) end
function ShootLock:ShouldFire(canFire, duration)
    local now = os.clock()
    local stillLocked = self._lockedUntil ~= nil and now < self._lockedUntil
    if canFire then self._lockedUntil = now + duration end
    return stillLocked or canFire
end
function ShootLock:Reset() self._lockedUntil = nil end

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

local function encodeAngles(angles)
    if angles.kind == "Normalized" then
        return RotationCodec.encodeSingle(math.rad(angles.pitch))
            .. RotationCodec.encodeSingle(math.rad(angles.yaw))
    end
    return string.char(math.clamp(math.floor(angles.pitch), 0, 255))
        .. string.char(math.clamp(math.floor(angles.yaw), 0, 255))
end

--=========================================================================
-- §7  ViewAngleDriver (只有 Knife 會用)
--=========================================================================
local ViewAngleDriver = {}
ViewAngleDriver.__index = ViewAngleDriver

function ViewAngleDriver.new()
    return setmetatable({
        _slots   = {},
        _winning = nil,
        _dirty   = false,
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

function ViewAngleDriver:SendViewAngles(slot, angles)
    if self._slots[slot] == angles then return end
    self._slots[slot] = angles
    self._dirty = true
    self:_Resolve()
end

function ViewAngleDriver:Flush()
    if not self._dirty then return end
    if self._winning == nil then self._dirty = false; return end
    self._dirty = false
    pcall(rawFireServerUnreliable, UpdateCameraRotationRemote, encodeAngles(self._winning), nil)
end

function ViewAngleDriver:ClearAll()
    for k in pairs(self._slots) do self._slots[k] = nil end
    self._winning = nil
    self._dirty = true
end

function ViewAngleDriver:Destroy() self:ClearAll() end

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
local FighterController = require(LocalPlayer.PlayerScripts.Controllers.FighterController)

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

local function slotOfItem(item) return item.Info and item.Info.Class end

function ActionPlanner.getAction(ctx)
    local lf = ctx.itemBehaviors
    if not lf then return nil end
    local W = Config.data.Ragebot.Weapons
    local best, bestP       = nil, math.huge
    local emptyBest, emptyP = nil, math.huge
    local anyEnabled = false
    for _, item in pairs(lf.Items or {}) do
        local slot = slotOfItem(item)
        if slot and W.Enabled[slot] then
            anyEnabled = true
            local p = table.find(W.Priority, slot) or math.huge
            if item.Info.Type == "Gun" and (item.Data.Ammo or 0) == 0 then
                if (item.Data.AmmoReserve or 0) > 0 and p < emptyP then
                    emptyBest, emptyP = { item = item, type = "Gun" }, p
                end
            elseif best == nil or p < bestP then
                best, bestP = { item = item, type = item.Info.Type }, p
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
-- §13  GunItem / MeleeItem 送封包輔助函式
-- ★ Light 版關鍵: 用 game 原生的 gun:ShootAt (內部 encodeShot 算 hitData),
--   不用常數 HIT_DATA!
--=========================================================================
local function callShootAt(gun, origin, dir, hitInfo)
    -- 優先用 game 提供的 ShootAt (它自己算 encodeShot / hitData)
    if type(gun.ShootAt) == "function" then
        return pcall(gun.ShootAt, gun, origin, dir, hitInfo)
    end
    return false
end

local function callMeleeAttack(item, origin, dir, hitInfo, isHeavy)
    if isHeavy then
        if type(item.HeavyAttack) == "function" then
            return pcall(item.HeavyAttack, item, origin, dir, hitInfo)
        end
    else
        if type(item.Attack) == "function" then
            return pcall(item.Attack, item, origin, dir, hitInfo)
        end
    end
    return false
end

local function callReload(item)
    if type(item.Reload) == "function" then
        return pcall(item.Reload, item)
    end
    -- Fallback: 手工送 remote
    pcall(rawFireServer, UseItemRemote, item.Data.ObjectID, TOK_START_RELOADING,
          { ["\1"] = TOK_RELOAD, ["\2"] = TOK_RELOAD }, nil)
end

local function callEquip(item)
    if type(item.Equip) == "function" then
        return pcall(item.Equip, item)
    end
    local cf = item.ClientFighter or FighterController.LocalFighter
    local idx = (item.Data and item.Data.ItemIndex) or item.index
    if not cf or not idx or type(cf.EquipItem) ~= "function" then return end
    if setTID then pcall(setTID, 2) end
    pcall(cf.EquipItem, cf, idx)
    if setTID then pcall(setTID, 8) end
end

--=========================================================================
-- §14  HeadShotPlanner (K L13683) — Gun 策略
--=========================================================================
local HeadShotPlanner = {}
HeadShotPlanner.__index = HeadShotPlanner

local HSP_ABOVE_OFFSET = Vector3.new(0, 0.5, 0)   -- 頭上 0.5 studs
local HSP_BELOW_OFFSET = Vector3.new(0, -3, 0)    -- 頭下 3 studs
local HSP_ATTACK_DELAY = 0.06666666666666667      -- 4 frames @60Hz

local function lookAtFrom(origin, focus)
    local dir = focus - origin
    dir = Vector3.new(dir.X, 0, dir.Z)
    if dir.Magnitude < 1e-3 then dir = Vector3.new(0, 0, -1) end
    return CFrame.lookAt(origin, origin + dir, Vector3.new(0, -1, 0))
end

local function randomFarCFrame()
    return CFrame.new(
        math.random(-1000000, 1000000),
        math.random(5000, 10000),
        math.random(-1000000, 1000000))
end

-- Light 版不看敵方盾, 一律當 Above
local function getVerticalSideStub() return "Above" end

function HeadShotPlanner.new()
    return setmetatable({ _shootLock = ShootLock.new(), _attackStart = nil }, HeadShotPlanner)
end

function HeadShotPlanner:Plan(dt, target, gun, gated)
    local hitboxHead = target.aliveState.hitboxHead
    local headPosition = hitboxHead.Position
    local isAbove = getVerticalSideStub() ~= "Below"
    local offset = isAbove and HSP_ABOVE_OFFSET or HSP_BELOW_OFFSET

    local standCFrame
    if isAbove then
        standCFrame = CFrame.new(headPosition + offset)
    else
        standCFrame = lookAtFrom(headPosition + offset, headPosition)
    end

    if not self._shootLock:ShouldFire(gated, dt * Config.data.Ragebot.ShootFrames) then
        self._attackStart = nil
        return randomFarCFrame(), nil
    end

    local now2 = os.clock()
    local attackStart = self._attackStart or now2
    self._attackStart = attackStart
    if now2 - attackStart < HSP_ATTACK_DELAY then
        return standCFrame, nil   -- 站到位, 等 delay
    end

    local shoot = function()
        local origin = standCFrame.Position
        local aim = CFrame.lookAt(origin, headPosition)
        callShootAt(gun, aim, aim, { part = hitboxHead })
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

function HeadPlanner:Plan(dt, target, weapon, gated)
    local rootPart = target.aliveState.rootPart
    local hitboxHead = target.aliveState.hitboxHead
    local headPosition = hitboxHead.Position
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
        return randomFarCFrame(), nil, nil
    end

    local now2 = os.clock()
    local attackStart = self._attackStart or now2
    self._attackStart = attackStart
    if now2 - attackStart < HSP_ATTACK_DELAY then
        return standCFrame, nil, nil
    end

    local origin = standCFrame.Position
    local aim = CFrame.new(origin, headPosition)
    local hitInfo = { part = hitboxHead }

    -- ★ Knife 分支: 用 HeavyAttack (背刺秒殺) + 送目標朝向的 viewAngles
    if weapon.Info and weapon.Info.Name == "Knife" then
        return standCFrame, cameraAngles(rootPart), function()
            callMeleeAttack(weapon, aim, aim, hitInfo, true)   -- isHeavy = true
        end
    end

    -- 其他近戰: 普通 Attack
    return standCFrame, nil, function()
        callMeleeAttack(weapon, aim, aim, hitInfo, false)
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

-- 可選的強制蹲 (基於主版 StateHook)
local function sendCrouchState(value)
    pcall(rawFireServer, UpdateStateRemote, TOK_IS_CROUCHING, value)
end

function LightRagebot.new()
    return setmetatable({
        _enabled              = false,
        _spatialLimitGate     = SpatialLimitGate.new(FighterRegistry),
        _targetSelection      = TargetSelection.new(FighterRegistry, PlayerTagsStub),
        _hitscanStrategy      = HeadShotPlanner.new(),
        _meleeStrategy        = HeadPlanner.new(),
        _characterController  = nil,
        _fireCount            = 0,
        _diagnostic           = false,
        _crouchSentFrame      = -1,
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
    local cc = self._characterController
    if cc then
        cc:SetServerCFrame(nil)
        cc:SendViewAngles(VIEW_ANGLES_SLOT, nil)
    end
    -- 清 crouch (如果之前有送)
    if Config.data.Ragebot.ForceCrouch then
        sendCrouchState(false)
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
        plan.weaponAction = function() callEquip(item) end
        plan._isReloadOrSwap = true
        return plan
    end
    if action.type == "Reload" then
        local item = action.itemEnum.item
        local plan = self:_EvadePlan(clientCF, evadeMode)
        plan.weaponAction = function() callReload(item) end
        plan._isReloadOrSwap = true
        return plan
    end
    if target == nil then return self:_EvadePlan(clientCF, evadeMode) end
    local ie = action.itemEnum
    if ie.type == "Gun" then
        local gun = ie.item
        -- 檢查是否正在 reload
        if type(gun.IsReloading) == "function" then
            local ok, r = pcall(gun.IsReloading, gun)
            if ok and r then return self:_EvadePlan(clientCF, evadeMode) end
        end
        local cf, act = self._hitscanStrategy:Plan(dt, target, gun, gated)
        return { cframe = cf, weaponAction = act, isAttack = true }
    end
    if ie.type == "Melee" then
        local cf, va, act = self._meleeStrategy:Plan(dt, target, ie.item, gated)
        return { cframe = cf, viewAngles = va, weaponAction = act, isAttack = true }
    end
    return {}
end

function LightRagebot:_ApplyPlan(plan, cc)
    cc:SetServerCFrame(plan.cframe)
    cc:SendViewAngles(VIEW_ANGLES_SLOT, plan.viewAngles)
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
    self:_ApplyPlan(plan, cc)

    -- ★ 可選: 攻擊時強制蹲下 (Light 版本預設關)
    if Config.data.Ragebot.ForceCrouch and plan.isAttack then
        local currentFrame = math.floor(os.clock() * 60)
        if currentFrame ~= self._crouchSentFrame then
            sendCrouchState(true)
            self._crouchSentFrame = currentFrame
        end
    end

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

    gBox:AddToggle("RB_ForceCrouch", {
        Text = "強制蹲下 (實驗)", Default = false,
        Tooltip = "攻擊時每 tick 送 IsCrouching=true. Luraph 下可能無效.",
        Callback = function(v) Config.data.Ragebot.ForceCrouch = v end,
    })
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
