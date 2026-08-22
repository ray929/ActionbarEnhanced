# AGENTS.md — 本项目所有 AI Agent 必读

> **给所有 agent 的强制要求（用户指定）：**
> 1. 动手改代码前，先完整读完本文件。
> 2. 每轮修改完成后**必须本地提交**（语义化单行 `type(scope): description`，不自动 push）——此为用户明确授权的常设指令。
> 3. 功能变更后同步更新 `README.md`（面向普通插件使用者，中英双语同一文件，**不含**安装/构建/环境变量章节）。
> 4. 踩到新坑、发现新注意点、确立新约定时，**必须把结论写回本文件**对应章节——本文件是项目工程经验的唯一沉淀处，不写下来等于白踩。
> 5. **学到新知识（API 用法、框架机制、源码调研结论等）归纳到 `docs/` 目录**，一个主题一个 `<Topic>.md`；坑/红线/约定写本文件，知识点写 `docs/`，两者分工不混（见 §9）。
> 6. `README.md` 面向普通插件使用者，**不出现 agent / AGENTS.md 相关内容**。
> 7. WoW API 事实核查以 https://warcraft.wiki.gg/ 为准；不使用任何 WoW 相关 MCP。

## 1. 项目定位

围绕【暴雪原生动作条】做增强，**不做第三方动作条（Bartender/Dominos）适配，不替换/不重排动作条**。一切功能以 12.x combat-safe 为前提：插件不读受保护数据，只搬运/配置暴雪已渲染的对象。

## 2. 模块地图（加载顺序见 .toc）

| 文件 | 职责 |
|---|---|
| Settings.lua | 全局样式常量（颜色/字号/字体/描边），必须最先加载；外观不存盘 |
| Manual.lua | 手动绑定：spellID→目标技能，倒计时/层数/发光/反发光渲染（全栈单文件） |
| AutoCDM.lua | 自动发现：CDM 启用的增益自动铺到匹配按钮（BuffIconCooldownViewer） |
| PresetData.lua | 预设法术/光环配置（用户编辑区，SELF_BUFFS/PRESETS 表），必须先于 Preset.lua 加载；改预设只动此文件 |
| Preset.lua | 预设光环/武器附魔渲染（CDM 不渲染的），走官方 AuraContainer 通道；配置从 BAR.PresetData 读取，文件本身不含法术表 |
| BleedReminder.lua | 流血高亮提醒（矮人石像形态按钮红光）：AuraContainer `includeDispelTypes={Bleed}` + ProcGlow 挂 AuraButton 靠暴雪显隐传播驱动，零光环读取 |
| CooldownGlow.lua | CDM「主冷却」技能就绪 ProcGlow（绿，可配常亮/1–5s） |
| TrinketGlow.lua | 饰品就绪 ProcGlow（黄） |
| ButtonColor.lua | 按钮三态变色：灰=CD、蓝=资源不足、红=超范围 |
| ButtonText.lua | 按键/层数/宏文字字号与描边 |
| HideActionBarBorders.lua | 隐藏原生边框、图标放大、1px 黑描边 |
| RemoveExtraActionButtonTexture.lua | 清理额外技能按钮装饰（0.5s ticker 重施） |
| DisableAutoAddSpells.lua | 阻止新技能自动入条（劫持 IconIntroTracker.OnEvent） |
| ButtonClickThrough.lua | 每条动作条鼠标穿透（SecureHandlerStateTemplate 安全环境） |
| Options.lua | AceConfig 独立配置窗口（Addon Compartment 入口） |
| MinimapButton.lua | 小地图按钮（LibDBIcon） |

## 3. 12.1 Secret Values 红线（最重要，违者必出"进战斗消失"）

