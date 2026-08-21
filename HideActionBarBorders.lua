-- ActionbarEnhanced/HideActionBarBorders.lua
-- 隐藏原生动作条边框：忠实移植自 HideActionBarBorders（emallson）。
-- 作用：隐藏 NormalTexture、去掉图标圆角蒙版、把高亮/选中等覆盖层纹理重映射到动作条图集的方块区域
--       （保留悬停时的淡方槽效果，来自 UI-HUD-ActionBar-IconFrame-Mouseover 区域）、
--       冷却扫光铺满整钮、隐藏施法/打断边框 → 图标呈纯方块、无外框。
-- 开关存于 ActionbarEnhancedDB.hideBorders（默认开启）；改动需重载界面生效。
-- 依赖二进制纹理：Resources/uiactionbar2x.tga（移植自原插件，提供方块覆盖层与悬停方槽）。
-- 功能启用时同时给按钮加 1 像素黑色描边（紧贴按钮内缘，盖在放大图标之上）。

ActionbarEnhanced = ActionbarEnhanced or {}
local BAR = ActionbarEnhanced
BAR.HideBorders = BAR.HideBorders or {}

local BARS = {
    "Action",
    "MultiBarBottomLeft",
    "MultiBarBottomRight",
    "MultiBarLeft",
    "MultiBarRight",
    "MultiBar5",
    "MultiBar6",
    "MultiBar7",
    "PetAction",
    "Stance",
}

local function ButtonCount(bar)
    if bar == "PetAction" or bar == "Stance" then
        return 10
    else
        return 12
    end
end

-- 动作条图集（移植自原插件）：提供方块覆盖层与各状态区域（含悬停方槽 Mouseover）。
local replacementTexture = "interface/addons/ActionbarEnhanced/Resources/uiactionbar2x"

local replacementAtlas = {
    ["UI-HUD-ActionBar-IconFrame-Slot"] = { 64, 31, 0.701172, 0.951172, 0.102051, 0.162598, false, false, "2x" },
    ["UI-HUD-ActionBar-IconFrame"] = { 46, 22, 0.701172, 0.880859, 0.316895, 0.36084, false, false, "2x" },
    ["UI-HUD-ActionBar-IconFrame-AddRow"] = { 51, 25, 0.701172, 0.900391, 0.215332, 0.265137, false, false, "2x" },
    ["UI-HUD-ActionBar-IconFrame-Down"] = { 46, 22, 0.701172, 0.880859, 0.430176, 0.474121, false, false, "2x" },
    ["UI-HUD-ActionBar-IconFrame-Flash"] = { 46, 22, 0.701172, 0.880859, 0.475098, 0.519043, false, false, "2x" },
    ["UI-HUD-ActionBar-IconFrame-FlyoutBorderShadow"] = { 52, 26, 0.701172, 0.904297, 0.163574, 0.214355, false, false, "2x" },
    ["UI-HUD-ActionBar-IconFrame-Mouseover"] = { 46, 22, 0.701172, 0.880859, 0.52002, 0.563965, false, false, "2x" },
    ["UI-HUD-ActionBar-IconFrame-Border"] = { 46, 22, 0.701172, 0.880859, 0.361816, 0.405762, false, false, "2x" },
    ["UI-HUD-ActionBar-IconFrame-AddRow-Down"] = { 51, 25, 0.701172, 0.900391, 0.266113, 0.315918, false, false, "2x" },
}

-- 把覆盖层纹理重映射到图集的对应方块区域（保留悬停方槽等观感）。
local function RemapTexture(texture)
    if not texture then return end
    local atlasId = texture:GetAtlas()
    local atlas = replacementAtlas[atlasId]
    if atlas == nil then return end  -- 该纹理不是动作条图集区域则不动
    local width = texture:GetWidth()
    local height = texture:GetHeight()
    texture:SetTexture(replacementTexture)
    texture:SetTexCoord(atlas[3], atlas[4], atlas[5], atlas[6])
    texture:SetWidth(width)
    texture:SetHeight(height)
end

local function HideBorder(button)
    if button.NormalTexture then button.NormalTexture:Hide() end
    if button.icon and button.IconMask then
        pcall(button.icon.RemoveMaskTexture, button.icon, button.IconMask)
    end
end

-- 图标素材放大 1.15 倍：暴雪自带图标四周有一圈边框，放大使其溢出按钮即可裁掉。
-- 等效实现：图标与按钮同尺寸 + SetTexCoord 只取素材中央 1/ICON_SCALE 区域
-- （与"放大后裁切"数学等价，视觉一致），只动 icon 纹理本身，不改按钮尺寸/位置/点击范围。
-- ⚠️ 绝不能用 button:SetClipsChildren(true) 裁整个按钮：法术弹出菜单（猎人召唤宠物、
-- 法师传送等 SpellFlyout）打开时会被暴雪 SetParent 到源按钮上（FlyoutPopupMixin:
-- AttachToButton，12.1.0 源码核实），整钮裁切会把弹出菜单一起裁掉 → 菜单被截断隐藏。
local ICON_SCALE = 1.15
local function EnlargeIcon(button)
    local icon = button.icon
    if not icon then return end
    local bw = button:GetWidth()
    if not bw or bw <= 0 then return end
    icon:ClearAllPoints()
    icon:SetAllPoints(button)
    -- 裁掉素材自带边框：只显示中央 1/ICON_SCALE 区域，铺满按钮
    local inset = (1 - 1 / ICON_SCALE) / 2
    icon:SetTexCoord(inset, 1 - inset, inset, 1 - inset)
