# Actionbar Enhanced

> Move buff information shown by Blizzard's built-in Cooldown Manager (CDM) onto your native action bar buttons — for World of Warcraft retail 12.1.

将暴雪自带 CDM（冷却/增益查看器）中显示的【玩家自身增益】信息，覆盖到原生动作条按钮上（正式服 12.1）。

## Features / 功能

- 把暴雪 CDM 中显示的玩家自身增益（剩余时间 / 层数）覆盖到原生动作条按钮上（combat-safe，不扫单位光环，挂 UIParent 容器）。
- 手动绑定：按 spellID 绑定，支持专精级配置（时间 / 层数位置；时间位置可选「发光」——光环激活时按钮 ProcGlow 高亮、不显示时间，层数照常；或「反发光」——无光环时按钮紫色高亮、有光环时熄灭，与「发光」的青色区分）。
- 自动发现（AutoCDM）：移植 CDMButtonAuras，自动把 CDM 启用的增益铺到动作条。
- 冷却高亮提醒（CooldownGlow）：CDM「主冷却」技能就绪后 ProcGlow 高亮，可配常亮 / 限时。
- **预设光环（Preset.lua）**：追踪【CDM 未渲染】的光环与武器附魔——由「基本配置 → 常见职业技能持续时间显示」开关控制（默认开启），在 `Preset.lua` 的 `PRESETS` 表里加一行即可，无需改其他代码。已内置各职业常见减伤/爆发技能的持续时间光环（盾墙/圣盾术/冰封之韧/斗篷/树皮术等，ID 按 12.x wowhead 核实）与武器附魔；光环类写 `auraSpellID`（光环 ID）+ `actionSpellID`（显示到哪个技能按钮），走 12.1 官方 **AuraContainer** 通道（容器按 `includeSpellIDs` 过滤，暴雪特权渲染倒计时/层数，插件零读取 → 战斗内照常显示）；武器附魔类写 `presetType="weaponEnchant"` + `enchantID` + `actionSpellID`（火舌 / 大地生命 / 唤潮护卫等）。种族技能（如矮人石像形态，与职业无关）同样写进 `PRESETS` 不设 class，`IsPlayerSpell` 会自动过滤掉未学该技能的种族。
- 按钮文字调整（ButtonText）：调整原生按键 / 层数 / 宏文本字号与描边。
- 隐藏原生动作条边框（HideActionBarBorders）：图标放大去边框并裁切溢出，启用时按钮加 1 像素黑色描边。
- **动作条按钮变色（ButtonColor）**：CD 中 → 灰色；资源不足 → 蓝色；超出范围 → 红色（三态独立判定，全局开关默认开启）。
- 配置 GUI 通过 Addon Compartment 打开（AceConfig 独立窗口）。战斗中无法打开配置，会自动延迟到脱离战斗后弹出。

## WoW 12.1 Compatibility & Architecture / 12.1 兼容性与架构说明

本插件针对 12.1 的「Addonpocalypse」安全模型（Secret Values / Forbidden Aspects）做了专门设计。**核心理念：插件自己不读单位光环数据，只移动/配置暴雪渲染好的对象**，因此在战斗内零读取、零 taint。

- **CDM 已渲染的光环（AutoCDM / Manual）**：reparent 暴雪 `BuffIconCooldownViewer` 里已画好的 `Cooldown` / `Applications` 控件。
- **CDM 未渲染的光环（Preset.lua）**：用 12.1 官方 **AuraContainer**——插件建容器、按 `includeSpellIDs` 声明「要追踪哪些光环」，暴雪以特权读数据并驱动容器内 AuraButton 的倒计时/层数/显隐，插件同样零读取、战斗内可用。

### Why reparent, not read / 为什么只搬运不读取
- 12.1 起，战斗中 `GetAuraDataByIndex`（按 index 扫描）、`UNIT_AURA` 事件 payload、`AuraData` 结构的 `duration/expirationTime/applications/name` 全部为 **secret 值**——一旦读取或比较即 `taint`，表现为进战斗整片消失。
- 本插件不读任何 unit-aura 数据：通过钩 CDM 的 `OnAcquireItemFrame` + `RefreshData`，把 CDM `BuffIconCooldownViewer` 已经渲染好的 **`Cooldown` 倒计时控件**与 **`Applications` 层数 FontString** 直接 `SetParent` 到动作按钮上。数据由暴雪自己算、自己画，插件只搬位置。

