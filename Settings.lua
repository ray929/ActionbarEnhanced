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
S.FONT_SIZE = 14                     -- 字号（时间、层数通用，像素）
S.OUTLINE = "THICKOUTLINE"           -- 重描边样式（THICKOUTLINE / OUTLINE / nil）

-- =========================================================
-- 统一配色（手动 Overlay + 自动 AutoCDM 共用）
--   时间（倒计时数字）按【自身 / 别人buff / 别人debuff】染不同色
--   层数统一粉红色
-- =========================================================
S.TIME_COLOR_SELF         = { 0.20, 1.00, 0.20 }  -- 自身：鲜绿
S.TIME_COLOR_OTHER_BUFF   = { 1.00, 1.00, 0.00 }  -- 别人的 buff：#FFFF00 纯黄
S.TIME_COLOR_OTHER_DEBUFF = { 1.00, 0.20, 0.20 }  -- 别人的 debuff：鲜红
S.STACK_COLOR             = { 0x3F/255, 0xC7/255, 0xEB/255 }  -- 层数：#3FC7EB

-- 取时间颜色：自身=浅绿；别人 debuff=浅紫；别人 buff（及其它）=黄
-- ⚠️ 必须用 isHarmful 布尔判定 debuff：新客户端 auraData.auraType 是 Enum.AuraType【数字】，
--    不是 "Magic" 等字符串，旧写法用字符串比对永远失败 → 别人的 debuff 全误判成 buff（黄）。
function S.GetTimeColor(unit, isHarmful)
    if unit == "player" then
        return S.TIME_COLOR_SELF
    elseif isHarmful then
        return S.TIME_COLOR_OTHER_DEBUFF
    else
        return S.TIME_COLOR_OTHER_BUFF
    end
end
