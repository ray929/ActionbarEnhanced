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
--
-- ⚠️ 独立数据回退路径（v2 新增）：
--   · 某些长时间 buff（如真言术韧 spellID 21562）不在暴雪 CDM 追踪集里，
--     但确实存在于玩家身上且需要在动作条上显示持续时间。
--   · 对这类 buff，本模块提供 extraTracked 回退：用 C_UnitAuras.GetAuraDataBySpellID
--     从玩家身上直接读取 auraInstanceID，再走同一套安全 API 渲染。
--   · 由 UNIT_AURA 事件驱动更新（因为 CDM 不追踪 → 无 viewerItem → 无 RefreshData hook）。

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
local autoOverlays = {}   -- [button] = { button, cd, stackText, container, viewerItem | unit, auraInstanceID }

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
-- 战斗安全刷新：两条路径合一
-- =========================================================
-- 路径 A（CDM viewerItem）：读取 frame.auraDataUnit / frame.auraInstanceID，按归属上色
-- 路径 B（独立回退）：读取 ov.unit / ov.auraInstanceID，固定为自己的增益（player 单位）
-- 两条路径使用完全相同的安全 API（GetAuraDuration + GetAuraApplicationDisplayCount）
local function UpdateOverlay(ov)
    -- 确定数据来源：viewerItem 优先（CDM 路径），否则走独立回退路径
    local item = ov.viewerItem
    local unit, auraInstanceID, isMine

    if item and item.auraDataUnit and item.auraInstanceID then
        -- 路径 A：CDM viewerItem 数据
        unit = item.auraDataUnit
        auraInstanceID = item.auraInstanceID
        isMine = (unit == "player")
    elseif ov.unit and ov.auraInstanceID then
        -- 路径 B：独立回退数据（extraTracked）
        unit = ov.unit
        auraInstanceID = ov.auraInstanceID
        isMine = true  -- extraTracked 只追踪玩家自身光环
    else
        ov.cd:Hide(); ov.stackText:Hide(); ov.container:Hide()
        return
    end

    -- 可见性：GetRect 守卫（只读，不污染安全帧），不可见则隐藏
    if not PositionOverlay(ov) then
        ov.cd:Hide(); ov.stackText:Hide(); ov.container:Hide()
        return
    end
    ov.container:Show()

    local timeColor = isMine and OWN_TIME_COLOR or OTHER_TIME_COLOR

    -- 时间：GetAuraDuration → DurationObject → SetCooldownFromDurationObject（addon 不读 secret 数字）
    local ok, durObj = pcall(C_UnitAuras.GetAuraDuration, unit, auraInstanceID)
    if ok and durObj then
        ov.cd:SetCooldownFromDurationObject(durObj, true)
        ov.cd:Show()
        StyleCountdown(ov.cd, timeColor)  -- 上色（绿/红）+ 硬代码字号 + 重描边
    else
        ov.cd:Hide()
    end

    -- 层数：GetAuraApplicationDisplayCount（非 secret 访问器），>1 才显示
    local showStack, stackVal = false, nil
    local okC, cnt = pcall(C_UnitAuras.GetAuraApplicationDisplayCount, unit, auraInstanceID)
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

-- =========================================================
-- 路径 A：CDM 自动发现（原版 CDMButtonAuras 核心逻辑）
-- =========================================================
-- 对每个 CDM item：收集候选 spellID（spellID + overrideSpellID + linkedSpellIDs）→ 取名字
-- → 找自然按钮 → 建/更新覆盖层。对齐 CDMButtonAuras 的多名字匹配。
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
        -- 清除回退标记（CDM 有数据时优先用 CDM 路径）
        ov.unit = nil
        ov.auraInstanceID = nil
        ov.extraTracked = nil
        UpdateOverlay(ov)
    end
end