end

-- 功能启用时给按钮加 1 像素黑色描边：用 4 条 WHITE8X8 纹理紧贴按钮内缘，
-- 层级 OVERLAY 保证盖在放大图标之上；幂等，按钮尺寸自适应。
local function AddBlackBorder(button)
    if button._AEBorderAdded then return end
    button._AEBorderAdded = true
    local tex = "Interface\\Buttons\\WHITE8X8"
    local edges = {
        { "TOPLEFT", "TOPRIGHT", "height" },
        { "BOTTOMLEFT", "BOTTOMRIGHT", "height" },
        { "TOPLEFT", "BOTTOMLEFT", "width" },
        { "TOPRIGHT", "BOTTOMRIGHT", "width" },
    }
    for _, e in ipairs(edges) do
        local t = button:CreateTexture(nil, "OVERLAY")
        t:SetTexture(tex)
        t:SetVertexColor(0, 0, 0, 1)
        t:SetPoint(e[1], button, e[1], 0, 0)
        t:SetPoint(e[2], button, e[2], 0, 0)
        if e[3] == "height" then t:SetHeight(1) else t:SetWidth(1) end
    end
end

local function AdjustButtonOverlays(button)
    if button.cooldown then button.cooldown:SetAllPoints(button) end
    RemapTexture(button.HighlightTexture)
    RemapTexture(button.CheckedTexture)
    RemapTexture(button.SpellHighlightTexture)
    RemapTexture(button.NewActionTexture)
    RemapTexture(button.PushedTexture)
    RemapTexture(button.Border)
    if button.SlotBackground then button.SlotBackground:SetDrawLayer("BACKGROUND", -1) end
    if button.SpellCastAnimFrame then
        button.SpellCastAnimFrame:SetScript("OnShow", function(self) self:Hide() end)
    end
    if button.InterruptDisplay then
        button.InterruptDisplay:SetScript("OnShow", function(self) self:Hide() end)
    end
end

local function HideSelf(self) self:Hide() end

local function Setup()
    for _, bar in ipairs(BARS) do
        for i = 1, ButtonCount(bar) do
            local key = bar .. "Button" .. i
            local button = _G[key]
            if button then
                HideBorder(button)
                EnlargeIcon(button)
                AddBlackBorder(button)
                button:HookScript("OnShow", function()
                    HideBorder(button)
                    EnlargeIcon(button)
                    AddBlackBorder(button)
                end)
                AdjustButtonOverlays(button)
                if button.NormalTexture then
                    button.NormalTexture:HookScript("OnShow", HideSelf)
                end
            end
        end
    end
end

-- =========================================================
-- 启用开关（存盘于 ActionbarEnhancedDB.hideBorders，默认开启）
-- =========================================================
function BAR.HideBorders.EnsureDB()
    ActionbarEnhancedDB = ActionbarEnhancedDB or {}
    if ActionbarEnhancedDB.hideBorders == nil then
        ActionbarEnhancedDB.hideBorders = true
    end
end

function BAR.HideBorders.IsEnabled()
    return ActionbarEnhancedDB and ActionbarEnhancedDB.hideBorders == true
end

function BAR.HideBorders.SetEnabled(v)
    BAR.HideBorders.EnsureDB()
    ActionbarEnhancedDB.hideBorders = v
    if v then
        Setup()   -- 开启即时预览；关闭需重载才能恢复（原插件本身无法无损撤销）
    end
    print("|cff33ccff[ActionbarEnhanced]|r 隐藏原生动作条边框已"
        .. (v and "【启用】" or "【关闭】") .. "，重新加载界面后完全生效。")
    StaticPopup_Show("ACTIONBARENHANCED_RELOAD")
end

-- 切换开关后询问是否重载的弹窗：确定重载 = 立即 ReloadUI；稍后 = 用户自行重载
StaticPopupDialogs["ACTIONBARENHANCED_RELOAD"] = {
    text = "切换「隐藏原生动作条边框」需要重新加载界面才能完全生效。是否现在重新加载？",
    button1 = "确定重载",
    button2 = "稍后",
    OnAccept = function() ReloadUI() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- 加载时按开关应用（PLAYER_ENTERING_WORLD 时按钮已全部存在）
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:SetScript("OnEvent", function()
    BAR.HideBorders.EnsureDB()
    if BAR.HideBorders.IsEnabled() then
        Setup()
    end
end)
