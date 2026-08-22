-- ActionbarEnhanced/TrinketGlow.lua
-- 主动饰品动作条高亮提醒：当动作条上的【主动饰品】就绪（不在冷却）时，
-- 用 LibCustomGlow 的 Proc Glow 给对应动作条按钮高亮，提醒玩家「饰品可用」。
-- 移植自 MiniTrinketGlow（Verz），按本插件模块规范精简：
--   · 仅一个总开关（存 ActionbarEnhancedDB.trinketGlow.enabled），无战斗限制、无黑名单；
--   · 发光用项目已加载的 LibCustomGlow-1.0（ProcGlow），glow key 用 "TG" 与冷却高亮的 "BAR" 区分；
--   · 仅覆盖原生动作条按钮（与 CooldownGlow 同套前缀），第三方动作条（BT4/Dominos）不处理。
--
-- 就绪判定（忠实移植 MiniTrinketGlow）：
--   GetInventoryItemCooldown("player", slot13/14) 返回传统三值 (start, duration, usable)，
--   均为普通 number（非 secret，区别于 C_ActionBar.GetActionCooldown 的 CooldownInfo secret 值），
--   可直接比较：
--     usable == 1 且 start == 0 且 duration == 0 → 饰品就绪 → 高亮；否则熄灭。
--   · usable ~= 1 → 被动饰品（无"使用"效果）→ 不高亮（原版天然排除被动饰品）。
--   · GCD 期间暴雪让 start/duration 反映 GCD → 判定为非就绪 → 发光消失（此乃 MiniTrinketGlow 固有行为，
--     与原版一致，不做特殊修补）。GCD 结束后 ACTIONBAR_UPDATE_COOLDOWN + CheckTrinketUsed 延时重评会重新点亮。
--
-- 残留/关闭仍发光问题的根因与解法：
--   早前版本只在「非饰品按钮」分支里 GlowOff，饰品移动后旧按钮不再被识别为饰品、也不再被遍历/事件未触发，
--   其 glow 永久残留；关闭开关也只在 SetEnabled(false) 一步 StopAll，时序不对就清不掉。
--   现改为「维护当前发光按钮集合 glowing」：每次 Run 重算 shouldGlow，凡在 glowing 但不在 shouldGlow 的按钮
--   一律熄灭；Run 在禁用时先 ClearAllGlow。任何移动/关闭/翻页都能被正确清干净（与原版逐按钮 Glow(button,glow)
--   的思路一致，天然无残留）。

local BAR = ActionbarEnhanced
if not BAR then return end

local TG = {}
BAR.TrinketGlow = TG

-- LibCustomGlow 已在 .toc 先于本文件加载
local LCG = LibStub and LibStub("LibCustomGlow-1.0", true)
TG._LCG = LCG

-- 发光颜色（鲜黄，区别于冷却高亮的鲜绿）；若 LCG 缺失走暴雪原生 overlay glow 兜底
local TG_COLOR = { 1.0, 1.0, 0.2, 1 }

local TRINKET1 = INVSLOT_TRINKET1 or 13
local TRINKET2 = INVSLOT_TRINKET2 or 14

-- 覆盖的原生动作条按钮前缀（与 CooldownGlow 同套，外加 MultiBar5/6/7）
local PREFIXES = {
    "ActionButton",
    "MultiBarBottomLeftButton",
    "MultiBarBottomRightButton",
    "MultiBarRightButton",
    "MultiBarLeftButton",
    "MultiBar5Button",
    "MultiBar6Button",
    "MultiBar7Button",
}

-- 追踪饰品上次冷却起始 start，用于检测「刚使用」并安排延时重评（原版逻辑）
local lastTrinketStart = { [TRINKET1] = 0, [TRINKET2] = 0 }

-- 当前正在发光的按钮集合（弱键，避免长期持有按钮引用）。Run 用它对账熄灭残留。
local glowing = setmetatable({}, { __mode = "k" })

-- =========================================================
-- 配置开关（存 ActionbarEnhancedDB.trinketGlow.enabled，默认开启）
-- =========================================================
function TG.EnsureDB()
    ActionbarEnhancedDB = ActionbarEnhancedDB or {}
    ActionbarEnhancedDB.trinketGlow = ActionbarEnhancedDB.trinketGlow or {}
    if ActionbarEnhancedDB.trinketGlow.enabled == nil then
        ActionbarEnhancedDB.trinketGlow.enabled = true
    end
end

function TG.IsEnabled()
    return ActionbarEnhancedDB and ActionbarEnhancedDB.trinketGlow
        and ActionbarEnhancedDB.trinketGlow.enabled ~= false
end

