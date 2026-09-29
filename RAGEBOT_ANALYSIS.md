# RAGEBOT 完整分析报告

基于 `kicia_deobfuscated_optimized.lua` 和 `7r6d3rk.luau` 的完整逆向分析。

---

## 1. 假位置 (Fake Position / Server CFrame Desync)

**核心机制**: `RootDesync` + `CharacterController.SetServerCFrame`

RAGEBOT 通过 `RootDesync` 模块实现服务端位置与客户端位置的分离:

```
文件: kicia_deobfuscated_optimized.lua
行号: 24994 - CharacterController.SetServerCFrame
行号: 24941 - RootDesync.new(state.rootPart)
```

**工作流程**:
1. `CharacterController` 在初始化时创建 `RootDesync` 对象，绑定到角色的 `rootPart`
2. `SetServerCFrame(cframe)` 设置服务器认为的位置，与客户端实际渲染位置不同
3. 当 RAGEBOT 激活时，`_Plan()` 返回一个 `plan.cframe`，这就是假位置
4. 通过 `_ApplyPlan()` 调用 `characterController:SetServerCFrame(cframe)` 将假位置发送给服务器
5. 重置时 `SetServerCFrame(nil)` 恢复同步

**关键代码** (行 63156-63181):
```lua
function Ragebot:_ApplyPlan(plan, target, context)
    local characterController = context.characterController
    local cframe = plan.cframe
    if cframe == nil or target == nil or plan.shouldSkipDefense then
        characterController:SetServerCFrame(cframe)
        characterController:SendViewAngles(viewAnglesRemote, plan.viewAngles)
        return
    end
    -- 有目标时使用防御性CFrame
    characterController:SetServerCFrame(Defense.getDefensiveCFrame(
        cframe, equippedItem, target.fighterState, aliveState.rootPart
    ))
end
```

**不在射击时的假位置**: 当 `ShouldFire` 返回 false 时，返回一个随机远处坐标:
```lua
-- 行 13627-13632
return CFrame.new(
    math.random(-1000000, 1000000),
    math.random(5000, 10000),
    math.random(-1000000, 1000000)
), nil
```

---

## 2. 射击封包 (Shoot Packet)

**核心机制**: `ShootAt` / `AttackEncoded` / `HeavyAttackEncoded`

### Hitscan 枪械射击 (HeadShotPlanner)

**文件位置**: 行 13589-13743

```lua
function HeadShotPlanner:Plan(deltaTime, target, weapon, now)
    local hitboxHead = target.aliveState.hitboxHead
    local headPosition = hitboxHead.Position
    -- 计算站位(目标头部上方/下方)
    local standCFrame = CFrame.new(headPosition + offset)
    -- ShootFrames 节流检查
    if not self._shootLock:ShouldFire(now, deltaTime * settings.data.Ragebot.ShootFrames) then
        return randomFarCFrame(), nil  -- 不射击则返回随机远处位置
    end
    -- 攻击延迟 (66ms)
    if now2 - attackStart < attackDelay then
        return standCFrame, nil  -- 等待期间不射击
    end
    -- 构造射击封包
    local function shoot()
        local origin = shootFrom.Position
        local aim = CFrame.lookAt(origin, headPosition)
        weapon:ShootAt(aim, aim, { part = hitboxHead })
    end
    return shootFrom, shoot
end
```

### Melee 近战射击 (BackstabPlanner)

**文件位置**: 行 39900-39982

```lua
-- 使用编码后的角度数据发送攻击
weapon:AttackEncoded(fromData, toData, hitboxHead, hitData)
weapon:HeavyAttackEncoded(fromData, toData, hitboxHead, hitData)
```

近战使用 `PartGlue` 将自身"粘"到目标 hitbox 附近，然后发送编码后的攻击角度数据，包含 pitch/yaw/roll 旋转信息。

### 封包发送路径:
```
Plan() → shoot() → weapon:ShootAt(aim, aim, hitInfo)
                 → weapon:AttackEncoded(from, to, part, data)
                 → weapon:HeavyAttackEncoded(from, to, part, data)
```

---

## 3. 玩家 TP (Player Teleport / Server Position Set)

**核心**: `SetServerCFrame` 实现服务端位置瞬移

RAGEBOT 的 TP 逻辑嵌入在 `_Plan()` 的返回值中:

1. **射击 TP**: 计算出目标头部位置，将自身假位置 TP 到目标头部附近 (`CFrame.new(headPosition + offset)`)
2. **闪避 TP**: 通过 `_EvadePlan()` 返回的 cframe 瞬移到闪避位置
3. **位置应用**: `_ApplyPlan()` → `characterController:SetServerCFrame(plan.cframe)`

