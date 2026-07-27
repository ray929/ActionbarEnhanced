-- ActionbarEnhanced/RemoveExtraActionButtonTexture.lua
-- 移除额外动作条（ExtraActionButton1 / ZoneAbilityFrame）的装饰材质与边框：
-- 移植自 luo/RemoveExtraActionButtonTexture.lua，并按 HideActionBarBorders 思路一并移除边框。
--
-- 原理：
--   · 隐藏 .style/.Style 主装饰材质（参考实现核心）；
--   · 按 HideActionBarBorders 类似操作：隐藏 NormalTexture / Border，去掉图标圆角蒙版 IconMask。
--   额外动作条/区域技能在进入特定场景时才出现，且暴雪会在更新时重新设置 style，
--   故启用期间用 0.5s 轻量 ticker 持续重施，保证装饰不重新出现。
-- 单一开关存于 ActionbarEnhancedDB.removeExtraActionTexture.enabled（角色级存档，默认启用）。
-- 关闭无法无损还原（IconMask 已移除），需重载界面恢复原生外观（与 HideActionBarBorders 一致）。

ActionbarEnhanced = ActionbarEnhanced or {}
local BAR = ActionbarEnhanced
BAR.RemoveExtraActionTexture = BAR.RemoveExtraActionTexture or {}

local MOD = BAR.RemoveExtraActionTexture
MOD._ticker = nil

-- 移除单个帧/按钮的装饰：隐藏 style 材质 + 边框类纹理 + 去掉图标圆角蒙版
local function StripStyle(frame)
    if not frame then return end
    -- 主装饰材质（参考实现核心；ExtraActionButton 用 .style，ZoneAbilityFrame 用 .Style）
    local style = frame.style or frame.Style
    if style then
        style:SetAlpha(0)
        style:Hide()
    end
    -- 边框类（HideActionBarBorders 思路）
    if frame.NormalTexture then frame.NormalTexture:Hide() end
    if frame.Border then frame.Border:Hide() end
    -- 去掉图标圆角蒙版（与 HideActionBarBorders 一致；移除后无法无损还原 → 关闭需重载）
    if frame.icon and frame.IconMask then
        pcall(frame.icon.RemoveMaskTexture, frame.icon, frame.IconMask)
    end
end

-- 全量应用一次
local function Apply()
    StripStyle(ExtraActionButton1)
    if ZoneAbilityFrame then
        StripStyle(ZoneAbilityFrame)
        -- ZoneAbilityFrame 内部可能含子按钮
        if ZoneAbilityFrame.buttons then
            for _, b in ipairs(ZoneAbilityFrame.buttons) do StripStyle(b) end
        end
    end
end

-- =========================================================
-- 配置开关（默认启用）
-- =========================================================
function MOD.EnsureDB()
    ActionbarEnhancedDB = ActionbarEnhancedDB or {}
    ActionbarEnhancedDB.removeExtraActionTexture = ActionbarEnhancedDB.removeExtraActionTexture or {}
    if ActionbarEnhancedDB.removeExtraActionTexture.enabled == nil then
        ActionbarEnhancedDB.removeExtraActionTexture.enabled = true
    end
end

function MOD.IsEnabled()
    return ActionbarEnhancedDB and ActionbarEnhancedDB.removeExtraActionTexture
        and ActionbarEnhancedDB.removeExtraActionTexture.enabled ~= false
end

function MOD.Start()
    Apply()
    -- 暴雪会在场景切换/技能更新时重新设置 style，用轻量 ticker 持续重施
    if not MOD._ticker then
        MOD._ticker = C_Timer.NewTicker(0.5, Apply)
    end
end

function MOD.Stop()
    if MOD._ticker then
        MOD._ticker:Cancel()
        MOD._ticker = nil
    end
    -- 不尝试在线还原（IconMask 已移除），重载界面后由暴雪重建原生外观
end

function MOD.SetEnabled(v)
    MOD.EnsureDB()
    ActionbarEnhancedDB.removeExtraActionTexture.enabled = v
    if v then
        MOD.Start()
        print("|cff33ccff[ActionbarEnhanced]|r 移除额外动作条材质已【启用】。")
    else
        MOD.Stop()
        print("|cff33ccff[ActionbarEnhanced]|r 移除额外动作条材质已【关闭】，重载界面后恢复原生外观。")
    end
end

-- 加载即确保 DB 并依开关应用（PLAYER_LOGIN 时相关帧已就绪）
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function()
    MOD.EnsureDB()
    if MOD.IsEnabled() then MOD.Start() end
end)
