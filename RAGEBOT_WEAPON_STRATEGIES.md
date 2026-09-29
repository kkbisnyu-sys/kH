# RAGEBOT 武器策略还原与映射

对 RAGEBOT 攻击逻辑的完整还原：每种武器使用什么策略、发送什么封包。

---

## 一、武器分类系统 (ItemBehaviors)

**位置**: `c972f775-7r6d3rk.luau` 行 40116-40129 / `kicia_deobfuscated_optimized.lua` 行 88020-88043

```lua
function ItemBehaviors:AddItem(item, index)
    local itemType = getField(getField(item, "Info"), "Type")
    local entry = nil
    if itemType == "Melee" then
        entry = { type = "Melee", item = MeleeItem.new(item, index) }
    elseif itemType == "Gun" then
        entry = { type = "Gun", item = GunItem.new(item, index) }
    elseif itemType == "Throwable" then
        entry = { type = "Throwable", item = ThrowableItem.new(item, index) }
    elseif itemType == "Custom" then
        entry = { type = "Custom", item = CustomItem.new(item, index) }
    end
    -- ...
end
```

> ⚠️ **反混淆注意**: `290375ec-kicia_deobfuscated_optimized.lua` 行 88026-88033 中的类名被混淆器打乱了 (GunItem/ThrowableItem/CustomItem 被互换)。原始 `.luau` 才是正确映射。

**四种武器类型**:
| Info.Type | Item Class | 用途 |
|-----------|-----------|------|
| `Gun` | GunItem | 主武器/副武器 - 枪械 |
| `Melee` | MeleeItem | 近战武器 (刀、锤等) |
| `Throwable` | ThrowableItem | 投掷物 (手雷) |
| `Custom` | CustomItem | 特殊装备 (弓箭、特殊道具) |

---

## 二、Ragebot 策略选择器 (`_Plan`)

**位置**: `kicia_deobfuscated_optimized.lua` 行 63077-63137

```lua
function Ragebot:_Plan(dt, action, target, rootPart, clientCFrame, evadeMode)
    -- 1. 无 action / 无目标 / 换弹中 → 只闪避
    if action == nil then return self:_EvadePlan(...) end
    if action.type == "Swap"   then ... plan.weaponAction = item:Equip end
    if action.type == "Reload" then ... plan.weaponAction = item:Reload end
    if target == nil then return self:_EvadePlan(...) end

    local itemEnum = action.itemEnum
    -- 2. 分派到具体策略
    if itemEnum.type == "Gun" then
        -- 枪械 → HitscanStrategy
        if gun:IsReloading() then return self:_EvadePlan(...) end
        gunCFrame, gunAction = self._hitscanStrategy:Plan(dt, target, gun, rootPart, gated)
        return { cframe = gunCFrame, weaponAction = gunAction, shouldForceCrouch = true }

    elseif itemEnum.type == "Melee" then
        -- 近战 → MeleeStrategy
        meleeCFrame, meleeViewAngles, meleeAction =
            self._meleeStrategy:Plan(dt, target, melee, rootPart, gated)
        return {
            cframe = meleeCFrame,
            viewAngles = meleeViewAngles,
            weaponAction = meleeAction,
            shouldSkipDefense = true,
            shouldForceCrouch = true
        }

    else
        -- Throwable / Custom / 其他 → 不做任何计划 (放弃)
        return {}
    end
end
```

**关键观察**:
- **Gun**: 使用 `HitscanStrategy`（内部就是 HeadShotPlanner 家族）
- **Melee**: 使用 `MeleeStrategy`（内部就是 BackstabPlanner）
- **Throwable/Custom**: 直接返回空计划，RAGEBOT 不控制它们
- **shouldSkipDefense**: 近战跳过防御性位置调整
- **shouldForceCrouch**: 枪械和近战都强制蹲下

---

## 三、GUN 武器 → HitscanStrategy → HeadShotPlanner

### 3.1 计划器: `HeadShotPlanner:Plan()` (行 13683-13736)

