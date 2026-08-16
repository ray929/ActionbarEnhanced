# Actionbar Enhanced

> An all-in-one enhancement suite for World of Warcraft's **native** action bars. No bar replacement, no repositioning — your bars stay 100% Blizzard-native, just way more readable.
>
> 一站式增强魔兽世界【原生动作条】的功能合集。不替换、不重排动作条——你的动作条保持 100% 暴雪原生，只是变得好用得多。

## Features / 功能

### Timers & stacks on buttons / 按钮上的倒计时与层数

- Display buff countdowns and stack counts directly on action bar buttons, sourced from Blizzard's Cooldown Manager (CDM) — no more staring at buff frames.
- 把增益的剩余时间与层数直接显示在动作条按钮上，数据来自暴雪冷却管理器（CDM），不用再盯 buff 框。
- Two modes / 两种模式：
  - **Auto / 自动**：buffs enabled in the Blizzard CDM settings automatically appear on the matching buttons. Zero configuration.
    在暴雪 CDM 设置里启用的增益，自动显示到对应技能按钮，零配置。
  - **Manual / 手动**：bind any tracked buff to any skill by spellID, per-specialization; timer / stack position adjustable (default / top / bottom / left / right).
    按 spellID 把任意已追踪增益绑定到任意技能按钮，按专精独立保存；时间 / 层数位置可调（默认 / 上 / 下 / 左 / 右）。
- Built-in presets for common class defensives & burst buffs (Shield Wall, Divine Shield, Icebound Fortitude, Barkskin...) and weapon enchants that CDM does not render.
- 内置 CDM 不渲染的常见职业减伤 / 爆发技能（盾墙 / 圣盾术 / 冰封之韧 / 树皮术等）与武器附魔预设，开箱即用。

### Glow alerts / 发光提醒

| Color 颜色 | Trigger 触发条件 | Source 来源 |
|---|---|---|
| Cyan 青色 | Aura present / 光环存在 | Manual「发光」mode 手动绑定·发光模式 |
| Purple 紫色 | Aura missing / 光环不存在 | Manual「反发光」mode 手动绑定·反发光模式 |
| Green 绿色 | Cooldown ready / 技能就绪 | CooldownGlow 冷却高亮 |
| Yellow 黄色 | Trinket ready / 饰品就绪 | TrinketGlow 饰品高亮 |

- Cooldown ready glow is configurable: always on, or fade out 1–5s after ready.
- 冷却就绪发光可配置：常亮，或就绪后 1–5 秒自动熄灭。

### Button state coloring / 按钮状态变色

- Gray = on cooldown; blue = not enough resources; red = out of range.
- 灰色 = 冷却中；蓝色 = 资源不足；红色 = 超出施法范围。

### Clean look & QoL / 外观清理与实用功能

- Hide native bar borders and enlarge icons, with a subtle 1px outline.
- 隐藏原生动作条边框、放大图标，并加 1 像素黑色描边。
- Strip decorations from the extra action button (zone abilities).
- 清理额外技能按钮（区域技能）的装饰材质与边框。
- Adjust keybind / stack / macro text size with outline.
- 调整按键 / 层数 / 宏文字的字号与描边。
- Stop newly learned spells from being auto-added to your bars.
- 阻止新学习的技能自动挤进动作条。
- Optional per-bar mouse click-through (clicks fall through to what's underneath).
- 每条动作条可单独开启鼠标穿透（点击落到动作条下方）。

## Getting Started / 快速上手

1. Open the config window: click the **minimap button**, or the **Addon Compartment** (the little suitcase by the minimap) → *Actionbar Enhanced*.
   打开设置窗口：点击**小地图按钮**，或小地图旁的**插件抽屉**（小箱子图标）→ *Actionbar Enhanced*。
2. Type **`/cdm`** to open Blizzard's own Cooldown Manager settings and pick which buffs to track.
   输入 **`/cdm`** 直接打开暴雪自带冷却管理器设置，勾选想追踪的增益。
3. For auto mode that's all. For manual mode, enter a spellID in the manual binding tab to bind a buff to a skill.
   自动模式到此即可。手动模式在「手动配置光环」页输入 spellID，把增益绑定到指定技能。
4. The config window cannot open in combat — it automatically re-opens once combat ends.
   战斗中无法打开设置窗口，脱战后会自动弹出。

## FAQ / 常见问题

- **The manual binding list is empty? / 「手动配置光环」列表是空的？**
  Get any buff first (food, flask, class buff) — entries appear automatically.
  先获得任意一个增益（食物 / 合剂 / 职业 buff），条目会自动出现。

- **Does it keep working in combat? / 战斗中能正常显示吗？**
  Yes. The addon never reads protected aura data — it only repositions objects Blizzard has already rendered, so timers, stacks and glows keep working in combat, dungeons and PvP.
  能。插件从不读取受保护的光环数据，只搬运暴雪已渲染好的对象，因此战斗 / 副本 / PvP 中倒计时、层数、发光全部照常工作。

- **Third-party action bars? / 支持 Bartender / Dominos 吗？**
  No, by design — this addon is exclusively about enhancing the native bars.
  不支持。本插件定位就是专注增强原生动作条。

- **Turned off "block auto-add spells" but it's still blocked? / 关闭「阻止新技能自动入条」后仍不恢复？**
  That Blizzard mechanism is bound to the login session; a full relog is required (a mere `/reload` won't do it).
  该机制绑定登录会话，需要小退重新登录才能恢复（仅重载界面无效）。

- **Tooltips disappear with click-through enabled? / 开鼠标穿透后按钮没提示了？**
  Known trade-off of disabling mouse capture; keyboard bindings still work.
  这是关闭鼠标捕获的已知取舍；键盘施法不受影响。

## Compatibility / 兼容性

- World of Warcraft retail 12.x. 正式服 12.x。
- Only Blizzard-native action bars are supported. 仅支持暴雪原生动作条。
- Combat-safe by architecture (API research notes in `docs/`). 架构上战斗安全（API 调研笔记见 `docs/`）。
