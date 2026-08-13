-- ActionbarEnhanced/AutoCDM.lua
-- 自动发现模块：把暴雪 CDM 光环查看器（BuffIconCooldownViewer）里【已渲染好的对象】——
--   倒计时 Cooldown 控件、层数 FontString——直接 reparent 到动作条按钮上。
-- 关键设计（12.1 正确的做法）：
--   · addon 完全不读 aura 数据（不碰 C_UnitAuras / GetAuraDuration / auraDataCached 等
--     secret 值），只移动暴雪已渲染的对象 → 战斗中照常显示，无 taint 风险；
--   · 对象由暴雪继续驱动（CDM 的 RefreshData 会 SetCooldown / SetText），
--     我们只负责 reparent 位置与显示开关；
--   · 匹配按钮：用 CDM cooldownInfo 的候选 spellID（含 linkedSpellIDs/override）
--     做名字匹配，解决天赋改名场景（光环"烈焰震击" vs 按钮"流电炽焰"）。
--
-- ⚠️ 与 CDMButtonAuras 同框运行时：本模块的 hook 标记用 __BARAutoCDMHooked（不与其
--   __CDMBAHooked 冲突），否则会被对方抢先标记导致本模块永不 hook → 永远不更新。

local BAR = ActionbarEnhanced
if not BAR then return end

local AutoCDM = {}
BAR.AutoCDM = AutoCDM

-- 共用 Settings.lua 的样式配置（字体 / 字号 / 描边 / 自动发现配色）
local S = BAR.Settings or {}

-- CDM 光环查看器（用户确认：只要 BuffIconCooldownViewer，不要 BuffBar）
local VIEWER_NAMES = { "BuffIconCooldownViewer" }

-- 法术名 -> 附加按钮名列表（对齐 CDM 的 AuraMapByName，默认空）。
-- 默认仅为光环自身名，故匹配行为与 CDM 默认配置一致。
local AuraMapByName = {}

-- 覆盖层表（按动作按钮对象索引）
local overlays = {}   -- [actionButton] = overlayFrame

-- =========================================================
-- 覆盖层：按钮的轻量容器（不自建 Cooldown/Stacks，
-- 由 AttachItemObjects 把 CDM 已渲染对象 reparent 进来）
-- =========================================================
-- 覆盖层：UIParent 中立容器（与动作按钮【零锚依赖】，绝不 SetPoint 到按钮）。
-- 由 CDM item 的已渲染对象（Cooldown 控件 / 层数 FontString）reparent 进来。
-- 为什么挂 UIParent：若把容器挂到安全动作按钮上（即使是其子帧），非安全帧依赖安全帧
-- 会把 taint 传播到动作条按钮 → 进战斗后 combat-lockdown 把整条动作条判定污染而隐藏。
-- 容器只挂 UIParent，位置由 PositionOverlay 用 btn:GetRect() 读按钮屏幕坐标再摆放
-- （只读操作不污染安全帧，且容器与按钮无锚依赖，taint 无处传播）。
local function GetOverlay(actionButton)
    local ov = overlays[actionButton]
    if not ov then
        ov = CreateFrame("Frame", nil, UIParent)
        ov:SetFrameStrata("HIGH")
        ov:SetFrameLevel(1000)
        ov:SetSize(36, 36)
        ov:Hide()
        ov.button = actionButton
        overlays[actionButton] = ov
    end
    return ov
end

-- 把覆盖层容器定位到动作按钮之上（用屏幕坐标，绝不锚到按钮）。
-- 用 btn:GetRect() 读按钮屏幕矩形（只读，不污染安全帧），再相对 UIParent 原点摆放。
-- ⚠️ 缩放换算：GetRect() 返回【按钮自身有效缩放坐标系】的值，容器用【UIParent 有效缩放】，
--    两者不同 → 换算比 r = 按钮有效缩放 / UIParent 有效缩放，位置与尺寸都乘 r 对齐屏幕像素。
local function PositionOverlay(ov)
    if not ov or not ov.button then return false end
    local btn = ov.button
    local left, bottom, width, height = btn:GetRect()
    if not left then return false end
    local r = 1
    local bs, ps = btn:GetEffectiveScale(), UIParent:GetEffectiveScale()
    if bs and ps and ps > 0 then r = bs / ps end
    ov:ClearAllPoints()
    ov:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left * r, (bottom + height) * r)
    ov:SetSize(width * r, height * r)
    return true
end

-- 安全检测任意可能为 secret 的值（secret 值不可比较/运算/布尔测试）
local function IsSecret(v)
    local ok, res = pcall(function() return issecretvalue and issecretvalue(v) end)
    return ok and res
