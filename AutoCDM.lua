-- ButtonAurasReborn/AutoCDM.lua
-- 独立模块：完整移植 CDMButtonAuras 的【自动发现】能力（无需手动绑定，自动显示 CDM 追踪的全部增益），
-- 并用我们自己的文字样式渲染（按归属上色：自己的绿 / 别人的红 / 层数黄）。
--
-- ⚠️ 与 Overlay.lua（手动绑定系统）【完全分离】：
--   · 独立的状态表（autoOverlays），绝不碰 Overlay.lua 的 overlays 表；
--   · 独立的 CDM hook（OnAcquireItemFrame + 每个 item 的 RefreshData）；
--   · 独立的事件帧与刷新逻辑；
--   · 独立的样式常量（时间按归属绿/红、层数黄）。
-- 本文件不修改 Core.lua / Overlay.lua / Options.lua 的任何现有逻辑，避免交叉污染导致的"奇怪 bug"。
--
-- ⚠️ 战斗安全（与 Overlay.lua 同款、已验证）：
--   · 覆盖层 = 纯 UIParent 容器 + GetRect 屏幕坐标绝对定位，与动作按钮【零锚依赖】（不 SetPoint 到按钮）；
--   · 时间用 GetAuraDuration 返回的 DurationObject 交给 Cooldown 控件（addon 不读 secret 数字）；
--   · 层数用 GetAuraApplicationDisplayCount（非 secret 访问器）直接 SetText；
--   · 归属判断用 frame.auraDataUnit == 'player'（CDMButtonAuras 同款做法），绝不读 secret 字段。

local BAR = ButtonAurasReborn
if not BAR then return end

local AutoCDM = {}
BAR.AutoCDM = AutoCDM

-- =========================================================
-- 样式常量（本模块独立使用，与手动绑定系统的 F0FF00/00FDFF 区分开，方便识别两套系统）
-- =========================================================
local FONT = STANDARD_TEXT_FONT
local FONT_SIZE = 20            -- 字号硬代码写死
local THICK = "THICKOUTLINE"
local OWN_TIME_COLOR   = { 0.30, 1.00, 0.30 }   -- 自己的增益：绿
local OTHER_TIME_COLOR = { 1.00, 0.30, 0.30 }   -- 别人的增益：红
local STACK_COLOR      = { 1.00, 1.00, 0.00 }   -- 层数：黄 (F0FF00)

-- 本模块独立的状态（绝不碰 Overlay.lua 的 overlays 表）
-- 以按钮对象为 key（一个按钮对应一个自然技能，即一个被追踪增益）
local autoOverlays = {}   -- [button] = { button, cd, stackText, container, viewerItem }

-- CDM 两个查看器（本模块本地常量，保持独立、不依赖 Core 的 VIEWER_NAMES）
local VIEWER_NAMES = { "BuffIconCooldownViewer", "BuffBarCooldownViewer" }

-- =========================================================
-- 战斗安全定位（从 Overlay.lua 验证过的逻辑原样搬入，本模块独立副本）
-- 容器只挂 UIParent，位置用 btn:GetRect() 读屏幕坐标再相对 UIParent 原点绝对摆放；
-- 容器与按钮之间无任何"锚依赖"，taint 无处传播 → 战斗中不会被 combat-lockdown 隐藏。
-- ⚠️ 缩放换算：GetRect() 返回按钮自身有效缩放坐标系的值，容器挂 UIParent 用 UIParent 有效缩放，
--    两者不同需乘换算比 r = 按钮有效缩放 / UIParent 有效缩放。
-- 返回 true 表示按钮当前可见（已定位），false 表示不可见（调用方应隐藏）。
-- =========================================================
local function PositionOverlay(ov)
    if not ov or not ov.button or not ov.container then return false end
    local btn = ov.button
    local left, bottom, width, height = btn:GetRect()
    if not left then return false end  -- 按钮不可见（载具/御空术切换等）→ 不重定位
    local r = 1
    local bs, ps = btn:GetEffectiveScale(), UIParent:GetEffectiveScale()
    if bs and ps and ps > 0 then r = bs / ps end
    local cw, ch = width * r, height * r
    ov.container:ClearAllPoints()
    ov.container:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left * r, (bottom + height) * r)
    ov.container:SetSize(cw, ch)
    -- 计时数字落在按钮【左下】区域：cd 占容器左下 62%（数字居中 → 视觉贴左下）
    if ov.cd then
        ov.cd:ClearAllPoints()
        ov.cd:SetPoint("BOTTOMLEFT", ov.container, "BOTTOMLEFT", 1, 1)
        ov.cd:SetPoint("TOPRIGHT", ov.container, "BOTTOMLEFT", cw * 0.62, ch * 0.62)
    end
    return true