```lua
function HeadShotPlanner:Plan(deltaTime, target, weapon, now)
    local hitboxHead = target.aliveState.hitboxHead
    local headPosition = hitboxHead.Position

    -- 1. 计算站位偏移
    --    上方: aboveOffset = Vector3.new(0, 0.5, 0)     -- 头顶上方 0.5 studs
    --    下方: belowOffset = Vector3.new(0, -3, 0)      -- 头下方 3 studs
    local isAbove = getVerticalSide(target.fighterState) ~= "Below"
    local offset = isAbove and aboveOffset or belowOffset

    -- 2. 计算 standCFrame (假位置)
    local standCFrame
    if isAbove then
        standCFrame = CFrame.new(headPosition + offset)          -- 头顶直接放置
    else
        standCFrame = lookAtFrom(headPosition + offset, headPosition)  -- 下方看向头
    end

    -- 3. ShootFrames 节流
    if not self._shootLock:ShouldFire(now, deltaTime * ShootFrames) then
        self._attackStart = nil
        return randomFarCFrame(), nil    -- 不射击 → TP 到随机远处
    end

    -- 4. 攻击延迟 (attackDelay = 0.0667s ≈ 4帧)
    if now2 - attackStart < attackDelay then
        return standCFrame, nil          -- 到位但等待延迟
    end

    -- 5. 构造射击闭包
    local function shoot()
        local origin = shootFrom.Position
        local aim = CFrame.lookAt(origin, headPosition)
        weapon:ShootAt(aim, aim, { part = hitboxHead })
    end
    return shootFrom, shoot
end
```

### 3.2 GunItem 发送封包 (行 72943-72962)

```lua
function GunItem:ShootAt(origin, direction, hitInfo)
    local hitPart, hitData = encodeShot(origin, hitInfo)
    self:ShootEncoded(
        partCodec.encode(origin),
        partCodec.encode(direction),
        hitPart,
        hitData
    )
end

function GunItem:ShootEncoded(origin, direction, hitPart, hitData)
    local shotArgs = {
        ["\0"] = origin,      -- 起点 (编码后)
        ["\1"] = direction,   -- 方向 (编码后)
        ["\2"] = hitPart,     -- 命中部件 (加密ID)
        ["\3"] = hitData,     -- 命中数据 (法线/UV等)
    }
    if self.name == "Revolver" then
        -- Revolver 特殊分支 (原代码为空)
    end
    shotArgs["\4"] = nil

    -- Raycast 类型的枪 (SMG, AR, Sniper) 加 true 标记
    local payload = self.isRaycast
                     and { ["\1"] = shotArgs, ["\2"] = true }
                     or  { ["\1"] = shotArgs }

    -- 发送 remote: UseItemRemote(objectId, "StartShooting", payload)
    fireRemote(UseItemRemote, self.objectId,
               remoteCodec.encode("StartShooting"), payload, nil)
end
```

**枪械封包特点**:
- 所有子弹类枪械 (Pistol/SMG/AR/Sniper/Shotgun) 都走 `ShootEncoded` → `StartShooting`
- Raycast 类型 (`isRaycast=true`) 追加第二个参数 `true`
- Revolver 有特殊代码分支（本版本可能未启用）
- 位置和方向经过 `partCodec.encode` 编码（防反作弊）
- 命中部件和法线经过 `encodeShot` 加密

---

## 四、MELEE 武器 → MeleeStrategy → BackstabPlanner

### 4.1 计划器: `BackstabPlanner:Plan()` (行 40109-40183)