```lua
-- 行 63156-63161
characterController:SetServerCFrame(cframe)          -- TP到计算位置
characterController:SendViewAngles(remote, angles)    -- 同时设置视角
```

**FallenPartsDestroyHeight 绕过** (行 62996-63002):
```lua
-- 启用时设为 NaN 防止掉出地图被销毁
fallenHeight = enabled and (0/0) or defaultFallenHeight
setProperty(workspace, "FallenPartsDestroyHeight", fallenHeight)
```

---

## 4. HOOK 镜头 (Camera Hook)

### 4.1 Camera Replication Hook (行 13450-13521)

**目的**: 阻止客户端将真实摄像机角度发送给服务器

```lua
function hookCameraReplication(self_)
    -- 1. 获取 FighterController 的元表
    -- 2. 找到 _CameraReplicationLoop 方法
    -- 3. 通过 debug.getupvalues 找到 EncodeCameraRotation 工具对象
    -- 4. 创建代理对象替换编码函数
    utilityProxy.EncodeCameraRotation = function(_, rotation)
        if next(self._slots) == nil and not self._fullySuppressed then
            return RotationCodec.encodeCameraRotation(rotation)  -- 正常编码
        end
        -- 有视角覆盖时，返回上次编码或不更新
        local encoded = getField(FighterController, "_last_encoded_camera_rotation")
        if not encoded then
            encoded = RotationCodec.encodeCameraRotation(rotation)
        end
        return encoded
    end
    -- 5. 用 debug.setupvalue 替换
    debug.setupvalue(replicationLoop, utilityIndex, utilityProxy)
end
```

### 4.2 Camera Sway Hook (行 26979-27027)

**目的**: 禁用摄像机摇摆效果

```lua
function hookCameraSway(self_, prototype)
    -- 找到 GetCameraSway 方法中的 CameraController
    -- 创建代理，将 GetPublicState 始终返回 "ThirdPerson"
    proxy.GetPublicState = function() return "ThirdPerson" end
    -- 用代理替换原始对象
    upvalue[key] = setmetatable(proxy, { __index = value })
end
```

### 4.3 hookCameraData (行 20766-20823)

**目的**: GC扫描，通过 `getgc(true)` 查找并 hook `GetCameraData` 方法，用于绕过反作弊检测。

### 4.4 ViewAngleDriver (行 25263-25480)

**目的**: 控制发送给服务器的视角角度

```lua
-- 通过 Joints Hook 控制角色骨骼朝向
function ViewAngleDriver:_LoadJointsHook()
    -- hook ClientFighterCharacterJoints.Update
end

-- 通过 Replication Hook 控制发送的摄像机旋转
function ViewAngleDriver:_LoadReplicationHook()
    -- hook _CameraReplicationLoop 中的 EncodeCameraRotation
end

-- Flush 时通过 remote 发送编码后的角度
function ViewAngleDriver:Flush()
    UpdateCameraRotationRemote(encodeAngles(winning), nil)
end
```

---

## 5. 玩家蹲下 (Forced Crouch)

**核心**: `_ApplyForcedCrouch` 通过 `stateHook` 强制蹲下

```lua
-- 行 63188-63194 / 行 62664-62670
function Ragebot:_ApplyForcedCrouch(forced)
    if forced then
        self._stateHook:SetForced("IsCrouching", true)
    else
        self._stateHook:ClearForced("IsCrouching")
    end
end
```

**触发条件**:
- 枪械射击时 (`shouldForceCrouch = true`，行 63132)
- 近战攻击时 (`shouldForceCrouch = true`，行 63122)
- Translocate 模式下不强制蹲 (`_ApplyForcedCrouch(false)`，行 63045)
- 重置时取消蹲下 (`_ApplyForcedCrouch(false)`，行 63201)

**蹲下状态录制** (MovementRecorder):
```lua
-- 行 5270-5278
function sampleCrouch_proto(self_)
    crouching = getField(MechanicsController, "IsCrouching") == true
    if crouching == self_._lastCrouching then return end
    self_._lastCrouching = crouching
    local action = { kind = "Crouch", crouching = crouching }
end
```

**蹲下状态回放** (7r6d3rk.luau 行 95533-95537):
```lua
elseif action6.kind == "Crouch" then
    MechanicsController14.SetCrouching(action6.crouching)
end
```

---