- **绝不读单位光环数据**：`GetAuraDataByIndex` / `AuraUtil.ForEachAura` 全量扫描、`UNIT_AURA` payload 第 2/3 参数、`frame.auraDataCached`、`frame.auraSpellID`、`GetAuraDuration` —— 一律禁止。
- 两条合法通道：
  - **A. reparent**：CDM viewer 里暴雪已渲染好的 `Cooldown` 控件 / `Applications` FontString 直接 `SetParent` 搬到自己的容器，数据由暴雪继续驱动（Manual/AutoCDM 用）。
  - **B. AuraContainer**：自建容器 + `includeSpellIDs` 声明追踪哪些光环，暴雪特权渲染（Preset 用；大地之盾等战斗中必 secret 的光环只能走这条）。
    - **容器显隐管理坑（Preset，2026-08-19 修）**：容器一经创建**绝不 Hide→Show 切换显隐**——`Hide` 注销 UNIT_AURA 注册（`ShouldRegisterForDynamicEvents = IsVisible and IsEnabled`），重新 `Show` 触发 `OnShow_Intrinsic→UpdateAllAuras→FullAuraRebuild`，该全量重建在战斗中(secret)解析光环失败，光环帧被清空后要等下一次 UNIT_AURA（通常=脱战）才恢复 → 症状为「切换动作条切走再切回，倒计时消失直到脱战」。正解：按钮找不到/定位失败时把容器**停靠屏幕外**（SetPoint 到 -10000，IsVisible 保持 true），事件注册与倒计时持续在线，切回重定位瞬时恢复。⚠️ 连带点：停靠时必须清矩形缓存，否则恢复时按钮矩形未变会被"位置未变跳过 SetPoint"逻辑卡在屏幕外。
    - **AuraButton 子帧几何操作战斗中被 Forbidden 拦截（Preset，2026-08-19 修）**：cd（Cooldown）等 addon 创建的子帧虽 parent 到 AuraButton，但战斗中(secret)对它们 `SetPoint`/`ClearAllPoints` 可能被 Forbidden Aspect 拦截抛错（脱战同代码正常）——症状为「停靠时容器挪走了、cd 因绝对锚定 UIParent 滞留原位 → 倒计时数字不消失」。正解三件套：① **子帧一律相对锚定 AuraButton，绝不绝对锚定 UIParent**——btn→cd/fs 锚定链自动跟随容器，停靠**只挪容器一个帧**（addon 自己的帧，SetPoint 战斗安全），战斗中零操作 Forbidden 对象；② initializeFrame 里对 AuraButton 必须 **`SetSize` + `SetAllPoints(container)` 双保险**（CustomAuraContainerFlowLayoutMixin 源码核实）：暴雪 flow layout 的 ApplyElementLayout 会对 slot 帧 `ClearAllPoints` 后以**单锚点**重锚、`GetElementSize` 读 `element:GetSize()`——框架不管 slot 帧尺寸，SetAllPoints 的锚定派生尺寸在 ClearAllPoints 后丢失，**没有显式 SetSize 就塌缩 0×0 → 整个预设不可见**（pcall 吞掉 Forbidden 错误时尤其隐蔽，旧版能显示纯因 cd 绝对锚定 UIParent 不依赖 btn 几何）；③ 倒计时数字样式 SetFont/SetTextColor pcall 失败时**不标记完成**，脱战后重试上色（否则数字永远白色）。initializeFrame 之外对 AuraButton 的 SetSize 属尽力而为（pcall，失败保持 36×36 不影响可见性）。
  - **B+ 层数条/阈值变色**（2026-08-18 审计 buffbar 插件沉淀，全程零读光环数据）：
    - 核心三板斧：`CreateFrame("AuraContainer", nil, owner, "CustomAuraContainerTemplate")` + 每 slot `AddAuraSlot(key, filter, { candidateFilters = { includeSpellIDs = {...} }, initializeFrame = ... })` + 容器 `SetUnit(token)`；减益只认自己上的用 filter `"HARMFUL|PLAYER"`。
    - **层数驱动**：`button:SetApplicationBar(statusBar, { maxApplications = N })` 把任意 StatusBar 交给暴雪特权代码 SetValue（层数/充能进度自动填充）；层数数字用 `button:SetApplicationCount(fontString, { formatter = C_StringUtil.CreateNumericRuleFormatter() 的 0 层显示空/≥1 显示 %d 规则 })`。secret 环境暴雪写不受限，插件 Lua 全程不碰数据。
    - **阈值变色**：同一 spellID 注册**多个独立 slot 克隆**，各自套几何陷阱叠出"到阈值换色"——底色槽 maxApplications=maxStacks；阈值槽 maxApplications=阈值（分母变小控制填充比例）+ MaskTexture 只露接缝左/右侧（接缝 = 条宽 × 阈值/maxStacks）；层数未达阈值时暴雪自动隐藏该克隆，达到时显示。环形样式则每格一个 slot（activationAt = max(阈值, 格序号)），⚠️ 25 层+3 阈值 ≈ 101 slot/条，帧开销大，慎用于高频场景。
    - **战斗门禁**：官方元 API `C_Secrets.ShouldAurasBeSecret()`（返回布尔，本身不泄密）+ `InCombatLockdown()` 双查，战斗中绝不创建/重建容器，只记 `pendingRebuild` 待 `PLAYER_REGEN_ENABLED` 重建；登录期在 `ADDON_LOADED` 后先建（光环未 secret）。
    - 代价：战斗中不能改任何配置（阈值/位置/增删均需脱战重建）；登录后进战斗前没建成的条整场缺席。目标单位（target）模块战斗中切目标 `SetUnit`+`UpdateAllAuras` 需 pcall，secret 期失败则停在旧目标，脱战恢复。
    - 若日后做"层数进度条/阈值变色"类功能，此路 combat-safe，优先考虑。
