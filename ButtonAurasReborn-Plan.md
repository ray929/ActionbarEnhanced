# ButtonAurasReborn 可行性分析与开发规划

> 目标：适配正式服 12.0.7（Interface 120007），通过 hook 暴雪自带的 CDM（Cooldown Manager）
> 获取增益信息，仅把"用户绑定了动作条按钮的增益"覆盖到原生动作条按钮上（左上=剩余时间/绿色，左下=层数/紫色，字号16，不显示图标）。

---

## 一、需求重述（逐条对齐）

| # | 需求 | 落点 |
|---|------|------|
| 1 | 适配 12.0.7 | toc `## Interface: 120007`（Ayije_CDM 已验证兼容 120005/120007） |
| 2 | 只看增益，跳过技能冷却 | 只 hook `BuffIconCooldownViewer` / `BuffBarCooldownViewer`，并筛选 `auraDataUnit`/`auraInstanceID` 存在的 item |
| 3 | 不读 unit auras（战斗中不可用） | 改为 hook CDM；剩余时间/层数都从 CDM 自身数据取（附战斗安全兜底） |
| 4 | 仅绑定了按钮的增益迁移 | 配置表：spellID → 绑定按钮名（未绑定则不覆盖，无独立的"选中"状态） |
| 5 | 每个增益单独绑定一个动作条按钮 | 配置表：spellID → 按钮名（如 `ActionButton3`） |
| 6 | 左上剩余时间(绿)/左下层数(紫)，字号16 | overlay 两个 FontString，固定样式 |
| 7 | 图标不显示 | overlay 只渲染文字，不画增益图标 |
| 8 | 载具/宠物对战/御空术导致绑定条隐藏时，信息一并隐藏 | `IsVisible()` 守卫 + 事件监听 |
| 9 | 仅原生动作条 | 限定 `ActionButtonUtil.ActionBarButtonNames` 列表 |

---

## 二、核心结论

**可行性：高。**

暴雪在 11.x 引入、12.x 沿用的 Cooldown Manager（CDM）暴露了全局查看器 `BuffIconCooldownViewer` 与 `BuffBarCooldownViewer`。它们本身就是"战斗中可用、无需扫描 unit auras"的增益展示源。三个参考插件（**CDMButtonAuras / Ayije_CDM / vflow**）均已验证可以 hook 这些查看器并取得 spellID / 剩余时间 / 层数。所需时间、层数均可在 **不调用 `C_UnitAuras` 扫描接口** 的前提下取得：

- 剩余时间：主路径 `info.startTime + info.duration - GetTime()`（来自 `GetCooldownViewerCooldownInfo`）；
- 层数：主路径 hook item frame 的 `RefreshApplications(displayCount)` 或读原生 `Applications`/`count` FontString。

兜底层（若主路径在某版本字段缺失）使用 12.0 专门提供的"单点、secret-safe"接口 `C_UnitAuras.GetAuraDuration` / `GetAuraApplicationDisplayCount`，**不同于被禁的 `UnitAura` 扫描，战斗内仍可用**。

---

## 三、关键技术验证（来自参考实现）

### 3.1 Hook 入口
```lua
hooksecurefunc(BuffIconCooldownViewer, 'OnAcquireItemFrame', OnItemAcquired)
hooksecurefunc(BuffBarCooldownViewer,  'OnAcquireItemFrame', OnItemAcquired)
```
每个 item frame 带 `item.cooldownID`（CDMButtonAuras、Ayije_CDM、vflow 三处一致）。

### 3.2 取 spellID（用于匹配 / 绑定）
```lua
local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(item.cooldownID)
-- info.spellID / info.linkedSpellIDs[] / info.overrideSpellID
```
优先级处理参考 vflow `ResolveSpellID`：`linkedSpellIDs[1]` → `overrideSpellID` → `spellID`。
**仅筛选增益**：保留 `info.auraDataUnit` 且 `info.auraInstanceID` 同时存在的 item（确为 aura）。