## 6. 目标锁定 (Target Lock)

### 6.1 TargetLock 系统 (行 118682-118717)

```lua
function handleInput_proto2(self_, input, processed)
    local config = Config.data.TargetLock
    if not (config.Enabled and matchesBind(input, config.Bind)) then return end
    if config.Mode == "Unlock" then
        self_._lockedPlayer = nil        -- "Unlock"模式: 按键解锁
        return
    end
    local candidate = self._pickLockCandidate()
    if candidate ~= nil then
        self._lockedPlayer = candidate    -- 锁定候选目标
    end
end
```

### 6.2 SelectAware 智能选择 (行 118700-118717)

```lua
function selectAware_proto(self_, selector, context, options)
    local config = Config.data.TargetLock
    -- 已锁定目标不可锁定时清除
    if not selector:IsLockable(self._lockedPlayer) then
        self._lockedPlayer = nil
    end
    -- 有锁定目标直接选该玩家
    if config.Enabled and self._lockedPlayer ~= nil then
        return selector:SelectPlayer(self._lockedPlayer, context, options)
    end
    -- LockOnly模式: 没有锁定则不选择任何目标
    if config.Enabled and config.LockOnly then
        return nil
    end
    -- 否则选最佳目标，且如果是Unlock模式，自动锁定
    local best = selector:SelectBest(context, options)
    if best and config.Enabled and config.Mode == "Unlock" and self._lockedPlayer == nil then
        self._lockedPlayer = best.player
    end
    return best
end
```

### 6.3 Ragebot TargetSelection (行 91975-92058)

```lua
function TargetSelection:GetTarget()
    -- 优先选择标记为 "Hacker" 的玩家
    if Config.data.Ragebot.PrioritizeHackers then
        for _, player in self._playerTags:GetPlayersWith("Hacker") do
            local fighter = self._fighters.byPlayer[player]
            if isValidTarget(fighter) then return toTarget(fighter) end
        end
    end
    -- 遍历敌人列表选第一个有效目标
    for _, enemy in self._fighters.enemies do
        if isValidTarget(enemy) then return toTarget(enemy) end
    end
end
```

**有效目标条件**:
- `fighter.isEnemy` = true
- `fighter:IsInvincible()` = false
- `fighter.character.state.alive` = true
- 不在偏转(deflecting)状态

---

## 7. FFLAG 设置

**核心**: 启用 RAGEBOT 时修改 Roblox 内部 FFlags

```lua
-- 行 63003-63022
function Ragebot:SetEnabled(enabled)
    -- 1. FallenPartsDestroyHeight → NaN (防止假位置被销毁)
    workspace.FallenPartsDestroyHeight = enabled and (0/0) or defaultFallenHeight

    -- 2. DFIntS2PhysicsSenderRate: 15 → 120
    --    增加物理数据发送频率，让服务器更快接收位置更新
    setFFlag(fflags, "DFIntS2PhysicsSenderRate", enabled and "120" or "15")

    -- 3. DFIntAssemblyHistoryBufferSize: 15 → 2147483648 (2GB)
    --    极大扩展装配体历史缓冲区，防止位置回滚
    setFFlag(fflags, "DFIntAssemblyHistoryBufferSize", enabled and "2147483648" or "15")

    -- 4. DFIntAssemblyHistorySkipSize: 8 → 0
    --    禁止跳过历史记录，确保所有位置数据被保留
    setFFlag(fflags, "DFIntAssemblyHistorySkipSize", enabled and "0" or "8")
end
```

| FFlag | 默认值 | 启用值 | 作用 |
|-------|--------|--------|------|
| `DFIntS2PhysicsSenderRate` | 15 | 120 | 物理发送频率 ×8 |
| `DFIntAssemblyHistoryBufferSize` | 15 | 2147483648 | 历史缓冲区极大化 |
| `DFIntAssemblyHistorySkipSize` | 8 | 0 | 不跳过任何历史帧 |

---

## 8. SHOOTFRAMES

**默认值**: `1` (行 61210)
**UI 范围**: `Min = 1, Max = 5` (行 18317)

**作用**: 控制射击频率的倍率器

```lua
-- 行 13624
if not self._shootLock:ShouldFire(now, deltaTime * settings.data.Ragebot.ShootFrames) then
    -- ShootFrames 越大，节流越严格 → 射击间隔越长
    -- ShootFrames = 1: 每帧尝试射击 (最快)
    -- ShootFrames = 5: 每5帧节流一次 (最慢)
    return randomFarCFrame(), nil
end
```

