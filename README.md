# Actionbar Enhanced

> Move buff information shown by Blizzard's built-in Cooldown Manager (CDM) onto your native action bar buttons — for World of Warcraft retail 12.0.7.

将暴雪自带 CDM（冷却/增益查看器）中显示的【玩家自身增益】信息，覆盖到原生动作条按钮上（正式服 12.0.7）。

## Features / 功能

- Hooks Blizzard's `BuffIconCooldownViewer` / `BuffBarCooldownViewer` (CDM) — no scanning of unit auras, combat-safe.
- Captures **player** buffs only (filtered by `auraDataUnit` + `auraInstanceID` on the CDM frame).
- Config GUI (Blizzard Settings panel): lists captured buffs with icon + name + spellID, click a row to select/deselect.
- Selection persists across sessions (`ActionbarEnhancedDB`).
- (Planned) Show remaining time (green, top-left) and stacks (purple, bottom-left), font size 16, no icon overlay.

## Installation / 安装

Copy the `ActionbarEnhanced` folder into `World of Warcraft\_retail_\Interface\AddOns\`, then enable it in-game (Esc → AddOns).

## Configuration / 配置

Open the settings panel via the **Addon Compartment** (top-right of the minimap area, click the Actionbar Enhanced entry), or via Esc → Options → AddOns → Actionbar Enhanced.

> If the list is empty, gain a buff first (food / flask / class buff) — it will appear automatically.

## Environment Variables / 环境变量

None. This is a pure WoW addon; all state lives in `ActionbarEnhancedDB`.

## Release / 构建

No build step. Loads directly via the `.toc` file.
