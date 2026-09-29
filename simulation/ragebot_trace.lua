-- RAGEBOT TP+封包 协作时序模拟器
-- 复现: Ragebot:Update(dt) → _ApplyPlan → weaponAction 的完整调度
-- 目标: 验证假位置TP和射击封包是否能"配合"发送

------------------------------------------------------------
-- 模拟 Roblox 环境
------------------------------------------------------------
local FRAME_TIME = 1/60  -- 60 FPS
local now_clock = 0
local logs = {}
local packet_log = {}

local function log(chan, msg)
    local t = string.format("[%.4fs][%s] %s", now_clock, chan, msg)
    table.insert(logs, t)
    print(t)
end

local function fire_remote(name, args)
    table.insert(packet_log, { t = now_clock, name = name, args = args })
    log("NET", ">>> FireServer("..name..") "..args)
end

------------------------------------------------------------
-- CFrameDesync (真实的假位置机制)
------------------------------------------------------------
local CFrameDesync = {}
CFrameDesync.__index = CFrameDesync

function CFrameDesync.new(rootPart)
    return setmetatable({
        _rootPart = rootPart,
        _cframe = nil,      -- 想要服务器看到的位置
        _oldCFrame = nil,   -- 保存的客户端真实位置
    }, CFrameDesync)
end

function CFrameDesync:SetServerCFrame(cf)
    log("DESYNC", "SetServerCFrame stored → "..(cf or "nil").."  (part.CFrame NOT yet moved!)")
    self._cframe = cf
end

function CFrameDesync:HeartbeatUpdate()
    -- kicia.lua 行 144325 - 这才是真正移动 rootPart 的地方
    if self._cframe ~= nil then
        self._oldCFrame = self._rootPart.CFrame
        self._rootPart.CFrame = self._cframe
        log("HEARTBEAT", "rootPart.CFrame ← "..self._cframe..
                          "  (server physics will replicate THIS position)")
    end
end

function CFrameDesync:RenderStepUpdate()
    -- kicia.lua 行 144315 - 客户端渲染前恢复真实位置
    if self._oldCFrame ~= nil then
        self._rootPart.CFrame = self._oldCFrame
        log("RENDER", "rootPart.CFrame ← "..self._oldCFrame.." (restore client view)")
        self._oldCFrame = nil
    end
end

------------------------------------------------------------
-- 模拟角色 + 武器 + 目标
------------------------------------------------------------
local rootPart = { CFrame = "Vec3(0,5,0)" }
local desync = CFrameDesync.new(rootPart)

local weapon = {
    name = "AK47", type = "Gun", isRaycast = true,
    ShootAt = function(self, aim, aim2, hit)
        -- kicia.lua 行 72943: encodeShot + ShootEncoded
        fire_remote("UseItemRemote.StartShooting",
                    "origin="..aim..", part="..hit.part..", isRaycast=true")
    end,
    Reload = function() fire_remote("UseItemRemote.StartReloading","") end,
    Equip  = function() fire_remote("UseItemRemote.EquipItem","") end,
}

local target = {
    aliveState = { hitboxHead = { part = "EnemyHead", Position = "Vec3(100,50,200)" } },
    fighterState = { alive = true }
}

------------------------------------------------------------
-- HeadShotPlanner (简化版)
------------------------------------------------------------
local ShootLock = { _last = -1 }
function ShootLock:ShouldFire(now, interval)
    if now - self._last >= interval then
        self._last = now
        return true
    end
    return false
end

local function planShoot(dt, target, weapon, now)
    -- 站位: 目标头顶上方 0.5
    local headPos = target.aliveState.hitboxHead.Position
    local standCFrame = "CFrame.new(Vec3(100,50.5,200))"  -- headPos + (0,0.5,0)

    -- ShootFrames 节流 (ShootFrames=1)
    if not ShootLock:ShouldFire(now, dt * 1) then
        return "CFrame.new(Vec3(-999999,7500,-999999))", nil  -- 远处
    end

    local shoot = function()
        weapon:ShootAt("CFrame.lookAt("..standCFrame..","..headPos..")",
                       "aim2", { part = target.aliveState.hitboxHead.part })
    end
    return standCFrame, shoot
end

