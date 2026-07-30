# Actionbar Enhanced

> Move buff information shown by Blizzard's built-in Cooldown Manager (CDM) onto your native action bar buttons — for World of Warcraft retail 12.0.7.

将暴雪自带 CDM（冷却/增益查看器）中显示的【玩家自身增益】信息，覆盖到原生动作条按钮上（正式服 12.0.7）。

## Features / 功能

- 把暴雪 CDM 中显示的玩家自身增益（剩余时间 / 层数）覆盖到原生动作条按钮上（combat-safe，不扫单位光环，挂 UIParent 容器）。
- 手动绑定：按 spellID 绑定，支持专精级配置（时间 / 层数位置；时间位置可选「发光」——光环激活时按钮 ProcGlow 高亮、不显示时间，层数照常）。
- 自动发现（AutoCDM）：移植 CDMButtonAuras，自动把 CDM 启用的增益铺到动作条。
- 冷却高亮提醒（CooldownGlow）：CDM「主冷却」技能就绪后 ProcGlow 高亮，可配常亮 / 限时。
- 按钮文字调整（ButtonText）：调整原生按键 / 层数 / 宏文本字号与描边。
- 隐藏原生动作条边框（HideActionBarBorders）。
- **动作条按钮变色（ButtonColor）**：CD 中 → 灰色；资源不足 → 蓝色；超出范围 → 红色（三态独立判定，全局开关默认开启）。
- 配置 GUI 通过 Addon Compartment 打开（AceConfig 独立窗口）。战斗中无法打开配置，会自动延迟到脱离战斗后弹出。

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
