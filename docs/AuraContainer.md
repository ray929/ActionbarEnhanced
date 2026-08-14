# AuraContainer 参考（WoW 12.1.0）

> 本文档记录 12.1.0 正式服（build 69299）引入的 **AuraContainer / AuraButton** 框架，
> 供本项目（ActionbarEnhanced）以后查阅。内容核实自：
> - `Gethe/wow-ui-source` `live` 分支（= 12.1.0，`Blizzard_AuraContainer/` 与 `Blizzard_APIDocumentationGenerated/`）
> - warcraft.wiki.gg 《Patch 12.1.0/API changes》
>
> 核实日期：2026-08-15。⚠️ 12.x 变化快，实际开发前若版本已更新，请以 `wow-ui-source` 最新分支为准。

---

## 一、帧类型与模板

| 项 | 说明 |
|---|---|
| 新帧类型 `AuraContainer` | `CreateFrame("AuraContainer", nil, parent, "CustomAuraContainerTemplate")` — **注意不是 `"Frame"`**（写 `"Frame"` 会触发 `dirtyFlags` nil 报错） |
| 新帧类型 `AuraButton` | 由容器内部创建，addon 一般不直接 `CreateFrame` |
| 模板 | `CustomAuraContainerTemplate` / `ManagedAuraContainerTemplate` / `CustomAuraButtonTemplate` / `SecureGroupHeaderTemplate` |
| 已移除 | `SecureAuraHeaderTemplate`（Mainline 已删，需迁移到 AuraContainer）；旧 API `AddAuraFrame`（PTR4 起移除，改用 `AddAuraGroup`/`AddAuraSlot`） |

## 二、三个「槽位」抽象

| 抽象 | 入口 | 行为 |
|---|---|---|
| **AuraGroup** | `AddAuraGroup(groupKey, filterString, options)` | 动态自管理集合；容器自动创建/回收 AuraButton、自动锚定、自动撑大容器 |
| **AuraSlot** | `AddAuraSlot(slotKey, filterString, options)` | 单光环槽（≈ maxFrameCount=1 的 group）；AuraButton **不参与自动布局**，位置由你在 `initializeFrame` 里 `SetAllPoints` 决定（本项目 Preset.lua 即用此） |
| **ItemEnchantment** | `AddItemEnchantment(itemEnchantmentSlot, options)` | 临时武器附魔（火舌/大地生命/唤潮护卫都能走这里，可替代 `GetWeaponEnchantInfo` 自建方案） |

三者均返回对应的 `AuraButton` frame 引用。

## 三、过滤（两层）

**第一层 `filterString`**：标准过滤串，如 `"HELPFUL"`、`"HELPFUL|RAID"`；支持 `!` 取反（`!PLAYER`）、`DISPELLABLE`。

**第二层 `candidateFilters`**（精确过滤，table）：

```lua
{
    includeSpellIDs = { [spellID] = true },   -- 按光环 ID 精确过滤（本项目 Preset 用的就是这个）
    excludeSpellIDs = { [spellID] = true },
    includeDispelTypes = { [dispelName] = true },
    excludeDispelTypes = { [dispelName] = true },
    isFromPlayerOrPlayerPet = bool,
    isRoleAura      = bool,
    isPriorityAura  = bool,
    isStealable     = bool,
    isBossAura      = bool,
    isBossOrRoleAura = bool,
    canApplyAura    = bool,
    maxDuration     = number,   -- 自动排除永久光环（duration==0）
    nameplateShowAll     = bool,
    nameplateShowPersonal = bool,
    processedAuraType    = ...,
}
```

### ⚠️ 关键限制 `CanApplyIdentityCandidateFilters`

`includeSpellIDs` / `excludeSpellIDs` **不是无条件生效**。满足下面任一才生效：

1. 光环的 `C_Secrets.GetSpellAuraSecrecy(spellID) == Enum.SecrecyLevel.NeverSecret`（never-secret 白名单）；
2. 非 harmful（敌方 debuff 被禁）+ 非「敌方单位的 helpful」。

目的：防止插件对「敌方身上的精确 debuff」做 pinpoint 显示（"Move now!" 文本类 exploit）。

**结论**：追踪**玩家自己（unit="player"）的 buff** 不受限；追踪敌方/目标身上的 debuff 会受限。

## 四、排序

`sortMethod`（`AuraContainerSortMethod`）：`Unsorted / Default / BigDefensive / UnitFrameDebuff / ImportantOnly / Expiration / ExpirationOnly / Name / NameOnly / AuraInstanceIDOnly`，配合 `sortDirection`。

## 五、布局

`layout`（AuraGroup 选项）：`elementSpacing / lineSpacing / groupSpacing / groupLineSpacing / forceNewLine / elementWidth / elementHeight / layoutIndex`；ItemEnchantment 另有 `placement`。

## 六、AuraButton 子控件（`initializeFrame` 里注册，暴雪驱动内容）

