# RAGEBOT 原檔完整追蹤 (v6 補丁基礎)

用 MCP 把兩份原檔完整翻過 (Ragebot 模組全部 26 個 helper)，找出 v5 遺漏的細節 + TP 為什麼不對 + 鏡頭 HOOK 遺漏。

---

## ★ 關鍵發現 1: 原檔有 **兩個** Ragebot!

`c972f775-7r6d3rk.luau` 有兩個 Ragebot 模組:

### 主 Ragebot (module `iq`, L108494-108793) — 複雜版
- 用 HitscanStrategy + MeleeStrategy 分開處理
- 有 HeadGlueShotPlanner (PartGlue + 預編碼角度)
- 有 SpatialLimitGate, ProjectileBreakerTeleport, Evasion 三種模式
- 有 Defense (Riot Shield 側)
- **這是 v5 還原的版本**

### 簡化版 Silent Aim Ragebot (module `ir`, L108795-108903) — 簡單版
```lua
function t4790:Update()
    ...
    local hitboxHead13 = GetTarget8.aliveState.hitboxHead
    -- ★ 直接 TP 到 target rootPart 位置 (不用 offset, 不用 PartGlue)
    _innerContext37.characterController:SetServerCFrame(
        CFrame.new(GetTarget8.aliveState.rootPart.Position))
    local EquippedItemAsGun15 = _innerContext37.itemBehaviors:EquippedItemAsGun()
    if EquippedItemAsGun15 == nil then return end
    -- ★ 從 head +50 studs → head -50 studs, 垂直穿過 hitbox
    local v12421 = CFrame.new(hitboxHead13.Position + Vector3.new(0, 50, 0))
    local v12422 = CFrame.new(hitboxHead13.Position - Vector3.new(0, 50, 0))
    EquippedItemAsGun15:ShootAt(v12421, v12422, { part = hitboxHead13 })
end
```

**為什麼這個簡單版可能命中率更好**:
1. TP 到 target 身上 → server 看你就站在他頭上, 距離 0
2. 射線從 (head + 50Y) 垂直射到 (head - 50Y) → 100% 穿過 head 碰撞盒
3. 沒有 encoded angle template 的解碼問題
4. 沒有 PartGlue 拆 WeldConstraint 的副作用
5. 缺點: 你的角色會在 target 位置閃現 (被反作弊看到)

**v6 已加**: 呼叫 `ragebot:SilentAimUpdate()` 而不是 `ragebot:Update()` 即可切換到這個模式.

---

## ★ 關鍵發現 2: 鏡頭 HOOK 本來就有兩個, v5 只做了一個

### hookCameraReplication (R L37544-37589 → ViewAngleDriver._InstallReplicationHook) — v5 已做
- Hook `FighterController._CameraReplicationLoop` 的 `EncodeCameraRotation` upvalue
- 讓 server 只收到我方指定的 rotation, 不是真的相機方向

### hookCameraSway (R L82070-82182 → CameraSwayDisabler) — **v5 遺漏**
- Hook `FighterController.GetCameraSway` 裡的 `CameraController` upvalue
- 讓 `CameraController.GetPublicState()` 永遠回傳 `"ThirdPerson"`
- 效果: 停用第一人稱相機晃動 → view spoof 更穩

**為什麼這個對命中重要**:
- 第一人稱下, 相機同步比較嚴格 (server 會用 camera state 交叉驗證射擊方向)
- 強制 ThirdPerson state → server 走 third-person 的較寬鬆驗證路徑
- 遊戲的 NoCameraSway 選項就是靠這個 hook

**v6 已加**: `CameraSwayDisabler` 模組, `SetEnabled(true)` 時自動 install.

---

## ★ 關鍵發現 3: 主 Ragebot 的 TP 到底怎麼算的

從 `HeadGlueShotPlanner:Plan` 追下去:

```
1. PartGlue.new() 時只算一次: 
   PG_FAR_CF = CFrame.new(random(-100000,-10000), 100000, random(-100000,10000))
   ↑ 這是「遠方天空的一個固定點」

2. 每 tick Plan() 呼叫時:
   glued = partGlue:Acquire(ourRoot, targetHead)
   
   Acquire 做的事:
   a. setthreadidentity(8) → sethiddenproperty(ourRoot, "PhysicsRepRootPart", targetHead)
      → server 現在把 ourRoot 的位置當成跟 targetHead 一起走
   b. targetHead 的 WeldConstraint.Part1 = nil, Anchored = true
      → 讓 targetHead 本地 anchored, 不會跟角色移動
   c. rawSetCFrame(targetHead, CFrame.new(PG_FAR_CF.Position))
      → 本地把 targetHead 搬到「遠方天空」
   d. return PG_FAR_CF
   
3. Plan 用 PG_FAR_CF + ABOVE_OFFSET 當 stand 位置:
   stand = PG_FAR_CF + Vector3.new(0, -0.7, 0.05)
   
4. Ragebot._ApplyPlan:
   SetServerCFrame(stand)  → 我方 rootPart 也搬到「遠方天空」
   
5. 呼叫 gunShootEncoded(gun, ABOVE_ORIGIN, ABOVE_DIR, targetHead, HIT_DATA):
   - ABOVE_ORIGIN = {x=-9e37, y=0, z=0, pitch=-π/2, yaw=π, roll=π}
   - ABOVE_DIR    = {x=0, y=-9e7, z=0, pitch=-π/2, yaw=π, roll=π}
   - HIT_DATA     = {0, 1, 0, 0, 0, 0} = head local space (0,1,0)
```