- secret 值 **不能靠 `type()` 预判**（12.1 起 secret 的 type() 可返回 number/boolean/string 等），统一用 `issecretvalue` 判定；对外部帧/数据的访问一律 `pcall` 包裹兜底。
- 新 `AuraButton` 的 `IsShown` 可能返回 secret；CDM item frame 是**普通 Frame**，`IsShown` 安全（判定光环激活就用它）。
- 冷却数据：`GetInventoryItemCooldown` 返回传统三值 number（安全，TrinketGlow 用）；`C_ActionBar.GetActionCooldown` 的 CooldownInfo 是 **secret**（勿用）。
- 冷却缓存坑（ButtonColor，2026-08-18 修）：`_cdCache` 以按钮为 key，翻页/姿态/载具/占据切换后同一按钮换了技能 → 缓存持有旧技能冷却态（页面事件只应用不重算，isOnGCD 又不可跨时机重读）→ 残留错误灰显（进载具不施法可一直挂灰到下次施法）。修正：钩 cooldown 帧 **OnHide**（引擎隐藏 = 无漩涡 = 必然非真实 CD，缓存安全置 false）+ **OnShow**（脱战时经 `C_ActionBar.GetActionCooldownDuration(action, true)` + `DurationObject:GetRemainingDuration()` 精算写缓存——ignoreGCD 在 C 层剔除 GCD，绕开 isOnGCD 时序问题；精算前必查 `HasSecretValues()`，战斗中 secret 只补刷新不写缓存，待下次施法自愈）。GreyOnCooldown 2.0.2 同款 hook 点。
- 按 spellID 定点的 `GetPlayerAuraBySpellID` 等在 12.1 仍存在但标注 `RequiresNonSecretAura`，战斗中仅白名单光环可用——不要依赖。

## 4. Taint / 安全帧坑

