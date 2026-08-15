-- ActionbarEnhanced/Preset.lua
-- 预设显示模块：追踪【不在 CDM 里的光环】（CDM 不渲染 → 没有可 reparent 的对象）。
--
-- 12.1 现实（已核实官方 API 文档 + Patch 12.1.0/API_changes）：
--   · 大地之盾(974/383648)、天怒(462854)不在 CDM 追踪集，且大地之盾已被暴雪
--     移出 "never secret" 白名单 → 战斗中(及副本/M+/PvP 受限场景)插件用
--     C_UnitAuras 自建查询一律读到 secret/空，【任何插件都无法在战斗中读取】。
--     （旧版能显示是因为 12.0.7 白名单还在，12.1 已移除，非代码改坏。）
--
-- 本模块改用 12.1 官方安全通道：【AuraContainer】（暴雪渲染层）：
--   · 每个预设一个容器(CustomAuraContainerTemplate)，按 includeSpellIDs 过滤光环；
--     光环数据由暴雪【特权】读取（AuraContainerPublicAuraSource），addon 零读取、
--     零 secret/taint 问题 → 战斗中照常显示与更新。
--   · 容器内 AuraButton 由暴雪驱动：倒计时(SetCooldownFromDurationObject)、
--     层数(SetApplicationCount)、显隐(ApplyVisibility)——addon 不读任何字段。
--   · addon 只负责两件事：把容器定位到动作条按钮上方（屏幕坐标、零锚依赖），
--     以及在 initializeFrame 回调里创建并注册子控件（必须 parent 到 AuraButton）。
--   · 武器附魔走 item enchant 通道（非 unit aura），12.1 战斗中不受限，
--     自建 Cooldown 由 1 秒 ticker 刷新（不挂每帧 OnUpdate）。
--
-- 用法：SELF_BUFFS 按当前职业自动启用；额外预设写 PRESETS；无需改其他代码。

local BAR = ActionbarEnhanced
if not BAR then return end

local Preset = {}
BAR.Preset = Preset

Preset.debug = (ActionbarEnhancedDB and ActionbarEnhancedDB.presetDebug) or false
                 -- 诊断开关：游戏内输入 /preset debug 切换详细日志（存盘持久化，reload 不丢）

-- 共用 Settings.lua 的样式配置（字体 / 字号 / 描边 / 配色）
local S = BAR.Settings or {}

-- =========================================================
-- 预设数据（用户编辑区）
-- =========================================================
-- 预设支持两种类型：
--
-- 类型 A：unit aura（光环）——12.1 AuraContainer 暴雪渲染层，战斗中也能显示
--   auraSpellID   : 要追踪的【光环法术ID】（单个 number，或 {id1,id2} 数组，任一命中即显示）
--   actionSpellID : 覆盖显示到哪个技能按钮（该技能的法术ID；该技能必须放在动作条上）
--   unit(可选)/filter(可选) : "player" / "HELPFUL"(默认)
--
-- 类型 B：武器临时附魔（weaponEnchant）— item enchant 通道（非 unit aura），【12.1 战斗中也能显示】
--   presetType    : 必须写 "weaponEnchant"
--   enchantID     : 武器附魔 ID
--   actionSpellID : 覆盖显示到哪个技能按钮（施放技能的法术ID）
--   enchantName(可选): 兼容字段（新方案按 enchantID 匹配，不再用名字）
--
-- 【按职业自动启用】SELF_BUFFS：玩家自身职业技能产生的 buff 的「光环→法术」映射，
--   提取自 BuffReminders/Data/Buffs.lua 的 self 表（含萨满武器附魔、盗贼涂毒、圣骑武器仪式等；
--   已排除药水/食物/磨刀石等消耗品，以及姿态/形态/开关态等非时限光环）。
--   运行时按当前职业过滤，只给当前角色建容器。
--
-- 【手动追加】PRESETS：SELF_BUFFS 未覆盖、需要手动加的预设写这里。

