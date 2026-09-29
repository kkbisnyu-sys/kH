# Light Ragebot (LegitRagebot) 完整命中流程

**位置**: `290375ec-kicia_deobfuscated_optimized.lua` L73620-73800+
**Doc 02 §12 名稱**: LegitRagebot

---

## 一、依賴 (只有 11 個模組, 主 Ragebot 有 20+)

```lua
local Config           = up0.y()      -- Config.data.Ragebot
local HitscanStrategy  = up0.it()     -- 就是 HeadShotPlanner (L13683)
local Keybinds         = up0.eL()
local MeleeStrategy    = up0.iu()     -- 就是 HeadPlanner (L51894)
local RandomEvasion    = up0.ik()
local SpatialLimitGate = up0.il()
local TargetSelection  = up0.id()
local Trove            = up0.q()
local ActionPlanner    = up0.io()
```

**Light Ragebot 缺什麼** (跟主 Ragebot 對照):
- ❌ 沒有 `PartGlue` — **不會黏頭**
- ❌ 沒有 `Defense` — 不管敵方防暴盾
- ❌ 沒有 `StateHook` — **不會強制蹲**
- ❌ 沒有 `ProjectileBreakerTeleport` — 只支援 Random 閃避
- ❌ 沒有 `Translocate` — 沒有 kill part TP
- ❌ 沒有 `getRiotShieldSide` — 不看盾方向

---

## 二、開火時的整條路徑 (從 Update 到封包送出)

```
Ragebot.Update(dt)                                          -- L73720
  │
  ├─ if context nil / not enabled / dead → _Reset; return
  │
  ├─ clientCFrame = characterController:GetClientCFrame()   -- 真實位置
  ├─ target      = _targetSelection:GetTarget()             -- 選第一個活敵人
  ├─ action      = ActionPlanner.getAction(context)         -- Swap/Reload/Attack
  │
  ├─ plan = _Plan(dt, action, target, clientCFrame, mode)   -- L73752
  │     │
  │     ├─ gated = target ~= nil and not _spatialLimitGate:Tick(target)
  │     │         (SpatialLimitGate: 只要目標 |座標| >= 2^22 就開始學習)
  │     │
  │     ├─ if action.type == "Swap" → { cframe = evadeCF, weaponAction = ()->item:Equip() }
  │     ├─ if action.type == "Reload" → { cframe = evadeCF, weaponAction = ()->item:Reload() }
  │     │
  │     ├─ if itemEnum.type == "Gun":                       -- ★ 開火主流程
  │     │    if gun:IsReloading() → 回 evade
  │     │    (gunCF, shoot) = HeadShotPlanner:Plan(dt, target, gun, gated)   -- ★
  │     │    return { cframe = gunCF, weaponAction = shoot }
  │     │
  │     └─ if itemEnum.type == "Melee":
  │          (meleeCF, viewAngles, attack) = HeadPlanner:Plan(dt, target, melee, gated)
  │          return { cframe = meleeCF, viewAngles = viewAngles, weaponAction = attack }
  │
  ├─ applyPlan(plan, context)                               -- L73640
  │     characterController:SetServerCFrame(plan.cframe)    -- 假位置寫入 _cframe
  │     characterController:SendViewAngles(20, plan.viewAngles)
  │
  └─ if plan.weaponAction then plan.weaponAction() end      -- ★ 送 shoot 封包
```

**同一幀後續** (由 GameLoop.Heartbeat 分開觸發):
- `CFrameDesync:HeartbeatUpdate()` → `rootPart.CFrame = _cframe` (假位置真正寫入)
- 物理引擎複製 rootPart.CFrame 到 server (DFIntS2PhysicsSenderRate=120Hz)
- `ViewAngleDriver:Flush()` → 送 UpdateCameraRotation 封包

---

## 三、Gun 開火核心: HeadShotPlanner:Plan (L13683)