end

-- 安全判断 CDM item frame 是否显示（= 光环是否激活）。
-- ⚠️ 12.1 蓝贴提到过新 AuraButton 的 IsShown 会返回 secret；CDM item frame 是普通
--   Frame 不受此限制，但为绝对稳妥仍 pcall 包裹：异常/secret 时按"未激活"处理。
local function IsItemShown(item)
    if not item then return false end
    local ok, shown = pcall(function() return item:IsShown() end)
    if not ok or shown == nil then return false end
    -- secret 值不可直接当布尔：再经 IsSecret 检查，secret 视为未激活
    if IsSecret(shown) then return false end
    return not not shown
end

-- =========================================================
-- 按钮查找（对齐 CDMButtonAurasControllerMixin）
-- =========================================================
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

-- 传入【多个候选 spellID】（CDM linkedSpellIDs + override + base），任一命中即可
local function GetActionButtonList(spellIDs)
    if type(spellIDs) == "number" then spellIDs = { spellIDs } end
    local buttonList = {}
    local nameSeen = {}
    for _, spellID in ipairs(spellIDs) do
        if spellID and not IsSecret(spellID) then
            local cdSpellName = C_Spell.GetSpellName(spellID)
            if cdSpellName and not nameSeen[cdSpellName] then
                nameSeen[cdSpellName] = true
                local spellNameList = { cdSpellName }
                tAppendAll(spellNameList, AuraMapByName[cdSpellName] or {})
                for _, spellName in ipairs(spellNameList) do
                    local button = FindActionButtonForSpellName(spellName)
                    if button and not buttonList[button] then
                        buttonList[#buttonList + 1] = button
                    end
                end
            end
        end
    end
    return buttonList
end

-- 隐藏 CDM item 的图标与装饰边框（Icon 本体 + IconOverlay 外框 + MaskTexture 等）。
-- 屏幕外容器：把 CDM item frame（图标+背景框整体）移到这里，实现"看不见"，
-- 无需 Hide 任何 region。item 的 Show/Hide 状态不因位置改变 → IsItemShown 激活判断不受影响。
local offscreenFrame = CreateFrame("Frame", nil, UIParent)
offscreenFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -1000, 1000)
offscreenFrame:SetSize(40, 40)
offscreenFrame:Show()

-- =========================================================
-- 核心：把 CDM item 已渲染对象 reparent 到按钮容器
-- =========================================================
-- item.Cooldown：暴雪渲染的倒计时控件（RefreshCooldownInfo 里 CooldownFrame_Set 驱动，
--   含倒计时数字 FontString）；item.Applications.Applications：层数（RefreshApplications
--   SetText 驱动）。reparent 后暴雪仍通过 item 引用驱动它们，addon 零读取。
--
-- ⚠️ 生命周期：CDM item frame 是池化的（光环增删时 ReleaseAll + Acquire 复用）。
--   光环消失时 item 被 Hide，必须把 reparent 出去的对象还回 item，否则下次 item 复用
--   显示别的光环时，按钮上会残留/错位。判断用 item:IsShown()（普通帧状态，非 secret）。