local SELF_BUFFS = {
    -- 萨满 SHAMAN
    { class = "SHAMAN", auraSpellID = 383648, actionSpellID = 974 },      -- 大地之盾（光环 383648 → 技能 974）
    { class = "SHAMAN", auraSpellID = 462854, actionSpellID = 462854 },   -- 天怒（光环=技能）
    { class = "SHAMAN", auraSpellID = 192106, actionSpellID = 192106 },   -- 闪电之盾
    { class = "SHAMAN", auraSpellID = 52127, actionSpellID = 52127 },     -- 水之护盾
    { class = "SHAMAN", auraSpellID = 546, actionSpellID = 546 },     -- 水上行走
    { class = "SHAMAN", auraSpellID = 6196, actionSpellID = 6196 },     -- 视界术
    { class = "SHAMAN", presetType = "weaponEnchant", enchantID = 5400, actionSpellID = 318038, enchantName = "Flametongue" },      -- 火舌武器
    { class = "SHAMAN", presetType = "weaponEnchant", enchantID = 5401, actionSpellID = 33757, enchantName = "Windfury" },          -- 风怒武器
    { class = "SHAMAN", presetType = "weaponEnchant", enchantID = 6498, actionSpellID = 382021, enchantName = "Earthliving Weapon" }, -- 大地生命武器
    { class = "SHAMAN", presetType = "weaponEnchant", enchantID = 7528, actionSpellID = 457481, enchantName = "Tidecaller's Guard" }, -- 唤潮者护卫
    { class = "SHAMAN", auraSpellID = 188389, actionSpellID = 470057, unit = "target", filter = "HARMFUL" },
    { class = "SHAMAN", auraSpellID = 188389, actionSpellID = 470411, unit = "target", filter = "HARMFUL" },
    -- 盗贼 ROGUE（武器涂毒：光环 = 技能 同 ID）
    { class = "ROGUE", auraSpellID = 381664, actionSpellID = 381664 },  -- 增效毒药 Amplifying
    { class = "ROGUE", auraSpellID = 2823, actionSpellID = 2823 },      -- 致命毒药 Deadly
    { class = "ROGUE", auraSpellID = 315584, actionSpellID = 315584 },  -- 即时毒药 Instant
    { class = "ROGUE", auraSpellID = 8679, actionSpellID = 8679 },      -- 致伤毒药 Wound
    { class = "ROGUE", auraSpellID = 381637, actionSpellID = 381637 },  -- 萎缩毒药 Atrophic
    { class = "ROGUE", auraSpellID = 5761, actionSpellID = 5761 },      -- 麻痹毒药 Numbing
    { class = "ROGUE", auraSpellID = 3408, actionSpellID = 3408 },      -- 减速毒药 Crippling
    -- 法师 MAGE
    { class = "MAGE", auraSpellID = 1459, actionSpellID = 1459 },        -- 奥术智慧（团队增益）
    { class = "MAGE", auraSpellID = 210126, actionSpellID = 1459 },      -- 奥术魔宠（buff 210126 → 奥术智慧 1459）
    -- 术士 WARLOCK
    { class = "WARLOCK", auraSpellID = 196099, actionSpellID = 108503 }, -- 牺牲魔典
    -- 战士 WARRIOR
    { class = "WARRIOR", auraSpellID = 6673, actionSpellID = 6673 },     -- 战斗怒吼（团队增益）
    -- 德鲁伊 DRUID
    { class = "DRUID", auraSpellID = 1126, actionSpellID = 1126 },       -- 野性印记（团队增益，432661 为 NPC 版）
    -- 牧师 PRIEST
    { class = "PRIEST", auraSpellID = 21562, actionSpellID = 21562 },    -- 真言术韧（团队增益）
    { class = "PRIEST", auraSpellID = 586, actionSpellID = 586 },    -- 渐隐术
    { class = "PRIEST", auraSpellID = 10060, actionSpellID = 10060 },    -- 能量灌注
    { class = "PRIEST", auraSpellID = 19236, actionSpellID = 19236 },    -- 绝望祷言
    { class = "PRIEST", auraSpellID = 17, actionSpellID = 17 },    -- 真言术盾
    { class = "PRIEST",  auraSpellID = 121557, actionSpellID = 121536 }, -- 羽毛
    { class = "PRIEST", auraSpellID = 589, actionSpellID = 589, unit = "target", filter = "HARMFUL" }, -- 暗影术痛


    -- 圣骑士 PALADIN（武器仪式）
    { class = "PALADIN", presetType = "weaponEnchant", enchantID = 7144, actionSpellID = 433583 }, -- 裁决仪式（buff 433584）
    { class = "PALADIN", presetType = "weaponEnchant", enchantID = 7143, actionSpellID = 433568 }, -- 圣化仪式（buff 433550）
    -- 唤魔者 EVOKER（增辉协调：黑 403264 / 铜 403265 二选一）
    { class = "EVOKER", auraSpellID = { 403264, 403265 }, actionSpellID = 403208 },
    -- 唤魔者 EVOKER 青铜龙祝福（团队增益，光环为多阶段变体）
    { class = "EVOKER", auraSpellID = { 381732, 381741, 381746, 381748, 381749, 381750, 381751, 381752, 381753, 381754, 381756, 381757, 381758 }, actionSpellID = 364342 },
}