### 3.3 取剩余时间（不读 unit auras）
- 主路径：`remaining = info.startTime + info.duration - GetTime()`
  （CDM 自身的冷却环数据同源；`GetCooldownViewerCooldownInfo` 返回 `startTime`/`duration`，ButtonCD 也读取了 `info.duration`/`info.expirationTime`）。
- 兜底（战斗安全）：`local durObj = C_UnitAuras.GetAuraDuration(unit, auraInstanceID); remaining = durObj:GetRemainingDuration()`。

### 3.4 取层数（不读 unit auras）
- 主路径：`hooksecurefunc(itemFrame, "RefreshApplications", function(_, displayCount) ... end)` 捕获显示层数（vflow 已 hook 此函数）；或读 item frame 原生 `Applications`/`count` FontString 文本。
- 兜底（战斗安全）：`C_UnitAuras.GetAuraApplicationDisplayCount(unit, auraInstanceID)`（SentinelHunterTools 标注为 secret-safe）。

> 不建议依赖 `info.count`：ButtonCD 对其也存疑（注释 "Info might have count?"）。层数主路径用 `RefreshApplications` hook 或 FontString 更稳。

### 3.5 绑定原生动作条按钮
- 枚举：`ActionButtonUtil.ActionBarButtonNames`（`ActionButton1..`、`MultiBarBottomLeft/RightButton`、`MultiBarRight/LeftButton`、`MultiBar6/7Button`、`StanceButton`、`PetActionButton` 等）。
- 用户配置：`spellID → 按钮名`。仅原生条，不处理 ElvUI/Bartender（其按钮不在该列表）。

### 3.6 覆盖层显示
在目标 `actionButton` 上挂 overlay（建议 FramePool 池化），两个 FontString：
- `Timer`：锚点 `TOPLEFT`，绿色（如 `0.2,1,0.2`），显示剩余秒数；
- `Stacks`：锚点 `BOTTOMLEFT`，紫色（如 `0.8,0.4,1`），显示层数；
- 字号统一 16：`fontString:SetFont(nil, 16, "OUTLINE")`（或指定字体路径）。
- **不绘制增益图标**，动作按钮自身图标保留 → 满足"图标不显示"。
- 计时用 overlay `OnUpdate`（节流 0.1s）刷新 remaining，避免战斗内改结构。

### 3.7 可见性 / 战斗·载具·宠物对战·御空术
- 守卫：`if not actionButton:IsVisible() then overlay:Hide() end`。
- 监听事件：`ACTIONBAR_SLOT_CHANGED`、`UPDATE_OVERRIDE_ACTIONBAR`（御空术/载具 override bar）、`UPDATE_VEHICLE_ACTIONBAR`、`UPDATE_BONUS_ACTIONBAR`、`PET_BATTLE_OPENING_START`/`PET_BATTLE_CLOSING_END`、`UNIT_EXITED_VEHICLE`、`PLAYER_ENTERING_WORLD`。
- 战斗锁定注意：overlay 在 `PLAYER_LOGIN` 预创建/池化，战斗内只改文本与显隐，**不新建/销毁 frame、不改 ActionButton 层级**。

---

## 四、风险与不确定点

| 风险 | 影响 | 缓解 |
|------|------|------|
| `info.startTime/duration` 对 buff 是否填充 | 剩余时间主路径失效 | 游戏内 `/dump` 验证；失败回退 `GetAuraDuration`（仍合规战斗安全） |
| `info.count` 可靠性 | 层数不准 | 用 `RefreshApplications` hook / FontString 主路径 |
| secret value 比较 | 个别 spellID 不可直接 `==` | pcall 比较（参考 vflow `SafeSpellIdEquals`）；玩家自身增益多为普通数值 |
| 同一增益出现在两个 viewer | 重复映射 | 以 spellID 去重，取其一 |
| 战斗内 UI 限制 | 报错/不生效 | overlay 池化 + 仅改文本/显隐 |

