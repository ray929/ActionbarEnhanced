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
-- 样式常量（统一取自 Settings.lua，集中管理；与手动绑定系统配色不同，见 Settings.lua）
-- =========================================================
local S = BAR.Settings

-- 本模块独立的状态（绝不碰 Overlay.lua 的 overlays 表）
-- 以按钮对象为 key（一个按钮对应一个自然技能，即一个被追踪增益）
local autoOverlays = {}   -- [button] = { button, cd, stackText, container, viewerItem | unit, auraInstanceID }

-- CDM 两个查看器（本模块本地常量，保持独立、不依赖 Core 的 VIEWER_NAMES）
local VIEWER_NAMES = { "BuffIconCooldownViewer", "BuffBarCooldownViewer" }

-- ⚠️ 前向声明：避免 Lua 局部变量词法作用域导致的"前向引用 nil"崩溃。
-- ResolveAll(268) 会调用 RefreshAllExtraTracked(499)，后者又调用 UpdateExtraTracked(443)，
-- UpdateExtraTracked 再调用 QueryPlayerAura(409) —— 三者定义均在 ResolveAll 之后。
-- 用 local 声明占位后，下方用 `function X()`（不带 local）赋值即可被 ResolveAll 正确引用，
-- 调用发生时（运行时）三个函数早已赋值完毕。这是 Lua 处理前向引用的标准做法。
local QueryPlayerAura, UpdateExtraTracked, RefreshAllExtraTracked

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
        ov.cd:SetPoint("BOTTOMLEFT", ov.container, "BOTTOMLEFT", 1, -3)
        ov.cd:SetPoint("TOPRIGHT", ov.container, "BOTTOMLEFT", cw * 0.62, ch * 0.62 - 4)
    end
    return true
end

-- 给 Cooldown 内置倒计时数字上字体/颜色（与 Overlay.lua 同款做法）。
-- cd:GetCountdownFontString() 拿到内置 FontString，直接 SetFont + SetTextColor。
-- 该 FontString 要等冷却真正运行后才存在，故每次更新后调一次（幂等、廉价）。
local function StyleCountdown(cd, color)
    local fs = cd.GetCountdownFontString and cd:GetCountdownFontString()
    if not fs then return end
    fs:SetFont(S.FONT, S.FONT_SIZE, S.OUTLINE)
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
    stack:SetFont(S.FONT, S.FONT_SIZE, S.OUTLINE)
    stack:SetTextColor(S.AUTO_STACK_COLOR[1], S.AUTO_STACK_COLOR[2], S.AUTO_STACK_COLOR[3])
    stack:SetPoint("TOPLEFT", container, "TOPLEFT", 2, -2)  -- 层数显示在【左上】
    stack:SetJustifyH("LEFT")
    stack:Hide()

    return cd, stack, container
end

-- =========================================================
-- 自动发现：找"当前放了某技能"的原生动作按钮（移植自 CDMButtonAuras）
-- =========================================================
-- 由一组候选法术【名】从缓存索引里取匹配的按钮。返回【所有】匹配的按钮
-- （一个法术可能同时出现在多个动作条上，每个按钮都挂覆盖层，与 CDMButtonAuras 一致）。
-- names 可为字符串或字符串数组；任一名字命中即视为匹配（对齐 CDMButtonAuras
-- GetActionButtonList 的"多名字匹配"思路，避免漏掉真言术韧这类护甲/祝福类）。
--
-- ⚠️ 关键改造（修复"不同步/错误信息"）：
--   旧写法在 UpdateFromItem 里【逐个 CDM 帧】直接把 ov.viewerItem 指到该帧，并键控于按钮。
--   这有两个致命缺陷：
--     ① CDM 会把同一帧对象【复用】去显示别的 buff（多目标战斗频繁发生），
--        复用后旧按钮仍指向该帧 → 显示【新 buff 的错误信息】。
--     ② 同一法术在多目标时可能有【多个帧】（自己 + 各目标），每个帧的 RefreshData
--        都去覆盖同一按钮的 viewerItem → 谁最后刷新谁赢 → 显示【随机目标】的持续时间。
--   手动绑定系统（Overlay.lua）之所以正常，是因为它每次刷新都【按 spellID 实时重找】当前帧。
--   本模块改为：每次刷新走全局 ResolveAll()，重新判定"每个按钮当前该显示哪个帧"，
--   并对同名多帧【优先选 auraDataUnit=="player" 的帧】（玩家自身光环），结果确定且
--   与 CDM 图标（玩家自身那枚）一致。解析只读 frame.auraDataUnit / cooldownID 等安全字段，战斗安全。
--
-- 法术名索引（spellToButtons）缓存：避免每次解析都遍历全部按钮 + 调 GetSpellName。
-- 仅在动作条/专精变化时由 RebuildButtonIndex 重建；解析本身只读缓存，高效且战斗安全。
local spellToButtons = {}   -- [spellName] = { btn, btn, ... }
local buttonSpell   = {}     -- [btn] = spellName（仅记录放了法术的按钮）