-- =========================================================
-- 路径 B：独立数据回退（v2 新增 —— 解决真言术韧等"不在 CDM 追踪集但需显示"的 buff）
-- =========================================================
-- 原理：某些长时间 buff（如真言术韧 21562）不在暴雪 CDM 的追踪集里，
-- 所以不会有 viewerItem → 路径 A 永远拿不到数据。
-- 回退方式：直接用 C_UnitAuras.GetAuraDataBySpellID 从玩家身上读该 spellID 的光环，
-- 取出 auraInstanceID（非 secret 标识符），再走同一套安全 API 渲染。
-- ⚠️ 安全约束：
--   · GetAuraDataBySpellID 返回值可能含 secret 字段，我们【只】取 auraInstanceID 数字
--   · 不对其返回值做任何比较/算术操作（避免 taint）
--   · 后续渲染仍用已验证的安全 API（GetAuraDuration → DurationObject 等）
--   · 仅在非战斗时建立初始链接（UNIT_AURA 事件在战斗中也安全触发，但初始化避开战斗）

-- 额外追踪表：[spellID] = true（存盘于 ButtonAurasRebornDB.autoCDM.extraTracked）
local extraTrackedCache = {}  -- 运行时缓存：[spellID] = { unit, auraInstanceID }

function AutoCDM.GetExtraTracked()
    AutoCDM.EnsureDB()
    return ButtonAurasRebornDB.autoCDM.extraTracked or {}
end

function AutoCDM.AddExtraTracked(spellID)
    AutoCDM.EnsureDB()
    ButtonAurasRebornDB.autoCDM.extraTracked = ButtonAurasRebornDB.autoCDM.extraTracked or {}
    ButtonAurasRebornDB.autoCDM.extraTracked[spellID] = true
    extraTrackedCache[spellID] = nil  -- 清缓存强制下次 RefreshAll 重新查询
end

function AutoCDM.RemoveExtraTracked(spellID)
    AutoCDM.EnsureDB()
    if ButtonAurasRebornDB.autoCDM.extraTracked then
        ButtonAurasRebornDB.autoCDM.extraTracked[spellID] = nil
    end
    extraTrackedCache[spellID] = nil
end

-- 由 spellID 尝试从玩家身上获取光环数据（回退路径的核心）。
-- 返回 (unit, auraInstanceID) 或 (nil, nil)。
-- ⚠️ 只在非战斗或安全上下文中调用（避免 taint）。
-- 两步查找：
--   1. GetAuraDataBySpellID 精确匹配 spellID（最快）
--   2. 若失败，按 spellName 遍历玩家增益找名字匹配的
--      （处理"基础 spellID ≠ 玩家身上实际光环 spellID"的情况，
--       如真言术韧 21562 是基础法术 ID，玩家身上的实际光环可能用 override/变体 ID）
-- spellName 可选；提供时启用名字回退查找。
local function QueryPlayerAura(spellID, spellName)
    -- 步骤 1：spellID 精确匹配（战斗安全，GetAuraDataBySpellID 不涉及 secret 比较）
    local ok, data = pcall(C_UnitAuras.GetAuraDataBySpellID, "player", spellID)
    if ok and data then
        local instanceID = data.auraInstanceID
        if instanceID then
            return "player", instanceID
        end
    end

    -- 步骤 2：按名字遍历玩家增益回退查找
    -- ⚠️ 战斗中不执行！GetAuraDataByIndex 返回的 aura.name 是 secret string，
    --    在战斗中做 == 比较会报 "attempt to compare field 'name' (a secret string value)" taint 错误。
    --    长时间 buff（如真言术韧 1 小时）的 auraInstanceID 在整个生命周期内固定，
    --    战斗中用脱战时建立的映射即可，UpdateOverlay 仍走安全的 GetAuraDuration/GetAuraApplicationDisplayCount。
    if not spellName or InCombatLockdown() then return nil, nil end
    local i = 1
    while true do
        local okI, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
        if not okI or not aura then break end
        -- 只比较 name 字符串（非战斗时安全）
        if aura.name and aura.name == spellName then
            if aura.auraInstanceID then
                return "player", aura.auraInstanceID
            end
        end
        i = i + 1
        if i > 40 then break end  -- 安全上限
    end
    return nil, nil