- 覆盖层容器**只挂 UIParent**，绝不 `SetPoint` 到安全动作按钮（非安全帧依赖安全帧 → taint 传播 → combat lockdown 整片隐藏）。定位用 `btn:GetRect()` 读屏幕坐标（只读不污染）+ 缩放换算 `r = 按钮有效缩放 / UIParent有效缩放`（不换算会偏移）。
- **不跑自己的 OnUpdate 去刷挂在安全按钮上的子帧**（同上 taint 复检问题）。刷新一律 hook CDM item 的 `RefreshData`（暴雪驱动、战斗中照常触发）。
- 对受保护帧调 `EnableMouse(false)` 等必须在 **SecureHandlerStateTemplate + RegisterStateDriver 安全环境**（ButtonClickThrough 的教训：普通 Lua 调用会永久 taint，连编辑模式都会报错）。
- 非安全代码绝不能遍历受保护表（错误："attempted to iterate a table that cannot be accessed while tainted"）。
- **动作条按钮禁用 `SetClipsChildren`（HideActionBarBorders，2026-08-21 修）**：法术弹出菜单（猎人召唤宠物/法师传送等 SpellFlyout）打开时会被 `FlyoutPopupMixin:AttachToButton` **SetParent 到源按钮上**（12.1.0 build 69404 源码核实），整钮裁切会把菜单一起裁剪到按钮矩形内 → 菜单被截断隐藏。图标"放大去边框"一律用 **`icon:SetTexCoord` 裁素材中央区域**（与放大+裁帧数学等价；已核实 ActionButton/PetActionBar/StanceBar 均不重置 icon 的 TexCoord）。详见 `docs/SpellFlyout.md`。
- **ADDON_ACTION_BLOCKED 归属判定（2026-08-21 排查 EllesmereUIRaidFrames 案例）**：`addonName` = 直接执行被拦截调用的插件；判定本插件是否有责看两点——① 堆栈里是否出现本插件帧/函数（该案例全程 EllesmereUIRaidFrames+暴雪 SecureGroupHeaders，零本插件代码）；② 是否存在共享对象 taint 传播路径（本插件不监听 GROUP_ROSTER/UNIT_NAME 事件、不碰 secure header/raid frame，无传播面）。战斗中 GROUP_ROSTER_UPDATE/UNIT_NAME_UPDATE → SecureGroupHeader 重排 → 插件 OnAttributeChanged 回调改受保护子帧（SetHeight 等）被拦，是 raid frame 类插件在 12.x RestrictedAddOnEnvironment 下的典型架构问题（VuhDo/Grid2 同款），非本插件传染。

## 5. CDM 扫描坑

- 枚举 viewer 帧用 `itemFramePool:EnumerateActive`（= active 帧）；**别用 `GetItemFrames`**（拖动 CDM 触发 RefreshLayout→ReleaseAll 时瞬间变空/不全，且含池化隐藏帧 → 列表乱跳/清空）。
- `Rescan` 用"新表扫描、扫到 0 帧保留旧表"策略，避免过渡态直接清空已知列表。
- spellID 要**收全部候选**（`spellID/override/overrideTooltip/linkedSpellIDs`）：12.1 天赋改名场景（光环"烈焰震击" vs 按钮"流电炽焰"）只记一个 ID 会匹配失败。候选写在自己造的非 secret 字段 `frame.__BARSpellID/__BARSpellIDs` 上，绝不读 secret 的 `frame.auraSpellID`。
- 与 CDMButtonAuras 同框共存时 hook 标记键要区分（本项目用 `__BARHooked`/`__BARAutoCDMHooked`），否则被对方抢先标记 → 永不 hook。
- 登录时序：PLAYER_LOGIN 后 0.5s / 2s 双重延迟 Rescan 兜底（viewer 冷启动慢）。
- 动作条切换（翻页/姿态/载具/御龙术）不一定触发 `ACTIONBAR_SLOT_CHANGED`，要同时监听 bonus/override/shapeshift/possess/multicast 等事件统一重建。
- **按钮缓存必须每 tick 自愈验证（Preset，2026-08-19 修「脱战后切页数字滞留」；2026-08-21 在 89ea1a8 回退基线上重做并扩展到 weaponEnchant）**：`p.button` 缓存依赖页面事件失效，但 UNIT_AURA 驱动的 RefreshAll **不清缓存**——若翻页过渡期 Find 扫到旧数据或事件漏网，缓存残留旧按钮，之后每次刷新都把容器拉回旧按钮位置 → 倒计时常驻不消失。正解：两类预设统一走 `ResolveButton(p, actionSpellID)`——`pcall(GetActionInfo, p.button.action)` + `GetSpellName` 名字比对（与 Find 匹配逻辑对称）验证缓存，失效即作废重找；stance 按钮（action=nil）跳过验证（内容不随翻页变，验证反而每 tick 触发全量重扫）。开销：预设数 × 2 次 API 调用/秒，可忽略。
- **IsPlayerSpell 失效分支必须清理残留显示（Preset，2026-08-21 修「切专精后剩余时间滞留，需 reload 消除」）**：切专精后新专精没学 `actionSpellID` 时，UpdatePresetAura/UpdatePresetWeaponEnchant 的 `if not IsPlayerSpell(...)` 分支**绝不能裸 return**——容器/覆盖层滞留旧按钮位置：类型 A 光环未消散则倒计时常驻；类型 B 更隐蔽（武器附魔在武器上**跨专精持续存在**，EnchantTick 停止刷新后 Cooldown 冻结在旧按钮上长达数十分钟）。正解：该分支调用 `DeactivatePreset(p)` 隐藏容器/覆盖层 + 清 `p.button`/rect 缓存；同时事件集合加 `ACTIVE_TALENT_GROUP_CHANGED`（切专精：动作条整体换技能 + IsPlayerSpell 集合变化）触发 invalidateButtons+延迟 RefreshAll 及时清理，1s ticker 兜底自愈。切专精必然脱战，容器 Hide/再 Show 不触发战斗中 FullAuraRebuild 风险，可放心用 Hide（无需停靠屏幕外方案）。