```lua
function BackstabPlanner:Plan(deltaTime, target, weapon, ourPart, now)
    local hitboxHead = target.aliveState.hitboxHead
    local isAbove = getVerticalSide(target.fighterState) ~= "Below"

    -- 1. 计算精细偏移
    --    aboveOffset = Vector3.new(0, -0.7, 0.05)     -- 稍微低于目标 + 前偏
    --    belowOffset = Vector3.new(0, -3.85, 0.05)    -- 更低偏移
    local offset = isAbove and aboveOffset or belowOffset

    -- 2. 使用 PartGlue 将 ourPart "粘"到目标 hitbox 上
    --    (物理约束确保攻击范围内)
    local gluedCFrame = self._partGlue:Acquire(ourPart, hitboxHead)
    self._gluedOurPart = ourPart

    local standCFrame = isAbove
        and (gluedCFrame + offset)
        or lookAtFrom(gluedCFrame.Position + offset, hitboxHead.Position)

    -- 3. 构造攻击角度数据 (欧拉角编码)
    local pitch, yaw, roll = aliveState.rootPart.CFrame:ToOrientation()
    local attackPitch = isAbove and abovePitch or belowPitch   -- ±π/2
    local fromAngles  = isAbove and upperAngles or lowerAngles  -- 起点角度模板
    local toAngles    = isAbove and upperAngles2 or lowerAngles2 -- 终点角度模板
    local fromData = withRotation(fromAngles, attackPitch, yaw, roll)
    local toData   = withRotation(toAngles,   attackPitch, yaw, roll)

    -- 4. 命中窗口: hitboxWindow = 0.625s
    if now2 < self._hitboxWindowUntil then
        -- 在命中窗口内，连续发送 HeavyAttack
        return standCFrame, normalizedAngles(pitch, yaw),
            function() weapon:HeavyAttackEncoded(fromData, toData, hitboxHead, hitData) end
    end

    -- 5. ShootFrames 节流 + 攻击冷却
    if not self._shootLock:ShouldFire(now, dt * ShootFrames) then return randomFarCFrame() end
    if now2 < self._attackCooldown then return randomFarCFrame() end

    -- 6. 分支: Knife 用 Heavy (背刺)，其他 Melee 用普通攻击
    if weapon.name ~= "Knife" then
        return standCFrame, nil,
            function() weapon:AttackEncoded(fromData, toData, hitboxHead, hitData) end
    end

    -- Knife 分支: 启动窗口/冷却，发送 HeavyAttack (背刺秒杀)
    self:_RecordBackstab()  -- hitboxWindowUntil = now + 0.625; attackCooldown = now + 1.25
    return standCFrame, normalizedAngles(pitch, yaw),
        function() weapon:HeavyAttackEncoded(fromData, toData, hitboxHead, hitData) end
end
```

### 4.2 MeleeItem 发送封包 (行 87918-87940)

```lua
function MeleeItem:Attack(origin, direction, target)
    local hitPart, hitData = encodeHit(origin, target)
    self:AttackEncoded(Vector3Codec.encode(origin),
                       Vector3Codec.encode(direction), hitPart, hitData)
end

function MeleeItem:AttackEncoded(origin, direction, hitPart, hitData)
    local attack = {
        ["\0"] = origin, ["\1"] = direction,
        ["\2"] = hitPart, ["\3"] = hitData
    }
    local args = {
        ["\1"] = attack,
        ["\2"] = StringCodec.encode("AttackAnimation1")   -- 动画名
    }
    -- 发送 remote: UseItemRemote(objectId, "StartShooting", args)
    fireRemote(UseItemRemote, self.objectId,
               StringCodec.encode("StartShooting"), args, nil)
end

function MeleeItem:HeavyAttack(origin, direction, target)
    local hitPart, hitData = encodeHit(origin, target)
    self:HeavyAttackEncoded(Vector3Codec.encode(origin),
                            Vector3Codec.encode(direction), hitPart, hitData)
end

function MeleeItem:HeavyAttackEncoded(origin, direction, hitPart, hitData)
    local attack = {
        ["\0"] = origin, ["\1"] = direction,
        ["\2"] = hitPart, ["\3"] = hitData
    }
    local args = {
        ["\1"] = attack,
        ["\2"] = StringCodec.encode("HeavyAttackAnimation1")
    }
    -- 发送 remote: UseItemRemote(objectId, "StartAiming", args)
    fireRemote(UseItemRemote, self.objectId,
               StringCodec.encode("StartAiming"), args, nil)
end
```

**近战封包特点**:
| 攻击类型 | Remote 事件 | 动画名 | 用途 |
|---------|------------|--------|------|
| Attack | `StartShooting` | `AttackAnimation1` | 普通近战攻击 |
| HeavyAttack | `StartAiming` | `HeavyAttackAnimation1` | 重击/背刺 |

> **重要**: MeleeItem 的 HeavyAttack 复用了 `StartAiming` 这个 remote 事件——服务器把"举起武器"当作"重击" (类似瞄准就是蓄力)。

---

## 五、专门的 KnifeRagebot 独立模块

**位置**: `kicia_deobfuscated_optimized.lua` 行 44643-44763 (UI) + 行 51894 (逻辑)

Ragebot 有一套**专门为 Knife 设计的独立系统**——`KnifeRagebot`，它使用 `HeadPlanner`（不同于通用的 HeadShotPlanner）:

### 5.1 HeadPlanner:Plan (行 51894-51954)

