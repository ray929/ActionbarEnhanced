-- ActionbarEnhanced/ButtonColor.lua
-- 动作条按钮变色：整合 GreyOnCooldown（CD 中变灰）与 tullaRange（超出范围变红）的功能，
-- 并新增「资源不足 → 蓝色」状态。三种状态独立判定、由本模块统一设置图标颜色，互不冲突。
--
-- 状态优先级（互斥，高优先级覆盖低优先级）：
--   1) CD 中        → 图标去色（灰色）   —— 最高优先级，此时技能根本不可施放
--   2) 资源不足     → 蓝色 vertex color  —— 缺蓝/缺能量/缺怒气等（notEnoughMana）
--   3) 超出范围     → 红色 vertex color  —— 目标在射程外
--   4) 其余         → 正常（白色 vertex + 不透明度恢复）
--
-- 实现要点：
--   · 直接修改原生动作条按钮的 icon 纹理（SetDesaturation / SetVertexColor），属 texture 操作，
--     taint-safe，战斗中照常工作（与原生 ActionButton_UpdateUsable 同性质）。
--   · 通过 ActionBarButtonEventsFrame:ForEachFrame 注册所有原生动作条按钮（含 Multibar 等），
--     hook 其 Update / UpdateUsable（均加 type=="function" 保护），并 hook 全局
--     ActionButton_UpdateCooldown 与 ActionButton_UpdateRangeIndicator 安全函数，
--     以及 cooldown:OnCooldownDone 时刷新；同时 hook RegisterFrame 覆盖登录后动态创建的按钮。
--     ⚠️ 零售版动作按钮【实例】没有 UpdateCooldown 方法，只能钩全局 ActionButton_UpdateCooldown。
--   · CD 判定：CooldownInfo.isOnGCD 字段「只在响应 SPELL_UPDATE_COOLDOWN 事件时可信」，任意时机
--     读它会把 GCD 误判成真实冷却导致全灰。故只在 SPELL_UPDATE_COOLDOWN 事件里读取并缓存每个按钮的
--     真实冷却态（BC._cdCache），其余刷新时机复用缓存，绝不跨时机读 isOnGCD。
--     效果：有 CD 技能用了立即灰（使用即触发该事件），纯 GCD 波及的技能不灰，且不再全灰。
--     ⚠️ 也绝不可比较 startTime/duration/GetRemainingDuration 等 secret number 数值（tainted 下报错）。
--   · 资源判定用 C_ActionBar.IsUsableAction → (isUsable, notEnoughMana)，缺资源且不可用即变蓝。
--   · 范围判定用 IsActionInRange(action) 明确为 false/0 才认作超范围（无射程技能返回 nil 不处理）。
--   · 事件驱动刷新（合并同帧多次事件），事件兜底覆盖 CD / 资源 / 范围 / 翻页 / 姿态切换。
--   · 单一配置开关存于 ActionbarEnhancedDB.buttonColor.enabled（角色级存档，默认开启）。

local BAR = ActionbarEnhanced
if not BAR then return end

local BC = {}
BAR.ButtonColor = BC

-- 颜色（RGB，0~1）；变灰走 desaturation 不依赖颜色
-- 资源不足 → 红10% 绿30% 蓝100%（偏蓝）；超出范围 → 红100% 绿30% 蓝10%（偏红）
local COLOR = {
    oom    = { 0.10, 0.30, 1.00 },  -- 资源不足
    oor    = { 1.00, 0.30, 0.10 },  -- 超出范围
}
-- 彩色态降饱和度强度（0=原色，1=全灰）；CD 灰态仍用 1
local DESAT_COLOR = 0.6

-- =========================================================
-- 配置开关（存盘于 ActionbarEnhancedDB.buttonColor.enabled，默认开启）
-- =========================================================
function BC.EnsureDB()
    ActionbarEnhancedDB = ActionbarEnhancedDB or {}
    ActionbarEnhancedDB.buttonColor = ActionbarEnhancedDB.buttonColor or {}
    if ActionbarEnhancedDB.buttonColor.enabled == nil then
        ActionbarEnhancedDB.buttonColor.enabled = true
    end
end

function BC.IsEnabled()
    return ActionbarEnhancedDB and ActionbarEnhancedDB.buttonColor
        and ActionbarEnhancedDB.buttonColor.enabled ~= false
end