```lua
local aboveOffset = Vector3.new(0, 0.5, 0)   -- 頭上 0.5 studs
local belowOffset = Vector3.new(0, -3, 0)    -- 頭下 3 studs
local attackDelay = 0.06666666666666667      -- 4 frames @ 60Hz

function HeadShotPlanner:Plan(dt, target, weapon, gated)   -- 'now' 參數其實是 gated
    local hitboxHead   = target.aliveState.hitboxHead
    local headPosition = hitboxHead.Position

    -- ★ 判斷從上方還是下方打
    local isAbove = getVerticalSide(target.fighterState) ~= "Below"
    local offset  = isAbove and aboveOffset or belowOffset

    -- ★ 站位 = 目標頭上方 0.5 或 下方 3 studs
    local standCFrame
    if isAbove then
        standCFrame = CFrame.new(headPosition + offset)              -- 頭上直接放
    else
        standCFrame = lookAtFrom(headPosition + offset, headPosition) -- 頭下, 看向頭
    end

    -- ★ ShootLock 節流: 只有 gated=true 才會放行
    if not self._shootLock:ShouldFire(gated, dt * ShootFrames) then
        self._attackStart = nil
        return CFrame.new(                    -- 不開火 → TP 到隨機遠處
            math.random(-1000000, 1000000),
            math.random(5000, 10000),
            math.random(-1000000, 1000000)
        ), nil
    end

    -- ★ 第一次進入攻擊狀態時記錄時間, 之後延遲 0.0667s 才真的開火
    local now2 = os.clock()
    local attackStart = self._attackStart or now2
    self._attackStart = attackStart

    -- ★ 攻擊延遲期間 (前 4 frame) 只 TP 到站位, 不開火
    if now2 - attackStart < attackDelay then
        return standCFrame, nil
    end

    -- ★ 延遲過了 → 真的送封包
    local shoot = function()
        local origin = standCFrame.Position
        local aim = CFrame.lookAt(origin, headPosition)   -- 從站位看向頭
        weapon:ShootAt(aim, aim, { part = hitboxHead })
    end
    return standCFrame, shoot
end
```

### 關鍵行為

1. **站位選擇**: 只看目標的 vertical side (Above/Below), 不看敵方盾
2. **兩個判斷擋在 shoot 之前**:
   - **`gated` 必須 = true** (SpatialLimitGate 放行)
   - **`os.clock() - attackStart >= 0.0667s`** (攻擊延遲)
3. **不放行時 TP 到隨機遠處** `(±1e6, 5000~10000, ±1e6)` — 讓自己在天上, 不會被打
4. **每一發都要重新等 0.0667s** (attackStart 在 ShootLock 未放行時被清 nil)
5. **shoot() 用 `weapon:ShootAt(aim, aim, {part=head})`** — 高階 API, 內部會自動 encodeShot 算出真實 hitData

---

## 四、Gun 封包: `weapon:ShootAt` → `ShootEncoded`

`GunItem:ShootAt` (kicia.lua L72943):
```lua
function GunItem.ShootAt(item, origin, direction, hitInfo)
    local hitPart, hitData = encodeShot(origin, hitInfo)   -- ★ 算出真實 hitData
    item:ShootEncoded(
        partCodec.encode(origin),       -- 編碼 CFrame origin
        partCodec.encode(direction),    -- 編碼 CFrame direction
        hitPart,                         -- 加密的 head ID
        hitData                          -- 命中資料 (法線, UV 等)
    )
end
```

`GunItem:ShootEncoded` (L72949):
```lua
function GunItem:ShootEncoded(origin, direction, hitPart, hitData)
    local shotArgs = {
        ["\0"] = origin,
        ["\1"] = direction,
        ["\2"] = hitPart,
        ["\3"] = hitData
    }
    local payload = self.isRaycast
        and { ["\1"] = shotArgs, ["\2"] = true }
        or  { ["\1"] = shotArgs }
    rawFireServer(UseItemRemote, self.objectId,
                  encode("StartShooting"), payload)
end
```

### Light Ragebot 送的 payload

```
FireServer(UseItemRemote,
    gun.objectId,
    encode("StartShooting"),
    {
        ["\1"] = {
            ["\0"] = encoded_origin,     -- ~ head.Position + (0, 0.5, 0)
            ["\1"] = encoded_direction,  -- 從 origin 看向 head
            ["\2"] = encrypted_head_id,
            ["\3"] = real_hitData        -- 用 encodeShot 從 origin+head 算出來
        },
        ["\2"] = gun.isRaycast           -- true/false
    }
)
```

---