## 6. LibCustomGlow 坑

- `ProcGlow_Start` 会**叠层**：每次 Start 新建发光帧，不先 Stop 会越叠越厚。所有 glow 封装必须幂等守卫（如 `btn.__ManualGlow`），Stop 后才允许再 Start。
- glow key 各模块必须独立（Manual=`MANUALGLOW`、CooldownGlow=`BAR`、TrinketGlow=`TG`、BleedReminder=`BLEED`），互不误杀。
- 按钮移动/翻页/开关切换后发光会**残留**：维护"当前发光集合"，每次重算对账熄灭不再应发光的按钮（TrinketGlow 的解法），不要只在新位置点亮。
- **发光状态会"冻结"在亮，需光环事件对账（Manual，2026-08-22 修「活力苏醒消失后神龙之赐发光滞留到 reload」）**：覆盖层/发光状态若只由「CDM item 的 RefreshData hook + 动作条/进出战斗事件」两条链路驱动，光环消失时 CDM 可能把 item 释放回池/复用（该 spellID 不再有 RefreshData），发光就冻结在「亮」。隐蔽点：Options 的 0.5s 签名 ticker 曾是无意识兜底，但 2026-08-16 性能优化加「窗口未开直接 return」后正常游戏时（配置窗口全程关闭）兜底等于被砍断 → 滞留直到 reload / 下一个动作条事件，症状即「触发原因不明、reload 后修复」。正解（AutoCDM ScheduleRefresh 同款模式，战斗安全）：① `UNIT_AURA`(player) 0.2s 防抖对账即时修正；② 0.5s 兜底 ticker 仅当存在覆盖层时运行（§10 ticker 与消费者挂钩）。⚠️ 连带：对账引入后 `MoveItemOffscreen` 高频重入，必须加幂等守卫（`GetParent() == offscreenFrame` 判断，非标记位——CDM 重新 parent 回查看器后仍能重新移走），否则反复 ClearAllPoints+SetPoint 触发布局重算。
- **TrinketGlow 空槽误判 + 宏编辑不重建映射（2026-08-22 修「还魂术恒亮黄光」）**：① `/use 13|14` 宏留在动作条、饰品却被卸下时，空槽的 `GetInventoryItemCooldown` 返回 (0,0,1) 被误判「就绪」→ 按钮恒亮黄光；正解：`GetInventoryItemID("player", slot) ~= nil` 前置守卫（没饰品就无「可用」可言）。② 宏编辑（增删 /use 13|14 行）**不触发** `ACTIONBAR_SLOT_CHANGED`（槽位内容未变，还是同一个宏），必须监听 `UPDATE_MACROS` 重建「按钮→饰品槽」映射，否则删掉 /use 行后旧按钮发光要等到下一次动作条/装备事件才熄灭。排查提示：黄=TrinketGlow、绿=CooldownGlow、青/红=Manual、红=BleedReminder；纯法术按钮不会进 TrinketGlow 映射（只有饰品 item 或含 /use 13|14 的宏会），用户报某技能黄光时先确认该按钮是否实为 `/use 13` 宏——饰品就绪时这类宏亮黄光是**设计行为**。