-- 把对象 reparent 到按钮容器（锚定到容器内按钮 icon 对应区域 / 左上）
local function AttachItemObjects(ov, item)
    local ok = pcall(function()
        if not item or not IsItemShown(item) then return end
        local cd = item.GetCooldownFrame and item:GetCooldownFrame()
        local stacks = item.GetApplicationsFontString and item:GetApplicationsFontString()
        if not cd then return end

        -- 容器先定位到按钮上方（屏幕坐标，绝不锚到按钮）
        if not PositionOverlay(ov) then
            ov:Hide()
            return
        end

        -- 倒计时控件：reparent 到容器，锚定到容器【左下角】区域
        -- （对齐旧版与 Manual 默认：时间数字显示在按钮左下角 62% 框）
        cd:SetParent(ov)
        cd:ClearAllPoints()
        local w, h = ov:GetSize()
        cd:SetPoint("BOTTOMLEFT", ov, "BOTTOMLEFT", 1, -6)
        cd:SetPoint("TOPRIGHT", ov, "BOTTOMLEFT", w * 0.62, h * 0.62 - 7)
        -- 去掉冷却扫光（转圈扇形指示）与边缘描边——只留倒计时数字，不要淡淡背景
        -- ⚠️ 暴雪每次 RefreshData 都会 SetDrawSwipe(true)，故每次 attach 都重新关掉
        cd:SetDrawSwipe(false)
        cd:SetDrawEdge(false)

        -- 应用 Settings 样式（颜色/字号/描边，可在 Settings.lua 修改）。
        -- ⚠️ 倒计时数字 FontString 要等冷却真正运行、暴雪渲染出数字后才存在，
        --    每次 attach 都调一次（幂等、廉价）。无 buff/debuff 判定（不读 secret），
        --    时间统一用 S.TIME_COLOR_OTHER_BUFF，可在 Settings 改为想要的颜色。
        local cds = cd.GetCountdownFontString and cd:GetCountdownFontString()
        if cds then
            cds:SetFont(S.FONT, S.FONT_SIZE, S.OUTLINE)
            cds:SetTextColor(S.TIME_COLOR_OTHER_BUFF[1], S.TIME_COLOR_OTHER_BUFF[2], S.TIME_COLOR_OTHER_BUFF[3])
        end

        -- 层数：reparent 到容器左上（对齐 CDM 左上）
        if stacks then
            stacks:SetParent(ov)
            stacks:ClearAllPoints()
            stacks:SetPoint("TOPLEFT", ov, "TOPLEFT", 5, -5)
            stacks:SetFont(S.FONT, S.FONT_SIZE, S.OUTLINE)
            stacks:SetTextColor(S.STACK_COLOR[1], S.STACK_COLOR[2], S.STACK_COLOR[3])
        end

        item.__BARAttachedTo = ov  -- 记录对象当前挂在哪个容器，供 Detach 归还
        ov.CDItem = item
        ov:Show()

        -- 用户要求：CDM 原图标/背景框无意义 → 把整个 item frame 移到屏幕外看不见。
        -- 无需 Hide 任何 region（图标、IconOverlay 框、MaskTexture 一起移走）。
        -- ⚠️ 记录原 parent 供 detach 还原；item 的 Show/Hide 状态不因位置改变，
        --    IsItemShown 激活判断依然有效。
        if not item.__BAROrigParent then
            item.__BAROrigParent = item:GetParent()
        end
        item:SetParent(offscreenFrame)
        item:ClearAllPoints()
        item:SetPoint("TOPLEFT", offscreenFrame, "TOPLEFT", 0, 0)
    end)
    return ok
end

-- 把 reparent 出去的对象还回 item（光环消失 / 全量刷新时调用）
local function DetachItemObjects(item)
    if not item or not item.__BARAttachedTo then return end
    local ov = item.__BARAttachedTo
    item.__BARAttachedTo = nil
    if ov then
        ov.CDItem = nil
        ov:Hide()
    end
    pcall(function()
        local cd = item.GetCooldownFrame and item:GetCooldownFrame()
        local stacks = item.GetApplicationsFontString and item:GetApplicationsFontString()
        if cd then
            cd:SetParent(item)
            cd:ClearAllPoints()
        end
        if stacks then
            stacks:SetParent(item)
            stacks:ClearAllPoints()
        end
        -- 把 item frame 还原到 CDM 原 parent（图标/背景框回到原位置；
        -- 光环消失时 item 本身会被暴雪 Hide，自然不可见）
        if item.__BAROrigParent then
            item:SetParent(item.__BAROrigParent)
            item.__BAROrigParent = nil
            item:ClearAllPoints()
        end
    end)
end

-- 收集 CDM item 的全部候选 spellID（用于匹配按钮）
local function CollectCandidateSpellIDs(item)
    local candidates = {}
    local seen = {}
    local function add(sid)
        if sid and not IsSecret(sid) and not seen[sid] then
            seen[sid] = true
            candidates[#candidates + 1] = sid
        end
    end
    if C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo and item.cooldownID then
        local ok, cdInfo = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, item.cooldownID)
        if ok and cdInfo then
            add(cdInfo.spellID)
            add(cdInfo.overrideSpellID)
            add(cdInfo.overrideTooltipSpellID)
            add(cdInfo.linkedSpellID)
            if cdInfo.linkedSpellIDs then
                for _, sid in ipairs(cdInfo.linkedSpellIDs) do add(sid) end
            end
            if cdInfo.spellCategoryID then
                local lastSpellID, lastItemID = C_Spell.GetLastCategoryCooldownSource(cdInfo.spellCategoryID)
                add(lastSpellID)
            end
        end
    end
    return candidates
end

-- =========================================================
-- 更新逻辑
-- =========================================================
-- 该 item 是否已被【手动绑定】到某按钮（reparent 对象只有一份，手动优先，自动让路）。
-- ⚠️ 必须定义在 UpdateFromItem 之前（Lua local 只对声明之后的代码可见）。
local function IsItemManuallyBound(item)
    if not BAR.IsBound then return false end
    local candidates = CollectCandidateSpellIDs(item)
    for _, sid in ipairs(candidates) do
        if BAR.IsBound(sid) then
            return true
        end
    end
    return false
