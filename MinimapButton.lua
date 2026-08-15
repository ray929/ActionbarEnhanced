-- ActionbarEnhanced/MinimapButton.lua
-- 小地图快捷按钮：基于 LibDataBroker-1.1 + LibDBIcon-1.0（参考 DFCN_DelveHelper 的实现）。
--   · 左键点击 → 打开设置面板（复用 Options.OpenConfig，自动处理战斗中延迟打开）
--   · 左键拖动 → 绕小地图边缘移动，位置存档（LibDBIcon 内置，角度存 db.minimapPos）
--   · 右键点击 → 锁定/解锁位置（LibDBIcon 的 Lock/Unlock，db.lock 存档）
-- 显隐由 Options「基本配置」开关控制（ActionbarEnhancedDB.minimap.enabled，默认开启）。
-- 拖动/锁定/位置存盘全部交给 LibDBIcon，自实现极简、无自写拖动逻辑。

local BAR = ActionbarEnhanced
if not BAR then return end

local ADDON_FOLDER = "ActionbarEnhanced"
local addonName = C_AddOns.GetAddOnMetadata(ADDON_FOLDER, "Title") or "Actionbar Enhanced"
local iconPath = C_AddOns.GetAddOnMetadata(ADDON_FOLDER, "IconTexture") or "Interface\\Icons\\INV_Misc_Gear_01"

-- 存档（角色级，与全局各模块约定一致：直接读写 ActionbarEnhancedDB）
ActionbarEnhancedDB = ActionbarEnhancedDB or {}
ActionbarEnhancedDB.minimap = ActionbarEnhancedDB.minimap or {}
local mm = ActionbarEnhancedDB.minimap
if mm.enabled == nil then mm.enabled = true end

local LDB = LibStub("LibDataBroker-1.1", true)
local LibDBIcon = LibStub("LibDBIcon-1.0", true)

-- 库缺失时回退：不显示按钮，但保留接口，避免 Options 调用报错
if not LDB or not LibDBIcon then
    BAR.MinimapButton = {
        SetVisible = function() end,
        IsVisible = function() return false end,
    }
    return
end

local function CreateLDBObject()
    return LDB:NewDataObject(addonName, {
        type = "data source",
        icon = iconPath,
        OnClick = function(_, button)
            if button == "LeftButton" then
                if BAR.OpenConfig then BAR.OpenConfig() end
            elseif button == "RightButton" then
                -- 右键锁定/解锁位置
                if mm.lock then
                    LibDBIcon:Unlock(addonName)
                    print(("|cff33ccff[ActionbarEnhanced]|r 小地图按钮位置已%s"):format("解锁"))
                else
                    LibDBIcon:Lock(addonName)
                    print(("|cff33ccff[ActionbarEnhanced]|r 小地图按钮位置已%s"):format("锁定"))
                end
            end
        end,
        OnTooltipShow = function(tt)
            tt:AddLine(addonName, 1, 1, 1)
            tt:AddLine("左键：打开设置", 1, 1, 1)
            tt:AddLine("拖动：移动位置", 0.8, 0.8, 0.8)
            tt:AddLine(("右键：%s位置"):format(mm.lock and "解锁" or "锁定"), 0.8, 0.8, 0.8)
        end,
    })
end

local ldb = CreateLDBObject()
LibDBIcon:Register(addonName, ldb, mm)

-- 显隐：mm.enabled 控制（Options 读写），通过 LibDBIcon 的 Show/Hide 实现
local function SetVisible(v)
    mm.enabled = v
    if v then
        LibDBIcon:Show(addonName)
    else
        LibDBIcon:Hide(addonName)
    end
end

-- 初始显隐
SetVisible(mm.enabled)

-- 暴露给 Options 的接口
BAR.MinimapButton = {
    SetVisible = SetVisible,
    IsVisible = function() return mm.enabled ~= false end,
}