## 7. 存档结构（SavedVariablesPerCharacter: ActionbarEnhancedDB）

- `specs[specID].bindings[spellID] = { bindSpell, glow, inverseGlow, timePos, stackPos }`——绑定按专精独立；specID 取 `GetSpecializationInfo`，拿不到用 0（通用槽）。2026-08-17 起发光/反发光从 timePos 拆出为独立布尔字段（glow=有光环亮青、inverseGlow=无光环亮红，允许同时勾、状态切换换色），timePos/stackPos 增加 `"无"`=不显示该数字；四项（发光/反发光/时间/层数）互相独立。SelectSpec 内做旧档迁移：timePos="发光"/"反发光"→拆字段，showTime/showStack=false→位置"无"（字段已废弃清理）。
- 模块开关各存各的：`clickThrough[1..8]`、`trinketGlow.enabled`、`disableAutoAdd.enabled`、`removeExtraActionTexture.enabled`、`bleedReminder.enabled` 等。
- 外观（颜色/字号）是 Settings.lua 硬编码常量，**不存盘**；旧存档的顶层 timeColor/stackColor/fontSize 字段在 InitSpecStorage 时清理。
- 兼容：旧扁平 `bindings`（顶层）迁移到 `specs[0]`；字符串型绑定转 table。

## 8. 工程规范（Windows 环境专项）

- **分支策略：仅用 main，不建 dev**（用户指定 2026-08-16）。每轮修改直接提交到 main；无远程仓库，不 push。
- **仓库换行是 LF**！Windows 编辑器（含部分 AI 写入路径）会把整库转成 CRLF → 61 个文件全量 diff churn（已实际踩坑）。提交前对改动的文本文件执行 `sed -i 's/\r$//' <files>` 规范回 LF。
- 命令经 MSYS2 bash：`D:/msys64/usr/bin/bash.exe -lc "..."`，路径用正斜杠；`git log/diff` 加 `--no-pager`。
- 临时文件放 `.temp/`（gitignore）；不引入新外部依赖库除非用户同意。
- 验证：改完进游戏 `/reload` 实测；涉及刷新/显隐的功能**必须测战斗内**（secret 行为只在受限环境出现，非战斗环境测不出问题）。

### 发布打包（GitHub → CurseForge 自动打包）

- 根目录 `pkgmeta.yaml` 是 CurseForge 打包配置：`package-as: ActionbarEnhanced`；ignore 了 `docs/`、`AGENTS.md`、`Libs/LibStub/tests`。Resources/ 只保留被引用的 `uiactionbar2x.tga`（4 个未引用字体约 42MB 已于 2026-08-16 删除）。⚠️ 若日后新增资源文件（自定义字体等），记得确认被代码引用且无需加 ignore。
- `.toc` 的 `## Version: @project-version@` 是打包替换令牌：CurseForge 打包时替换为 tag 名（本地开发时游戏内显示字面量 `@project-version@` 属正常现象）。**发版流程：改完 → 提交 → 打 tag（如 `v1.0.0`）→ push（含 tag）**。tag 含 `alpha` → Alpha 文件；含 `beta` → Beta；其他 → Release；未打 tag 的 commit 打包为 Alpha。
- Libs/ 库直接提交（本仓库即游戏目录，externals 只在 CF 服务端生效无法满足本地运行），故 `enable-nolib-creation: no`、不声明 externals。
- GitHub webhook 需用户手动配置一次：CF 账户生成 API token → 仓库 Settings → Webhooks → URL 填 `https://www.curseforge.com/api/projects/{projectID}/package?token={token}`。

## 9. 知识库（docs/ 目录）

**分工约定**：坑 / 红线 / 项目约定 → 写本文件（AGENTS.md）；学到的**新知识**（API 用法、框架机制、暴雪源码调研结论、版本变更核实）→ 归纳成 `docs/<Topic>.md`。新文档须在下面登记。