end

-- 为一个额外追踪的 spellID 创建/更新 overlay。
-- 流程：spellID → 法术名 → 匹配动作条按钮 → 查询玩家光环 → 建/更 overlay
local function UpdateExtraTracked(spellID)
    if not spellID or spellID <= 0 then return end

    -- 先取法术名
    local okN, spellName = pcall(C_Spell.GetSpellName, spellID)
    if not okN or not spellName then return end

    -- 匹配按钮
    local buttons = FindActionButtonsForSpellName(spellName)
    if #buttons == 0 then return end

    -- 查询玩家身上的光环数据（回退路径：先 spellID 精确匹配，失败则按名字遍历查找）
    local unit, instanceID = QueryPlayerAura(spellID, spellName)
    if not unit or not instanceID then
        -- 玩家身上暂时没有这个 buff → 隐藏已有 overlay（不清除，等下次 UNIT_AURA 再试）
        for _, btn in ipairs(buttons) do
            local ov = autoOverlays[btn]
            if ov and ov.extraTracked then
                ov.cd:Hide(); ov.stackText:Hide(); ov.container:Hide()
            end
        end
        return
    end

    -- 为每个匹配按钮创建/更新 overlay（走回退路径）
    for _, btn in ipairs(buttons) do
        local ov = autoOverlays[btn]
        if not ov then
            local cd, stack, container = CreateAuraDisplay()
            ov = {
                button = btn,
                cd = cd,
                stackText = stack,
                container = container,
                viewerItem = nil,       -- 路径 B 不用 viewerItem
                unit = unit,
                auraInstanceID = instanceID,
                extraTracked = true,     -- 标记为回退路径
                extraSpellID = spellID,  -- 记录原始 spellID（用于去重）
            }
            autoOverlays[btn] = ov
            cd:SetScript("OnCooldownDone", function() UpdateOverlay(ov) end)
        else
            -- 已有 overlay：若当前由 CDM 路径 A 管理（有 viewerItem），不覆盖（CDM 优先）
            if ov.viewerItem then return end
            -- 否则更新回退数据
            ov.unit = unit
            ov.auraInstanceID = instanceID
            ov.extraTracked = true
            ov.extraSpellID = spellID
        end
        UpdateOverlay(ov)
    end
end

-- 刷新所有额外追踪的 buff（由 RefreshAll 和 UNIT_AURA 事件调用）
local function RefreshAllExtraTracked()
    if not AutoCDM.IsEnabled() then return end
    local tracked = AutoCDM.GetExtraTracked()
    for spellID, _ in pairs(tracked) do
        UpdateExtraTracked(spellID)
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
-- 调试开关：/run ButtonAurasReborn.AutoCDM.debugAcquire = true
-- 开启后每次 OnAcquireItemFrame 都打印 item 的关键字段，验证"OnAcquire 是否对所有 buff 触发"
AutoCDM.debugAcquire = false

local function InstallHooks()
    if not C_CooldownViewer or not C_CooldownViewer.GetCooldownViewerCooldownInfo then return end
    for _, viewerName in ipairs(VIEWER_NAMES) do
        if not hookedViewers[viewerName] then
            local v = _G[viewerName]
            if v and v.OnAcquireItemFrame then
                hooksecurefunc(v, "OnAcquireItemFrame", function(_, f)
                    if not AutoCDM.IsEnabled() then return end
                    -- 调试输出：验证 OnAcquireItemFrame 是否对所有 buff 触发（不只是追踪集）
                    if AutoCDM.debugAcquire and f then
                        local cdID = f.cooldownID or "?"
                        local unit = f.auraDataUnit or "?"
                        local inst = f.auraInstanceID or "?"
                        local spName = "?"
                        if f.cooldownID then
                            local okI, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, f.cooldownID)
                            if okI and info and info.spellID then
                                local okN, nm = pcall(C_Spell.GetSpellName, info.spellID)
                                if okN and nm then spName = nm end
                            end
                        end
                        print("|cff00ccff[Acquire]|r cdID=" .. tostring(cdID)
                            .. " unit=" .. tostring(unit)
                            .. " inst=" .. tostring(inst)
                            .. " spell=" .. spName)
                    end
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
    -- 预置常见的不在 CDM 追踪集但需显示的长时间 buff（用户可自行增删）
    ButtonAurasRebornDB.autoCDM.extraTracked = ButtonAurasRebornDB.autoCDM.extraTracked or {}
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

