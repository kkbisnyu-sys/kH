# v8: 把 TP 換成 LegitRagebot

依 doc 04 §A/§B 和 doc 06 §4 完整還原 LegitRagebot 的兩個策略模組, 取代主版的 HeadGlue + Backstab.

---

## 為什麼要換

**主版本 HeadGlue** 靠這些「非常規手段」讓子彈中:
1. **PartGlue**: `setthreadidentity(8)` + `sethiddenproperty(root, "PhysicsRepRootPart", targetHead)` — 這需要 executor 支援, 而且改的是 Roblox 隱藏屬性
2. **拆敵人的 WeldConstraint**: 本地把 target head 焊接拆掉並 Anchored
3. **極端座標 `-9e37`**: 靠 server 端距離檢查溢位成 inf/NaN 繞過驗證
4. **常數 hitData `(0,1,0)`**: 不算真實表面點

**這些依賴太多 assumptions**, 遊戲更新 / 反作弊補丁任何一個都可能讓它失效.

**LegitRagebot** 是**同一份原檔** (`R L109300-109485`) 提供的**備用策略**, 完全不依賴上面 4 樣, 只用:
1. 直接 TP 到 head 附近 (真實世界座標)
2. **等 66ms 讓 server 收到位置封包**
3. 用 `gun:ShootAt` 讓 GunItem 自算真實 hitData
4. 起點/方向都是 `lookAt(stand, head)` — 合法外觀的射線

---

## 兩個策略的差異對比

### LegitShotPlanner (取代 HeadGlueShotPlanner)

| 項目 | HeadGlue (主版) | LegitShot (新) |
|-----|---------------|----------------|
| **依賴 PartGlue** | ✅ 每 tick Acquire | ❌ 完全不用 |
| **PhysicsRepRootPart** | ✅ 設成 target head | ❌ 不動 |
| **拆敵人 WeldConstraint** | ✅ 本地拆 | ❌ 不動 |
| **站位偏移 (Above)** | `(0, -0.7, 0.05)` (相對 head) | `(0, 0.5, 0)` (世界座標) |
| **站位偏移 (Below)** | `(0, -3.85, 0.05)` + 倒立 | `(0, -3, 0)` + 倒立 |
| **開火起點 `\0`** | 常數 `(-9e37, 0, 0)` | `CFrame.lookAt(stand, head)` 真實 |
| **開火方向 `\1`** | 常數 `(0, ∓9e7, 0)` | `CFrame.lookAt(stand, head)` 同起點 |
| **命中點 hitData** | 常數 `(0, 1, 0, 0, 0, 0)` | `encodeShot` 真實表面點 |
| **開火 API** | `gunShootEncoded` 直接送 | `gun:ShootAt(...)` 讓 GunItem 自算 |
| **開火延遲** | 無 (立即射) | ✅ **66ms 站定延遲** (讓位置到 server) |
| **ShootLock 節流** | ✅ dt × ShootFrames | ✅ 同 |
| **不開火時 CFrame** | `rand(±1e6, 5000~10000, ±1e6)` | 同 |

### LegitMeleePlanner (取代 BackstabPlanner)

| 項目 | Backstab (主版) | LegitMelee (新) |
|-----|----------------|-----------------|
| **依賴 PartGlue** | ✅ | ❌ |
| **站位 (Above, 非刀)** | glued + `(0, -0.7, 0.05)` | `CFrame.new(head)` (root 在頭中心) |
| **站位 (Below)** | 相對 head 倒立 | `lookAtFrom(head - 3Y, head)` 倒立 |
| **背刺視窗** | ✅ 0.625s 每幀連打 | ❌ 無 |
| **背刺冷卻** | ✅ 1.25s | ❌ 無 |
| **Knife 攻擊** | `HeavyAttackEncoded` + 目標朝向 viewAngles | `melee:HeavyAttack(...)` + 目標朝向 viewAngles |
| **非刀近戰** | `AttackEncoded` | `melee:Attack(...)` |
| **編碼方向** | `\3=攻擊pitch, \4=目標yaw, \5=目標roll` (偽裝背後) | 真實 lookAt CFrame |
| **開火延遲** | 無 | ✅ 66ms 站定延遲 |

---

## LegitRagebot 一幀時序 (與主版對照)

### 主版一幀
```
[PreSim/Heartbeat] Ragebot:Update
├─ HeadGlue:Plan
│   ├─ PartGlue:Acquire (setthreadidentity(8), 拆weld, anchor)
│   └─ stand = farCF + (-0.7, 0.05, 0)   -- 天空 100000Y 附近
├─ SetServerCFrame(stand)
├─ ForcedCrouch(true)
└─ shoot()  → gunShootEncoded(ABOVE_ORIGIN, ABOVE_DIR, head, HIT_DATA)
              ↑ 靠極端值溢位過驗證

[Heartbeat] CFrameDesync 寫入 rootPart.CFrame = 天空
[Physics] 物理引擎排位置封包
[Network] 位置 + shoot 一起送出 (但 shoot 靠溢位不需要位置對)
```

