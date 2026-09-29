# 簡易版 vs 主版 Ragebot 封包對比

已讀 8 份 MD: `01, 02, 05, 07, 08, 09, 11, 14`. 缺 6 份 (`03, 04, 06, 10, 12, 13`).

**Doc 05 §2** 直接列出了 3 個版本的封包差異表 — 這篇是完整對比 + 我 v6 實作誤差修正.

---

## 一、三個 Ragebot 版本並列 (Doc 05 §2)

| 版本 | 起點 (origin) | 方向 (direction) | 命中點 (hitData) | 伺服器看到的你 |
|-----|--------------|-----------------|----------------|--------------|
| **主 Ragebot** (`iq`, HeadGlue+Backstab) | `(-9e37, 0, 0)` + rx=∓π/2 | `(0, ∓9e7, 0)` | **常數 `(0, 1, 0)`** | PartGlue 黏在頭上方 0.7 或下方 3.85 |
| **LegitRagebot** (`it`, `iu`) | `lookAt(站位, 頭)`, **真實位置** | 同起點 | `GetClosestPointOnSurface`, **真實表面點** | 傳送到頭上 0.5 (或下 3), 等 ~66ms 才開火 |
| **簡易 Ragebot** (`ir`) | 頭 + (0, 50, 0), **真實 CFrame** | 頭 - (0, 50, 0), **真實 CFrame** | **真實表面點** (由 encodeShot 計算) | server CFrame 直接設在對方 rootPart |

---

## 二、封包內容逐項比對

### 2.1 起點/方向 (origin / direction)

**主版** — 用**預編碼常數** 直接送 (不經 CFrameCodec.encode):
```lua
ABOVE_ORIGIN = { ["\0"] = -9e37, ["\1"] = 0,     ["\2"] = 0, ["\3"] = -π/2, ["\4"] = π, ["\5"] = π }
ABOVE_DIR    = { ["\0"] = 0,     ["\1"] = -9e7,  ["\2"] = 0, ["\3"] = -π/2, ["\4"] = π, ["\5"] = π }
```
- `-9e37` 接近 float32 max (3.4e38), server 端「起點-你的位置」距離檢查會**溢位成 inf/NaN**, 比較永遠 false → 繞過驗證 (doc 05 §2 推論)

**簡易版** — 用**真實 CFrame** 經 partCodec 編碼:
```lua
gun:ShootAt(
    CFrame.new(head.Position + Vector3.new(0, 50, 0)),   -- origin CFrame
    CFrame.new(head.Position - Vector3.new(0, 50, 0)),   -- direction CFrame
    { part = head }
)
```
GunItem:ShootAt 內部 (K L72943):
```lua
hitPart, hitData = encodeShot(origin, {part=head})     -- ★ 動態計算 hitData
ShootEncoded(partCodec.encode(origin), partCodec.encode(dir), hitPart, hitData)
```

### 2.2 命中點 (hitData) — **關鍵差異!**

**主版** — 常數:
```lua
HIT_DATA = { ["\0"] = 0, ["\1"] = 1, ["\2"] = 0, ["\3"] = 0, ["\4"] = 0, ["\5"] = 0 }
-- 意義: head local space (0, 1, 0) = 頭頂 1 stud
-- 推測是「命中法線朝 +Y」的假設 (doc 08 §7.3)
```

**簡易版** — 動態計算:
```lua
-- encodeShot 會用 origin 位置 + part 幾何算出「射線在 part 表面的最近命中點」
-- 這是真實的表面座標 (在 part 的 object space)
hitPart, hitData = encodeShot(origin, {part=head})
```

### 2.3 TP 機制

**主版**:
```
PartGlue:Acquire(自己的 root, 目標頭)
├─ setthreadidentity(8) → sethiddenproperty(root, "PhysicsRepRootPart", head)
├─ 拆頭上的 WeldConstraint.Part1, 頭本地 Anchored=true
├─ 頭本地 CFrame = farCF (100000Y 附近)
└─ 站位 = farCF + (0, -0.7, 0.05)
→ SetServerCFrame(站位)
→ 伺服器認為: 我在 head.CFrame * (0, -0.7, 0.05)  [推論]
```

**簡易版**:
```lua
ctx.characterController:SetServerCFrame(
    CFrame.new(target.aliveState.rootPart.Position)
)
-- 完全沒有 PartGlue, 沒有 PhysicsRepRootPart, 沒有 WeldConstraint 拆解
-- 伺服器直接看到你站在對方腳邊
```

### 2.4 送出封包 (Doc 11 § 4.3)

**兩個版本都用同一個 remote + 同一個機制**:
```lua
-- 都是原始 FireServer (f11097 = 載入時抽的 RemoteEvent.FireServer)
f11097(
    UseItemRemote,
    objectId,                         -- Info.ObjectID
    EnumCodec.encode("StartShooting"), -- inputType byte
    {
        ["\1"] = shotArgs,   -- 起點/方向/命中零件/命中點
        ["\2"] = isRaycast   -- 只有射線槍才帶
    }
)
```

差別只在 `shotArgs` 裡面的內容 (見 2.1 / 2.2).

---

## 三、我 v6 的 `SilentAimUpdate` 對比

### 現況 (❌ 錯誤!)
```lua
-- v6 L1650+
gunShootEncoded(gun, CFrameCodec.encode(origin), CFrameCodec.encode(dir),
                target.aliveState.hitboxHead, HIT_DATA)   -- ★ 用了主版的常數 HIT_DATA
```

**問題** — 我 v6 的 SilentAimUpdate:
- ✅ 用了真實 CFrame (符合簡易版)
- ✅ 用了 CFrameCodec.encode 編碼 (符合簡易版)
- 🔴 **用了主版的常數 HIT_DATA `{0,1,0,0,0,0}`** ← 不對!