-- 一次性重新同步所有覆盖层（增量同步，不清空现有数据源）：
--   1. 路径 A：重扫两个 CDM viewer 的当前帧（UpdateFromItem 会设置 viewerItem）
--   2. 路径 B：重扫 extraTracked 列表
--   3. 只隐藏本次扫描没有被更新的 CDM overlay（CDM 已不再追踪的 buff）
-- ⚠️ 不清空现有 viewerItem 再重建（那样会打断 RefreshData hook 的实时性，导致延迟）
function AutoCDM.RefreshAll()
    if not AutoCDM.IsEnabled() then
        for _, ov in pairs(autoOverlays) do
            ov.viewerItem = nil; ov.unit = nil; ov.auraInstanceID = nil
            ov.cd:Hide(); ov.stackText:Hide(); ov.container:Hide()
        end
        return
    end

    -- 记录本次扫描发现的 CDM button 集合（用于后续清理过期 overlay）
    local seenCDMButtons = {}

    -- 路径 A：CDM 自动发现（UpdateFromItem 会设置 ov.viewerItem）
    for _, viewerName in ipairs(VIEWER_NAMES) do
        local viewer = _G[viewerName]
        if viewer and viewer.GetItemFrames then
            local ok, frames = pcall(viewer.GetItemFrames, viewer)
            if ok and frames then
                for _, f in ipairs(frames) do
                    if f.cooldownID then
                        UpdateFromItem(f)
                        -- 记录哪些 button 被本次扫描更新了
                        -- UpdateFromItem 内部会匹配按钮并设置 viewerItem
                        -- 这里简单标记：遍历 autoOverlays 找有 viewerItem==f 的
                    end
                end
            end
        end
    end

    -- 标记本次扫描中被更新的 overlay（有 viewerItem 且 viewerItem 仍有效的）
    for _, ov in pairs(autoOverlays) do
        if ov.viewerItem then
            -- 检查 viewerItem 是否还在当前 CDM frames 里
            local stillValid = false
            for _, viewerName in ipairs(VIEWER_NAMES) do
                local viewer = _G[viewerName]
                if viewer and viewer.GetItemFrames then
                    local ok, frames = pcall(viewer.GetItemFrames, viewer)
                    if ok and frames then
                        for _, f in ipairs(frames) do
                            if f == ov.viewerItem then
                                stillValid = true
                                break
                            end
                        end
                    end
                end
                if stillValid then break end
            end
            if not stillValid then
                ov.viewerItem = nil
                ov.cd:Hide(); ov.stackText:Hide(); ov.container:Hide()
            end
        end
    end

    -- 路径 B：额外追踪回退
    RefreshAllExtraTracked()

    -- 重新定位所有有数据源的 overlay（按钮可能移动了）
    for _, ov in pairs(autoOverlays) do
        if ov.viewerItem or (ov.extraTracked and ov.auraInstanceID) then
            if not PositionOverlay(ov) then
                ov.cd:Hide(); ov.stackText:Hide(); ov.container:Hide()
            end
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
evFrame:RegisterEvent("UNIT_AURA")  -- v2 新增：驱动 extraTracked 回退路径的更新

-- UNIT_AURA 防抖标志（避免战斗中频繁遍历光环）
local auraUpdatePending = false

