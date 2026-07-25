-- ButtonAurasReborn/AutoCDM.lua
-- 自动发现模块：完整移植 CDMButtonAuras 的【自动发现】逻辑（事件触发 / 更新时机 / 匹配方式
-- 与 CDMButtonAuras 完全一致）。渲染层同样对齐 CDM：
--   · 覆盖层 = 动作按钮的子帧（随按钮自动定位，零延迟，无 GetRect 重定位）；
--   · Cooldown 倒计时（SetCooldownFromDurationObject 后自动逐秒跳动）；
--   · Glow 按归属上色（player=绿 / 其他=红，ADD 混合）；
--   · 层数 NumberFontNormal，置于左上。
-- 仅变量/函数名按本项目习惯调整，行为与 CDMButtonAuras 一一对应、无任何逻辑差异。
--
-- ⚠️ 与 CDMButtonAuras 同框运行时：本模块的 hook 标记用 __BARAutoCDMHooked（不与其
--   __CDMBAHooked 冲突），否则会被对方抢先标记导致本模块永不 hook → 永远不更新。

local BAR = ButtonAurasReborn
if not BAR then return end

local AutoCDM = {}
BAR.AutoCDM = AutoCDM

-- 共用 Settings.lua 的样式配置（字体 / 字号 / 描边 / 自动发现配色）
local S = BAR.Settings or {}

-- 前向声明：UpdateOverlay 在 GetOverlay 之后才定义（见下方 UpdateOverlay = function），
-- 但 GetOverlay 的 OnCooldownDone 闭包需捕获同一 upvalue，故此处先声明。
local UpdateOverlay

-- 诊断开关：/run ButtonAurasReborn.AutoCDM.debug = true
-- 开启后打印关键更新链路（Acquire/Hook/UpdateFromItem/RefreshAll），用于对照 CDM 排查"更新不及时"。
AutoCDM.debug = false
local function D(msg)
    if AutoCDM.debug then print("|cff00ccff[AutoCDM]|r " .. msg) end
end

-- CDM 两个查看器（与 CDMButtonAuras 完全一致：BuffIconCooldownViewer / BuffBarCooldownViewer）
local VIEWER_NAMES = { "BuffIconCooldownViewer", "BuffBarCooldownViewer" }

-- 法术名 -> 附加按钮名列表（对齐 CDM 的 AuraMapByName，默认空）。
-- 默认仅为光环自身名，故匹配行为与 CDM 默认配置一致。
local AuraMapByName = {}

-- 覆盖层表（按动作按钮对象索引，对齐 CDM 的 overlayFrames）
local overlays = {}   -- [actionButton] = overlayFrame

-- =========================================================
-- 覆盖层（对齐 CDMButtonAurasOverlayMixin）
-- =========================================================
-- 与 CDM 一样：覆盖层是动作按钮的子帧，尺寸=按钮尺寸，Cooldown 锚定到按钮 icon，
-- Glow 用于归属上色，Stacks 显示层数。不再使用 UIParent 容器 / GetRect 重定位。
local function GetOverlay(actionButton)
    local ov = overlays[actionButton]
    if not ov then
        ov = CreateFrame("Frame", nil, actionButton)
        ov:SetPoint("CENTER")
        local w, h = actionButton:GetSize()
        if w and h then ov:SetSize(w, h) end

        if actionButton.cooldown then
            ov:SetFrameLevel(actionButton.cooldown:GetFrameLevel() + 1)
        end

        -- Cooldown（倒计时）：与 CDM 同款锚定到按钮 icon
        local cd = CreateFrame("Cooldown", nil, ov)
        local icon = actionButton.icon or actionButton
        cd:SetPoint("TOPLEFT", icon, "LEFT", 5, -3)
        cd:SetPoint("BOTTOMRIGHT", icon, "BOTTOM", 0, -3)
        cd:SetDrawSwipe(false)
        cd:SetCountdownFont(S.FONT)        -- 字体名（Settings）
        cd:SetCountdownAbbrevThreshold(60)
        cd:Hide()
        ov.Cooldown = cd
        -- 倒计时数字的实际 FontString（通过它控制字号 / 描边 / 颜色，见 UpdateOverlay）

        -- Glow：对齐 CDM —— 用 CDM 的真实辉光贴图（CDMButtonAuras 已加载，路径可用），
        -- 按归属上色（player=绿 / 其他=红），ADD 混合，半透明。
        -- ⚠️ 之前用 SetColorTexture(1,1,1,1) 纯白方块会洗白按钮/数字，导致"看着没正常显示"。
        local glow = ov:CreateTexture(nil, "ARTWORK")
        glow:SetAllPoints(ov)
        glow:SetTexture("Interface\\Addons\\CDMButtonAuras\\Textures\\Overlay")
        glow:SetBlendMode("ADD")
        glow:SetAlpha(0.5)
        glow:Hide()
        ov.Glow = glow

        -- 层数（对齐 CDM：左上；字体/字号/颜色在 UpdateOverlay 统一应用 Settings）
        local stacks = ov:CreateFontString(nil, "OVERLAY")
        stacks:SetPoint("TOPLEFT", 5, -5)
        ov.Stacks = stacks

        -- 倒计时归零时重算（对齐 CDM 的 OnCooldownDone）
        cd:SetScript("OnCooldownDone", function() UpdateOverlay(ov) end)

        overlays[actionButton] = ov
    end
    return ov