```lua
function HeadPlanner:Plan(deltaTime, target, weapon, now)
    -- 站位偏移 (与 HeadShotPlanner 类似)
    --   aboveOffset = Vector3.new(0, 0, 0)      -- 不偏移，直接在头位置
    --   belowOffset = Vector3.new(0, -3, 0)
    ...
    -- ShootFrames 节流 + 攻击延迟 (0.0667s)
    ...

    -- 分支: Knife 用 HeavyAttack (背刺), 其他用普通 Attack
    if weapon.name == "Knife" then
        return standCFrame, cameraAngles(rootPart), function()
            weapon:HeavyAttack(aim, aim2, hitInfo)   -- ← 未编码版本!
        end
    end
    return standCFrame, nil, function()
        weapon:Attack(aim, aim2, hitInfo)             -- ← 未编码版本!
    end
end
```

> 注意 `HeadPlanner` 直接调用 `Attack`/`HeavyAttack`（内部会自动 `encodeHit` → `*Encoded`），
> 而 `BackstabPlanner` 直接调用 `*Encoded` 版本（跳过 `encodeHit`，使用预编码的角度模板）。

### 5.2 HeadGlueShotPlanner (行 137363-137413) - 枪械黏贴变种

```lua
function HeadGlueShotPlanner:Plan(deltaTime, target, shooter, ourPart, now)
    -- 使用 PartGlue 把 ourPart 粘到目标头部 hitbox
    local glued = self._partGlue:Acquire(ourPart, head)

    -- 预编码的偏移角度模板 (跟 BackstabPlanner 一样)
    -- aboveOrigin/aboveDirection: 上方射击的极端坐标模板
    -- belowOrigin/belowDirection: 下方射击的极端坐标模板

    -- ShootFrames 节流
    if not self._shootLock:ShouldFire(now, dt * ShootFrames) then
        return randomFarCFrame(), nil
    end

    -- 使用预编码模板直接调用 ShootEncoded (跳过 encodeShot)
    local function shoot()
        shooter:ShootEncoded(origin, direction, head, hitData)
    end
    return cframe, shoot
end
```

**特点**:
- 是"枪械 + 物理粘贴"混合策略
- 直接使用编码后的坐标模板 (`origin`/`direction` 是预定义的极端值)
- 常量 `hitData = {0, 1, 0, 0, 0, 0}` (无脑向上法线)
- 跳过 `encodeShot`，避免真实计算暴露位置

---

## 六、武器策略总览表

| 武器类别 | 策略选择器 | 计划器 | 攻击方法 | Remote 事件 | 特点 |
|---------|-----------|--------|---------|------------|------|
| **枪械 (Pistol/SMG/AR)** | `HitscanStrategy` | HeadShotPlanner | `ShootAt` → `ShootEncoded` | `StartShooting` | 头顶站位 + 编码射击 |
| **狙击枪 (Sniper)** | `HitscanStrategy` | HeadShotPlanner | `ShootAt` → `ShootEncoded` | `StartShooting` | 同上 + `isRaycast=true` |
| **霰弹枪 (Shotgun)** | `HitscanStrategy` | HeadShotPlanner | `ShootAt` → `ShootEncoded` | `StartShooting` | 同上 |
| **左轮 (Revolver)** | `HitscanStrategy` | HeadShotPlanner | `ShootEncoded` | `StartShooting` | 有特殊分支(空实现) |
| **通用近战 (Bat/Pipe)** | `MeleeStrategy` | BackstabPlanner | `AttackEncoded` | `StartShooting` + `AttackAnimation1` | 使用 PartGlue |
| **匕首 (Knife)** | `MeleeStrategy` | BackstabPlanner | `HeavyAttackEncoded` | `StartAiming` + `HeavyAttackAnimation1` | 背刺，含 0.625s 命中窗口 |
| **专用 Knife 分离** | KnifeRagebot | HeadPlanner | `HeavyAttack` | `StartAiming` | 独立UI，无 PartGlue |
| **枪械+粘贴** | (HeadGlueShotPlanner) | HeadGlueShotPlanner | `ShootEncoded` | `StartShooting` | 预编码模板 + PartGlue |
| **投掷物 (Throwable)** | (无策略) | — | — | — | RAGEBOT 直接放弃 |
| **特殊道具 (Custom)** | (无策略) | — | — | — | RAGEBOT 直接放弃 |

---

## 七、封包发送核心 Remote 列表

所有 RAGEBOT 相关的 remote 事件都通过 `UseItemRemote` 发送:

```lua
-- 枪械射击
fireRemote(UseItemRemote, objectId, encode("StartShooting"),
    { shotArgs, isRaycast_flag }, nil)

-- 近战普通攻击
fireRemote(UseItemRemote, objectId, encode("StartShooting"),
    { attack_data, encode("AttackAnimation1") }, nil)

-- 近战重击/背刺
fireRemote(UseItemRemote, objectId, encode("StartAiming"),
    { attack_data, encode("HeavyAttackAnimation1") }, nil)

-- 换弹
fireRemote(UseItemRemote, objectId, encode("StartReloading"),
    { encode("Reload"), encode("Reload") }, nil)

-- 视角同步 (独立于 UseItemRemote)
fireRemote(UpdateCameraRotationRemote, encodeAngles(winning), nil)
```

**关键编码器**:
- `partCodec.encode(cframe)` — 位置编码
- `Vector3Codec.encode(v3)` — 向量编码
- `StringCodec.encode(str)` — 字符串编码
- `remoteCodec.encode(name)` — 事件名编码
- `encodeShot(origin, hitInfo)` — 命中信息编码 (返回 hitPart+hitData)
- `encodeHit(origin, target)` — 近战命中编码

---

## 八、完整流程图

```
context.itemBehaviors:GetItems()  →  ActionPlanner.getAction(context)
                                              │
                            ┌─────────────────┼───────────────────┐
                            │                 │                   │
                         "Swap"           "Reload"             "Attack"
                            │                 │                   │
                    item:Equip()      item:Reload()             ▼
                                                        Ragebot:_Plan()
                                                                │
                                      ┌─────────────────────────┼────────────────────┐
                                      │                         │                    │
                                   Gun 类型                 Melee 类型         Throwable/Custom
                                      │                         │                    │
                              HitscanStrategy              MeleeStrategy         return {}
                                      │                         │                (放弃)
                              HeadShotPlanner              BackstabPlanner
                                      │                         │
                     standCFrame + shoot()          standCFrame + attack()
                     (头顶+0.5或下方-3)              (PartGlue粘贴 + 角度)
                                      │                         │
                                      ▼                         ▼
                          weapon:ShootAt(aim,aim,hit)  weapon:AttackEncoded / :HeavyAttackEncoded
                                      │                         │
                                      ▼                         ▼
                             ShootEncoded()              StartShooting/StartAiming
                                      │                         │
                                      └───────┬─────────────────┘
                                              ▼
                                    UseItemRemote:Fire(...)
                                              │
                                              ▼
                                     [服务器接收射击]

同时:
  ─  _ApplyPlan → SetServerCFrame (假位置TP)
  ─  _ApplyPlan → SendViewAngles  (视角欺骗)
  ─  _ApplyForcedCrouch(true)     (强制蹲下)
```

---

## 九、关键还原点

### 反混淆前后对比

**混淆版 (`290375ec-kicia_deobfuscated_optimized.lua` 行 88028)**:
```lua
elseif itemType == "Gun" then
    entry = { type = "Gun", item = ThrowableItem.new(item, index) }  -- ❌ 错误映射
```

**原版 (`c972f775-7r6d3rk.luau` 行 40124-40125)**:
```lua
elseif v5323 == "Gun" then
    t1228 = { type = "Gun", item = v5310.new(p1287, p1288) }  -- ✅ v5310 = GunItem
```

反混淆器打乱了 upvalue 引用，导致类名在文件中显示错误。要理解真实行为，必须交叉参考原始 `.luau`。

### 三种"头部瞄准"策略的区别

| 策略 | 使用者 | PartGlue | 角度处理 | 攻击方法 |
|------|--------|----------|---------|---------|
| HeadShotPlanner | 通用 Ragebot Gun | ❌ 不用 | 实时计算 lookAt | `ShootAt` (含 encodeShot) |
| BackstabPlanner | 通用 Ragebot Melee | ✅ 用 | 预编码模板 + 实时旋转 | `AttackEncoded`/`HeavyAttackEncoded` |
| HeadPlanner | KnifeRagebot 专用 | ❌ 不用 | 简单 cameraAngles | `Attack`/`HeavyAttack` |
| HeadGlueShotPlanner | 混合策略 (未启用) | ✅ 用 | 预编码常量 | `ShootEncoded` (跳过 encodeShot) |

**策略越"极端"，越难被反作弊检测**:
1. HeadPlanner: 最简单，直接算，容易被检测
2. HeadShotPlanner: 通过 encodeShot 编码，中等隐蔽
3. HeadGlueShotPlanner: 预编码常量+物理粘贴，最隐蔽
4. BackstabPlanner: 使用极端角度模板+PartGlue，专门骗过背刺检测