------------------------------------------------------------
-- Ragebot:Update - 复刻 kicia.lua 行 63025-63075
------------------------------------------------------------
local function ragebotUpdate(dt)
    log("UPDATE", "=== Ragebot:Update(dt="..dt..") 开始 ===")

    -- 1. 获取目标
    log("UPDATE", "target = TargetSelection:GetTarget()  → EnemyHead")

    -- 2. _Plan → HeadShotPlanner:Plan
    local cframe, shoot = planShoot(dt, target, weapon, now_clock)
    local plan = { cframe = cframe, weaponAction = shoot, shouldForceCrouch = true }
    log("UPDATE", "plan.cframe = "..cframe)
    log("UPDATE", "plan.weaponAction = "..(shoot and "shoot()" or "nil"))

    -- 3. _ApplyPlan(plan) - kicia.lua 行 63156
    log("UPDATE", "→ _ApplyPlan()")
    desync:SetServerCFrame(plan.cframe)               -- 存储假位置 (未生效)
    log("UPDATE", "→ SendViewAngles(remote, angles)")  -- 视角欺骗

    -- 4. _ApplyForcedCrouch - kicia.lua 行 63067
    log("UPDATE", "→ _ApplyForcedCrouch("..tostring(plan.shouldForceCrouch)..")")

    -- 5. weaponAction() - kicia.lua 行 63072-63074
    --    ★ 关键: 射击封包在这里被发出
    if plan.weaponAction then
        log("UPDATE", "→ weaponAction()  ★ 射击封包立即发送 ★")
        plan.weaponAction()
    end

    log("UPDATE", "=== Ragebot:Update 结束 ===\n")
end

------------------------------------------------------------
-- 主循环: 模拟 3 帧
------------------------------------------------------------
print("═══════════════════════════════════════════════════════════")
print("  RAGEBOT 时序仿真 - 3 帧 (每帧 16.67ms)")
print("═══════════════════════════════════════════════════════════\n")

for frame = 1, 3 do
    print(string.format(">>>>>>>>>>> FRAME %d @ %.4fs <<<<<<<<<<<", frame, now_clock))

    -- Step 1: Ragebot:Update (RenderStepped/PreRender 时钟)
    ragebotUpdate(FRAME_TIME)

    -- Step 2: Heartbeat 事件 — CFrameDesync 才真正把 rootPart 移到假位置
    log("TICK", "-- Roblox Heartbeat 事件触发 --")
    desync:HeartbeatUpdate()

    -- Step 3: 物理线程通过 DFIntS2PhysicsSenderRate 复制 rootPart 到服务器
    log("PHYS", "[假位置] rootPart 被物理线程复制到服务器 (FFlag=120Hz)")

    -- Step 4: 下一帧 RenderStepped 前 - 恢复客户端真实位置
    now_clock = now_clock + FRAME_TIME
    log("TICK", "-- 下一帧 RenderStepped 前 --")
    desync:RenderStepUpdate()

    print()
end

------------------------------------------------------------
-- 汇总分析
------------------------------------------------------------
print("═══════════════════════════════════════════════════════════")
print("  封包传输时序汇总")
print("═══════════════════════════════════════════════════════════")
for i, p in ipairs(packet_log) do
    print(string.format("  #%d @ %.4fs → %s", i, p.t, p.name))
end

print("\n═══════════════════════════════════════════════════════════")
print("  验证结论")
print("═══════════════════════════════════════════════════════════")
print([[
✓ SetServerCFrame(cframe) 在 _ApplyPlan 里被立即调用 (存入 _cframe)
✓ weaponAction() 紧接在 _ApplyForcedCrouch 之后被立即调用
✓ 射击封包 (UseItemRemote:FireServer) 在同一 Update tick 内发出

但两者通过不同通道到达服务器:
  ┌ 射击封包: UseItemRemote:FireServer(...)     ← 立即发送
  └ 假位置 : rootPart.CFrame → Heartbeat 更新 → 物理线程复制
             (DFIntS2PhysicsSenderRate = 120Hz)

★ 这就是为什么 FFlag 必须把 PhysicsSenderRate 从 15 → 120:
  确保假位置封包在射击封包之前(或同一tick内)到达服务器,
  否则服务器会看到你在原位置射击 → 命中检测失败。

★ SetServerCFrame 存进 _cframe 但并未立即修改 rootPart.CFrame,
  实际改变发生在同一帧的 Heartbeat 事件里 (kicia.lua L144325)。
  RenderStepped 前又还原回 _oldCFrame → 客户端始终看到自己在原位置。
]])