end

-- 给 Cooldown 内置倒计时数字上字体/颜色（与 Overlay.lua 同款做法）。
-- cd:GetCountdownFontString() 拿到内置 FontString，直接 SetFont + SetTextColor。
-- 该 FontString 要等冷却真正运行后才存在，故每次更新后调一次（幂等、廉价）。
local function StyleCountdown(cd, color)
    local fs = cd.GetCountdownFontString and cd:GetCountdownFontString()
    if not fs then return end
    fs:SetFont(FONT, FONT_SIZE, THICK)
    fs:SetTextColor(color[1], color[2], color[3])
end

-- 创建一个"计时器(Cooldown) + 层数(FontString)"显示单元（纯 UIParent 中立容器，零锚依赖）。
local function CreateAuraDisplay()
    local container = CreateFrame("Frame", nil, UIParent)
    container:SetFrameStrata("HIGH")
    container:SetFrameLevel(1000)
    container:SetSize(36, 36)  -- 临时尺寸，首次 PositionOverlay 时按按钮真实尺寸重设

    local cd = CreateFrame("Cooldown", nil, container, "CooldownFrameTemplate")
    cd:SetDrawSwipe(false)
    cd:SetDrawEdge(false)
    if cd.SetHideCountdownNumbers then cd:SetHideCountdownNumbers(false) end
    if cd.SetCountdownAbbrevThreshold then cd:SetCountdownAbbrevThreshold(60) end
    cd:Hide()

    local stack = container:CreateFontString(nil, "OVERLAY")
    stack:SetFont(FONT, FONT_SIZE, THICK)
    stack:SetTextColor(STACK_COLOR[1], STACK_COLOR[2], STACK_COLOR[3])
    stack:SetPoint("TOPLEFT", container, "TOPLEFT", 2, -2)  -- 层数显示在【左上】
    stack:SetJustifyH("LEFT")
    stack:Hide()

    return cd, stack, container
end