## 五、Server 判定推測 (Doc 07 §3.2 推理)

Server 收到 shoot 封包時:
1. 解碼 `encoded_origin`, `encoded_direction` → 世界 CFrame
2. **origin 位置 ≈ head.Position + (0, 0.5, 0)** — 就在頭頂 0.5 studs
3. **direction 指向 head** — 射線從頭頂往頭中心
4. Server raycast: 從 origin 沿 direction 射, **必定穿過 head hitbox**
5. `hitPart` 對應 head 的加密 ID → 目標身分確認
6. `hitData` 記錄命中點的法線 (由 encodeShot 算出)
7. Server 更新 damage → 目標扣血

### 這種打法為什麼會中

因為 **Light Ragebot 是把自己「假位置」放到目標頭上方 0.5 studs**, 而 shoot 封包的 origin 是 `standCFrame.Position` = 該假位置. 對 server 來說:
- 你的角色在頭頂 0.5 studs (由 CFrameDesync 位置封包告知)
- 你的 shoot 起點也在頭頂 0.5 studs (由 shoot 封包告知)
- 兩者一致 → **距離檢查通過**
- 射線 0.5 studs 就打中頭 → **命中檢查通過**

---

## 六、Melee 開火: HeadPlanner:Plan (L51894)

```lua
local aboveOffset = Vector3.new(0, 0, 0)     -- ★ 直接站頭上 (offset=0)
local belowOffset = Vector3.new(0, -3, 0)

function HeadPlanner:Plan(dt, target, weapon, gated)
    -- ... 判斷 isAbove, 選 offset (同 Gun) ...
    local standCFrame = isAbove
        and CFrame.new(headPosition + offset)
        or  lookAtFrom(headPosition + offset, headPosition)

    -- ★ 同樣的 ShootLock 節流
    if not self._shootLock:ShouldFire(gated, dt * ShootFrames) then
        self._attackStart = nil
        return randomFar, nil, nil
    end

    -- ★ 同樣的攻擊延遲 0.0667s
    if now2 - attackStart < attackDelay then
        return standCFrame, nil, nil
    end

    local origin = standCFrame.Position
    local aim = CFrame.new(origin, headPosition)
    local hitInfo = { part = hitboxHead }

    -- ★ Knife → HeavyAttack (背刺), 其他 → Attack
    if weapon.name == "Knife" then
        return standCFrame, cameraAngles(rootPart), function()
            weapon:HeavyAttack(aim, aim, hitInfo)
        end
    end
    return standCFrame, nil, function()
        weapon:Attack(aim, aim, hitInfo)
    end
end
```

### Melee 封包 (`MeleeItem:Attack` / `HeavyAttack`)

kicia.lua L87918-87940:
```lua
function MeleeItem:Attack(origin, direction, target)
    local hitPart, hitData = encodeHit(origin, target)
    self:AttackEncoded(Vector3Codec.encode(origin), Vector3Codec.encode(direction), hitPart, hitData)
end

function MeleeItem:AttackEncoded(origin, direction, hitPart, hitData)
    local attack = { ["\0"]=origin, ["\1"]=direction, ["\2"]=hitPart, ["\3"]=hitData }
    local args = { ["\1"]=attack, ["\2"]=encode("AttackAnimation1") }
    rawFireServer(UseItemRemote, self.objectId, encode("StartShooting"), args)
end

function MeleeItem:HeavyAttackEncoded(origin, direction, hitPart, hitData)
    -- 一樣格式, 但用 "StartAiming" + "HeavyAttackAnimation1"
    rawFireServer(UseItemRemote, self.objectId, encode("StartAiming"), args)
end
```

Knife 的 HeavyAttack 是背刺秒殺.

---

## 七、SetEnabled 做的環境改動 (跟主 Ragebot 一樣)

```lua
function LegitRagebot:SetEnabled(enabled)
    self._enabled = enabled
    -- FallenPartsDestroyHeight → NaN (防止假位置被判掉出地圖)
    workspace.FallenPartsDestroyHeight = enabled and 0/0 or defaultHeight
    -- 3 個 FFlag 提升物理發送率
    setfflag("DFIntS2PhysicsSenderRate",       enabled and "120" or "15")
    setfflag("DFIntAssemblyHistoryBufferSize", enabled and "2147483648" or "15")
    setfflag("DFIntAssemblyHistorySkipSize",   enabled and "0" or "8")
end
```