function BC.SetEnabled(v)
    BC.EnsureDB()
    ActionbarEnhancedDB.buttonColor.enabled = v
    if v then
        BC.Start()
        print("|cff33ccff[ActionbarEnhanced]|r 动作条按钮变色已【启用】。")
    else
        BC.Stop()
        print("|cff33ccff[ActionbarEnhanced]|r 动作条按钮变色已【关闭】。")
    end
end

-- =========================================================
-- 取按钮当前指向的 spellID（spell / macro 兼容，同 CooldownGlow 思路）
-- =========================================================
local function GetButtonSpellID(btn)
    if not btn.action then return nil end
    local ok, at, id = pcall(GetActionInfo, btn.action)
    if not ok or not at or not id then return nil end
    if at == "spell" then
        return (id > 0) and id or nil
    elseif at == "macro" then
        if not (id and id > 0) then return nil end
        local sid
        if C_Macro and C_Macro.GetMacroSpell then
            local _, spellID = C_Macro.GetMacroSpell(id)
            sid = spellID
        elseif GetMacroSpell then
            local _, spellID = GetMacroSpell(id)
            sid = spellID
        end
        if not (sid and sid > 0) then
            local okN, nm = pcall(function()
                return (C_Spell and C_Spell.GetSpellName) and C_Spell.GetSpellName(id) or GetSpellInfo(id)
            end)
            if okN and nm then sid = id end
        end
        return (sid and sid > 0) and sid or nil
    end
    return nil
end

-- =========================================================
-- 判定动作是否处于“真实冷却”（排除纯 GCD）。
-- 关键：CooldownInfo.isOnGCD 字段 wiki 明确「只在响应 SPELL_UPDATE_COOLDOWN 事件时可信」，
-- 任意时机（UNIT_POWER_UPDATE / ACTIONBAR_UPDATE_COOLDOWN / hook UpdateUsable 等）读它不可靠，
-- 会把 GCD 误判成真实冷却导致全灰。故采用【缓存】策略：
--   · 只在 SPELL_UPDATE_COOLDOWN 事件（isOnGCD 唯一可信时机）里读取并缓存每个按钮的真实冷却态；
--   · 其余所有刷新时机复用缓存，绝不跨时机读 isOnGCD。
-- 效果：用了的有 CD 技能立即灰（使用即触发 SPELL_UPDATE_COOLDOWN），纯 GCD 波及的技能不灰，且不再全灰。
-- =========================================================
-- 冷却状态缓存：btn -> true/false（是否真实冷却）。weak keys，按钮回收自动清。
BC._cdCache = setmetatable({}, { __mode = "k" })

-- 计算单按钮是否处于真实冷却（⚠️ 仅在 SPELL_UPDATE_COOLDOWN 等 isOnGCD 可信时机调用）
local function ComputeRealCooldown(btn)
    local action = btn.action
    if action then
        local ok, cd = pcall(C_ActionBar.GetActionCooldown, action)
        if ok and cd and cd.isActive == true and not cd.isOnGCD then
            return true
        end
        return false
    end
    local sid = GetButtonSpellID(btn)
    if sid and C_Spell and C_Spell.GetSpellCooldown then
        local ok, cd = pcall(C_Spell.GetSpellCooldown, sid)
        if ok and cd and type(cd) == "table" and cd.isActive == true and not cd.isOnGCD then
            return true
        end
    end
    return false
end

-- 刷新全部按钮的冷却缓存（只在 SPELL_UPDATE_COOLDOWN 事件调用）
local function RefreshCooldownCache()
    for btn in pairs(BC._buttons) do
        BC._cdCache[btn] = ComputeRealCooldown(btn)
    end
end