-- =========================================================
-- 自动发现：找"当前放了某技能"的原生动作按钮（移植自 CDMButtonAuras）
-- =========================================================
-- 由一组候选法术【名】遍历所有原生动作条按钮，用 GetActionInfo 拿到按钮上的技能，
-- 比对法术名（名称等价，自动处理 linked/override 法术）。返回【所有】匹配的按钮
-- （一个法术可能同时出现在多个动作条上，每个按钮都挂覆盖层，与 CDMButtonAuras 一致）。
-- names 可为字符串或字符串数组；任一名字命中即视为匹配（对齐 CDMButtonAuras
-- GetActionButtonList 的"多名字匹配"思路，避免漏掉真言术韧这类护甲/祝福类——
-- 其 info 的 overrideSpellID/linkedSpellIDs 与 spellID 指向不同名字）。
-- 注意：按钮端【直接】用 C_Spell.GetSpellName(actionSpellID) 取名字（不做 GetBaseSpell 重定向），
-- 与 UpdateFromItem 收集候选名字时用的 GetSpellName(id) 完全对称。
-- 若此处走 GetBaseSpell，会把"真言术韧(21562)"之类有 base-spell 重定向的法术重定向成异名的基础法术，
-- 导致与候选名字（直接 GetSpellName(21562)="真言术韧"）对不上 → 护甲/祝福类不显示（战斗 buff 无重定向故正常）。
local function FindActionButtonsForSpellName(names)
    local result = {}
    if not names then return result end
    if type(names) == "string" then names = { names } end
    local nameSet = {}
    for _, n in ipairs(names) do nameSet[n] = true end
    local btnNames = (BAR.GetActionBarButtonNames and BAR.GetActionBarButtonNames()) or {}
    for _, btnName in ipairs(btnNames) do
        local btn = _G[btnName]
        if btn and btn.action then
            local _, actionSpellID = GetActionInfo(btn.action)
            if actionSpellID and actionSpellID > 0 then
                local okN, actionSpellName = pcall(C_Spell.GetSpellName, actionSpellID)
                if okN and actionSpellName and nameSet[actionSpellName] then
                    result[#result + 1] = btn
                end
            end
        end
    end
    return result
end

-- =========================================================
-- 战斗安全刷新：读取 frame.auraDataUnit / frame.auraInstanceID，按归属上色
-- =========================================================
local function UpdateOverlay(ov)
    local item = ov.viewerItem
    if not item or not item.auraDataUnit or not item.auraInstanceID then
        ov.cd:Hide(); ov.stackText:Hide(); ov.container:Hide()
        return
    end
    -- 可见性：GetRect 守卫（只读，不污染安全帧），不可见则隐藏
    if not PositionOverlay(ov) then
        ov.cd:Hide(); ov.stackText:Hide(); ov.container:Hide()
        return
    end
    ov.container:Show()

    -- 归属判断：auraDataUnit == 'player' 即自己的增益（CDMButtonAuras 同款做法）
    local unit = item.auraDataUnit
    local isMine = (unit == "player")
    local timeColor = isMine and OWN_TIME_COLOR or OTHER_TIME_COLOR

    -- 时间：GetAuraDuration → DurationObject → SetCooldownFromDurationObject（addon 不读 secret 数字）
    local ok, durObj = pcall(C_UnitAuras.GetAuraDuration, unit, item.auraInstanceID)
    if ok and durObj then
        ov.cd:SetCooldownFromDurationObject(durObj, true)
        ov.cd:Show()
        StyleCountdown(ov.cd, timeColor)  -- 上色（绿/红）+ 硬代码字号 + 重描边
    else
        ov.cd:Hide()
    end

    -- 层数：GetAuraApplicationDisplayCount（非 secret 访问器），>1 才显示
    local showStack, stackVal = false, nil
    local okC, cnt = pcall(C_UnitAuras.GetAuraApplicationDisplayCount, unit, item.auraInstanceID)
    if okC and cnt ~= nil then
        local okN, n = pcall(function() return tonumber(cnt) end)
        if okN and n and n > 1 then
            showStack = true
            stackVal = cnt
        end
    end
    if showStack then
        ov.stackText:SetText(stackVal)
        ov.stackText:Show()
    else
        ov.stackText:Hide()
    end
end

-- 对每个 CDM item：收集候选 spellID（spellID + overrideSpellID + linkedSpellIDs）→ 取名字
-- → 找自然按钮 → 建/更新覆盖层。对齐 CDMButtonAuras 的多名字匹配，覆盖"护甲/祝福类
-- 法术的 override/linked 名字异于 spellID"的情形（如真言术韧），这是它们能显示的关键。
local function UpdateFromItem(item)
    if not item or not item.cooldownID then return end
    local ok, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, item.cooldownID)
    if not ok or not info then return end

    -- 收集所有候选 spellID（spellID + overrideSpellID + linkedSpellIDs），
    -- 任一对应名字能匹配到动作条按钮即显示。
    local ids = {}
    if info.spellID and info.spellID > 0 then ids[#ids + 1] = info.spellID end
    if info.overrideSpellID and info.overrideSpellID > 0 then ids[#ids + 1] = info.overrideSpellID end
    if info.linkedSpellIDs then
        for _, id in ipairs(info.linkedSpellIDs) do
            if id and id > 0 then ids[#ids + 1] = id end
        end
    end
    local candidates = {}
    for _, id in ipairs(ids) do
        local okN, nm = pcall(C_Spell.GetSpellName, id)
        if okN and nm then candidates[#candidates + 1] = nm end
    end
    if #candidates == 0 then return end

    local buttons = FindActionButtonsForSpellName(candidates)
    if #buttons == 0 then return end  -- 该技能不在任何原生动作条上 → 无按钮可挂

    for _, btn in ipairs(buttons) do
        local ov = autoOverlays[btn]
        if not ov then
            local cd, stack, container = CreateAuraDisplay()
            ov = { button = btn, cd = cd, stackText = stack, container = container, viewerItem = nil }
            autoOverlays[btn] = ov
            -- 倒计时归零时主动重刷（对齐 CDMButtonAuras 的 OnCooldownDone，补漏边缘 case）
            cd:SetScript("OnCooldownDone", function() UpdateOverlay(ov) end)
        end
        ov.viewerItem = item
        UpdateOverlay(ov)
    end
end

-- =========================================================
-- CDM hook（本模块独立，不与 Core/Overlay 的 hook 共享）
-- =========================================================
local function HookViewerItem(item)
    if not item or item.__AutoCDMHooked then return end
    item.__AutoCDMHooked = true
    hooksecurefunc(item, "RefreshData", function()
        if AutoCDM.IsEnabled() then UpdateFromItem(item) end
    end)
end

local hookedViewers = {}
local function InstallHooks()
    if not C_CooldownViewer or not C_CooldownViewer.GetCooldownViewerCooldownInfo then return end
    for _, viewerName in ipairs(VIEWER_NAMES) do
        if not hookedViewers[viewerName] then
            local v = _G[viewerName]
            if v and v.OnAcquireItemFrame then
                hooksecurefunc(v, "OnAcquireItemFrame", function(_, f)
                    if not AutoCDM.IsEnabled() then return end
                    if f and f.cooldownID then
                        HookViewerItem(f)
                        UpdateFromItem(f)
                    end
                end)
                hookedViewers[viewerName] = true
            end
        end
    end
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
    AutoCDM.RefreshAll()
end

-- 一次性重新同步所有自动覆盖层：登录 / 进场 / 切专精 / 动作条变动 / 进出战斗后调用。
-- 先清空所有 viewerItem，再重扫两个查看器的当前帧，最后隐藏没有 viewerItem 的覆盖层
-- （即 CDM 已不再追踪的 buff，避免残留）。关闭时则全部隐藏。
function AutoCDM.RefreshAll()
    if not AutoCDM.IsEnabled() then
        for _, ov in pairs(autoOverlays) do
            ov.viewerItem = nil
            ov.cd:Hide(); ov.stackText:Hide(); ov.container:Hide()
        end
        return
    end
    for _, ov in pairs(autoOverlays) do
        ov.viewerItem = nil
    end
    for _, viewerName in ipairs(VIEWER_NAMES) do
        local viewer = _G[viewerName]
        if viewer and viewer.GetItemFrames then
            local ok, frames = pcall(viewer.GetItemFrames, viewer)
            if ok and frames then
                for _, f in ipairs(frames) do
                    if f.cooldownID then UpdateFromItem(f) end
                end
            end
        end
    end
    -- 隐藏没有 viewerItem 的覆盖层（buff 不再被追踪）
    for _, ov in pairs(autoOverlays) do
        if not ov.viewerItem then
            ov.cd:Hide(); ov.stackText:Hide(); ov.container:Hide()
        end
    end
end

-- 供本模块 hook 调用（RefreshData 回调中）
function AutoCDM.OnItemRefresh(item)
    if not AutoCDM.IsEnabled() then return end
    UpdateFromItem(item)
end

-- =========================================================
-- 独立事件帧（与 Core/Overlay 的事件处理完全分离）
-- =========================================================
local evFrame = CreateFrame("Frame")
evFrame:RegisterEvent("PLAYER_LOGIN")
evFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
evFrame:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
evFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
evFrame:RegisterEvent("PLAYER_REGEN_DISABLED")

evFrame:SetScript("OnEvent", function(_, event)
    AutoCDM.EnsureDB()
    InstallHooks()
    if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        -- 延迟两次，覆盖加载后 CDM 布局变化
        C_Timer.After(0.5, function() InstallHooks(); AutoCDM.RefreshAll() end)
        C_Timer.After(2.0, function() InstallHooks(); AutoCDM.RefreshAll() end)
    elseif event == "ACTIONBAR_SLOT_CHANGED" then
        -- 动作条槽位变化（进出姿态/切换栏等）：重新同步
        C_Timer.After(0.1, function() AutoCDM.RefreshAll() end)
    else
        -- 进出战斗：重新同步一次（战斗中靠 RefreshData 实时驱动，此处补漏）
        C_Timer.After(0.1, function() AutoCDM.RefreshAll() end)
    end
end)

-- =========================================================
-- 诊断：打印每个 viewer 的帧数，以及每个 item 的候选 spellID/名字/匹配按钮数。
-- 重载后若某 buff 不显示，聊天框执行：/run ButtonAurasReborn.AutoCDM.DebugPrint()
-- 找到对应那一行，看 names 和 btns 数即可定位（btns=0 即没匹配到动作条按钮）。
-- 仅打印元数据，不读 secret 数字/aura 字段，安全可在战斗中调用。
-- =========================================================
function AutoCDM.DebugPrint()
    print("|cff00ccff[AutoCDM]|r === 诊断开始（启动" .. (AutoCDM.IsEnabled() and "启用" or "禁用") .. "）===")
    for _, viewerName in ipairs(VIEWER_NAMES) do
        local viewer = _G[viewerName]
        if viewer and viewer.GetItemFrames then
            local ok, frames = pcall(viewer.GetItemFrames, viewer)
            if ok and frames then
                print("  " .. viewerName .. ": 帧数=" .. #frames)
                local shown = 0
                for _, f in ipairs(frames) do
                    if f.cooldownID and shown < 60 then
                        shown = shown + 1
                        local okI, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, f.cooldownID)
                        if okI and info then
                            local ids = {}
                            if info.spellID and info.spellID > 0 then ids[#ids + 1] = info.spellID end
                            if info.overrideSpellID and info.overrideSpellID > 0 then ids[#ids + 1] = info.overrideSpellID end
                            if info.linkedSpellIDs then
                                for _, id in ipairs(info.linkedSpellIDs) do
                                    if id and id > 0 then ids[#ids + 1] = id end
                                end
                            end
                            local names = {}
                            for _, id in ipairs(ids) do
                                local okN, nm = pcall(C_Spell.GetSpellName, id)
                                if okN and nm then names[#names + 1] = nm end
                            end
                            local btns = FindActionButtonsForSpellName(names)
                            print("    cdID=" .. tostring(f.cooldownID)
                                .. " ids={" .. table.concat(ids, ",") .. "}"
                                .. " names={" .. table.concat(names, ",") .. "}"
                                .. " btns=" .. #btns)
                        end
                    end
                end
            else
                print("  " .. viewerName .. ": GetItemFrames 失败")
            end
        else
            print("  " .. viewerName .. ": 不存在")
        end
    end
    print("|cff00ccff[AutoCDM]|r === 诊断结束 ===")
end