-- 手动追加的预设（SELF_BUFFS 之外的写这里；自动的来自上方 SELF_BUFFS）
local PRESETS = {
    -- { auraSpellID = 123456, actionSpellID = 123, unit = "player", filter = "HELPFUL" },
    -- { presetType = "weaponEnchant", enchantID = 5400, actionSpellID = 318038 },
}

-- 运行时生效的预设 = PRESETS(手动) + 按当前职业过滤的 SELF_BUFFS(自动)，去重
local ACTIVE_PRESETS = {}

local function PresetKey(p)
    if p.presetType == "weaponEnchant" then
        return "E" .. tostring(p.enchantID) .. "_" .. tostring(p.actionSpellID)
    end
    local id = p.auraSpellID
    if type(id) == "table" then
        local parts = {}
        for _, v in ipairs(id) do parts[#parts + 1] = tostring(v) end
        return "A" .. table.concat(parts, ",") .. "_" .. tostring(p.actionSpellID)
    end
    return "A" .. tostring(id) .. "_" .. tostring(p.actionSpellID)
end

local function BuildActivePresets(classToken)
    wipe(ACTIVE_PRESETS)
    local seen = {}
    local function add(p)
        local key = PresetKey(p)
        if not seen[key] then
            seen[key] = true
            ACTIVE_PRESETS[#ACTIVE_PRESETS + 1] = p
        end
    end
    for _, p in ipairs(PRESETS) do add(p) end
    if classToken then
        for _, p in ipairs(SELF_BUFFS) do
            if p.class == classToken then add(p) end
        end
    end
end

-- =========================================================
-- 工具函数
-- =========================================================
-- 安全判断 secret 值（12.1 受限内容返回 secret，不可比较/运算/布尔测试）
local function IsSecret(v)
    local ok, res = pcall(function() return issecretvalue and issecretvalue(v) end)
    return ok and res
end

-- 格式化光环 ID（支持单个 number 或 {id1,id2} 数组）用于日志/状态显示
local function FmtAuraID(id)
    if type(id) == "table" then return table.concat(id, "/") end
    return tostring(id)
end

-- 复用 AutoCDM 的按钮查找：按法术名找到原生动作条按钮
local function FindActionButtonForSpellName(name)
    if not name then return end
    local barNames = (ActionButtonUtil and ActionButtonUtil.ActionBarButtonNames) or {}
    for _, actionBar in ipairs(barNames) do
        if type(actionBar) == "string" then
            for i = 1, (NUM_ACTIONBAR_BUTTONS or 12) do
                local btn = _G[actionBar .. i]
                -- 只匹配【可见】的按钮：MultiBarLeft/MultiBarRight 等左右动作条共享 action 槽位，
                -- 同一技能会同时命中左右两个按钮，隐藏栏的按钮 GetActionInfo 也返回该技能，
                -- 若不跳过隐藏按钮，会错误匹配到隐藏栏（导致"拖到右栏却显示在左栏/不显示"）。
                if btn and btn:IsShown() then
                    -- 不判断 btn.action（对齐官方 GetActionButtonBySpellID），MultiBar 按钮
                    -- 的 action 可能为 nil/特殊，直接 GetActionInfo 更稳（nil 时返回 nil 安全跳过）
                    local _, actionSpellID = GetActionInfo(btn.action)
                    if actionSpellID then
                        -- 直接 GetSpellName(actionSpellID)，【不要】GetBaseSpell 重定向：
                        -- GetBaseSpell 会把部分法术重定向成异名基础法术，导致名字匹配失败
                        -- （AutoCDM 的 63cafe4 已踩过此坑，见其"去掉 GetBaseSpell 重定向"）。
                        local actionSpellName = C_Spell.GetSpellName(actionSpellID)
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

-- =========================================================
-- 类型 A：unit aura —— 12.1 AuraContainer 暴雪渲染层
-- =========================================================
-- 重设 AuraButton 内倒计时框锚点。
-- ⚠️ 传坐标时用【绝对屏幕坐标】锚到 UIParent——AuraContainer 的 flow layout 会在光环变化/切目标时
--    异步把容器尺寸覆盖成空布局值(≈1x1)，若 cd 相对 btn/容器锚定会跟着错位；绝对锚定不受影响。
--    无坐标时（initializeFrame 阶段）退化为相对 btn 的临时锚点，之后定位时被绝对锚点覆盖。
local function LayoutAuraChildren(p, left, bottom, width, height, r)
    local cd = p.cd
    if not cd then return end
    if left then
        r = r or 1
        local rx, ry = left * r, bottom * r
        local rw, rh = width * r, height * r
        cd:ClearAllPoints()
        cd:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", rx + 1, ry - 6)
        cd:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", rx + rw * 0.62, ry + rh * 0.62 - 7)
    else
        local btn = p.auraButton
        if not btn then return end
        local w, h = btn:GetSize()
        if not w or w <= 0 then w, h = 36, 36 end
        cd:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 1, -6)
        cd:SetPoint("TOPRIGHT", btn, "BOTTOMLEFT", w * 0.62, h * 0.62 - 7)
    end
end

-- 把容器定位到动作按钮之上（屏幕坐标，绝不锚到按钮；含缩放换算）。
-- 容器是 addon 创建的普通 Frame，SetPoint/SetSize 均可安全调用。
-- ⚠️ 位置(SetPoint)可缓存；尺寸(SetSize)与子控件布局每次都要重做——
--    AuraContainer 的 flow layout 会在光环变化时异步覆盖容器尺寸(OnLayoutComplete→SetSize)，
--    若把 SetSize/子控件布局也缓存跳过，尺寸被覆盖后不再纠正 → 倒计时框错位。
local function PositionContainer(container, btn, p)
    if not container or not btn then return false end
    local left, bottom, width, height = btn:GetRect()
    if not left then
        if Preset.debug and p then
            local btnName = btn.GetName and btn:GetName() or "?"
            local okShown, shown = pcall(function() return btn:IsShown() end)
            print(("|cff33ccff[Preset]|r 光环%s → 按钮%s 定位失败(GetRect=nil, IsShown=%s)"):format(FmtAuraID(p.auraSpellID), tostring(btnName), tostring(okShown and shown)))
        end
        return false
    end
    local r = 1
    local bs, ps = btn:GetEffectiveScale(), UIParent:GetEffectiveScale()
    if bs and ps and ps > 0 then r = bs / ps end
    -- 仅位置变化时才重新 SetPoint（省 ClearAllPoints+SetPoint）
    if not p or p._rectL ~= left or p._rectB ~= bottom or p._rectW ~= width or p._rectH ~= height then
        if Preset.debug and p then
            local btnName = btn.GetName and btn:GetName() or "?"
            print(("|cff33ccff[Preset]|r 光环%s → 按钮%s rect=(%.0f,%.0f,%.0f,%.0f) r=%.3f"):format(FmtAuraID(p.auraSpellID), tostring(btnName), left, bottom, width, height, r))
        end
        container:ClearAllPoints()
        container:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left * r, (bottom + height) * r)
        if p then
            p._rectL, p._rectB, p._rectW, p._rectH = left, bottom, width, height
        end
    end
    -- 尺寸与子控件布局每次重做（对抗暴雪 flow layout 的异步尺寸覆盖）；
    -- cd 用绝对屏幕坐标锚定，容器尺寸即使被覆盖也不会让倒计时框错位
    container:SetSize(width * r, height * r)
    LayoutAuraChildren(p, left, bottom, width, height, r)
    return true