---

## 八、閃避 (只有 Random 一種)

```lua
function LegitRagebot:_EvadePlan(clientCFrame, mode)
    if mode ~= "Random" then return {} end   -- ★ 其他模式全部當 Off
    return { cframe = RandomEvasion.compute(clientCFrame) }
end
```

RandomEvasion:
- 選一個水平圓環上的點 (半徑 100~150)
- 選 X/Y/Z 其中一軸設成 **2^30 (1073741824)**
- 每 frame 重抽

**沒有 ProjectileBreaker, 沒有 Translocate**.

---

## 九、目標選擇 (跟主 Ragebot 共用 TargetSelection)

```lua
function TargetSelection:GetTarget()
    -- 優先打 Hacker (若 PrioritizeHackers=true)
    -- 否則遍歷 enemies, 拿第一個 valid target
end

-- valid = isEnemy + not IsInvincible + alive + not deflecting
```

**沒有距離判斷, 沒有 FOV, 沒有視線**. 只挑第一個活敵人.

---

## 十、時間軸: 一次完整開火

假設 `_enabled = true`, 目標剛出現在正常距離 (|座標| < 2^22, gated=true 直接放行):

```
Frame 0 (attackStart=nil, 目標第一次被選中):
  Update:
    - SpatialLimitGate:Tick(target) → gated=true (目標在範圍內)
    - HeadShotPlanner:Plan:
        - ShootLock:ShouldFire(true, dt*ShootFrames) → 放行, _lockedUntil = now + dt
        - _attackStart = os.clock()   ← 記錄開始時間
        - now2 - attackStart = 0 < 0.0667s → return (standCFrame, nil)  ★ 不開火
    - applyPlan: SetServerCFrame(頭上 0.5)
    - weaponAction = nil → 不送 shoot 封包
  Heartbeat: rootPart.CFrame = 頭上 0.5 studs

Frame 1~3 (0.0167~0.05s):
  Update:
    - ShootLock:ShouldFire → 還在 lockedUntil 內, 放行
    - now2 - attackStart < 0.0667s → 繼續 return (standCFrame, nil)
    - 玩家角色維持在頭上 0.5 位置
  (server 每 8ms 收到一次「玩家在頭上 0.5」的位置封包)

Frame 4 (0.0667s 到):
  Update:
    - ShootLock:ShouldFire → 放行
    - now2 - attackStart >= 0.0667s → ★ 建立 shoot 閉包
    - return (standCFrame, shoot)
    - applyPlan: SetServerCFrame(頭上 0.5)
    - weaponAction() → shoot() → ★ weapon:ShootAt(aim, aim, {part=head})
                       → ShootEncoded → rawFireServer(UseItemRemote, ...)
  Heartbeat: rootPart.CFrame = 頭上 0.5 studs (第 5 次)

  Server:
    - 已收到 5 個位置封包確認玩家在頭上 0.5
    - 收到 shoot 封包: origin=(頭上0.5), direction=看向頭, hitPart=head
    - Raycast 從 (頭上0.5) 沿 direction → 命中 head ✓
    - Damage 應用到目標

Frame 5:
  Update:
    - ShootLock:ShouldFire → 現在 _lockedUntil 過了, canFire=true → 放行, 重設 _lockedUntil
    - now2 - attackStart 仍 >= 0.0667s → return (standCFrame, shoot)
    - 又送一發!

(這樣每個 frame 都送一發, 直到目標死亡或離開範圍)
```

---

## 十一、Light 跟主 Ragebot 的最重要差異

