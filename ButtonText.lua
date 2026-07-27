-- ActionbarEnhanced/ButtonText.lua
-- 调整【原生动作条按钮】自带的文字样式（倍率相对 AutoCDM 字号）：
--   · button.HotKey  （按键绑定）   — 字号倍率 + 锚点位置 + 加厚描边
--   · button.Count   （层数）       — 字号倍率 + 锚点位置 + 加厚描边
--   · button.Name    （宏文本）     — 仅字号倍率 + 加厚描边，位置固定（按钮下方，不改）
-- 机制参考 MattActionBarFont（已验证战斗安全）：直接改写按钮非安全子 FontString，
-- 并在原生刷新（UpdateHotkeys / UpdateCount / Update）后重新套用，防止被原生重置冲掉。
-- 目标：完全替代 MattActionBarFont 的「HotKey + Count」样式能力（v1 复用 ActionbarEnhanced 现有字体）。

local BAR = ActionbarEnhanced
local S = BAR.Settings or {}

local BT = {}
BAR.ButtonText = BT

-- =========================================================
-- 配置：仅 enabled 入存档（ActionbarEnhancedDB.buttonText）；其余全部硬编码。
--   字号用「倍率」：实际像素 = round(倍率 × S.FONT_SIZE)，S.FONT_SIZE 即 AutoCDM 覆盖层字号（=1）。
--   描边统一加厚（THICKOUTLINE）；颜色不改动（保持原生）。
-- =========================================================
local DEFAULTS = {
    enabled = true,
}

-- 硬编码布局（倍率相对 AutoCDM 覆盖层字号 = 1）：
--   HotKey  0.7 倍，右下角；Count 0.9 倍，右上角；宏文本 0.6 倍（位置保持原生按钮下方）。
local LAYOUT = {
    hotkey = { scale = 0.6, anchor = "BOTTOMRIGHT", x = 4, y = 0 },
    count  = { scale = 0.9, anchor = "TOPRIGHT",  x = -1, y = -1 },
    macro  = { scale = 0.5 },
}

-- 防御式获取 DB：WoW 的 SavedVariables 在 ADDON_LOADED 之后、PLAYER_LOGIN 之前才整体加载，
-- 会覆盖文件加载时创建的临时表，故这里惰性确保字段存在并补齐默认值（对齐 Manual.InitSpecStorage 的时机）。
local function DB()
    ActionbarEnhancedDB = ActionbarEnhancedDB or {}
    local t = ActionbarEnhancedDB.buttonText
    if not t then
        t = {}
        ActionbarEnhancedDB.buttonText = t
    end
    for k, v in pairs(DEFAULTS) do
        if t[k] == nil then
            t[k] = v
        end
    end
    return t
end

-- 基准字号（AutoCDM 覆盖层字号）= 1.0 单位
local function BaseSize()
    return (S.FONT_SIZE and S.FONT_SIZE > 0) and S.FONT_SIZE or 16
end

-- 倍率 -> 实际像素（四舍五入，至少 1）
local function Px(scale)
    return math.max(1, math.floor((scale or 1) * BaseSize() + 0.5))
end

-- =========================================================
-- 枚举所有原生动作条按钮
-- =========================================================
local STANDARD_BARS = {
    "ActionButton",
    "MultiBarBottomLeftButton",
    "MultiBarBottomRightButton",
    "MultiBarRightButton",
    "MultiBarLeftButton",
    "MultiBar5Button",
    "MultiBar6Button",
    "StanceButton",
    "PetActionButton",
    "PossessButton",
    "ExtraActionButton",
}

