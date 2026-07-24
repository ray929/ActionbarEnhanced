-- ButtonAurasReborn/Settings.lua
-- 全局样式配置（字体 / 字号 / 颜色），供 Overlay.lua（手动绑定）与 AutoCDM.lua（自动发现）共用。
-- 本文件必须在所有其它文件【之前】加载（见 ButtonAurasReborn.toc）。
-- 改这里即可统一调整两处显示，无需分别改两个文件。
--
-- ⚠️ 颜色用 RGB 0~1 浮点：{ R/255, G/255, B/255 }。
--    例如 F0FF00 黄 = { 0xF0/255, 0xFF/255, 0x00/255 }；纯白 = { 1, 1, 1 }。

-- 确保全局命名空间存在（Core.lua 也会建，这里最先加载先兜底）
ButtonAurasReborn = ButtonAurasReborn or {}
local S = {}
ButtonAurasReborn.Settings = S

-- =========================================================
-- 字体与字号
-- =========================================================
S.FONT = STANDARD_TEXT_FONT          -- 字体（暴雪标准字体；要换可改成 "Fonts\\ARKai_C.ttf" 等）
S.FONT_SIZE = 16                     -- 字号（时间、层数通用，像素）
S.OUTLINE = "THICKOUTLINE"           -- 重描边样式（THICKOUTLINE / OUTLINE / nil）

-- =========================================================
-- 手动绑定系统（Overlay.lua）配色
-- =========================================================
S.MANUAL_TIME_COLOR  = { 0xF0/255, 0xFF/255, 0x00/255 }  -- 剩余时间：F0FF00 黄
S.MANUAL_STACK_COLOR = { 0x00/255, 0xFD/255, 0xFF/255 }  -- 层数：    00FDFF 青

-- =========================================================
-- 自动发现系统（AutoCDM.lua）配色（按归属上色）
-- =========================================================
S.AUTO_OWN_TIME_COLOR   = { 0.30, 1.00, 0.30 }   -- 自己的增益：绿
S.AUTO_OTHER_TIME_COLOR = { 1.00, 0.30, 0.30 }   -- 别人的增益：红
S.AUTO_STACK_COLOR      = { 1.00, 1.00, 0.00 }   -- 层数：黄 (F0FF00)