end

local function SetAura(ov, unit, auraInstanceID)
    ov.unit = unit
    ov.auraInstanceID = auraInstanceID
end

-- 对齐 CDMButtonAurasOverlayMixin:Update（逻辑完全一致），并叠加 Settings 的字体 / 配色
-- 用赋值式（非 local 重新声明），绑定到顶部前向声明的同一 upvalue
UpdateOverlay = function(ov)
    if ov.unit and ov.auraInstanceID then
        local duration = C_UnitAuras.GetAuraDuration(ov.unit, ov.auraInstanceID)
        if duration then
            ov.Cooldown:SetCooldownFromDurationObject(duration, true)
            ov.Cooldown:Show()
        else
            ov.Cooldown:Hide()
        end

        -- 层数：先设字体（避免 "Font not set"），再取文本 / 上色
        ov.Stacks:SetFont(S.FONT, S.FONT_SIZE, S.OUTLINE)
        local count = C_UnitAuras.GetAuraApplicationDisplayCount(ov.unit, ov.auraInstanceID)
        ov.Stacks:SetText(count)
        ov.Stacks:SetTextColor(S.AUTO_STACK_COLOR[1], S.AUTO_STACK_COLOR[2], S.AUTO_STACK_COLOR[3])

        -- 按归属取配色：player=自己的色 / 其他=别人的色（Settings）
        local glowColor, timeColor
        if ov.unit == "player" then
            glowColor = S.AUTO_OWN_TIME_COLOR
            timeColor = S.AUTO_OWN_TIME_COLOR
        else
            glowColor = S.AUTO_OTHER_TIME_COLOR
            timeColor = S.AUTO_OTHER_TIME_COLOR
        end

        -- Glow 归属上色（保留 0.5 透明度，与原 CDM 一致）
        ov.Glow:SetVertexColor(glowColor[1], glowColor[2], glowColor[3], 0.5)
        ov.Glow:Show()

        -- 倒计时数字：通过内部 FontString 控制字体 / 字号 / 描边 / 颜色（Settings）
        local cds = ov.Cooldown:GetCountdownFontString()
        if cds then
            cds:SetFont(S.FONT, S.FONT_SIZE, S.OUTLINE)
            cds:SetTextColor(timeColor[1], timeColor[2], timeColor[3])
        end

        ov:Show()
    else
        ov:Hide()
    end
end

-- =========================================================
-- 按钮查找（对齐 CDMButtonAurasControllerMixin）
-- =========================================================
-- 与 CDM 完全一致：遍历 ActionButtonUtil.ActionBarButtonNames × NUM_ACTIONBAR_BUTTONS，
-- 再遍历 StanceBar 姿态条；取基础 spellID 的名字做匹配；返回【第一个】命中的按钮。
local function FindActionButtonForSpellName(name)
    if not name then return end
    local barNames = (ActionButtonUtil and ActionButtonUtil.ActionBarButtonNames) or {}
    for _, actionBar in ipairs(barNames) do
        if type(actionBar) == "string" then
            for i = 1, (NUM_ACTIONBAR_BUTTONS or 12) do
                local btn = _G[actionBar .. i]
                if btn and btn.action then
                    local _, actionSpellID = GetActionInfo(btn.action)
                    if actionSpellID then
                        local baseSpellID = C_Spell.GetBaseSpell(actionSpellID)
                        local actionSpellName = C_Spell.GetSpellName(baseSpellID)
                        if name == actionSpellName then
                            return btn
                        end
                    end
                end
            end
        end
    end
    for i = 1, (NUM_SPECIAL_BUTTONS or 10) do
        local stanceBtn = StanceBar and StanceBar.actionButtons and StanceBar.actionButtons[i]
        if stanceBtn then
            local stanceSpellID = select(4, GetShapeshiftFormInfo(stanceBtn:GetID()))
            if stanceSpellID then
                local stanceSpellName = C_Spell.GetSpellName(stanceSpellID)
                if name == stanceSpellName then
                    return stanceBtn
                end
            end
        end
    end
