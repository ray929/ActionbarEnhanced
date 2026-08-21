-- ActionbarEnhanced/BleedReminder.lua
-- 流血高亮提醒（矮人石像形态）：玩家身上出现【流血类】减益时，
-- 在石像形态（种族技能 20594）动作条按钮上播放红色发光动画。
--
-- 12.1 Secret Values 约束下的实现原理（插件全程零光环数据读取，combat-safe）：
--   · 「身上是否有流血」的判定交给暴雪特权层：AuraContainer + AddAuraSlot(filter="HARMFUL",
--     candidateFilters.includeDispelTypes = { Bleed = true })。流血是 12.x 正式的 dispelName
--     分类（官方 AuraUtil.lua 的 DEBUFF_DISPLAY_INFO 有 Bleed 专属边框贴图/颜色/缩写）；
--   · includeDispelTypes 不受 CanApplyIdentityCandidateFilters 身份过滤限制
--     （AuraContainerUtil 源码：dispelTypes 判断在 identity 块之外），战斗中 secret 环境
--     照常由暴雪评估——官方玩家 debuff 框也是同一特权层；
--   · 红色 ProcGlow 挂在 AuraButton 上（initializeFrame 里创建，glow key = "BLEED"）：
--     AuraButton 显隐由暴雪 ApplyVisibility 控制（有流血显示、无流血隐藏），父帧隐藏时
--     子帧（glow）跟着不可见 → 高亮自动跟随流血出现/消失，插件无需读任何数值/显隐状态；
--   · 容器定位沿用 Preset 模式：GetRect 屏幕坐标 + 缩放换算（零锚依赖，不污染安全按钮）；
--     石像形态按钮不在动作条上时【停靠屏幕外】而非 Hide（Hide 会注销 UNIT_AURA 注册，
--     重新 Show 触发战斗中 FullAuraRebuild 失败，见 AGENTS.md §3 容器显隐坑）。
--
-- 注意：个别未被暴雪归类为 Bleed 的物理流血（dispelName=nil）无法触发——口径与官方
-- debuff 框一致（暴雪显示为流血边框的才会被追踪）。

local BAR = ActionbarEnhanced
if not BAR then return end

local BR = {}
BAR.BleedReminder = BR

-- LibCustomGlow 已在 .toc 先于本文件加载
local LCG = LibStub and LibStub("LibCustomGlow-1.0", true)

-- 共用 Settings.lua 的样式配置
local S = BAR.Settings or {}

-- 石像形态（矮人种族技能）法术 ID
local STONEFORM_SPELL_ID = 20594
-- 发光颜色（鲜红，区别于冷却高亮的鲜绿、饰品高亮的鲜黄）
local BLEED_COLOR = S.BLEED_GLOW_COLOR or { 1.0, 0.15, 0.15, 1 }

-- =========================================================
-- 配置开关（存于 ActionbarEnhancedDB.bleedReminder.enabled，默认开启）
-- =========================================================
function BR.EnsureDB()
    ActionbarEnhancedDB = ActionbarEnhancedDB or {}
    ActionbarEnhancedDB.bleedReminder = ActionbarEnhancedDB.bleedReminder or {}
    if ActionbarEnhancedDB.bleedReminder.enabled == nil then
        ActionbarEnhancedDB.bleedReminder.enabled = true
    end
end

function BR.IsEnabled()
    return ActionbarEnhancedDB and ActionbarEnhancedDB.bleedReminder
        and ActionbarEnhancedDB.bleedReminder.enabled ~= false
end

-- =========================================================
-- 容器与 AuraButton
-- =========================================================
local container    -- 唯一流血追踪容器（AuraContainer）
local initFailed   -- 战斗中创建失败标记（等 PLAYER_REGEN_ENABLED 重试）
local glowButton   -- 挂了 glow 的 AuraButton 引用（关闭开关时 Stop 用）
local anchorBtn    -- 石像形态动作条按钮缓存
local rectL, rectB, rectW, rectH  -- 按钮矩形缓存（位置未变跳过 SetPoint）

