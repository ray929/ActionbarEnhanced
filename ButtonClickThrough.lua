-- ActionbarEnhanced/ButtonClickThrough.lua
-- 技能栏鼠标穿透（ClickThrough）：关闭指定原生动作条的鼠标捕获，点击穿透到下方。
--
-- ⚠️ 为什么必须用安全环境（SecureHandler）：
--   原生动作条按钮是【受保护帧】。若用普通(非安全) Lua 直接调用 btn:EnableMouse(false)，
--   该帧会被打上 taint 标记，且【永久】生效于本次会话。之后暴雪的安全代码（编辑模式 EnterEditMode、
--   战斗中动作条更新等）遍历到这些帧时会报错：
--     "attempted to iterate a table that cannot be accessed while tainted"
--   即使用户不进战斗，仅打开编辑模式就会触发。
--   解决：用 SecureHandlerStateTemplate + RegisterStateDriver，在【安全环境】中切换 EnableMouse，
--   帧不会被 taint，编辑模式/战斗均不受影响。
--
-- 原理：每个栏一个安全处理器承载该栏帧引用，_onstate-ct 片段（安全环境）按 newstate 切换
--   EnableMouse（on=true → 穿透/EnableMouse(false)）。RegisterStateDriver 重注册不同表达式会在
--   安全环境触发片段执行，且不会引入 taint。
-- 副作用：悬停 tooltip 失效（依赖 EnableMouse）；键盘绑定仍可用（走安全属性，与鼠标无关）。
-- 配置存于 ActionbarEnhancedDB.clickThrough[1..8]，默认全 false（不穿透）。

ActionbarEnhanced = ActionbarEnhanced or {}
local BAR = ActionbarEnhanced
BAR.ButtonClickThrough = BAR.ButtonClickThrough or {}

local MOD = BAR.ButtonClickThrough

-- 栏序号 1-8 → 父帧名 + 按钮名前缀
--  1 = 主动作条（ActionBar1 / ActionButton1..12）
--  2 = MultiBarBottomLeft（底部左）
--  3 = MultiBarBottomRight（底部右）
--  4 = MultiBarRight（右侧）
--  5 = MultiBarLeft（左侧）
--  6 = MultiBar5
--  7 = MultiBar6
--  8 = MultiBar7
local BARS = {
    { frame = "ActionBar1",          prefix = "ActionButton" },
    { frame = "MultiBarBottomLeft",  prefix = "MultiBarBottomLeftButton" },
    { frame = "MultiBarBottomRight", prefix = "MultiBarBottomRightButton" },
    { frame = "MultiBarRight",       prefix = "MultiBarRightButton" },
    { frame = "MultiBarLeft",        prefix = "MultiBarLeftButton" },
    { frame = "MultiBar5",           prefix = "MultiBar5Button" },
    { frame = "MultiBar6",           prefix = "MultiBar6Button" },
    { frame = "MultiBar7",           prefix = "MultiBar7Button" },
}

-- 每栏一个安全处理器，承载该栏帧引用并负责在安全环境切换 EnableMouse
local handlers = {}

local function BuildHandler(i)
    if handlers[i] then return handlers[i] end
    local cfg = BARS[i]
    if not cfg then return nil end
    -- 安全处理器模板：提供 _onstate 安全片段执行能力
    local h = CreateFrame("Frame", "ABEClickThrough" .. i, nil, "SecureHandlerStateTemplate")
    local bar = _G[cfg.frame]
    if bar then h:SetFrameRef("bar", bar) end
    for n = 1, 12 do
        local btn = _G[cfg.prefix .. n]
        if btn then h:SetFrameRef("b" .. n, btn) end
    end
    -- 安全片段：on=true → 穿透（关鼠标）；on=false → 恢复点击。运行于安全环境，不 taint。
    h:SetAttribute("_onstate-ct", [[
        local on = tonumber(newstate) == 1
        local bar = self:GetFrameRef("bar")
        if bar then bar:EnableMouse(not on) end
        for i = 1, 12 do
            local b = self:GetFrameRef("b" .. i)
            if b then b:EnableMouse(not on) end
        end
    ]])
    handlers[i] = h
    return h
end

-- 在安全环境应用某栏（on=true 穿透）。RegisterStateDriver 重注册不同表达式会在安全环境触发 _onstate-ct。
local function ApplySecure(i, on)
    local h = BuildHandler(i)
    if not h then return end
    RegisterStateDriver(h, "ct", on and "1" or "0")
end

-- 强制在安全环境重施（暴雪编辑模式退出/翻页后可能恢复交互性）。
-- 先注册反向、再注册目标，确保 _onstate-ct 必定触发一次，且最终态正确（两次注册同帧内完成，无可见闪烁）。
local function ReapplySecure(i, on)
    local h = BuildHandler(i)
    if not h then return end
    RegisterStateDriver(h, "ct", on and "0" or "1")
    RegisterStateDriver(h, "ct", on and "1" or "0")
end

-- =========================================================
-- 配置开关（存盘于 ActionbarEnhancedDB.clickThrough[1..8]，默认全 false）
-- =========================================================
function MOD.EnsureDB()
    ActionbarEnhancedDB = ActionbarEnhancedDB or {}
    ActionbarEnhancedDB.clickThrough = ActionbarEnhancedDB.clickThrough or {}
    for i = 1, 8 do
        if ActionbarEnhancedDB.clickThrough[i] == nil then
            ActionbarEnhancedDB.clickThrough[i] = false
        end
    end
end

-- 读取某栏是否开启穿透（i: 1-8）
function MOD.IsEnabled(i)
    return ActionbarEnhancedDB and ActionbarEnhancedDB.clickThrough
        and ActionbarEnhancedDB.clickThrough[i] == true
end

-- 全量初始应用（载入时调用）：对已开启的栏在安全环境应用穿透
function MOD.Apply()
    MOD.EnsureDB()
    for i = 1, 8 do
        if MOD.IsEnabled(i) then
            ApplySecure(i, true)
        end
    end
end

-- 切换某栏穿透（i: 1-8, v: bool）。非战斗即时生效；战斗中仅存盘、脱离战斗后重施。
function MOD.SetEnabled(i, v)
    MOD.EnsureDB()
    ActionbarEnhancedDB.clickThrough[i] = v
    if InCombatLockdown() then
        print("|cffff6666[ActionbarEnhanced]|r 战斗中无法即时应用，脱离战斗后将自动生效。")
        return
    end
    if v then
        ReapplySecure(i, true)
    else
        ApplySecure(i, false)   -- 恢复点击
    end
end

-- 载入即确保 DB；登录（非战斗）时应用已开启的穿透栏。
-- 各事件重施已开启栏，抵消暴雪可能恢复的交互性（编辑模式退出 / 翻页 / 进战斗后等）。
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("ACTIONBAR_PAGE_CHANGED")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
-- 防重入 + 延迟 0.1s：彻底脱离保护功能(SetActionBarPage)的调用栈后再重施，
-- 避免 RegisterStateDriver 在保护上下文被 ADDON_ACTION_BLOCKED
-- （C_Timer.After(0) 仍可能与事件同帧执行，不够安全）。
local reapplyPending = false
local function ScheduleReapply()
    if reapplyPending then return end
    reapplyPending = true
    C_Timer.After(0.1, function()
        reapplyPending = false
        for i = 1, 8 do
            if MOD.IsEnabled(i) then
                ReapplySecure(i, true)
            end
        end
    end)
end

ev:SetScript("OnEvent", function()
    MOD.EnsureDB()
    ScheduleReapply()
end)