這樣送的封包是**主版和簡易版的雜交**:
- 位置封包: 簡易版 (TP 到 target rootPart)
- Shoot 封包起點/方向: 簡易版風格 (真實 CFrame)
- Shoot 封包 hitData: 主版風格 (常數)

Server 收到後, 可能:
1. 起點/方向合理 (真實 head±50Y) → 通過距離檢查
2. 但 hitData 是頭頂 1 stud → 可能不在射線經過的表面上 → 命中判定失敗

### v7 修法

改用 `gun:ShootAt(...)` 讓 GunItem 自己算 hitData:
```lua
-- v7 建議
if type(gun.ShootAt) == "function" then
    gun:ShootAt(origin, dir, { part = target.aliveState.hitboxHead })
else
    -- fallback: 手動算 encodeShot
    local encodeShot = require(...)  -- module aY
    local hitPart, hitData = encodeShot(origin, { part = target.aliveState.hitboxHead })
    gunShootEncoded(gun, CFrameCodec.encode(origin), CFrameCodec.encode(dir), hitPart, hitData)
end
```

---

## 四、為什麼主版可以「穩定」用常數 hitData 而簡易版不能?

**推論** (based on doc 05 §2 的 -9e37 分析):

主版用的極端值 `-9e37` 和 `-9e7` 會讓 server 的**距離/射線長度檢查溢位**:
```
射線長度 = |direction - origin| ≈ |(0,-9e7,0) - (-9e37,0,0)| = sqrt(9e37² + 9e7²)
        ≈ 9e37 → float32 = inf
比較「射線長度 ≤ 最大距離」→ inf ≤ X → false → **不判定失敗**
```

主版 = **靠溢位繞過驗證**, 所以 hitData 不需要準確 (server 根本沒真的驗證)

簡易版 = **真實座標**, 沒繞過驗證, 所以 hitData 必須是真實表面點.

我 v6 混用兩者 → 沒繞過驗證 (真實 origin) 但 hitData 是假的 → **必然失敗**.

---

## 五、11 章補的 FireServer 細節 (v7 需要注意)

**Doc 11 §3.3** — 載入器對 FireServer 做的驗證:
1. `islclosure(FireServer)` 必須為 false
2. `iscclosure(FireServer)` 必須為 true
3. `isfunctionhooked(FireServer)` 必須為 false
4. `debug.info(FireServer, "s")` 必須為 `"[C]"`
5. `FireServer == Instance.new("RemoteEvent").FireServer` (identity match)
6. **`tostring_tamperCheck`** — 對空 RemoteEvent 開一槍, 從 tostring 回呼檢查呼叫堆疊

**我 v6 的做法**:
```lua
-- v6 L79-83
local dummyRemote = Instance.new("RemoteEvent")
local dummyUnreliable = Instance.new("UnreliableRemoteEvent")
local rawFireServer         = dummyRemote.FireServer
local rawFireServerUnreliable = dummyUnreliable.FireServer
dummyRemote:Destroy()
dummyUnreliable:Destroy()
```

**沒問題** — 跟原檔一致 (從新建的空 RemoteEvent 拿, 沒經過真的 remote 的 metatable). 但**我沒做驗證**.

**v7 建議** — 加上完整驗證:
```lua
local function verifyFireServer(fs, label)
    if not fs then error("[kicia] "..label..": nil") end
    if debug.info and debug.info(fs, "s") ~= "[C]" then
        error("[kicia] "..label..": not C function (was "..debug.info(fs, "s")..")")
    end
    if islclosure and islclosure(fs) then
        error("[kicia] "..label..": is Lua closure (hooked?)")
    end
    if isfunctionhooked and isfunctionhooked(fs) then
        error("[kicia] "..label..": function hooked")
    end
    local fresh = Instance.new("RemoteEvent")
    local freshFs = fresh.FireServer
    fresh:Destroy()
    if fs ~= freshFs then
        error("[kicia] "..label..": identity mismatch (someone replaced FireServer)")
    end
end
verifyFireServer(rawFireServer, "FireServer")
verifyFireServer(rawFireServerUnreliable, "FireServerUnreliable")
```

這樣如果有其他外掛/hook 動了 FireServer, 我方會**明確報錯**而不是靜默失敗.

---

## 六、v7 的 3 個關鍵修正

基於 doc 05, 11 的比對:

### 修正 1: SilentAimUpdate 用 `gun:ShootAt` 而非 `gunShootEncoded`
讓 hitData 由 GunItem 動態計算, 不用常數.

### 修正 2: 加 FireServer 完整驗證 (載入時)
避免其他外掛動了 FireServer 導致 Ragebot 靜默失敗.

### 修正 3: 加 encodeShot 模組作為 fallback
如果 `gun.ShootAt` 不存在, 也能手動算 hitData 而不是硬用常數.

---

## 七、剩下 6 份 MD 期待內容

| 檔案 | 預期內容 |
|-----|---------|
| `03_目標鎖定.md` | TargetLock keybind 邏輯 (v6 沒實作, 用 first-enemy) |
| `04_7r6d3rk比對.md` | K vs R 版本差異細節 |
| `06_玩家TP與開火位置.md` | doc 07 的補充或前身 |
| `10_Ragebot輔助功能盤點.md` | 我可能漏的次要功能 |
| `12_Stability與ShootFrames.md` | 這兩個參數的深度分析 |
| `13_閃避TP與換彈.md` | Evasion mode + Reload/Swap 邏輯 |

其中 `04_7r6d3rk比對` 對我審計 v6 最有價值 (直接告訴我兩份原檔的差異).