function TG.SetEnabled(v)
    TG.EnsureDB()
    ActionbarEnhancedDB.trinketGlow.enabled = v
    if v then
        TG.Start()
        print("|cff33ccff[ActionbarEnhanced]|r 主动饰品动作条高亮提醒已【启用】。")
    else
        TG.ClearAllGlow()
        print("|cff33ccff[ActionbarEnhanced]|r 主动饰品动作条高亮提醒已【关闭】。")
    end
end

-- =========================================================
-- 饰品按钮识别 + 就绪判定（移植自 MiniTrinketGlow）
-- =========================================================
local function GetEquippedTrinketItemID(slot)
    return GetInventoryItemID("player", slot)
end

local function ParseMacroForTrinketSlot(body)
    if not body or body == "" then return nil end
    for line in body:gmatch("[^\r\n]+") do
        line = line:lower()
        line = line:gsub("%s+", " "):gsub("^%s+", "")
        if line:sub(1, 4) == "/use" then
            if line:find(" " .. TRINKET1, 5, true) then return TRINKET1 end
            if line:find(" " .. TRINKET2, 5, true) then return TRINKET2 end
        end
    end
    return nil
end

local function GetMacroBodyFromAction(action)
    local macroName = GetActionText(action)
    if not macroName or macroName == "" then return nil end
    local macroIndex = GetMacroIndexByName(macroName)
    if not macroIndex or macroIndex == 0 then return nil end
    local _, _, body = GetMacroInfo(macroIndex)
    return body
end

local function GetTrinketSlotForAction(action)
    local actionType, id = GetActionInfo(action)
    if actionType == "item" and id then
        local t1 = GetEquippedTrinketItemID(TRINKET1)
        local t2 = GetEquippedTrinketItemID(TRINKET2)
        if t1 and id == t1 then return TRINKET1 end
        if t2 and id == t2 then return TRINKET2 end
        return nil
    elseif actionType == "macro" then
        local body = GetMacroBodyFromAction(action)
        return ParseMacroForTrinketSlot(body)
    end
    return nil
end

-- 检测饰品「刚被使用」（自身 CD 开始）：usable==1 且 start 变化（duration>0）。
-- 返回 true 及 duration，供事件处理安排 duration+0.1 延时重评。
-- 注：GCD 也会让 start 变化并触发此处，但 Run 用 trinketReady 判定，GCD 期间不亮、
-- 结束后自动重评点亮，与原版行为一致。
local function CheckTrinketUsed(slot)
    local start, duration, enable = GetInventoryItemCooldown("player", slot)
    if enable ~= 1 then return false end
    if duration and duration > 0 and start and start > 0 then
        if start ~= lastTrinketStart[slot] then
            lastTrinketStart[slot] = start
            return true, start, duration
        end
    end
    return false
end

-- 缓存「饰品按钮 -> 装备槽位」映射：仅在动作条/装备变化时重建，
-- 避免每次 ACTIONBAR_UPDATE_COOLDOWN（高频）都全量扫描 8 前缀×12 按钮（含解析宏体），
-- 这是 Run 在战斗中频繁触发时的最大 CPU 开销。Run 只遍历这个 0~2 个元素的缓存。
local trinketButtons = {}

local function RebuildTrinketMap()
    wipe(trinketButtons)
    for _, prefix in ipairs(PREFIXES) do
        for i = 1, 12 do
            local btn = _G[prefix .. i]
            if btn and btn.action then
                local slot = GetTrinketSlotForAction(btn.action)
                if slot then
                    trinketButtons[btn] = slot
                end
            end
        end
    end
end

-- =========================================================
-- 发光（glow）控制：用 glowing 集合对账，保证无残留
-- =========================================================
local function ApplyGlow(btn, on)
    if on then
        if not btn.__TrinketGlow then
            if LCG then
                LCG.ProcGlow_Start(btn, { key = "TG", startAnim = true, color = TG_COLOR, scale = 0.9 })
            elseif ActionButton_ShowOverlayGlow then
                ActionButton_ShowOverlayGlow(btn)
            end
            btn.__TrinketGlow = true
        end
        glowing[btn] = true
    else
        if btn.__TrinketGlow then
            if LCG then
                LCG.ProcGlow_Stop(btn, "TG")
            elseif ActionButton_HideOverlayGlow then
                ActionButton_HideOverlayGlow(btn)
            end
            btn.__TrinketGlow = false
        end
        glowing[btn] = nil
    end
end

-- 彻底清除所有发光（含 glowing 集合），用于关闭开关 / 重置
function TG.ClearAllGlow()
    for btn in pairs(glowing) do
        if btn.__TrinketGlow then
            if LCG then
                LCG.ProcGlow_Stop(btn, "TG")
            elseif ActionButton_HideOverlayGlow then
                ActionButton_HideOverlayGlow(btn)
            end
            btn.__TrinketGlow = false
        end
        glowing[btn] = nil
    end