```lua
button:SetIcon(texture)
button:SetDurationCooldown(cooldown)         -- 倒计时 Cooldown 控件（暴雪 SetCooldownFromDurationObject 驱动）
button:SetDurationText(fontString, options)  -- mm:ss 文本（可指定 format / 颜色曲线）
button:SetDurationBar(statusBar, options)    -- 时长条
button:SetApplicationCount(fontString)       -- 层数（>1 才显示，暴雪 SetText 驱动）
button:SetApplicationBar(statusBar, options) -- 层数条
button:SetSpellName(fontString)              -- 法术名
button:AddDispelTypeTexture(texture, options) / button:SetDispelTypeText(fontString, options)  -- 驱散边框/文字
button:SetAuraBorder(texture, options)       -- 旧别名（等价 AddDispelTypeTexture）
button:SetAuraSymbol(fontString, options)    -- 旧别名（等价 SetDispelTypeText）
button:AddPandemicRegion(region)             -- 大流行（刷新窗口）高亮
button:SetCancelAuraButtons(clickTokens)     -- 右键取消光环
button:SetTooltipAnchorPoint(point, ox, oy)
button:SetHideTooltipInCombat(bool)
```

## 七、安全约束（Forbidden Aspects）

- **AuraButton**：`UntrustedScriptExecution / UntrustedLayoutScriptExecution / AlwaysPropagateInput / ScriptedInput / QueryFocus` → addon 不能挂脚本、不能注册事件、不能 query focus。
- **AuraContainer**：`EventRegistrations` → addon 不能给容器注册事件（容器内部自行监听）。
- **子控件注册后**：`InitializeInboundScriptObject` 加 `RemoveSecretAspects` + `ChangeParent` forbidden → **注册后不能改 parent / reparent**。
- 子控件必须 parent 到 AuraButton 下（`ValidateInboundScriptObject` 强制 descendant）。
- 上述限制在 `initializeFrame` 回调**之后**才生效 → 回调里可自由 `SetPoint`/`SetSize`/`SetFont`。
- 含 AuraGroup 的容器：追加 `UntrustedLayoutScriptExecution`（无 OnSizeChanged，锚定它的帧也受影响）。AuraSlot 不受此限制。
- 容器 `SetEnabled(false)` → 清空内部所有 AuraButton 和 ItemEnchantment。

## 八、单位与事件

- `container:SetUnit("player" / "target" / ...)` 绑定追踪单位。
  - `player` 最稳（战斗照常）；`target`/队友受「单位可见性」限制。
- 容器内部自动监听：`UNIT_AURA / WEAPON_ENCHANT_CHANGED / WEAPON_SLOT_CHANGED / AURA_DATA_PROVIDER_SWITCH`。
- **必须 `container:Show()` + `container:SetEnabled(true)`** 才会注册这些事件（`ShouldRegisterForDynamicEvents = IsVisible and IsEnabled`）。
- 战斗中可创建容器（12.1 PTR7 起允许）。

## 九、边界提醒（给新思路的判据）

1. **只能「摆位置 + 定样式」，拿不到数值**：倒计时秒数、层数数值在战斗中仍是 secret，addon 无法读出做自定义逻辑（如「剩 5 秒变色」）。
2. **身份过滤有敌我限制**（见第三节），不能按 spellID 精确追踪敌方/目标身上的 debuff。
3. **ItemEnchantment 通道**：武器附魔可走暴雪渲染（`AddItemEnchantment`），替代 `GetWeaponEnchantInfo` 自建 OnUpdate。
4. **永久光环**：`maxDuration` 过滤可排除永久光环；倒计时对永久光环（无 expirationTime）会 `SetTimeSpan(0,0)`。

## 十、与本项目（Preset.lua）的关系

- 类型 A（光环：天怒/大地之盾）→ 每预设一个 `AuraContainer` + `AddAuraSlot` + `includeSpellIDs`。
- 类型 B（武器附魔：火舌/大地生命/唤潮护卫）→ 目前走 `GetWeaponEnchantInfo` 自建（未迁移到 `AddItemEnchantment`）。
- 容器定位到动作条按钮上方：屏幕坐标 `SetPoint`（零锚依赖，与 AutoCDM 同哲学）。

## 附：源码参考文件（wow-ui-source live 分支）

```
Interface/AddOns/Blizzard_AuraContainer/
    Blizzard_AuraContainer.lua          -- AuraContainerSharedMixin / PrivateMixin（SetUnit/SetEnabled/事件）
    Blizzard_ManagedAuraContainer.lua   -- 脏标记/刷新/UNIT_AURA 处理
    Blizzard_CustomAuraContainer.lua    -- AddAuraGroup/AddAuraSlot/AddItemEnchantment + 校验
    Blizzard_CustomAuraButton.lua       -- SetIcon/SetDuration*/SetApplication* 等子控件注册
    Blizzard_AuraButton.lua             -- AuraButtonSharedMixin/PrivateMixin（UpdateAuraDuration）
    Blizzard_AuraContainerUtil.lua      -- DoesAuraPassCandidateFilters / CanApplyIdentityCandidateFilters
    Blizzard_CustomAuraContainer.xml    -- CustomAuraContainerTemplate
    Blizzard_CustomAuraButton.xml       -- CustomAuraButtonTemplate
Interface/AddOns/Blizzard_APIDocumentationGenerated/
    UnitAuraDocumentation.lua           -- C_UnitAuras 全部函数签名 + secret 标记
    UnitAuraSharedDocumentation.lua     -- RequiresValidUnitAuraInstance 等 Precondition
    PaperDollInfoDocumentation.lua      -- GetTemporaryEnchantmentInfo / TemporaryItemEnchantInfo
```