end

-- initializeFrame 回调：暴雪创建 AuraButton 后，addon 注册子控件。
-- ⚠️ 子控件必须 parent 到 btn（ValidateInboundScriptObject 强制 descendant，
--    InitializeInboundScriptObject 禁止之后改 parent），之后由暴雪驱动内容：
--     · cd  → ApplyDurationCooldown → SetCooldownFromDurationObject（倒计时数字自带）
--     · fs  → ApplyApplicationCount → SetText（层数，>1 才显示）
local function SetupAuraButton(p, btn)
    btn:SetAllPoints(p.container)
    local cd = CreateFrame("Cooldown", nil, btn)
    cd:SetDrawSwipe(false)
    cd:SetDrawEdge(false)
    cd:SetHideCountdownNumbers(false)
    btn:SetDurationCooldown(cd)
    p.cd = cd
    local fs = btn:CreateFontString(nil, "OVERLAY")
    fs:SetPoint("TOPLEFT", btn, "TOPLEFT", 5, -5)
    fs:SetFont(S.FONT, S.FONT_SIZE, S.OUTLINE)
    local sc = S.STACK_COLOR or { 1, 1, 1 }
    fs:SetTextColor(sc[1], sc[2], sc[3])
    btn:SetApplicationCount(fs)
    p.stacksFS = fs
    p.auraButton = btn
    LayoutAuraChildren(p)
end