end

-- =========================================================
-- 主循环：重算 shouldGlow，对账熄灭不再应发光的旧按钮
-- =========================================================
local function Run()
    if not TG.IsEnabled() then
        TG.ClearAllGlow()
        return
    end

    -- 1) 计算当前应发光的按钮集合：只遍历已缓存的饰品按钮（0~2 个），
    --    不再每次扫描全部前缀×12 按钮（ACTIONBAR_UPDATE_COOLDOWN 高频触发时大幅省 CPU）。
    local shouldGlow = {}
    for btn, slot in pairs(trinketButtons) do
        local start, duration, usable = GetInventoryItemCooldown("player", slot)
        -- 空槽守卫（2026-08-22）：/use 13|14 宏留在动作条、饰品却被卸下时，
        -- 空槽的冷却查询可能返回 (0,0,1) 被误判「就绪」→ 按钮恒亮黄光。
        -- 槽里没饰品就无「可用」可言，直接不亮。
        local trinketReady = GetInventoryItemID("player", slot) ~= nil
            and (usable == 1) and (start == 0) and (duration == 0)
        if trinketReady then
            shouldGlow[btn] = true
        end
    end

    -- 2) 熄灭：曾在 glowing 但已不在 shouldGlow（饰品移动/换装/翻页/进入 CD 等）
    for btn in pairs(glowing) do
        if not shouldGlow[btn] then
            ApplyGlow(btn, false)
        end
    end

    -- 3) 点亮：应发光且尚未点亮的按钮
    for btn in pairs(shouldGlow) do
        ApplyGlow(btn, true)
    end
end
TG.Run = Run

function TG.Start()
    if not LCG then
        print("|cff33ccff[ActionbarEnhanced]|r 错误：LibCustomGlow 未加载，饰品高亮不可用（检查 Libs/LibCustomGlow-1.0 是否正确加载）")
        return
    end
    RebuildTrinketMap()
    Run()
end

-- =========================================================
-- 事件驱动刷新
-- =========================================================
local evFrame = CreateFrame("Frame")
evFrame:RegisterEvent("PLAYER_LOGIN")
evFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
evFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
evFrame:RegisterEvent("ACTIONBAR_UPDATE_COOLDOWN")
evFrame:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
evFrame:RegisterEvent("ACTIONBAR_PAGE_CHANGED")
evFrame:RegisterEvent("SPELL_UPDATE_USABLE")
-- 宏编辑（增删 /use 13|14 行）不触发 ACTIONBAR_SLOT_CHANGED（槽位内容未变，还是同一个宏），
-- 必须监听 UPDATE_MACROS 才能重建「按钮→饰品槽」映射（原版 MiniTrinketGlow 同款），
-- 否则删掉 /use 行后旧按钮的发光要等到下一次动作条/装备事件才被对账熄灭。
evFrame:RegisterEvent("UPDATE_MACROS")

evFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" then
        TG.EnsureDB()
        if TG.IsEnabled() then
            TG.Start()
            -- 登录后延迟补评：装备/动作条可能在登录瞬间尚未完全就绪（冷启动）
            if C_Timer and C_Timer.After then
                C_Timer.After(1.0, function() if TG.IsEnabled() then Run() end end)
                C_Timer.After(3.0, function() if TG.IsEnabled() then Run() end end)
            end
        end
    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        local slot = ...
        if slot == TRINKET1 or slot == TRINKET2 then
            RebuildTrinketMap()
            Run()
        end
    elseif event == "ACTIONBAR_SLOT_CHANGED" or event == "ACTIONBAR_PAGE_CHANGED" then
        -- 饰品移动/翻页：重建映射并 Run（Run 會自动对账熄灭旧位置发光，无需额外 StopAll）
        RebuildTrinketMap()
        Run()
    elseif event == "ACTIONBAR_UPDATE_COOLDOWN" then
        -- 检测饰品刚使用（自身 CD 开始）→ 安排 duration+0.1 延时重评（原版逻辑）
        local used1, _, duration1 = CheckTrinketUsed(TRINKET1)
        local used2, _, duration2 = CheckTrinketUsed(TRINKET2)
        if used1 and C_Timer then C_Timer.After(duration1 + 0.1, Run) end
        if used2 and C_Timer then C_Timer.After(duration2 + 0.1, Run) end
        Run()
    else
        -- 其它事件（如 PLAYER_ENTERING_WORLD）：重建映射并 Run
        RebuildTrinketMap()
        Run()
    end
end)