### 12.1 关键 API 变更（与本插件相关）
- **安全模型**：被 secret 化的是「按 index / slot / instanceID 访问」与部分身份类 API（`UnitClass` 等）。按 spellID / name 定点访问的 API（`GetAuraDataBySpellName` / `GetPlayerAuraBySpellID`）在 12.1 仍存在，但标注了 `RequiresNonSecretAura`——战斗中仅对「白名单（非 secret）光环」返回非 secret 数据；非白名单光环（如大地之盾，12.1 已从 never-secret 列表移除）战斗中返回 secret/空，任何插件都无法自读，这类光环必须走 AuraContainer 渲染（见 Preset.lua）。
- **未被触碰的弃用/移除 API**：代码未使用 `getglobal` / `setglobal` / `CanAccessObject` / `UIParentLoadAddOn` / `SecureAuraHeaderTemplate` / `GetInspectSpecialization` / `ForEachAura`，保持干净。武器附魔单独走 `GetWeaponEnchantInfo`（item enchant 通道、非 unit aura，战斗安全，12.1 实测可用；另有 `C_PaperDollInfo.GetTemporaryEnchantmentInfo` 按 enchantID 兜底）。
- **光环 UI 框架重写（AuraContainer / AuraButton）**：12.1 把原生光环控件重写成 `AuraButton`，其子控件一旦配置后不可再重父化。Preset.lua 用 AuraContainer 时**不重父 AuraButton**：容器是插件创建的普通帧（可 `SetPoint` 到按钮上方），AuraButton 在容器内由暴雪布局，倒计时/层数子控件在 `initializeFrame` 回调里注册。而 AutoCDM 的 CDM `BuffIconCooldownViewer` 是独立老框架，item 帧为**普通 Frame（非 AuraButton 底层）**，reparent 不受 forbidden aspect 影响——12.1 正式服实测运行顺畅，已验证。

### 安全护栏 / 红线（勿破）
- `UNIT_AURA` 处理器**只触发刷新**（`RefreshAllOverlays`），绝不读取事件 payload 的第 2/3 个参数（单位 / auraInstanceID）。
- **禁止**调用 `GetAuraDataByIndex` / `AuraUtil.ForEachAura` 做全量扫描或发现。
- 所有 reparent 调用均用 `pcall` 包裹，作为防御性兜底（失败时静默跳过，不崩）。
- non-CDM buff 如需显示：走 **Preset.lua 的 AuraContainer 通道**——容器按 `includeSpellIDs` 过滤光环，暴雪特权渲染倒计时/层数，插件零读取、战斗内可用（大地之盾、天怒等已内置）；**绝不可用 `ForEachAura` / `GetAuraDataByIndex` 全量扫描发现**。

> 一句话：**此版本在 12.1 上是 combat-safe 的**。只要不引入「index 扫描 / 读 AuraData 字段 / 读 UNIT_AURA payload」三类写法，即可长期稳定。

## Installation / 安装

Copy the `ActionbarEnhanced` folder into `World of Warcraft\_retail_\Interface\AddOns\`, then enable it in-game (Esc → AddOns).

## Configuration / 配置

打开设置窗口：点击小地图旁的 **Addon Compartment**（Actionbar Enhanced 条目）。设置面板基于 AceConfig 独立窗口（非暴雪设置系统）。

- **战斗中无法打开配置**：若在战斗中点击，会提示「战斗中无法配置」，并在脱离战斗后自动弹出；若战斗时配置界面已打开则会强制关闭，脱离战斗后自动重开。
- 设置窗口底部有两个按钮：**重载界面**（ReloadUI）与其右侧的 **打开CDM**。
- 斜杠命令 **`/cdm`**：直接打开暴雪自带的冷却管理器（CooldownViewerSettings）。

> 若「手动配置光环」列表为空，先获得一个增益（食物 / 合剂 / 职业 buff）——它会自动出现。

## Environment Variables / 环境变量

None. This is a pure WoW addon; all state lives in `ActionbarEnhancedDB`.

## Release / 构建

No build step. Loads directly via the `.toc` file.