local function RebuildButtonIndex()
    spellToButtons = {}
    buttonSpell = {}
    local btnNames = (BAR.GetActionBarButtonNames and BAR.GetActionBarButtonNames()) or {}
    for _, btnName in ipairs(btnNames) do
        local btn = _G[btnName]
        if btn and btn.action then
            -- GetActionInfo 第二个返回值只有在 actionType=="spell" 时才是数字 spellID；
            -- 其它类型（equipmentset 返回套装名 string、macro 返回宏索引等）不能做数字比较。
            local actionType, actionID = GetActionInfo(btn.action)
            if actionType == "spell" and actionID and type(actionID) == "number" and actionID > 0 then
                local okN, actionSpellName = pcall(C_Spell.GetSpellName, actionID)
                if okN and actionSpellName then
                    buttonSpell[btn] = actionSpellName
                    spellToButtons[actionSpellName] = spellToButtons[actionSpellName] or {}
                    table.insert(spellToButtons[actionSpellName], btn)
                end
            end
        end
    end
end

local function FindActionButtonsForSpellName(names)
    local result = {}
    if not names then return result end
    if type(names) == "string" then names = { names } end
    local seen = {}
    for _, n in ipairs(names) do
        local btns = spellToButtons[n]
        if btns then
            for _, btn in ipairs(btns) do
                if not seen[btn] then
                    seen[btn] = true
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

    local timeColor = isMine and S.AUTO_OWN_TIME_COLOR or S.AUTO_OTHER_TIME_COLOR

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
-- 路径 A：CDM 自动发现（核心逻辑 —— 全局解析，修复"不同步/错误信息"）
-- =========================================================
-- 收集一个 cooldown info 的候选法术【名】（spellID + overrideSpellID + linkedSpellIDs），
-- 与旧 UpdateFromItem 内联的那段逻辑一致。
local function CollectCandidateNames(info)
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
    return names
end