-- 为预设创建 AuraContainer（每预设一个容器，独立定位到各自按钮）。
-- 光环过滤用 includeSpellIDs（按 auraData.spellId 精确匹配光环 ID）。
local function InitAuraPreset(p)
    if p.container then return true end
    if p._initFailed then return false end  -- 上次战斗中创建失败 → 等脱战重试
    local unit = p.unit or "player"
    local filter = p.filter or "HELPFUL"

    local container = CreateFrame("AuraContainer", nil, UIParent, "CustomAuraContainerTemplate")
    container:SetFrameStrata("HIGH")
    container:SetFrameLevel(1000)
    container:SetSize(36, 36)
    container:SetUnit(unit)
    container:SetEnabled(true)
    -- ⚠️ 先挂引用：AddAuraSlot 的 initializeFrame 回调【同步】执行，
    --   SetupAuraButton 里要用 p.container 做 SetAllPoints
    p.container = container

    -- 归一化光环 ID（支持单个 number 或 {id1,id2} 数组，任一命中即显示）
    local auraIDs = p.auraSpellID
    local includeSpellIDs = {}
    if type(auraIDs) == "table" then
        for _, id in ipairs(auraIDs) do includeSpellIDs[id] = true end
    elseif auraIDs then
        includeSpellIDs[auraIDs] = true
    end

    local auraFrame
    local ok = pcall(function()
        auraFrame = container:AddAuraSlot("preset", filter, {
            candidateFilters = { includeSpellIDs = includeSpellIDs },
            initializeFrame = function(btn) SetupAuraButton(p, btn) end,
        })
    end)
    if not ok then
        p._initFailed = true
        p.container = nil
        container:Hide()
        return false
    end
    p.auraFrame = auraFrame
    container:Show()
    return true
end

-- Cooldown 倒计时数字 FontString 要等暴雪首次 SetCooldownFromDurationObject 后才存在，
-- 用低频 ticker 轮询，设置一次字体/颜色后标记完成（幂等、廉价）。
-- ⚠️ 数字 FontString 带 secret aspect，SetFont/SetTextColor 包 pcall 防御。
local function ApplyCountdownFont(p)
    local cd = p.cd
    if not cd or p.cdStyled then return end
    local cds = cd.GetCountdownFontString and cd:GetCountdownFontString()
    if not cds then return end
    local unit = p.unit or "player"
    local c = (S.GetTimeColor and S.GetTimeColor(unit, false)) or S.TIME_COLOR_OTHER_BUFF or { 1, 1, 0 }
    pcall(function()
        cds:SetFont(S.FONT, S.FONT_SIZE, S.OUTLINE)
        cds:SetTextColor(c[1], c[2], c[3])
    end)
    p.cdStyled = true
end

local function UpdatePresetAura(p)
    if not p.auraSpellID or not p.actionSpellID then return end
    -- 玩家没学该施放技能（如元素萨满没学水之护盾/闪电之盾）→ 跳过，不追踪不刷屏
    if not IsPlayerSpell(p.actionSpellID) then
        return
    end
    if not InitAuraPreset(p) then return end
    local container = p.container

    -- 解析显示目标按钮（缓存，找不到时 ticker 定期重试；该 actionSpellID 必须放在动作条上）
    if not p.button then
        p.button = FindActionButtonForSpellName(C_Spell.GetSpellName(p.actionSpellID))
    end
    local btn = p.button
    if not btn then
        -- 只提示一次（找到后重置），避免 ticker/重试反复刷屏
        if Preset.debug and not p._btnMissingLogged then
            print(("|cff33ccff[Preset]|r 光环%s → 技能%s 按钮【未找到】"):format(FmtAuraID(p.auraSpellID), p.actionSpellID))
            p._btnMissingLogged = true
        end
        container:Hide()
        return
    end
    p._btnMissingLogged = nil
    if not PositionContainer(container, btn, p) then
        container:Hide()
        return
    end
    -- 容器保持可见以接收 UNIT_AURA（ShouldRegisterForDynamicEvents = IsVisible and IsEnabled）；
    -- AuraButton 的显隐由暴雪 ApplyVisibility 控制（有光环显示、无光环隐藏）
    container:Show()
    ApplyCountdownFont(p)
end

-- =========================================================
-- 类型 B：武器临时附魔（weaponEnchant）
--   走 item enchant 通道（非 unit aura），12.1 战斗中也能检测（GetWeaponEnchantInfo 战斗安全）。
--   返回该 enchantID 的【剩余秒数】；未找到返回 nil。
--     · 主路径 GetWeaponEnchantInfo()  —— 直接返回 enchantID + 剩余毫秒到期，/1000 即剩余秒（BuffReminders 实测）
--     · 兜底 C_PaperDollInfo.GetTemporaryEnchantmentInfo —— 12.1 官方替代 API
-- =========================================================
local function GetWeaponEnchantExpiration(enchantID, enchantName)
    -- 主路径：旧 API（用户实测 12.1 仍可用）
    local ok, hasMain, mainExp, _, mainID, hasOff, offExp, _, offID = pcall(GetWeaponEnchantInfo)
    if ok then
        if mainID == enchantID and mainExp then return mainExp / 1000 end
        if offID == enchantID and offExp then return offExp / 1000 end
    end
    -- 兜底：12.1 新 API。返回结构 TemporaryItemEnchantInfo{enchantID, remainingTimeMs, ...}，
    -- 按 enchantID 匹配（注意：结构无 Name 字段，旧代码按名字匹配是错的）
    local function trySlot(slot)
        local fok, info = pcall(C_PaperDollInfo.GetTemporaryEnchantmentInfo, slot)
        if fok and info and info.enchantID == enchantID and info.remainingTimeMs then
            return info.remainingTimeMs / 1000
        end
    end
    for _, slot in ipairs({ 16, 17 }) do  -- INVSLOT_MAINHAND, INVSLOT_OFFHAND
        local sec = trySlot(slot)
        if sec and sec > 0 then return sec end
    end
    return nil