-- initializeFrame 回调：暴雪创建 AuraButton 后挂红色发光。
-- ⚠️ SetSize + SetAllPoints 双保险（AGENTS.md 2026-08-19 坑）：flow layout 的
--    ApplyElementLayout 会对 slot 帧 ClearAllPoints 后单锚点重锚，SetAllPoints 的
--    派生尺寸随即丢失——没有显式 SetSize 就塌缩 0×0，整个高亮不可见。
-- ⚠️ ProcGlow 幂等守卫：initializeFrame 可能因 AuraButton 池化重用被多次调用，
--    重复 ProcGlow_Start 会叠层越来越厚（AGENTS.md §6）。
local function SetupBleedAuraButton(btn)
    btn:SetSize(36, 36)
    btn:SetAllPoints(container)
    if LCG and not btn.__BARBleedGlow then
        pcall(LCG.ProcGlow_Start, btn, {
            key = "BLEED", startAnim = true, color = BLEED_COLOR, scale = 1.0,
        })
        btn.__BARBleedGlow = true
        glowButton = btn
    end
end

-- 创建流血追踪容器（每角色一个，登录后创建；战斗中创建可能失败 → 标记等脱战重试）
local function InitContainer()
    if container then return true end
    if initFailed then return false end
    -- 战斗门禁（AGENTS.md B+）：战斗中绝不创建容器
    if InCombatLockdown() then
        initFailed = true
        return false
    end
    local ok, c = pcall(CreateFrame, "AuraContainer", nil, UIParent, "CustomAuraContainerTemplate")
    if not ok or not c then
        initFailed = true
        return false
    end
    c:SetFrameStrata("HIGH")
    c:SetFrameLevel(1000)
    c:SetSize(36, 36)
    c:SetUnit("player")
    c:SetEnabled(true)
    -- 先挂引用：AddAuraSlot 的 initializeFrame 回调同步执行，SetupBleedAuraButton 要用
    container = c
    local okSlot = pcall(function()
        c:AddAuraSlot("bleed", "HARMFUL", {
            candidateFilters = { includeDispelTypes = { ["Bleed"] = true } },
            initializeFrame = SetupBleedAuraButton,
        })
    end)
    if not okSlot then
        initFailed = true
        container = nil
        c:Hide()
        return false
    end
    c:Show()
    return true
end

-- =========================================================
-- 石像形态按钮定位（Preset 同款查找/自愈/停靠模式）
-- =========================================================
-- 按法术名找到原生动作条按钮（只匹配可见按钮；左右动作条共享槽位，隐藏栏会误匹配）
local function FindStoneformButton()
    local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(STONEFORM_SPELL_ID)
    if not name then return end
    local barNames = (ActionButtonUtil and ActionButtonUtil.ActionBarButtonNames) or {}
    for _, actionBar in ipairs(barNames) do
        if type(actionBar) == "string" then
            for i = 1, (NUM_ACTIONBAR_BUTTONS or 12) do
                local btn = _G[actionBar .. i]
                if btn and btn:IsShown() then
                    local _, actionSpellID = GetActionInfo(btn.action)
                    if actionSpellID then
                        -- 直接 GetSpellName 比对，不做 GetBaseSpell 重定向（AutoCDM 63cafe4 坑）
                        if name == C_Spell.GetSpellName(actionSpellID) then
                            return btn
                        end
                    end
                end
            end
        end
    end
end

-- 按钮缓存自愈验证（Preset.ResolveButton 模式）：翻页/切专精后同一按钮可能换了技能，
-- GetActionInfo + 名字比对（与 Find 对称）验证缓存，失效即作废重找
local function ResolveStoneformButton()
    local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(STONEFORM_SPELL_ID)
    if not name then return end
    if anchorBtn and anchorBtn.action ~= nil then
        local okA, _, curSpellID = pcall(GetActionInfo, anchorBtn.action)
        local curName = (okA and curSpellID) and C_Spell.GetSpellName(curSpellID) or nil
        if curName ~= name then
            anchorBtn = nil
        end
    end
    if not anchorBtn then
        anchorBtn = FindStoneformButton()
    end
    return anchorBtn
end