local function EnumerateButtons()
    local buttons = {}
    -- Dominos 动作条兼容
    if _G.Dominos then
        local i = 1
        while true do
            local btn = _G["DominosActionButton" .. i]
            if not btn then break end
            buttons[#buttons + 1] = btn
            i = i + 1
        end
    end
    for _, bar in ipairs(STANDARD_BARS) do
        for i = 1, 12 do
            local button = _G[bar .. i]
            if button then
                buttons[#buttons + 1] = button
            end
        end
    end
    return buttons
end

-- =========================================================
-- 应用样式
-- =========================================================
-- 仅在变化时 SetFont，避免每帧重设导致文字 reflow 闪烁
local function SetFontSafe(fs, size, flags)
    if not fs or not fs.GetFont then return end
    local f, s, fl = fs:GetFont()
    local curFlags = fl or ""
    local wantFlags = flags or ""
    if f ~= S.FONT or s ~= size or curFlags ~= wantFlags then
        fs:SetFont(S.FONT, size, flags)
    end
end

local OUTLINE = "THICKOUTLINE"   -- 一律加厚描边

local function ApplyHotKey(button)
    if not button then return end
    local fs = button.HotKey or button.bind   -- 宠物栏用 bind
    if not fs then return end
    local L = LAYOUT.hotkey
    SetFontSafe(fs, Px(L.scale), OUTLINE)
    fs:ClearAllPoints()
    fs:SetPoint(L.anchor, button, L.anchor, L.x, L.y)
end

local function ApplyCount(button)
    if not button then return end
    local fs = button.Count or _G[button:GetName() .. "Count"]
    if not fs then return end
    local L = LAYOUT.count
    SetFontSafe(fs, Px(L.scale), OUTLINE)
    fs:ClearAllPoints()
    fs:SetPoint(L.anchor, button, L.anchor, L.x, L.y)
end

-- 宏文本：只改字号 + 描边，不动位置（保留原生「按钮下方」锚点）
local function ApplyMacro(button)
    if not button then return end
    local fs = button.Name
    if not fs then return end
    SetFontSafe(fs, Px(LAYOUT.macro.scale), OUTLINE)
end

-- 遍历所有按钮，同时套用 HotKey + Count + 宏文本
function BT.ApplyAll()
    if not BT.IsEnabled() then return end
    for _, button in ipairs(EnumerateButtons()) do
        ApplyHotKey(button)
        ApplyCount(button)
        ApplyMacro(button)
    end
end

-- =========================================================
-- Hook 持久化：原生刷新后会把 HotKey / Count / 宏文本 重置回默认，
-- 必须在其后重新套用，样式才不会被冲掉。
-- =========================================================
local hooked = false
local function EnsureHooks()
    if hooked then return end
    -- HotKey：主刷新入口
    if ActionBarActionButtonMixin and ActionBarActionButtonMixin.UpdateHotkeys then
        hooksecurefunc(ActionBarActionButtonMixin, "UpdateHotkeys", function(button)
            if BT.IsEnabled() then ApplyHotKey(button) end
        end)
    end
    if type(_G.ActionButton_UpdateHotkeys) == "function" then
        hooksecurefunc("ActionButton_UpdateHotkeys", function(button)
            if BT.IsEnabled() then ApplyHotKey(button) end
        end)
    end
    if type(_G.PetActionButton_UpdateHotkeys) == "function" then
        hooksecurefunc("PetActionButton_UpdateHotkeys", function(button)
            if BT.IsEnabled() then ApplyHotKey(button) end
        end)
    end
    -- Count：原生刷新入口（若有）
    if ActionBarActionButtonMixin and ActionBarActionButtonMixin.UpdateCount then
        hooksecurefunc(ActionBarActionButtonMixin, "UpdateCount", function(button)
            if BT.IsEnabled() then ApplyCount(button) end
        end)
    end
    if type(_G.ActionButton_UpdateCount) == "function" then
        hooksecurefunc("ActionButton_UpdateCount", function(button)
            if BT.IsEnabled() then ApplyCount(button) end
        end)
    end
    -- 宏文本：按钮 action 变化时（含文字内容刷新）重套字体（位置不动，原生不会冲掉）
    if ActionBarActionButtonMixin and ActionBarActionButtonMixin.Update then
        hooksecurefunc(ActionBarActionButtonMixin, "Update", function(button)
            if BT.IsEnabled() then ApplyMacro(button) end
        end)
    end
    if type(_G.ActionButton_Update) == "function" then
        hooksecurefunc("ActionButton_Update", function(button)
            if BT.IsEnabled() then ApplyMacro(button) end
        end)
    end
    hooked = true
end

-- =========================================================
-- 启用开关（「调整按钮原生文字」）
-- =========================================================
function BT.IsEnabled()
    return DB().enabled ~= false
end

function BT.SetEnabled(v)
    DB().enabled = v
    if v then
        BT.ApplyAll()   -- 开启即时预览；关闭由原生刷新恢复默认，需重载才干净
    end
    print("|cff33ccff[ActionbarEnhanced]|r 调整按钮原生文字已"
        .. (v and "【启用】" or "【关闭】") .. "，重新加载界面后完全生效。")
    StaticPopup_Show("ACTIONBARENHANCED_BUTTONTEXT_RELOAD")
end

-- 切换开关后询问是否重载的弹窗：确定重载 = 立即 ReloadUI；稍后 = 用户自行重载
StaticPopupDialogs["ACTIONBARENHANCED_BUTTONTEXT_RELOAD"] = {
    text = "切换「调整按钮原生文字」需要重新加载界面才能完全生效。是否现在重新加载？",
    button1 = "确定重载",
    button2 = "稍后",
    OnAccept = function() ReloadUI() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- =========================================================
-- 事件驱动：登录 / 进场 / 翻页 / 改键 时重套用
-- =========================================================
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
ev:RegisterEvent("UPDATE_BINDINGS")
ev:SetScript("OnEvent", function(_, e)
    if e == "PLAYER_LOGIN" then
        EnsureHooks()
        C_Timer.After(0.2, BT.ApplyAll)
        C_Timer.After(1.0, BT.ApplyAll)
        C_Timer.After(3.0, BT.ApplyAll)
        -- 完全替代 MABF：检测到仍在启用则提示用户停用，避免两套样式互相覆盖
        if C_AddOns.IsAddOnLoaded("MattActionBarFont") then
            print("|cff33ccff[ActionbarEnhanced]|r 检测到 MattActionBarFont 仍在启用；本插件的「按钮文字」已可完全替代它，建议在插件列表停用 MABF 以避免样式冲突。")
        end
    elseif e == "PLAYER_ENTERING_WORLD" then
        C_Timer.After(0.2, BT.ApplyAll)
        C_Timer.After(1.0, BT.ApplyAll)
    else
        BT.ApplyAll()
    end
end)