end

-- 武器附魔倒计时【每秒】驱动：GetWeaponEnchantInfo 是【非 aura 通道】，战斗中也能安全读取。
-- 由 1 秒 ticker（Tick → RefreshWeaponEnchants）调用，每秒重算剩余时间并刷新 Cooldown
-- （start=now、duration=剩余秒）。不再挂每帧 OnUpdate——降频省 CPU，1 秒精度对武器附魔足够。
local function EnchantTick(ov)
    local p = ov._preset
    if not p then return end
    local expSec = GetWeaponEnchantExpiration(p.enchantID, p.enchantName)
    if not expSec or expSec <= 0 then
        ov:Hide()
        ov._active = false
        return
    end
    local w, h = ov:GetSize()
    local cd = p.cd
    cd:SetParent(ov)
    cd:ClearAllPoints()
    cd:SetPoint("BOTTOMLEFT", ov, "BOTTOMLEFT", 1, -6)
    cd:SetPoint("TOPRIGHT", ov, "BOTTOMLEFT", w * 0.62, h * 0.62 - 7)
    cd:SetDrawSwipe(false)
    cd:SetDrawEdge(false)
    cd:SetHideCountdownNumbers(false)
    pcall(function() cd:SetCooldown(GetTime(), expSec) end)
    local cds = cd.GetCountdownFontString and cd:GetCountdownFontString()
    if cds then
        cds:SetFont(S.FONT, S.FONT_SIZE, S.OUTLINE)
        local c = S.TIME_COLOR_SELF or { 0.20, 1.00, 0.20 }  -- 自身附魔：鲜绿
        cds:SetTextColor(c[1], c[2], c[3])
    end
    if p.stacksFS then p.stacksFS:Hide() end
    cd:Show()
    ov:Show()
    ov._active = true
end

-- 类型 B 覆盖层容器：UIParent 中立容器（与动作按钮【零锚依赖】，绝不 SetPoint 到按钮）。
-- 位置用 btn:GetRect() 读屏幕矩形再摆放（只读，不污染安全帧）。
local function GetOverlay(p)
    if p.overlay then return p.overlay end
    local ov = CreateFrame("Frame", nil, UIParent)
    ov:SetFrameStrata("HIGH")
    ov:SetFrameLevel(1000)
    ov:SetSize(36, 36)
    ov:Hide()
    -- 自建显示层（无 CDM 对象可 reparent）：倒计时 Cooldown + 层数 FontString
    local cd = CreateFrame("Cooldown", nil, ov)
    cd:SetHideCountdownNumbers(false)   -- 显示倒计时数字
    cd:Hide()
    local fs = ov:CreateFontString(nil, "OVERLAY")
    fs:Hide()
    p.overlay = ov
    p.cd = cd
    p.stacksFS = fs
    return ov
end

-- 类型 B 覆盖层定位。overlay 是 addon 自建的普通 Frame，尺寸/位置完全由 addon 控制，
-- 无暴雪异步覆盖 → 坐标未变即可完整跳过 SetPoint/SetSize（每秒 ticker 省去无谓锚点操作）。
local function PositionOverlay(ov, btn, p)
    if not ov or not btn then return false end
    local left, bottom, width, height = btn:GetRect()
    if not left then return false end
    if p and p._rectL == left and p._rectB == bottom and p._rectW == width and p._rectH == height then
        return true  -- 位置未变，跳过重设
    end
    local r = 1
    local bs, ps = btn:GetEffectiveScale(), UIParent:GetEffectiveScale()
    if bs and ps and ps > 0 then r = bs / ps end
    ov:ClearAllPoints()
    ov:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left * r, (bottom + height) * r)
    ov:SetSize(width * r, height * r)
    if p then
        p._rectL, p._rectB, p._rectW, p._rectH = left, bottom, width, height
    end
    return true
end

