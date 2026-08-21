# SpellFlyout（法术弹出菜单）机制速查

> 信息来源：Gethe/wow-ui-source live 分支，commit 81d15e4 = **12.1.0 (69404)**，核实日期 2026-08-21。
> 涉及文件：`Blizzard_ActionBar/Shared/SpellFlyout.lua|.xml`、`Blizzard_Flyout/Flyout.lua|.xml`、`Blizzard_ActionBar/Shared/ActionButton.lua`、`Blizzard_ActionBar/Mainline/ActionButtonTemplate.xml`。

## 结构与触发链

- `SpellFlyout`：全局唯一弹出菜单容器（初始挂 UIParent，`frameStrata="DIALOG"`，继承 SecureFrameTemplate + FlyoutPopupTemplate + SpellFlyoutMixin）。
- 菜单项按钮：`SpellFlyoutPopupButton1..N`（CheckButton，模板 `SpellFlyoutPopupButtonTemplate` = SmallActionButtonTemplate + FlyoutPopupButtonTemplate），**按需 CreateFrame、父级为 SpellFlyout**；图标经 `_G[name.."Icon"]:SetTexture(...)` 设置，拥有独立 cooldown/高亮。
- 触发链：任意 actionType=="flyout" 的动作条按钮（`BaseActionButtonMixin:UpdateFlyout` 中 `self:SetPopup(SpellFlyout)`）→ 点击走 `FlyoutButtonMixin:TogglePopup()` → `SpellFlyout:Toggle(...)` 填充菜单项 → `FlyoutPopupMixin:AttachToButton(button)`。
- 弹出方向来自按钮 KeyValue `popupDirection`（模板默认 UP）或所属 bar 的 `GetSpellFlyoutDirection()`；`popupOffset=-4` 表示菜单与按钮有 4px 重叠。

## 关键行为（Addon 视角，最重要的坑）

- **`AttachToButton` 会执行 `SpellFlyout:SetParent(源按钮)`** 并锚定到按钮边缘，`Show()`；关闭（`DetatchFromButton`）只 Hide 不还原父级，下次 Attach 再换。⇒ 对动作条按钮 `SetClipsChildren(true)` 会把打开的菜单裁剪到按钮矩形内——菜单本体在按钮外，视觉上即"菜单被截断隐藏"（本项目 HideActionBarBorders 2026-08-21 踩坑）。
- 菜单按钮外观走 SmallActionButtonTemplate 自带 NormalTexture/IconMask(45×45)，与主动作条按钮模板同源但独立实例 ⇒ 皮肤化主按钮（隐藏边框/放大图标）不会自动应用到菜单按钮，属预期行为。
- 菜单关闭时机：`ACTIONBAR_PAGE_CHANGED`、`PET_STABLE_UPDATE`/`PET_STABLE_SHOW`、世界地图最大化/显示、Esc（GameMenuEscPriority.Menu）、点击任一菜单项施法。
- 猎人召唤宠物：空宠位对应的菜单按钮不生成（`GetCallPetSpellInfo` 过滤）；offSpec（专精未学）条目 Disable 并去色。

## 对本插件的约束

- HideActionBarBorders 的"图标放大去边框"必须用 `icon:SetTexCoord` 裁素材中央区域（与放大+裁帧数学等价），**禁止对按钮 `SetClipsChildren`**。
- 已核实 12.1.0 源码中 ActionButton.lua / PetActionBar.lua / StanceBar.lua 对 icon 只有 SetTexture/SetVertexColor/SetDesaturated/Show/Hide，**不重置 TexCoord**，故 TexCoord 裁切可长期存续；若未来版本变更需重新核实。