-- =========================================================
-- 判定按钮状态："cooldown" / "oom" / "oor" / "normal"
-- =========================================================
local function GetButtonState(btn)
    local action = btn.action
    local sid = GetButtonSpellID(btn)
    if not action and not sid then return "normal" end

    -- 1) CD 中（最高优先级）：读冷却缓存（由 SPELL_UPDATE_COOLDOWN 可信时机维护）。
    --    用了的有 CD 技能：使用即触发 SPELL_UPDATE_COOLDOWN → 缓存立即置真 → 立即灰；
    --    纯 GCD 波及的技能：可信读到 isOnGCD=true → 缓存为假 → 不灰。绝不跨时机读 isOnGCD。
    if BC._cdCache[btn] then
        return "cooldown"
    end

    -- 2) 可用性：取一次 usable 状态，分别判定 资源不足 / 不可用（复用，省一次 pcall）
    local isUsable, notEnoughMana
    if action and C_ActionBar and C_ActionBar.IsUsableAction then
        local ok, u, m = pcall(C_ActionBar.IsUsableAction, action)
        if ok then isUsable, notEnoughMana = u, m end
    elseif sid and C_Spell and C_Spell.IsSpellUsable then
        local ok, u, m = pcall(C_Spell.IsSpellUsable, sid)
        if ok then isUsable, notEnoughMana = u, m end
    end

    -- 2a) 资源不足（缺蓝/缺资源）→ 蓝色
    if isUsable == false and notEnoughMana == true then
        return "oom"
    end
    -- 2b) 不可用（背包中不存在的物品 / 无可用次数 / 其它）→ 灰色（原生灰显行为的还原）
    --     ⚠️ 关键：Blizzard 本就用 desaturation 把"不可用"按钮灰掉；本插件此前在 "normal"
    --        态把图标强制 Reset 成满色，会把这种原生灰显覆盖成彩色（用户反馈"不存在的物品也是彩色的"）。
    if isUsable == false and notEnoughMana == false then
        return "unusable"
    end

    -- 3) 超出范围（最后）：IsActionInRange 明确 false/0 才认作超范围（nil = 无射程，不处理）
    local inRange
    if action then
        if C_ActionBar and C_ActionBar.IsActionInRange then
            local ok, r = pcall(C_ActionBar.IsActionInRange, action)
            if ok then inRange = r end
        elseif IsActionInRange then
            local ok, r = pcall(IsActionInRange, action)
            if ok then inRange = r end
        end
    end
    if inRange == false or inRange == 0 then return "oor" end

    return "normal"
end

-- =========================================================
-- 应用状态到按钮 icon（统一收口，三态不互相覆盖）
-- =========================================================
local function ApplyState(btn, state)
    local icon = btn.icon
    if not icon then return end
    if state == "cooldown" then
        icon:SetDesaturation(1)
    elseif state == "unusable" then
        -- 背包中不存在的物品 / 不可用：原生灰显，与原生 ActionButton_UpdateUsable 一致
        icon:SetDesaturation(1)
    elseif state == "oom" then
        icon:SetDesaturation(DESAT_COLOR)
        icon:SetVertexColor(COLOR.oom[1], COLOR.oom[2], COLOR.oom[3], 1)
    elseif state == "oor" then
        icon:SetDesaturation(DESAT_COLOR)
        icon:SetVertexColor(COLOR.oor[1], COLOR.oor[2], COLOR.oor[3], 1)
    else
        icon:SetDesaturation(0)
        icon:SetVertexColor(1, 1, 1, 1)
    end
end

-- 已注册按钮集合（用于全量刷新 / 关闭时恢复）
BC._buttons = BC._buttons or {}

-- 更新单个按钮（hook 到 Update / UpdateUsable / UpdateCooldown 时回调）
function BC.UpdateButton(btn)
    if not btn or not btn.icon then return end
    if not BC.IsEnabled() then return end
    ApplyState(btn, GetButtonState(btn))
end

-- 更新所有已注册按钮
function BC.RefreshAll()
    if not BC.IsEnabled() then return end
    for btn in pairs(BC._buttons) do
        BC.UpdateButton(btn)
    end
end

-- 注册单个按钮：记录 + hook 刷新时机（幂等）
local function RegisterButton(btn)
    if not btn or BC._buttons[btn] then return end
    BC._buttons[btn] = true
    if type(btn.UpdateUsable) == "function" then
        hooksecurefunc(btn, "UpdateUsable", BC.UpdateButton)
    end
    if type(btn.Update) == "function" then
        hooksecurefunc(btn, "Update", BC.UpdateButton)
    end
    if btn.cooldown then
        btn.cooldown:HookScript("OnCooldownDone", function()
            BC._cdCache[btn] = false       -- 冷却结束，直接清缓存
            BC.UpdateButton(btn)
        end)
    end
end

-- 射程实时刷新（10.1.5+ 事件式 API）：目标进出射程时引擎直接调用此安全函数，
-- 仅此路径能可靠捕获射程变化（ACTIONBAR_UPDATE_USABLE 不会因单纯射程变动而触发）。
hooksecurefunc("ActionButton_UpdateRangeIndicator", function(button)
    if not button or not button.icon then return end
    RegisterButton(button)            -- 幂等，确保按钮已注册
    if BC._buttons[button] then BC.UpdateButton(button) end
end)