end

-- 对齐 CDMButtonAurasControllerMixin:GetActionButtonList
-- 只用 cdInfo.spellID 的名字（外加 AuraMapByName 映射）找按钮，与 CDM 完全一致。
local function GetActionButtonList(spellID)
    local buttonList = {}
    local cdSpellName = C_Spell.GetSpellName(spellID)
    local spellNameList = { cdSpellName }
    tAppendAll(spellNameList, AuraMapByName[cdSpellName] or {})
    for _, spellName in ipairs(spellNameList) do
        local button = FindActionButtonForSpellName(spellName)
        if button then
            table.insert(buttonList, button)
        end
    end
    return buttonList
end

-- =========================================================
-- 更新逻辑（逐函数对齐 CDMButtonAurasControllerMixin）
-- =========================================================
-- 对齐 UpdateFromAura：跳过 secret spellId 与不可施加光环；找到按钮 → SetAura + Update
local function UpdateFromAura(unit, auraData)
    if not (issecretvalue and issecretvalue(auraData.spellId)) and auraData.canApplyAura then
        local buttonList = GetActionButtonList(auraData.spellId)
        for _, button in ipairs(buttonList) do
            local overlay = GetOverlay(button)
            SetAura(overlay, unit, auraData.auraInstanceID)
            UpdateOverlay(overlay)
        end
    end
end

-- 对齐 UpdateFromPlayerAuras：直接遍历 player 增益（HELPFUL），不依赖 CDM 节流 → 即时显示
local function UpdateFromPlayerAuras()
    if not AuraUtil or not AuraUtil.ForEachAura then return end
    AuraUtil.ForEachAura('player', 'HELPFUL', nil, function (auraData)
        UpdateFromAura('player', auraData)
    end, true)
end

-- 对齐 UpdateFromItem：只用 cdInfo.spellID 找按钮；把帧当前的
-- (auraDataUnit, auraInstanceID) 存到覆盖层并立即 Update（零延迟，与 CDM 同款实时性）
local function UpdateFromItem(item)
    if not item or not item.cooldownID then return end
    if not C_CooldownViewer or not C_CooldownViewer.GetCooldownViewerCooldownInfo then return end
    local cdInfo = C_CooldownViewer.GetCooldownViewerCooldownInfo(item.cooldownID)
    if cdInfo and cdInfo.spellID then
        D(("UpdateFromItem cd=%s spell=%s unit=%s inst=%s")
            :format(tostring(item.cooldownID), tostring(cdInfo.spellID),
                    tostring(item.auraDataUnit), tostring(item.auraInstanceID)))
        local buttonList = GetActionButtonList(cdInfo.spellID)
        for _, button in ipairs(buttonList) do
            local overlay = GetOverlay(button)
            SetAura(overlay, item.auraDataUnit, item.auraInstanceID)
            UpdateOverlay(overlay)
        end
    end
end

-- 对齐 UpdateFromViewer：遍历查看器当前所有帧，逐帧 UpdateFromItem
local function UpdateFromViewer(viewer)
    if not viewer or not viewer.GetItemFrames then return end
    local ok, frames = pcall(viewer.GetItemFrames, viewer)
    if ok and frames then
        for _, itemFrame in ipairs(frames) do
            if itemFrame.cooldownID then
                UpdateFromItem(itemFrame)
            end
        end
    end
end

-- 对齐 HookViewerItem：hook 每个 item 的 RefreshData → 驱动对应按钮更新（独立标记避免与
-- CDMButtonAuras 的 __CDMBAHooked 冲突）
local function HookViewerItem(item)
    if not item or item.__BARAutoCDMHooked then return end
    item.__BARAutoCDMHooked = true
    D("Hook " .. (item:GetName() or (tostring(item):gsub("table", "item"))))
    hooksecurefunc(item, "RefreshData", function()
        if AutoCDM.IsEnabled() then UpdateFromItem(item) end
    end)