-- 全局解析：遍历所有当前 CDM 帧，为每个匹配的按钮选出【最优】帧（优先玩家自身光环 auraDataUnit=="player"），
-- 把该帧的 (unit, instanceID) **当前值抓取**到 overlay 上，刷新显示。
--
-- ⚠️ 关键修复（数据不准 / 多目标错误信息）：绝不缓存 CDM 帧对象的引用！
--   旧写法 `ov.viewerItem = frame` 缓存了帧引用，而 CDM 会把同一帧对象**复用**去显示别的 buff，
--   复用后 UpdateOverlay 读到的就是新 buff 的 auraDataUnit/auraInstanceID → 显示错误数据，直到下次重解析。
--   正确做法（与 CDMButtonAuras 的 overlay:SetAura(unit, instanceID) 完全一致）：每个 overlay 只保存
--   **抓取到的 (unit, instanceID) 值对**，帧被复用也不影响已存的值；下一轮全量重解析再更新。
--
-- 每轮解析先【同步】清空所有 path-A 覆盖层的数据再重派生（CDMButtonAuras 的 clear+re-derive 同款），
-- 不走异步延迟（旧版 C_Timer.After 延迟是导致"延迟"的根因），因此既实时又无残留/错位。
-- 解析只读 frame.auraDataUnit（unit token，非 secret）/ cooldownID 等安全字段，战斗安全。
local function ResolveAll()
    if not AutoCDM.IsEnabled() then return end

    -- 记录每个按钮本次解析到的最佳帧的【抓取值】（优先玩家自身光环）
    local bestForButton = {}   -- [btn] = { unit=unitToken, instanceID=number, isPlayer=bool }

    for _, viewerName in ipairs(VIEWER_NAMES) do
        local viewer = _G[viewerName]
        if viewer and viewer.GetItemFrames then
            local ok, frames = pcall(viewer.GetItemFrames, viewer)
            if ok and frames then
                for _, f in ipairs(frames) do
                    if f.cooldownID and f.auraDataUnit and f.auraInstanceID then
                        local okI, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, f.cooldownID)
                        if okI and info then
                            local candidates = CollectCandidateNames(info)
                            if #candidates > 0 then
                                local buttons = FindActionButtonsForSpellName(candidates)
                                local isPlayer = (f.auraDataUnit == "player")
                                for _, btn in ipairs(buttons) do
                                    local cur = bestForButton[btn]
                                    -- 未指派、或【新帧属于玩家】优于【旧帧属于别人】时覆盖
                                    if not cur or (isPlayer and not cur.isPlayer) then
                                        bestForButton[btn] = {
                                            unit = f.auraDataUnit,
                                            instanceID = f.auraInstanceID,
                                            isPlayer = isPlayer,
                                        }
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- 同步清空所有 path-A 覆盖层的数据（保留 extraTracked 回退路径的覆盖层不动）
    for _, ov in pairs(autoOverlays) do
        if not ov.extraTracked then
            ov.viewerItem = nil
            ov.unit = nil
            ov.auraInstanceID = nil
            ov.cd:Hide(); ov.stackText:Hide(); ov.container:Hide()
        end
    end

    -- 按解析结果指派 + 刷新（抓取值存到 overlay，不存帧引用）
    for btn, best in pairs(bestForButton) do
        local ov = autoOverlays[btn]
        if not ov then
            local cd, stack, container = CreateAuraDisplay()
            ov = { button = btn, cd = cd, stackText = stack, container = container, viewerItem = nil }
            autoOverlays[btn] = ov
            -- 倒计时归零时主动重刷（补漏边缘 case）
            cd:SetScript("OnCooldownDone", function() UpdateOverlay(ov) end)
        end
        -- 已被 extraTracked 管理的按钮，交给回退路径处理，path-A 不抢占
        if ov.extraTracked then
            ov.viewerItem = nil
            ov.unit = nil
            ov.auraInstanceID = nil
        else
            ov.viewerItem = nil          -- 不再缓存帧引用
            ov.unit = best.unit          -- 抓取到的当前值（免疫帧复用）
            ov.auraInstanceID = best.instanceID
            ov.extraTracked = nil
            ov.extraSpellID = nil
            UpdateOverlay(ov)
        end
    end

    -- 路径 B：额外追踪回退（extraTracked），在未被 path A 占用的按钮上叠加显示
    RefreshAllExtraTracked()

    -- 重新定位所有有数据源的 overlay（按钮可能移动了）
    for _, ov in pairs(autoOverlays) do
        if (ov.unit and ov.auraInstanceID) or (ov.extraTracked and ov.auraInstanceID) then
            if not PositionOverlay(ov) then
                ov.cd:Hide(); ov.stackText:Hide(); ov.container:Hide()
            end
        end
    end
end