evFrame:SetScript("OnEvent", function(_, event, arg1)
    AutoCDM.EnsureDB()
    InstallHooks()

    if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        -- 延迟两次，覆盖加载后 CDM 布局变化
        C_Timer.After(0.5, function() InstallHooks(); AutoCDM.RefreshAll() end)
        C_Timer.After(2.0, function() InstallHooks(); AutoCDM.RefreshAll() end)
    elseif event == "ACTIONBAR_SLOT_CHANGED" then
        -- ⚠️ 只重新定位 overlay（按钮可能移动了位置），不清空数据源！
        -- 清空数据源会打断 RefreshData hook 的实时性 → 显示延迟
        -- RefreshData hook 仍然实时驱动时间/层数更新
        for _, ov in pairs(autoOverlays) do
            if ov.viewerItem or (ov.extraTracked and ov.auraInstanceID) then
                if not PositionOverlay(ov) then
                    ov.cd:Hide(); ov.stackText:Hide(); ov.container:Hide()
                end
            end
        end
    elseif event == "UNIT_AURA" then
        -- 只响应玩家自身的光环变化，加 0.5 秒防抖避免战斗中频繁遍历
        -- ⚠️ 战斗中不触发名字遍历（aura.name 是 secret string，比较会 taint）
        --    战斗中 extraTracked overlay 靠已建立的 auraInstanceID + GetAuraDuration 安全更新
        if arg1 == "player" and not auraUpdatePending and not InCombatLockdown() then
            auraUpdatePending = true
            C_Timer.After(0.5, function()
                auraUpdatePending = false
                if not InCombatLockdown() then
                    RefreshAllExtraTracked()
                end
            end)
        end
    else
        -- 进出战斗：立即重新同步（不延迟，避免战斗开始时 overlay 丢失）
        AutoCDM.RefreshAll()
    end
end)

-- =========================================================
-- 诊断：打印每个 viewer 的帧数 + extraTracked 状态
-- =========================================================
-- 重载后若某 buff 不显示，聊天框执行：/run ButtonAurasReborn.AutoCDM.DebugPrint()
function AutoCDM.DebugPrint()
    print("|cff00ccff[AutoCDM]|r === 诊断开始（启动" .. (AutoCDM.IsEnabled() and "启用" or "禁用") .. "）===")

    -- 路径 A：CDM viewer 状态
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
                            print("    [CDM] cdID=" .. tostring(f.cooldownID)
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

    -- 路径 B：extraTracked 状态
    local tracked = AutoCDM.GetExtraTracked()
    local count = 0
    for spellID, _ in pairs(tracked) do
        count = count + 1
    end
    print("  [ExtraTracked] 追踪数量=" .. count)
    for spellID, _ in pairs(tracked) do
        local okN, name = pcall(C_Spell.GetSpellName, spellID)
        local nameStr = (okN and name) or "?"
        local unit, instID = QueryPlayerAura(spellID, nameStr)
        local buttons = FindActionButtonsForSpellName(nameStr)
        local status = "未找到"
        if unit and instID then
            status = string.format("有数据(unit=%s,instance=%d)", tostring(unit), instID or 0)
        end
        print("    [Extra] spellID=" .. tostring(spellID)
            .. " name=" .. nameStr
            .. " btns=" .. #buttons
            .. " " .. status)
    end

    -- overlay 汇总
    local totalOv = 0
    local cdmOv = 0
    local extOv = 0
    for _, ov in pairs(autoOverlays) do
        totalOv = totalOv + 1
        if ov.viewerItem then cdmOv = cdmOv + 1 end
        if ov.extraTracked then extOv = extOv + 1 end
    end
    print("  [汇总] overlay总数=" .. totalOv .. " CDM路径=" .. cdmOv .. " Extra路径=" .. extOv)

    print("|cff00ccff[AutoCDM]|r === 诊断结束 ===")
end