end

-- 对齐 RefreshAllOverlays：先清空所有覆盖层，再重扫两个查看器 + player 增益，最后统一 Update
local function RefreshAllOverlays()
    D("RefreshAll")
    for _, overlay in pairs(overlays) do
        SetAura(overlay, nil, nil)
    end
    for _, viewerName in ipairs(VIEWER_NAMES) do
        UpdateFromViewer(_G[viewerName])
    end
    UpdateFromPlayerAuras()
    for _, overlay in pairs(overlays) do
        UpdateOverlay(overlay)
    end
end

-- =========================================================
-- hook 安装 + 事件（对齐 CDMButtonAurasControllerMixin:Initialize / OnEvent）
-- =========================================================
local evFrame          -- 前向声明（实际赋值见文件末尾的事件帧区块）
local hookedViewers = {}

local function InstallHooks()
    if not C_CooldownViewer or not C_CooldownViewer.GetCooldownViewerCooldownInfo then return end
    for _, viewerName in ipairs(VIEWER_NAMES) do
        if not hookedViewers[viewerName] then
            local v = _G[viewerName]
            if v and v.OnAcquireItemFrame then
                hooksecurefunc(v, "OnAcquireItemFrame", function(_, f)
                    if not AutoCDM.IsEnabled() then return end
                    if f then
                        D("Acquire " .. (f:GetName() or tostring(f)))
                        HookViewerItem(f)
                    end
                end)
                hookedViewers[viewerName] = true
            end
        end
    end
end

-- 对齐 Initialize：hook 两个查看器的 OnAcquireItemFrame，注册 ACTIONBAR_SLOT_CHANGED + UNIT_AURA(player)
local function Initialize()
    InstallHooks()
    evFrame:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
    evFrame:RegisterUnitEvent("UNIT_AURA", "player")
end

-- =========================================================
-- 启用开关（存盘于 ButtonAurasRebornDB.autoCDM.enabled，默认开启）
-- =========================================================
function AutoCDM.EnsureDB()
    ButtonAurasRebornDB = ButtonAurasRebornDB or {}
    ButtonAurasRebornDB.autoCDM = ButtonAurasRebornDB.autoCDM or {}
    if ButtonAurasRebornDB.autoCDM.enabled == nil then
        ButtonAurasRebornDB.autoCDM.enabled = true
    end
end

function AutoCDM.IsEnabled()
    return ButtonAurasRebornDB and ButtonAurasRebornDB.autoCDM
        and ButtonAurasRebornDB.autoCDM.enabled ~= false
end

function AutoCDM.SetEnabled(v)
    AutoCDM.EnsureDB()
    ButtonAurasRebornDB.autoCDM.enabled = v
    if v then
        RefreshAllOverlays()
    else
        for _, ov in pairs(overlays) do ov:Hide() end
    end
end

-- 供外部（配置面板 / Core）触发的全量刷新入口
function AutoCDM.RefreshAll()
    if AutoCDM.IsEnabled() then
        RefreshAllOverlays()
    else
        for _, ov in pairs(overlays) do ov:Hide() end
    end
end

-- =========================================================
-- 独立事件帧（与 Core/Overlay 的事件处理完全分离）
-- =========================================================
evFrame = CreateFrame("Frame")  -- 赋值给前面前向声明的同一 upvalue（勿加 local，否则会新建遮蔽变量）
-- 对齐 CDMButtonAuras：仅 PLAYER_LOGIN 注册；OnEvent 内再按需要在 Initialize 注册其余事件。
-- 不注册 PLAYER_ENTERING_WORLD / PLAYER_TARGET_CHANGED / PLAYER_REGEN_*（与 CDM 一致）。
evFrame:RegisterEvent("PLAYER_LOGIN")

evFrame:SetScript("OnEvent", function(_, event)
    AutoCDM.EnsureDB()

    if event == "PLAYER_LOGIN" then
        Initialize()
    elseif event == "ACTIONBAR_SLOT_CHANGED" then
        if AutoCDM.IsEnabled() then RefreshAllOverlays() end
    elseif event == "UNIT_AURA" then
        if AutoCDM.IsEnabled() then RefreshAllOverlays() end
    end
end)