-- 主刷新：重定位容器到石像形态按钮上方
local function Update()
    if not BR.IsEnabled() then return end
    -- 矮人专属：不会石像形态的角色零开销（容器都不建）
    if not IsPlayerSpell(STONEFORM_SPELL_ID) then return end
    if not InitContainer() then return end

    local btn = ResolveStoneformButton()
    if not btn then
        -- 按钮不在动作条上：停靠屏幕外而非 Hide（保持 UNIT_AURA 事件注册，
        -- AGENTS.md §3 容器显隐坑）；必须同时清矩形缓存，恢复时强制重定位
        container:ClearAllPoints()
        container:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", -10000, -10000)
        rectL, rectB, rectW, rectH = nil, nil, nil, nil
        return
    end
    local left, bottom, width, height = btn:GetRect()
    if not left then
        -- 按钮隐藏/过渡态：同样停靠屏幕外（不清缓存，rect 恢复后跳过重定位的
        -- 优化会失效，故这里也清）
        container:ClearAllPoints()
        container:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", -10000, -10000)
        rectL, rectB, rectW, rectH = nil, nil, nil, nil
        return
    end
    local r = 1
    local bs, ps = btn:GetEffectiveScale(), UIParent:GetEffectiveScale()
    if bs and ps and ps > 0 then r = bs / ps end
    -- 仅位置变化时才重新 SetPoint（省 ClearAllPoints+SetPoint）
    if rectL ~= left or rectB ~= bottom or rectW ~= width or rectH ~= height then
        container:ClearAllPoints()
        container:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left * r, (bottom + height) * r)
        rectL, rectB, rectW, rectH = left, bottom, width, height
    end
    -- 尺寸每次重做：flow layout 会在光环变化时异步覆盖容器尺寸（Preset 同款对抗）
    container:SetSize(width * r, height * r)
end
BR.Update = Update

-- =========================================================
-- 开关（配置面板调用）
-- =========================================================
function BR.SetEnabled(v)
    BR.EnsureDB()
    ActionbarEnhancedDB.bleedReminder.enabled = v
    if v then
        -- 开启：立即刷新（容器未建则建；战斗中建失败等 PLAYER_REGEN_ENABLED 自愈）
        pcall(Update)
        print("|cff33ccff[ActionbarEnhanced]|r 流血高亮提醒（矮人石像形态）已【启用】。")
    else
        -- 关闭：停掉 glow 并隐藏容器（对齐 Preset.SetEnabled 模式）。
        -- 战斗中重新开启的 FullAuraRebuild secret 失败由 PLAYER_REGEN_ENABLED 刷新自愈。
        if glowButton and LCG then
            pcall(LCG.ProcGlow_Stop, glowButton, "BLEED")
            glowButton.__BARBleedGlow = nil
        end
        glowButton = nil
        if container then container:Hide() end
        print("|cff33ccff[ActionbarEnhanced]|r 流血高亮提醒（矮人石像形态）已【关闭】。")
    end
end

-- =========================================================
-- 事件：动作条切换 → 清缓存 + 延迟重定位（Preset 模式：
-- 这些事件在保护上下文同步触发，立即操作容器会被 taint，必须延迟）
-- =========================================================
local actionbarEvents = {
    ACTIONBAR_SLOT_CHANGED       = true,
    ACTIONBAR_PAGE_CHANGED       = true,
    ACTIVE_TALENT_GROUP_CHANGED  = true,
    UPDATE_BONUS_ACTIONBAR       = true,
    UPDATE_OVERRIDE_ACTIONBAR    = true,
    UPDATE_SHAPESHIFT_FORM       = true,
    UPDATE_POSSESS_BAR           = true,
    UPDATE_MULTI_CAST_ACTIONBAR  = true,
}

local function InvalidateAnchor()
    anchorBtn = nil
    rectL, rectB, rectW, rectH = nil, nil, nil, nil
end

local evFrame = CreateFrame("Frame")
evFrame:RegisterEvent("PLAYER_LOGIN")
evFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
for ev in pairs(actionbarEvents) do evFrame:RegisterEvent(ev) end

evFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        BR.EnsureDB()
        -- 低频 ticker：按钮缓存自愈 + 重定位兜底（AuraButton 显隐由暴雪实时驱动，
        -- 这里只管容器跟着按钮走；空转开销 = 2 次 API 调用/秒，可忽略）
        C_Timer.NewTicker(1, function()
            if BR.IsEnabled() then pcall(Update) end
        end)
        if BR.IsEnabled() then
            Update()
            -- 登录冷启动兜底：动作条按钮可能尚未就绪
            C_Timer.After(1.0, function() pcall(Update) end)
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- 脱战：解除战斗中建容器失败的限制并刷新（开关在战斗中切换时也靠这里自愈）
        initFailed = nil
        if BR.IsEnabled() then pcall(Update) end
    else
        InvalidateAnchor()
        C_Timer.After(0.1, function() InvalidateAnchor(); pcall(Update) end)
        C_Timer.After(0.5, function() InvalidateAnchor(); pcall(Update) end)
    end
end)
