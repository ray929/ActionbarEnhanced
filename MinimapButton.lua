-- ActionbarEnhanced/MinimapButton.lua
-- 小地图快捷按钮：
--   · 左键点击 → 打开设置面板（复用 Options.OpenConfig，自动处理战斗中延迟打开）
--   · 左键拖动 → 绕小地图边缘移动，位置存档（角度）
--   · 右键点击 → 锁定/解锁位置（避免误操作拖动）
-- 显隐由 Options「基本配置」开关控制（ActionbarEnhancedDB.minimap.enabled，默认开启）。
-- 不依赖 LibDBIcon 等外部库，自包含实现。

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
if mm.angle == nil then mm.angle = math.rad(135) end   -- 初始左下角
if mm.radius == nil then mm.radius = 80 end            -- 离小地图中心距离（贴边）
if mm.lock == nil then mm.lock = false end

local button = CreateFrame("Button", "ActionbarEnhancedMinimapButton", Minimap)
button:SetSize(32, 32)
button:SetFrameStrata("MEDIUM")
button:SetFrameLevel(8)
button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

local icon = button:CreateTexture(nil, "BACKGROUND")
icon:SetSize(20, 20)
icon:SetPoint("CENTER", 0, 0)
icon:SetTexture(iconPath)

local border = button:CreateTexture(nil, "OVERLAY")
border:SetSize(32, 32)
border:SetPoint("CENTER", 0, 0)
border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

-- 根据角度把按钮摆到小地图边缘的圆形轨道上
local function UpdatePosition()
    local a = mm.angle or math.rad(135)
    local r = mm.radius or 80
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
end

local function SetVisible(v)
    if v then button:Show() else button:Hide() end
end

button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
button:RegisterForDrag("LeftButton")

button:SetScript("OnClick", function(_, mouseBtn)
    if mouseBtn == "RightButton" then
        mm.lock = not mm.lock
        print(("|cff33ccff[ActionbarEnhanced]|r 小地图按钮位置已%s"):format(mm.lock and "锁定" or "解锁"))
        return
    end
    if BAR.OpenConfig then BAR.OpenConfig() end
end)

button:SetScript("OnDragStart", function()
    if mm.lock then return end
    button:StartMoving()
end)

button:SetScript("OnDragStop", function()
    if mm.lock then return end
    button:StopMovingOrSizing()
    -- 计算相对小地图中心的角度并吸附到圆形轨道，存盘
    local mx, my = Minimap:GetCenter()
    local cx, cy = button:GetCenter()
    if mx and cx then
        mm.angle = math.atan2(cy - my, cx - mx)
    end
    UpdatePosition()
end)

button:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText(addonName, 1, 1, 1)
    GameTooltip:AddLine("左键：打开设置", 1, 1, 1)
    GameTooltip:AddLine("拖动：移动位置", 0.8, 0.8, 0.8)
    GameTooltip:AddLine(("右键：%s位置"):format(mm.lock and "解锁" or "锁定"), 0.8, 0.8, 0.8)
    GameTooltip:Show()
end)
button:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- 暴露给 Options 的显隐开关
BAR.MinimapButton = {
    frame = button,
    SetVisible = SetVisible,
    IsVisible = function() return button:IsShown() end,
}

UpdatePosition()
SetVisible(mm.enabled)