### LegitRagebot 一幀
```
[PreSim/Heartbeat] Ragebot:Update
├─ LegitShot:Plan
│   ├─ stand = CFrame.new(head + 0.5Y)   -- 真實座標, head 上方 0.5
│   ├─ ShootLock 放行, _attackStart = now
│   ├─ if now - _attackStart < 66ms: return stand, nil  ← 前 4 幀站著等
│   └─ 4 幀後: 才 return shoot()
├─ SetServerCFrame(stand)                 -- 真實 head + 0.5Y
├─ ForcedCrouch(true)
└─ shoot()  → gun:ShootAt(lookAt(stand,head), lookAt(stand,head), {part=head})
              ↑ GunItem 內部 encodeShot → 真實表面 hitData

[Heartbeat] CFrameDesync 寫入 rootPart.CFrame = head 上方
[Physics] 位置封包排入
[Network] 這 66ms 內每幀送位置, 直到位置封包確實到 server
[第 4 幀] shoot 封包送出, 此時 server 已收到位置 → 合法命中判定
```

**LegitRagebot 的 66ms 延遲很關鍵** — 它明確等 server 收到假位置後才開槍, 不像主版那樣靠溢位繞過.

---

## v8 修改摘要

在 `kicia_ragebot_complete.lua` 加了兩個新 class:

**LegitShotPlanner** (L1521-1594):
```lua
function LegitShotPlanner:Plan(dt, target, gun, ourRoot, gated)
    local head = target.aliveState.hitboxHead
    local isAbove = getRiotShieldSide(target.fighterState) ~= "Below"

    local stand
    if isAbove then
        stand = CFrame.new(head.Position + Vector3.new(0, 0.5, 0))
    else
        stand = lookAtFrom(head.Position + Vector3.new(0, -3, 0), head.Position)
    end

    if not self._shootLock:ShouldFire(gated, dt * ShootFrames) then
        self._attackStart = nil
        return randomFarGun(), nil
    end

    -- ★ 66ms 站定延遲
    local now = os.clock()
    self._attackStart = self._attackStart or now
    if now - self._attackStart < 1/15 then
        return stand, nil
    end

    return stand, function()
        local origin = CFrame.lookAt(stand.Position, head.Position)
        local dir    = CFrame.lookAt(stand.Position, head.Position)
        if type(gun.ShootAt) == "function" then
            pcall(gun.ShootAt, gun, origin, dir, { part = head })
        else
            gunShootEncoded(gun, CFrameCodec.encode(origin), CFrameCodec.encode(dir), head, HIT_DATA)
        end
    end
end
```

**LegitMeleePlanner** (L1596-1656): 同樣結構, 但用 Attack / HeavyAttack, 且 Knife 分支多送 viewAngles = target root 朝向.

**Ragebot.new** 改用:
```lua
_hitscanStrategy = LegitShotPlanner.new(),   -- 取代 HeadGlueShotPlanner
_meleeStrategy   = LegitMeleePlanner.new(),  -- 取代 BackstabPlanner
```

`_partGlue` 保留但**不再使用** — 讓未來想切回主版時可以直接改回來.

---

## 期待的效果

**優點**:
- ✅ 不依賴 `setthreadidentity` / `sethiddenproperty` (executor 支援問題消失)
- ✅ 不動 target 的 WeldConstraint (反作弊看不到本地敵人被改)
- ✅ 命中判定走 server 正常路徑 (不靠溢位)
- ✅ 66ms 延遲確保位置封包到 server 才開火
- ✅ hitData 是真實表面點, server 驗證通過

**缺點 / 取捨**:
- ⚠️ **開火慢**: 每個目標都要等 66ms (~4 幀 @ 60fps) 才開始射
- ⚠️ **可見範圍變小**: 你會出現在 target 頭上方 0.5, 對方隊友可能看到
- ⚠️ **Backstab 沒了**: LegitMelee 沒有 0.625s 連刀窗口, Knife 傷害輸出降低
- ⚠️ **Defense 依然運作**: 有盾時仍會轉 viewAngles

---

## 已讀 13/14 份 MD

| 檔 | 狀態 | 要點 |
|---|-----|------|
| 01 主流程 | ✅ | Config defaults, Update flow |
| 02 子模組 | ✅ | 各模組概觀 + 簡易版指到 L103890 |
| 03 目標鎖定 | ✅ | 只接 Aimbot, Ragebot 不用 |
| 04 K vs R 比對 | ✅ | **提供 LegitRagebot 完整程式碼** |
| 05 如何打人 | ✅ | 三版封包比較表 |
| 06 玩家TP與開火位置 | ✅ | **提供 Legit vs 主版站位對照** |
| 07 TP目的地嚴查 | ✅ | PartGlue 機制細節 |
| 08 Ragebot完整機制 | ✅ | 26 模組地圖 |
| 09 鏡頭Hook與蹲下 | ✅ | ViewAngleDriver + StateHook |
| 10 輔助功能盤點 | ✅ | HackerDetector, PartGlue 專用 |
| 11 原始FireServer | ✅ | 載入時 clone + validate |
| 13 閃避TP與換彈 | ✅ | Random/PBT/Translocate + Reload flow |
| 14 玩家TP機制再查 | ✅ | CFrameDesync 完整流程 |

**缺 `12_Stability與ShootFrames.md`** — 對 v8 影響不大 (Legit 版仍用 ShootLock + dt × ShootFrames).