**`ShootLock.ShouldFire(now, interval)`** 是一个时间节流器:
- 接收当前时间 `now` 和间隔 `deltaTime * ShootFrames`
- 如果距上次射击的时间 >= interval，允许射击并更新时间戳
- `deltaTime` 是帧间隔(~16ms)，乘以 ShootFrames 得到最小射击间隔

**应用场景**: 所有射击路径都经过 ShootFrames 检查:
- HeadShotPlanner (hitscan枪)
- BackstabPlanner (近战)
- KnifeRagebot
- 通用 Ragebot

---

## 9. STABILITY (稳定性)

**默认值**: `0.15` 秒 (行 61209)
**UI 范围**: Slider 控件

**作用**: 控制 SpatialLimitGate 中的目标锁定稳定性窗口

```lua
-- 行 18927
function isInsideLimit(self_, target)
    local measurement = self_._measurements[fighterState]
    local entryTime = measurement.limitEntryTime
    local hasAmmo = not (fighterState.itemObserver:GetEquippedAmmoState() == false)

    if not isInBounds(target.aliveState.rootPart.Position) then
        -- 目标离开范围时记录预期持续时间
        if entryTime ~= nil then
            if hasAmmo then
                measurement.expectedDuration = now - entryTime
            end
            measurement.limitEntryTime = nil
        end
        return false
    end

    if entryTime == nil then
        measurement.limitEntryTime = now
        entryTime = now
    end

    -- 核心逻辑: 预期持续时间 - Stability <= 已经过时间
    -- Stability 越大 → 需要在范围内停留更久才能射击
    -- Stability = 0.15s → 几乎立即允许射击
    if hasAmmo and measurement.expectedDuration - Ragebot.Stability <= now - entryTime then
        return false  -- 超过稳定窗口，允许继续
    end
    return true  -- 仍在稳定窗口内，限制射击
end
```

**简单理解**: Stability 是一个"预瞄延迟"。值越小，RAGEBOT 在目标进入射程后越快开火;值越大，需要等待更久确认目标稳定后才射击。

---

## 10. 武器切换 (Weapon Switch / ActionPlanner)

**核心**: `ActionPlanner.getAction()` (行 121605-121676)

```lua
function ActionPlanner.getAction(context)
    local weapons = Config.data.Ragebot.Weapons
    local onEmpty = weapons.OnEmpty  -- "SwapOrReload" | "Reload" | "Swap"
    local items = context.itemBehaviors:GetItems()

    -- 遍历所有武器，按优先级排序
    for _, entry in items do
        local slot = getSlot(entry)  -- "Primary"(1) / "Secondary"(2) / "Melee"(3)
        if slot and isSlotEnabled(slot) then
            local priority = table.find(weapons.Priority, slot)
            if entry.type == "Gun" and entry.item:GetAmmo() == 0 then
                -- 弹药为空 → 根据 OnEmpty 策略处理
                if onEmpty == "Reload" then
                    bestPriority = priority
                    best = entry
                else
                    emptyBest = entry  -- SwapOrReload: 记录为空弹夹候选
                end
            elseif priority < bestPriority then
                best = entry  -- 有弹药的最高优先级武器
            end
        end
    end

    -- 决策返回
    if best == nil then
        -- 所有启用的武器都没弹药
        if onEmpty == "Swap" then return nil end
        if emptyBest and emptyBest.item:IsEquipped() then
            return { type = "Reload", itemEnum = emptyBest }
        end
        return { type = "Swap", itemEnum = emptyBest }
    end
    if not best.item:IsEquipped() then
        return { type = "Swap", itemEnum = best }    -- 需要切换到该武器
    end
    if isEmpty then
        return { type = "Reload", itemEnum = best }   -- 当前武器需要换弹
    end
    return { type = "Attack", itemEnum = best }        -- 直接攻击
end
```

**在 `_Plan()` 中的处理** (行 63077-63136):
```lua
if action.type == "Swap" then
    local plan = self:_EvadePlan(clientCFrame, evadeMode)
    plan.weaponAction = function() item:Equip() end    -- 切换武器
    return plan
end
if action.type == "Reload" then
    local plan = self:_EvadePlan(clientCFrame, evadeMode)
    plan.weaponAction = function() item:Reload() end   -- 换弹
    return plan
end
```

**武器配置默认值**:
```lua
Weapons = {
    Priority = {},                                      -- 可自定义优先级顺序
    Enabled = { Primary = true, Secondary = true, Melee = true },
    OnEmpty = "SwapOrReload"                            -- 空弹夹时 切换+换弹
}
```