end

local function UpdateFromItem(item)
    if not item then return end
    pcall(function()
        -- 光环不在（item 被隐藏）→ 把对象还回 item
        if not IsItemShown(item) then
            DetachItemObjects(item)
            return
        end
        local candidates = CollectCandidateSpellIDs(item)
        if #candidates == 0 then return end
        -- ⚠️ 协调：reparent 是"移动"不是"复制"——同一个 item 的已渲染对象只有一份。
        --   若该光环已被【手动绑定】到某按钮，自动 CDM 跳过（让手动独占），
        --   否则自动先移走对象，手动就 attach 不到了（两者会互相抢）。
        --   注意：这里只跳过、绝不 Detach——Detach 会把手动已 attach 的对象还回 item。
        if IsItemManuallyBound(item) then
            return
        end
        local buttonList = GetActionButtonList(candidates)
        if #buttonList == 0 then return end
        local overlay = GetOverlay(buttonList[1])
        AttachItemObjects(overlay, item)
    end)
end

local function UpdateFromViewer(viewer)
    if not viewer or not viewer.GetItemFrames then return end
    local ok, frames = pcall(viewer.GetItemFrames, viewer)
    if ok and frames then
        for _, itemFrame in ipairs(frames) do
            UpdateFromItem(itemFrame)
        end
    end
end

-- hook 每个 item 的 RefreshData：暴雪刷新时重新 reparent/定位（战斗中也照常触发）
local function HookViewerItem(item)
    if not item or item.__BARAutoCDMHooked then return end
    item.__BARAutoCDMHooked = true
    hooksecurefunc(item, "RefreshData", function()
        if AutoCDM.IsEnabled() then UpdateFromItem(item) end
    end)
end

-- 全量刷新：先 detach 所有已 reparent 的对象（还回 item），再重扫查看器重新 attach。
-- 只处理 BuffIconCooldownViewer（用户确认，不需要 BuffBar）。
-- ⚠️ 已手动绑定的 item 跳过 detach（对象可能正被手动持有，detach 会把它还回 item 导致手动失效）。
local function RefreshAllOverlays()
    for _, overlay in pairs(overlays) do
        if overlay.CDItem then
            if not IsItemManuallyBound(overlay.CDItem) then
                DetachItemObjects(overlay.CDItem)
            end
        else
            overlay:Hide()
        end
    end
    for _, viewerName in ipairs(VIEWER_NAMES) do
        UpdateFromViewer(_G[viewerName])
    end
end

-- =========================================================
-- hook 安装 + 事件
-- =========================================================
local evFrame          -- 前向声明（实际赋值见文件末尾的事件帧区块）
local hookedViewers = {}

local function InstallHooks()
    for _, viewerName in ipairs(VIEWER_NAMES) do
        if not hookedViewers[viewerName] then
            local v = _G[viewerName]
            if v and v.OnAcquireItemFrame then
                hooksecurefunc(v, "OnAcquireItemFrame", function(_, f)
                    if not AutoCDM.IsEnabled() then return end
                    if f then
                        HookViewerItem(f)
                    end
                end)
                hookedViewers[viewerName] = true
            end
        end
    end
end

local function Initialize()
    InstallHooks()
    evFrame:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
    evFrame:RegisterUnitEvent("UNIT_AURA", "player")
end

-- =========================================================
-- 启用开关（存盘于 ActionbarEnhancedDB.autoCDM.enabled，默认开启）
-- =========================================================
function AutoCDM.EnsureDB()
    ActionbarEnhancedDB = ActionbarEnhancedDB or {}
    ActionbarEnhancedDB.autoCDM = ActionbarEnhancedDB.autoCDM or {}
    if ActionbarEnhancedDB.autoCDM.enabled == nil then
        ActionbarEnhancedDB.autoCDM.enabled = true
    end
end

function AutoCDM.IsEnabled()
    return ActionbarEnhancedDB and ActionbarEnhancedDB.autoCDM
        and ActionbarEnhancedDB.autoCDM.enabled ~= false
end

function AutoCDM.SetEnabled(v)
    AutoCDM.EnsureDB()
    ActionbarEnhancedDB.autoCDM.enabled = v
    if v then
        RefreshAllOverlays()
        print("|cff33ccff[ActionbarEnhanced]|r 光环自动发现已【启用】。")
    else
        for _, ov in pairs(overlays) do ov:Hide() end
        print("|cff33ccff[ActionbarEnhanced]|r 光环自动发现已【关闭】。")
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