---

## 五、推荐架构（模块划分）

```
ButtonAurasReborn/
├─ ButtonAurasReborn.toc        # Interface: 120007, SavedVariables: ButtonAurasRebornDB
├─ Core/
│  ├─ Hook.lua        # hook 两个 CDM viewer；维护 cdID→frame、spellID→cdID 映射
│  ├─ AuraState.lua   # 每个被追踪增益的运行时状态(remaining/stacks/active)
│  ├─ Overlay.lua     # 在 actionButton 上创建/更新文字覆盖层(Timer/Stacks)
│  └─ Binding.lua     # spellID→按钮名 映射、可见性检查、事件监听
├─ Config/
│  └─ Options.lua     # 选增益 + 绑按钮（slash 先行，后补 GUI）
└─ Locale/            # 可选
```

**数据流：**
`CDM Viewers → Hook → Map(spellID↔cdID) → Filter(已绑定按钮的增益) → Binding(→原生按钮) → Overlay(文字层) ── Visibility Guard ──→ ActionButton`

---

## 六、实施阶段

- **Phase 0 — 骨架**：toc(120007)、目录、SavedVariables、入口 `PLAYER_LOGIN` 注册。
- **Phase 1 — Hook & 映射（带调试）**：hook 两个 viewer；维护映射；`/dump` 验证 `GetCooldownViewerCooldownInfo` 字段（startTime/duration/count/aura*）；输出调试面板确认能拿到数据。
- **Phase 2 — 覆盖层渲染（已完成，2026-07-17）**：`Overlay.lua`。每个"已绑定"增益在对应原生按钮上创建两个 FontString：左上=剩余时间(绿,字号16)、左下=层数(紫,字号16)；数据来自 `C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)`（不读 unit auras，战斗可用）；OnUpdate 节流 0.1s 刷新；不渲染增益图标；绑定条 `IsVisible()` 为 false（小宠物对战/载具/御空术等）时信息隐藏。仅接受原生动作条按钮（`IsNativeButton` 前缀白名单）。`bar.OnBindingsChanged` 触发重建。
- **Phase 3 — 绑定与可见性**：spellID→按钮 映射；`IsVisible()` 守卫；载具/宠物对战/御空术 事件；战斗内仅改文本/显隐。
- **Phase 4 — 配置交互**：选"要迁移的增益" + "绑到哪个按钮"；slash 先上，再补 GUI。
- **Phase 5 — 打磨**：去重、性能（0.1s 节流、帧池）、edge case（层数1不显示、无剩余不显示计时）。

---

## 七、已确认的设计决策（2026-07-17）

1. **"图标不显示"**：在动作条按钮上**只显示 CDM 提供的剩余时间/层数文字**，且**不覆盖动作按钮自身原有内容**（图标、键位文字等保留）。CDM 源图标是否显示不在本插件关注范围（保留默认行为，不主动隐藏）。
2. **配置交互**：采用**简易 GUI**（暴雪设置面板 / AceConfig），便于勾选增益、选择绑定按钮。
3. **是否隐藏 CDM 中已迁移增益**：默认**不隐藏**（用户不关心 CDM 源图标），避免额外侵入 CDM 渲染。
4. **范围**：默认仅**玩家自身增益（`player`）**；如需目标/友方可后续扩展（架构已预留 `auraDataUnit` 字段）。

### 实施细节补充
- **Overlay 放置**：两个 FontString 固定在按钮**左上 / 左下角**，字号 16，不进入按钮中心，确保不遮挡原生图标与键位文字。
- **GUI 方案**：用 11.0+ 原生 `Settings.RegisterAddOnCategory` 或 `AceConfig-3.0` + `AceConfigDialog-3.0`。界面提供：
  ① 已检测到的增益列表（来自 CDM 当前 item，显示名称+spellID）勾选启用；
  ② 每个启用增益下拉选择"绑定按钮"（枚举 `ActionButtonUtil.ActionBarButtonNames` 的按钮名，如 `ActionButton3`、`MultiBarBottomLeftButton5`）。