local function UpdatePresetWeaponEnchant(p)
    if not p.enchantID or not p.actionSpellID then return end
    -- 玩家没学该施放技能（如元素萨满没学风怒/大地生命/唤潮护卫）→ 跳过，不追踪不刷屏
    if not IsPlayerSpell(p.actionSpellID) then
        return
    end
    if not p.button then
        p.button = FindActionButtonForSpellName(C_Spell.GetSpellName(p.actionSpellID))
    end
    local btn = p.button
    if not btn then
        if Preset.debug then print(("|cff33ccff[Preset]|r 武器附魔%s → 技能%s 按钮【未找到】"):format(p.enchantID, p.actionSpellID)) end
        return
    end
    local ov = GetOverlay(p)
    if not PositionOverlay(ov, btn, p) then
        ov:Hide()
        return
    end
    -- 武器附魔走非 aura 通道，战斗安全：由 1 秒 ticker 刷新（即使此刻正处于战斗）
    ov._preset = p
    EnchantTick(ov)   -- 立即填充一次（之后由 Tick → RefreshWeaponEnchants 每秒刷新）
end

-- 武器附魔非 unit aura → 战斗中也能检测；由 1 秒 ticker 刷新剩余时间（不读 aura，零 taint）
local function RefreshWeaponEnchants()
    for _, p in ipairs(ACTIVE_PRESETS) do
        if p.presetType == "weaponEnchant" then
            pcall(UpdatePresetWeaponEnchant, p)
        end
    end
end

-- =========================================================
-- 全量刷新
-- =========================================================
local function UpdatePreset(p)
    if p.presetType == "weaponEnchant" then
        UpdatePresetWeaponEnchant(p)
    else
        UpdatePresetAura(p)
    end
end

local function RefreshAll()
    for _, p in ipairs(ACTIVE_PRESETS) do
        pcall(UpdatePreset, p)
    end
end

-- 低频 ticker：类型 A 重定位容器 + 轮询倒计时字体；类型 B 清理到期/重附魔
local function Tick()
    for _, p in ipairs(ACTIVE_PRESETS) do
        if p.presetType ~= "weaponEnchant" then
            pcall(UpdatePresetAura, p)
        end
    end
    RefreshWeaponEnchants()
end

-- =========================================================
-- 对外接口（供配置面板/诊断调用；预设模块本身常开，无 enable 开关）
-- =========================================================
function Preset.RefreshAll()
    RefreshAll()
end

-- 类型 A：光环是否激活（AuraButton 显隐由暴雪控制；IsShown 在 12.1 可能返回 secret，防御处理）
local function AuraFrameShown(p)
    local f = p.auraFrame
    if not f then return false end
    local ok, shown = pcall(function() return f:IsShown() end)
    if not ok or IsSecret(shown) then return false end
    return not not shown
end