-- 防抖：CDM 在战斗中会频繁触发各帧的 RefreshData，合并为每游戏帧最多一次 ResolveAll，
-- 既保证实时同步又避免性能浪费。
local resolvePending = false
local function ScheduleResolve()
    if resolvePending then return end
    resolvePending = true
    C_Timer.After(0, function()
        resolvePending = false
        ResolveAll()
    end)
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
-- ✅ 全程战斗安全：不读取/比较任何 secret 值。
-- 三步查找：
--   1. GetAuraDataBySpellID 精确匹配 spellID（最快，战斗安全）
--   2. 若失败，用 C_UnitAuras.FindAuraByName 按名字匹配
--      ——【关键点】名字比较由暴雪代码在内部完成，addon 完全不碰 secret 字符串，
--         因此战斗中也能安全执行；我们只读取返回的 auraInstanceID（非 secret 句柄）。
--         处理"基础 spellID ≠ 玩家身上实际光环 spellID"的情况
--        （如真言术韧 21562 是基础法术 ID，玩家身上的实际光环用 override/变体 ID）。
--   3. （仅脱战，legacy 兜底）按名字遍历玩家增益，处理 FindAuraByName 不可用时的极端情况。
-- spellName 可选；提供时启用名字回退查找。
function QueryPlayerAura(spellID, spellName)
    -- 步骤 1：spellID 精确匹配（战斗安全）
    local ok, data = pcall(C_UnitAuras.GetAuraDataBySpellID, "player", spellID)
    if ok and data and data.auraInstanceID then
        return "player", data.auraInstanceID
    end

    if not spellName then return nil, nil end

    -- 步骤 2：FindAuraByName —— 暴雪内部做名字匹配，addon 只读非 secret 的 auraInstanceID。
    --   战斗安全：无 addon 侧 secret 字符串比较。
    --   兼容 filters 参数形态（字符串或表），两种都试以确保命中。
    for _, filt in ipairs({ "HELPFUL", { "HELPFUL" } }) do
        local okF, fa = pcall(C_UnitAuras.FindAuraByName, spellName, "player", filt)
        if okF and fa and fa.auraInstanceID then
            return "player", fa.auraInstanceID
        end
    end

    -- 步骤 3：（仅脱战兜底）手动按名字遍历——legacy，仅在 FindAuraByName 不可用时生效。
    if InCombatLockdown() then return nil, nil end
    local i = 1
    while true do
        local okI, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
        if not okI or not aura then break end
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
function UpdateExtraTracked(spellID)
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
            -- 已有 overlay：若当前由 CDM 路径 A 管理（有 unit/instanceID 且非 extraTracked），不覆盖（CDM 优先）
            if ov.unit and ov.auraInstanceID and not ov.extraTracked then return end
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
function RefreshAllExtraTracked()
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
        if AutoCDM.IsEnabled() then ScheduleResolve() end
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
                        ScheduleResolve()
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

-- 一次性重新同步所有覆盖层：
--   1. 重建按钮法术名索引（动作条/专精可能变化）
--   2. 路径 A：全局 ResolveAll（重判每个按钮当前该显示哪个 CDM 帧，自动处理帧复用/同名多帧）
--   3. 路径 B：重扫 extraTracked 列表
-- ResolveAll 内部已做"隐藏未被指派的覆盖层"，无需额外的 stillValid 滞后判断 → 不再有延迟/不同步。
function AutoCDM.RefreshAll()
    if not AutoCDM.IsEnabled() then
        for _, ov in pairs(autoOverlays) do
            ov.viewerItem = nil; ov.unit = nil; ov.auraInstanceID = nil
            ov.cd:Hide(); ov.stackText:Hide(); ov.container:Hide()
        end
        return
    end

    RebuildButtonIndex()
    ResolveAll()
end

-- 供本模块 hook 调用（RefreshData 回调中）
function AutoCDM.OnItemRefresh(item)
    if not AutoCDM.IsEnabled() then return end
    ScheduleResolve()
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
        -- 动作条槽位/分页/姿态变化：按钮上的法术可能已变 → 重建名索引并全局重解析。
        -- 注意：这里必须【重建索引 + 重解析】，不能只重定位——
        -- 旧写法的"只重定位不动数据源"正是导致与 CDM 不同步/延迟的元凶之一。
        -- ResolveAll 每次都从当前 CDM 帧重新判定，RefreshData hook 仍持续驱动实时更新。
        RebuildButtonIndex()
        ScheduleResolve()
    elseif event == "UNIT_AURA" then
        -- 只响应玩家自身的光环变化，加 0.5 秒防抖避免战斗中频繁遍历
        -- ✅ 战斗中也会触发：自 v3 起 QueryPlayerAura 用 FindAuraByName（暴雪内部匹配，
        --    addon 不碰 secret 字符串），战斗安全 → 战斗中施放/刷新 extraTracked buff
        --    （如真言术韧）也能立即发现并显示，无需等脱战。
        if arg1 == "player" and not auraUpdatePending then
            auraUpdatePending = true
            C_Timer.After(0.5, function()
                auraUpdatePending = false
                RefreshAllExtraTracked()
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
        -- path-A 已不再使用 viewerItem（改存抓取的 unit/instanceID），故用 unit+非extraTracked 判定
        if ov.unit and ov.auraInstanceID and not ov.extraTracked then cdmOv = cdmOv + 1 end
        if ov.extraTracked then extOv = extOv + 1 end
    end
    print("  [汇总] overlay总数=" .. totalOv .. " CDM路径=" .. cdmOv .. " Extra路径=" .. extOv)

    print("|cff00ccff[AutoCDM]|r === 诊断结束 ===")
end