---

## 八、当前进度（2026-07-17）

已实现、可游戏内测试：

- **Phase 0 骨架 + Phase 1 捕获核心**：`ButtonAurasReborn.toc`(120007) + `Core.lua`。
  - **关键修正（2026-07-17 晚，最终确认方向）**：数据源 = CDM【配置集】里**玩家已启用**的增益，**不要求该增益当前在身上/激活**。
    - ✅ 正确做法（读 Ayije_CDM `Core/SpellUtils.lua:636` + `Config/Core.lua:1723` 确认；这正是 Cooldown Manager 的"启用清单"语义，与 vflow 一致）：
      `Enum.CooldownViewerCategory` 的 buff 类分类（`TrackedBuff` / `TrackedBar`）→
      `C_CooldownViewer.GetCooldownViewerCategorySet(cat, true)`（第二参 `true`=含未激活条目）→
      对每个 cooldownID `GetCooldownViewerCooldownInfo` → `ResolveSpellID`(linkedSpellIDs[1]>overrideSpellID>spellID) → `C_Spell.GetSpellInfo`(name+iconID)。全程不读 unit auras。
    - ❌ 错误做法：扫描 `BuffIconCooldownViewer` 活动帧（`itemFramePool:EnumerateActive()` / `GetItemFrames()`）。那只能拿到**当前在身上**的 buff——所以"没 buff 时列表为空"，与用户想要的"cdm 里启用了就能看到"不符。活动帧扫描仅保留为"标记当前激活（绿色指示条）"的补充。
    - 2026-07-17 19:15 补充：用户进一步要求"只显示已启用的，未启用的不显示"。`GetCooldownViewerCategorySet(cat, true)` 会把分类下**所有**条目（含未启用）一并返回，需自行按"启用"过滤：
      - 分类收窄为只取 `TrackedBuff`（Cooldown Manager 的"增益"页 = 用户启用 buff 的地方）；`TrackedBar`（资源条/专注条，非 buff）排除。
      - 加 `IsEnabled(info)` 过滤：若 `info.enabled` / `info.isEnabled` 存在则按其过滤，否则不过滤（保守）。
      - `/bar debug` 增强：打印各分类 `includeEmpty=true/false` 条目数对比 + 前几条 info 的全部字段，用于定位"启用"标志（若 API 未暴露该标志，靠 debug 输出确定下一步）。
  - 绑定关系持久化到 `ButtonAurasRebornDB.bindings`（spellID→按钮名，未绑定则不覆盖）；提供 `/bar`、`/bar debug`、`/bar rescan`。
- **Phase 4 之「① 增益列表 + 绑定」**：`Options.lua` 用暴雪设置面板（画布分类）列出 CDM 捕获到的玩家增益（放大图标+名称），每行右侧二级下拉框把该增益绑定到某个原生动作条按钮。无独立"选中"状态——绑定按钮即为纳入覆盖的条件。含"刷新列表"按钮与已绑定计数。

文件清单：`ButtonAurasReborn.toc`、`Core.lua`、`Options.lua`。

测试方式：
- `/bar` 打开配置面板；`/bar debug` 在聊天框打印已捕获的增益；`/bar rescan` 强制重新扫描。
- 若列表为空，请先获得一个增益（食物 / 药剂 / 职业 buff），它会自动出现在列表中。

**未读取 unit auras**：所有数据来自 `C_CooldownViewer.GetCooldownViewerCooldownInfo` 与帧上的 `auraDataUnit/auraInstanceID`，符合需求 3。

下一步（待确认）：Phase 4 之「② 绑定按钮」下拉 + Phase 2 覆盖层渲染（左上剩余时间/绿、左下层数/紫、字号16、不画图标）。