**這個機制的精髓**:
- 我方 + target head 都被 TP 到「遠方天空」同一點附近
- 射擊封包送 `origin=-9e37, dir=-9e7` 極端值
- Server 解碼這些值 → 進入某個「特殊路徑」直接判定命中 target head
- 命中位置 = head local (0, 1, 0) = 頭頂正上方

**如果不中的可能原因**:
1. **setthreadidentity(8) 失敗** → PhysicsRepRootPart 沒設好, server 不認可 TP
2. **WeldConstraint 拆不掉** → targetHead 沒搬到 PG_FAR_CF, server 判定 head 位置不對
3. **encoded value 意義變了** → 遊戲更新後, -9e37 sentinel 不再是特殊路徑
4. **PhysicsRepRootPart 屬性名變了** → 遊戲更新後可能改名

**如何 debug**:
```lua
ragebot._diagnostic = true  -- v6 加的 flag
-- 之後每次射擊會 print:
-- [kicia] shoot pos=<serverCFrame> → head=<headPos> viewAngles=SET/nil
```

---

## ★ 關鍵發現 4: 主/簡易 Ragebot 都不呼叫 HeartbeatUpdate

原檔的 GameLoop (R L81412-81477) 用 4 個 signal:
```
SetPreCameraRender(fn)  → RenderStep at Camera priority - 1
SetPreRender(fn)        → RunService.PreRender
SetPreSimulation(fn)    → RunService.PreSimulation (物理算之前)
SetHeartbeat(fn)        → RunService.Heartbeat (物理算之後)
```

- **PreSimulation callback** → 呼叫 Ragebot:Update (計算 + 送 shoot 封包)
- **Heartbeat callback**     → 呼叫 PlayerContext:HeartbeatUpdate → CharacterController:HeartbeatUpdate

**原檔的時序**:
```
[PreSimulation] Ragebot:Update()
                ├─ SetServerCFrame(fake)  → _cframe = fake
                └─ weaponAction() → shoot 封包送出

[Physics simulation]  ← 這裡物理引擎用「舊」rootPart.CFrame 算網路封包 (server 認為玩家沒動)

[Heartbeat]     CharacterController:HeartbeatUpdate()
                └─ rootPart.CFrame = _cframe  → 真正把角色移到 fake

[下一個 Physics simulation]  ← 這時才發送 fake 位置
```

**問題**: 這樣 shoot 封包永遠比位置封包早 1 個物理 tick 送到 server!

**KI 怎麼解決?** 靠 FFlag `DFIntS2PhysicsSenderRate = 120`:
- 預設 15Hz → 每 66ms 送一次位置 → shoot 超前 66ms → server 判定失敗
- 提到 120Hz → 每 8ms 送一次位置 → shoot 超前 8ms → server 判定通常過

**v5 我加的 fix (HeartbeatUpdate 在 _ApplyPlan 裡)**:
```
Ragebot:Update()
├─ _ApplyPlan
│   ├─ SetServerCFrame(fake)
│   ├─ HeartbeatUpdate()  ★ 立刻把 rootPart.CFrame 設為 fake
│   └─ FlushViewAngles()
└─ weaponAction() → shoot 封包送出

[Physics simulation] ← 用「新」rootPart.CFrame 算, server 拿到 fake 位置

[Heartbeat] 沒事做 (已經 apply 過了)
```

**v6 保留這個 fix** — 比原版更可靠. 但代價: 客戶端每 frame 都會看到自己閃現到 fake 位置, 再被 RenderStep 拉回原位, 可能有微微抖動.

---

## v6 修的東西

| # | 位置 | 修改 |
|---|------|------|
| 1 | CameraSwayDisabler (新增) | Hook GetCameraSway 讓 GetPublicState 回傳 "ThirdPerson" |
| 2 | Ragebot.new | 加 `_cameraSwayDisabler` + `_diagnostic` flag |
| 3 | Ragebot:SetEnabled | 開時 hookCameraSway, print `setfflag=type` 便於 debug |
| 4 | Ragebot:_ApplyPlan | 三層 viewAngles fallback: plan → defensive → computeAimAtTarget |
| 5 | computeAimAtTargetViewAngles (新增) | 從 clientPos 到 targetHead 算出 pitch/yaw |
| 6 | Ragebot:SilentAimUpdate (新增) | R L108862 簡化版 - TP 到 target, 垂直射穿 |
| 7 | Ragebot:Destroy | 加 `_cameraSwayDisabler:Destroy()` |

---

## 如何測試哪個模式好用

在 UI 的 Ragebot toggle callback 換成 SilentAimUpdate 試試:

```lua
-- 找到 §24 GameLoop, 把
RunService.Heartbeat:Connect(function(dt)
    ragebot:Update(dt)  -- 主版 (複雜, 用 HeadGlueShotPlanner + PartGlue)
end)
-- 改成:
RunService.Heartbeat:Connect(function(dt)
    ragebot:SilentAimUpdate()  -- ★ 簡化版 (直接 TP 到 target, 垂直射)
end)
```

或者用 diagnostic 模式看主版有沒有動:
```lua
_G.__kicia_ragebot._diagnostic = true
-- 開 ragebot, 對敵人開槍, 看 output console:
-- [kicia] shoot pos=... → head=... viewAngles=SET
-- 如果 pos 是 (100000, ...) → PartGlue 正常
-- 如果 pos 是原本位置 → PartGlue 或 rawSetCFrame 失敗
-- 如果 viewAngles=nil → ViewAngleDriver hook 沒 install → 換 viewAngles=SET 前不會中
```