-- =========================================================
-- 诊断状态（/preset）与调试开关（/preset debug）
-- =========================================================
function Preset.Status()
    print("|cff33ccff[Preset]|r 预设数量:" .. #ACTIVE_PRESETS .. "（常开，无开关）")
    for _, p in ipairs(ACTIVE_PRESETS) do
        local actionName = C_Spell.GetSpellName(p.actionSpellID) or "?"
        local btn = p.button
        if p.presetType == "weaponEnchant" then
            local exp = GetWeaponEnchantExpiration(p.enchantID, p.enchantName)
            print(("  武器附魔%s[%s] → 技能[%s/%s] 按钮:%s 到期:%s 覆盖层:%s")
                :format(
                    p.enchantID,
                    p.enchantName or "?",
                    p.actionSpellID, actionName,
                    btn and "找到" or "未找到",
                    exp and ("%.0f秒"):format(exp) or "无",
                    (p.overlay and p.overlay:IsShown()) and "显示" or "隐藏"))
        else
            print(("  光环%s → 技能[%s/%s] 按钮:%s 容器:%s 光环显示:%s")
                :format(
                    FmtAuraID(p.auraSpellID),
                    p.actionSpellID, actionName,
                    btn and "找到" or "未找到",
                    p.container and "已建" or (p._initFailed and "建失败(等脱战)" or "未建"),
                    AuraFrameShown(p) and "显示" or "隐藏"))
        end
    end
end

SLASH_BARPRESET1 = "/preset"
SlashCmdList.BARPRESET = function(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if msg == "debug" then
        Preset.debug = not Preset.debug
        ActionbarEnhancedDB = ActionbarEnhancedDB or {}
        ActionbarEnhancedDB.presetDebug = Preset.debug
        print(("|cff33ccff[ActionbarEnhanced]|r 预设调试日志：%s"):format(Preset.debug and "开启" or "关闭"))
        RefreshAll()
    else
        Preset.Status()
    end
end

-- =========================================================
-- 事件
-- =========================================================
-- 动作条/页面/形态/载具/御龙术切换事件集合（对齐 Manual：翻页 PAGE_CHANGED、御龙术 OVERRIDE
-- 等场景不触发 SLOT_CHANGED，需一并监听才能让"切条后数字消失/跟随"及时生效）。
local actionbarEvents = {
    ACTIONBAR_SLOT_CHANGED       = true,
    ACTIONBAR_PAGE_CHANGED       = true,
    UPDATE_BONUS_ACTIONBAR       = true,
    UPDATE_OVERRIDE_ACTIONBAR    = true,
    UPDATE_SHAPESHIFT_FORM       = true,
    UPDATE_POSSESS_BAR           = true,
    UPDATE_MULTI_CAST_ACTIONBAR  = true,
}

local evFrame = CreateFrame("Frame")
evFrame:RegisterEvent("PLAYER_LOGIN")
for ev in pairs(actionbarEvents) do evFrame:RegisterEvent(ev) end
evFrame:RegisterEvent("PLAYER_REGEN_ENABLED")   -- 脱战：重试战斗中建失败的容器/刷新受限光环
evFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")  -- 武器附魔（重附/替换/卸下）立即刷新
evFrame:RegisterEvent("UNIT_INVENTORY_CHANGED")    -- 同上兜底
evFrame:RegisterUnitEvent("UNIT_AURA", "player")
evFrame:RegisterEvent("PLAYER_TARGET_CHANGED")   -- 切目标：unit="target" 的容器需手动刷新

evFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        -- 按当前职业构建生效预设（PRESETS 手动 + SELF_BUFFS 按职业自动过滤）
        local _, classToken = UnitClass("player")
        BuildActivePresets(classToken)
        -- 登录后稍候一帧再刷新，确保动作条按钮已就绪
        C_Timer.After(0, RefreshAll)
        -- 低频 ticker：类型 A 重定位/字体 + 类型 B 清理（AuraContainer 内部自行监听 UNIT_AURA）
        C_Timer.NewTicker(1, Tick)
    elseif actionbarEvents[event] then
        -- 动作条/页面/形态/载具/御龙术切换：清缓存 + 延迟重匹配。
        -- ⚠️ 绝不【立即】RefreshAll：ACTIONBAR_PAGE_CHANGED 等事件在 SetActionBarPage 的保护上下文
        --    同步触发，立即操作容器(SetPoint/SetSize)会被 taint/block，导致倒计时框错位/变色/变大小。
        --    改为延迟重试，且每次重试前都清 p.button（否则第一次会把过渡态按钮缓存进 p.button 固化）。
        local function invalidateButtons()
            for _, p in ipairs(ACTIVE_PRESETS) do
                p.button = nil
                p._rectL, p._rectB, p._rectW, p._rectH = nil, nil, nil, nil
            end
        end
        invalidateButtons()
        C_Timer.After(0.1, function() invalidateButtons(); RefreshAll() end)
        C_Timer.After(0.5, function() invalidateButtons(); RefreshAll() end)
    elseif event == "UNIT_AURA" then
        -- 仅触发刷新（容器内部已由暴雪监听并驱动 AuraButton；这里负责重定位等）
        RefreshAll()
    elseif event == "PLAYER_TARGET_CHANGED" then
        -- 切目标：AuraContainer 不监听目标切换，unit="target" 的容器不会自动跟随，
        -- 需显式触发其重新解析光环（暴雪目标框也是这么做：UpdateAuras→UpdateAllAuras）。
        for _, p in ipairs(ACTIVE_PRESETS) do
            if p.presetType ~= "weaponEnchant" and p.unit == "target" and p.container then
                pcall(function() p.container:UpdateAllAuras() end)
            end
        end
        -- UpdateAllAuras 触发 FullAuraRebuild，flow layout 会在下一帧把容器尺寸覆盖成空布局值
        -- （ApplyFlowLayout 无条件 OnLayoutComplete→SetSize）。延迟一小段后重新定位，
        -- 避免倒计时框短暂错位（否则要等 1 秒 ticker 才纠正）。
        C_Timer.After(0.05, function()
            for _, p in ipairs(ACTIVE_PRESETS) do
                if p.presetType ~= "weaponEnchant" and p.unit == "target" then
                    pcall(UpdatePresetAura, p)
                end
            end
        end)
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- 脱战：解除战斗中建容器失败的限制，重试创建并刷新
        for _, p in ipairs(ACTIVE_PRESETS) do p._initFailed = nil end
        RefreshAll()
    elseif event == "PLAYER_EQUIPMENT_CHANGED" or event == "UNIT_INVENTORY_CHANGED" then
        -- 武器附魔变化：直接刷新（不走 aura 受限逻辑，战斗中也安全）
        RefreshWeaponEnchants()
    end
end)