-- 冷却刷新：钩全局 ActionButton_UpdateCooldown（零售版动作按钮实例没有 UpdateCooldown
-- 方法，实例钩子会报 "not a function"）。引擎每次刷新冷却都会调用此全局函数。
hooksecurefunc("ActionButton_UpdateCooldown", function(self)
    if self and BC._buttons[self] then BC.UpdateButton(self) end
end)

-- =========================================================
-- 事件驱动刷新（合并同帧多次事件，每帧至多刷新一次）
-- =========================================================
local dirty = false
local dispatchFrame = CreateFrame("Frame")
dispatchFrame:Hide()
dispatchFrame:SetScript("OnUpdate", function(self)
    self:Hide()
    dirty = false
    if BC.IsEnabled() then BC.RefreshAll() end
end)

local function ScheduleRefresh()
    if dirty then return end
    dirty = true
    dispatchFrame:Show()
end

-- =========================================================
-- 启动 / 停止
-- =========================================================
function BC.Start()
    -- 注册现有按钮
    if ActionBarButtonEventsFrame and ActionBarButtonEventsFrame.ForEachFrame then
        pcall(ActionBarButtonEventsFrame.ForEachFrame, ActionBarButtonEventsFrame, RegisterButton)
    end
    -- 未来动态创建的按钮（动作条重建/扩展）
    if ActionBarButtonEventsFrame and not BC._regHook then
        hooksecurefunc(ActionBarButtonEventsFrame, "RegisterFrame", function(f)
            if f then RegisterButton(f) end
        end)
        BC._regHook = true
    end
    -- 确保事件帧已监听（Start 可能在 SetEnabled 时二次调用，重复注册无害）
    if BC._evFrame then
        BC._evFrame:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
        BC._evFrame:RegisterEvent("ACTIONBAR_PAGE_CHANGED")
        BC._evFrame:RegisterEvent("UPDATE_BONUS_ACTIONBAR")
        BC._evFrame:RegisterEvent("UPDATE_VEHICLE_ACTIONBAR")
        BC._evFrame:RegisterEvent("UPDATE_POSSESS_BAR")
        BC._evFrame:RegisterEvent("ACTIONBAR_UPDATE_COOLDOWN")
        BC._evFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
        BC._evFrame:RegisterEvent("SPELL_UPDATE_CHARGES")
        BC._evFrame:RegisterEvent("ACTIONBAR_UPDATE_USABLE")
        BC._evFrame:RegisterEvent("ACTIONBAR_UPDATE_STATE")
        BC._evFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
        BC._evFrame:RegisterEvent("UNIT_FLAGS")
        BC._evFrame:RegisterEvent("UNIT_POWER_UPDATE")
    end
    BC._started = true
    RefreshCooldownCache()  -- 初始化冷却缓存
    -- 立即刷新一次
    BC.RefreshAll()
end

function BC.Stop()
    if BC._evFrame then
        BC._evFrame:UnregisterAllEvents()
    end
    if BC._started then
        -- 恢复所有按钮颜色为原生外观
        for btn in pairs(BC._buttons) do
            if btn.icon then
                btn.icon:SetDesaturation(0)
                btn.icon:SetVertexColor(1, 1, 1, 1)
            end
        end
        BC._started = false
    end
end

-- =========================================================
-- 事件帧（PLAYER_LOGIN 启动；其余事件合并刷新）
-- =========================================================
local evFrame = CreateFrame("Frame")
BC._evFrame = evFrame
evFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" then
        BC.EnsureDB()
        if BC.IsEnabled() then BC.Start() end
        return
    end
    if event == "SPELL_UPDATE_COOLDOWN" then
        -- isOnGCD 唯一可信时机：同步更新冷却缓存，再合并刷新应用
        RefreshCooldownCache()
        ScheduleRefresh()
        return
    end
    if event == "UNIT_POWER_UPDATE" then
        local unit = ...
        if unit == "player" or unit == "pet" then ScheduleRefresh() end
        return
    end
    ScheduleRefresh()
end)
evFrame:RegisterEvent("PLAYER_LOGIN")

-- 文件加载即确保 DB 存在（SavedVariables 已在 ADDON_LOADED 注入）
BC.EnsureDB()