| 文档 | 主题 |
|---|---|
| `docs/AuraContainer.md` | 12.1.0 AuraContainer / AuraButton 框架全解：三种槽位（AuraGroup/AuraSlot/ItemEnchantment）、两层过滤（filterString + candidateFilters 含 includeSpellIDs）、AuraButton 子控件注册 API、Forbidden Aspects 安全约束、事件模型。核实自 wow-ui-source live 分支，核实日期 2026-08-15 |
| `docs/SpellFlyout.md` | 12.1.0 法术弹出菜单（SpellFlyout）机制：AttachToButton 会 SetParent 到源按钮（SetClipsChildren 截断菜单的根因）、菜单项按钮结构、关闭时机、皮肤化约束。核实自 wow-ui-source live 分支 12.1.0 (69404)，核实日期 2026-08-21 |

写 docs/ 文档的要求：注明信息来源（wow-ui-source 分支 / wiki.gg 页面）与核实日期；12.x 变化快，使用前若版本已更新需重新核实。

## 10. 性能优化红线（2026-08-16 大秘境 2~3% CPU 优化实战沉淀）

**高频事件清单（战斗中）**：`UNIT_POWER_UPDATE`（能量/连击点 tick，可达 10+/s）、`UNIT_AURA`（buff/proc 连发）、`ACTIONBAR_UPDATE_COOLDOWN` / `SPELL_UPDATE_COOLDOWN`（每个 GCD/施放/充能）、各 cooldown 事件的 RefreshData hook。**任何挂在这些事件上的处理都必须问：能不能缓存？能不能防抖？能不能只处理变化的部分？**

- **常驻 ticker 必须与"消费者是否在场"挂钩**：Options 的 0.5s 签名 ticker 曾在配置窗口关闭（战斗中必然关闭）时仍全量算签名——纯浪费。凡"为 GUI 刷新"的 ticker，先查窗口是否打开，未开直接 return。
- **按钮 spellID 必须缓存**（ButtonColor / CooldownGlow）：`GetActionInfo` pcall + 宏解析（`C_Macro.GetMacroSpell` + 兜底 `GetSpellName`）× 96 按钮 × 每次事件 = 最大热点。缓存 weak-key 表 + `false` 哨兵（nil 也缓存，避免空槽重复解析），在槽位/翻页/姿态/载具/天赋事件（`SID_INVALIDATE_EVENTS` 集合）整体 `wipe`。
- **全量刷新要限频**：ButtonColor 的 dispatch OnUpdate 从"每帧至多一次"改为"最小间隔 0.1s"（累加 elapsed），事件连发时刷新次数从事件频率降到 10/s；单按钮 hook 仍即时，视觉零差异。
- **全条扫描必须换成映射**（AutoCDM）：`FindActionButtonForSpellName` 每个候选名扫 96 按钮（GetActionInfo+GetBaseSpell+GetSpellName），× CDM item 数 × 候选数 × UNIT_AURA 重扫。改「名字→按钮」映射（O(96) 建一次，动作条事件失效），查找 O(1)。
- **重复计算要内联复用**：AutoCDM 的 `CollectCandidateSpellIDs`（pcall 链）曾被 UpdateFromItem / IsItemManuallyBound / detach 循环各收一遍（2~3 次/item）——收集一次传参复用。
- **SetPoint 前先比对矩形**：Manual/AutoCDM 的 PositionOverlay 每次刷新都 ClearAllPoints+SetPoint+SetSize（触发布局重算）；缓存 `_rectL/_rectB/_rectW/_rectH/_rectR`（⚠️ 必须含缩放比 r，改 UI 缩放不改矩形），未变直接 return true。
- **UNIT_AURA 全量重扫要防抖**（AutoCDM 0.2s / Preset 0.2s，cancel+NewTimer 模式）：AuraButton 显隐由暴雪实时驱动，插件侧只补重定位，0.2s 延迟无感。
- **隐藏按钮跳过判定**：全量 RefreshAll 先 `btn:IsShown()` 过滤；条重新显示时按钮 Update/UpdateUsable hook 会即时补色，无视觉差异。
- 量化背景：优化前大秘境战斗占用约 2~3% CPU；上述改完后按钮解析/布局调用在热路径上基本归零，残余为暴雪驱动部分。验证方式：`/console cpuDB off` 关闭或用性能统计插件（如 tdCPU2）战斗内复测。