---

## 11. 闪避 TP (Evasion Teleport)

**三种闪避模式**: `Off` / `Random` / `ProjectileBreaker` / `Translocate`

### 11.1 Random 闪避 (RandomEvasion)

```lua
-- 行 63139-63145
function Ragebot:_EvadePlan(clientCFrame, mode)
    if mode == "Off" then return {} end
    if mode ~= "ProjectileBreaker" then
        return { cframe = RandomEvasion.compute(clientCFrame) }
    end
    -- ...
end
```

**配置**:
```lua
Random = {
    AnchorFromCharacter = false,  -- 基于角色位置计算
    BaseRadius = 100,             -- 基础半径
    RadiusRandomFactor = 0.5      -- 随机因子
}
```

### 11.2 ProjectileBreaker 闪避

**文件位置**: 行 18135-18178 (collectBreakerParts) + 行 62700 (构造)

```lua
-- 行 63147-63151
return {
    cframe = self._projectileBreakerTeleport:Compute(clientCFrame),
    shouldSkipDefense = true  -- 跳过防御性位置调整
}
```

**工作原理**:
1. 扫描地图中带 `RaycastWhitelist` 标签的 BasePart
2. 根据 DepthUp/DepthForward 参数过滤可站立点
3. 在这些点之间进行 TP，间隔由 `RepositionInterval`(0.3s) 控制
4. 当目标池为空时退回到随机闪避

**配置**:
```lua
ProjectileBreaker = {
    DepthForward = { Min = 0, Max = 4 },
    DepthForwardFrequency = 5,
    DepthUp = { Min = 0, Max = 5.5 },
    DepthUpFrequency = 5,
    RepositionInterval = 0.3,
    FallbackAnchorFromCharacter = false,
    FallbackBaseRadius = 100,
    FallbackRadiusRandomFactor = 0.5
}
```

### 11.3 Translocate 闪避

**文件位置**: 行 63044-63049

```lua
if evadeMode == "Translocate" then
    self:_ApplyForcedCrouch(false)           -- 不强制蹲下
    Translocate.compute(clientCFrame, self._targetSelection:HasTargets())
    characterController.SetServerCFrame()     -- 设置TP位置
    return                                    -- 直接返回不进行后续计划
end
```

**Translocate 特点**:
- 将角色服务端位置放到目标下方 (`Offset = -5` studs)
- 不进行射击规划，纯粹闪避模式
- 不强制蹲下

```lua
-- 行 2632
-t49.Size.Y / 2 + up2.data.Ragebot.Evasion.Translocate.Offset
```

---

## 系统架构总结

```
Ragebot.Update(dt)
├── 检查 Context/State/Alive
├── 读取 Evasion.Mode
│   ├── "Translocate" → Translocate.compute() → SetServerCFrame()
│   └── 其他模式 → 继续
├── TargetSelection:GetTarget()
│   ├── PrioritizeHackers → 优先打标记玩家
│   └── 遍历敌人列表
├── ActionPlanner.getAction(context)
│   ├── "Swap" → item:Equip()
│   ├── "Reload" → item:Reload()
│   └── "Attack" → 进入射击规划
├── _Plan(dt, action, target, ...)
│   ├── Gun → HitscanStrategy:Plan() → shootFrom + shoot()
│   ├── Melee → MeleeStrategy:Plan() → cframe + viewAngles + attack()
│   └── 无目标/换弹 → _EvadePlan()
│       ├── "Random" → RandomEvasion.compute()
│       └── "ProjectileBreaker" → ProjectileBreakerTeleport:Compute()
├── _ApplyPlan(plan, target, context)
│   ├── SetServerCFrame(cframe)          # 假位置
│   ├── SendViewAngles(slot, angles)     # 视角封包
│   └── Defense.getDefensiveCFrame()     # 防御性位置
├── _ApplyForcedCrouch(shouldCrouch)     # 强制蹲下
└── plan.weaponAction()                   # 执行射击/换弹/切换

FFLAG (启用时):
├── DFIntS2PhysicsSenderRate = 120
├── DFIntAssemblyHistoryBufferSize = 2147483648
└── DFIntAssemblyHistorySkipSize = 0

Camera Hooks:
├── hookCameraReplication → 拦截 EncodeCameraRotation
├── hookCameraSway → 伪装 GetPublicState = "ThirdPerson"
├── hookCameraData → GC扫描 hook GetCameraData
└── ViewAngleDriver → 控制 Joints + Replication
```