| 面向 | Light (LegitRagebot) | Main (Ragebot) |
|-----|---------------------|----------------|
| **命中原理** | TP 到頭上 0.5, 從那位置正常打 | PartGlue 綁頭, 送極端 CFrame (-9e37) 讓 server 特殊處理 |
| **hitData** | 用 `encodeShot(origin, hitInfo)` 真實算出 | 常數 `{0,1,0,0,0,0}` |
| **站位** | 頭上 0.5 studs (Above) 或頭下 3 studs (Below) | PartGlue 後在 `farCF + (0,-0.7,0.05)` 或 `farCF + (0,-3.85,0.05)` |
| **shoot 使用** | `weapon:ShootAt(aim, aim, {part=head})` | `gun:ShootEncoded(aboveOrigin, aboveDir, head, HIT_DATA)` |
| **蹲下** | ❌ 不強制 | ✅ 攻擊時強制 |
| **視角** | 一般不送 (只有 Knife backstab 才送) | 有盾時送 ±90 pitch 隨機 yaw |
| **閃避模式** | 只有 Random | Random / ProjectileBreaker / Translocate |
| **PartGlue** | ❌ 沒有 | ✅ 每 tick Acquire |
| **PhysicsRepRootPart** | ❌ 不動 | ✅ 綁到目標頭 |
| **Defense pitch table** | ❌ 沒有 | ✅ 依盾方向 ±90 |
| **反作弊隱蔽性** | 比較容易被抓 (真的 TP 到頭上) | 較隱蔽 (server 看似合理的極端座標) |
| **命中率穩定性** | ✅ 高 (簡單原理, 沒 encoded 迷思) | ⚠️ 依賴 server 特殊處理 -9e37 |

---

## 十二、Light Ragebot 為什麼能打

**核心邏輯**: 「**把自己 TP 到目標頭頂 0.5 studs, 然後從那位置對頭正常開槍**」

三個支撐機制:
1. **CFrameDesync**: 讓 server 認為你在頭頂 (rootPart.CFrame 被物理引擎複製), 客戶端畫面看你沒動 (RenderStep 還原)
2. **FFlag 提升發送率**: 保證位置封包每 frame 都送出 (預設 15Hz 會漏, 提到 120Hz)
3. **weapon:ShootAt**: 用遊戲原本的 API 送 shoot 封包, `encodeShot` 內部把 origin (你的假位置) 和 head 一起編碼, server 判定為合理射擊

**跟主 Ragebot 不同**: Light 不玩 PhysicsRepRootPart 那一套「相對頭部位置」的技巧. 它就是**赤裸裸地** TP 到頭上打人.

**限制**:
- 反作弊看你瞬間跑到目標頭上, 容易標記
- 沒盾防禦, 貼上去被打
- 沒閃避多樣性, 只能 Random
- 沒強制蹲, hitbox 是站姿全高

---

## 十三、程式碼結構總結 (L73620-73800)

```
loadLegitRagebot() {
  依賴: HitscanStrategy(HeadShotPlanner), MeleeStrategy(HeadPlanner),
        TargetSelection, ActionPlanner, SpatialLimitGate, RandomEvasion

  LegitRagebot.new():
    _trove, _enabled=false,
    _playerContext,
    _targetSelection,
    _spatialLimitGate,
    _hitscanStrategy = HeadShotPlanner.new(),
    _meleeStrategy   = HeadPlanner.new(),
    _innerContext = nil

  LegitRagebot:_Initialize():
    ObserveContext("ragebot") + contextRemoved 監聽
    Keybinds:ObserveEnabledKeybind → SetEnabled

  LegitRagebot:SetEnabled(enabled):
    設 3 個 FFlag + FallenPartsDestroyHeight NaN

  LegitRagebot:Update(dt):
    context/alive 檢查
    target = TargetSelection:GetTarget()
    plan = _Plan(dt, ActionPlanner.getAction(context), target, clientCF, mode)
    applyPlan(plan, context)                  -- SetServerCFrame + SendViewAngles
    if plan.weaponAction then plan.weaponAction() end   -- 送封包

  LegitRagebot:_Plan(dt, action, target, clientCF, mode):
    gated = target and not SpatialLimitGate:Tick(target)
    action == nil / Swap / Reload / target nil → _EvadePlan
    Gun → HeadShotPlanner:Plan(dt, target, gun, gated)
    Melee → HeadPlanner:Plan(dt, target, melee, gated)
    else → {}

  LegitRagebot:_EvadePlan(clientCF, mode):
    if mode ~= "Random" then return {}
    return { cframe = RandomEvasion.compute(clientCF) }

  LegitRagebot:_Reset():
    (沒實作在讀到的部分, 應該是 SetServerCFrame(nil) + clear view angles + strategy reset)
}
```
