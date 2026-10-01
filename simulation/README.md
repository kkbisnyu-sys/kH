# RAGEBOT 时序验证

## 问题
TP 假位置和射击封包能不能在同一帧配合发送？

## 结论 (基于代码验证)

**是的，配合发送**，但通过**两个独立通道**到达服务器：

```
Ragebot:Update(dt)                      ← 每帧 RenderStepped 调用
├─ _ApplyPlan(plan)
│   └─ desync:SetServerCFrame(cframe)   ← 只是存进 _cframe 字段
├─ _ApplyForcedCrouch(true)
└─ plan.weaponAction()
    └─ weapon:ShootAt(...)               ★ 射击封包立即经 UseItemRemote 发出
        └─ UseItemRemote:FireServer(...)

<稍后同一帧 Heartbeat 事件触发>
CFrameDesync:HeartbeatUpdate()
└─ rootPart.CFrame = _cframe             ★ 假位置正式写入物理组件

<物理线程>
DFIntS2PhysicsSenderRate = 120Hz
└─ 物理复制器把 rootPart.CFrame 打包发送给服务器  ← 假位置封包

<下一帧 RenderStepped 前>
CFrameDesync:_RenderStepUpdate()
└─ rootPart.CFrame = _oldCFrame          ← 客户端渲染时还原真实位置
```

## 关键点

1. **同一 Update tick 内完成**：SetServerCFrame + weaponAction 都在一个函数调用栈里
2. **不同通道传输**：
   - 射击封包 → 立即经 RemoteEvent 发出
   - 假位置 → 靠物理引擎的 Heartbeat 更新 + `DFIntS2PhysicsSenderRate` 复制
3. **FFlag 的意义**：`DFIntS2PhysicsSenderRate` 从 15 提到 120 (×8)，就是为了确保假位置封包能够**赶在射击封包被服务器处理前**送达
4. **客户端视觉不变**：`_RenderStepUpdate` 在下一次渲染前把真实位置还原，玩家看到自己没动

## 运行

```bash
lua ragebot_trace.lua
```

或查看 `trace_output.txt`。

## 相关源码位置

| 组件 | 文件 | 行号 |
|------|------|------|
| Ragebot:Update | kicia_deobfuscated_optimized.lua | 63025 |
| _ApplyPlan | 同上 | 63156 |
| CFrameDesync:SetServerCFrame | 同上 | 144295 |
| CFrameDesync:HeartbeatUpdate | 同上 | 144325 |
| CFrameDesync:_RenderStepUpdate | 同上 | 144315 |
| GunItem:ShootEncoded | 同上 | 72949 |
| FFlag 设置 | 同上 | 63003-63022 |
