-- ActionbarEnhanced/CooldownGlow.lua
-- 冷却高亮提醒：读取暴雪冷却管理器（CDM）【主冷却 / Main cooldowns】分组里的技能，
-- 当某技能冷却完成（就绪可用）后用 LibCustomGlow 的 Proc Glow 给对应动作条按钮高亮，
-- 并【保持常亮】直到该技能被使用（重新进入冷却）才熄灭——一眼看清哪些大招可用。
-- 无论战斗内外、何时都高亮（不做战斗限制）。
--
-- 设计要点：
--   · 数据源走 C_CooldownViewer.GetCooldownViewerCategorySet(Enum.CooldownViewerCategory.Essential, false)，
--     只取用户在 CDM【主冷却】分组里放置的技能；辅助/隐藏分组（Utility 等）不发光。
--   · 发光用 LibCustomGlow-1.0 的 ProcGlow：glow 帧挂在 UIParent（taint-safe），
--     仅把动作按钮作为锚父，可安全用于安全动作条按钮，战斗中照常工作。
--   · 就绪发光（时长可配）：tracked 集合已是用户精选的「主冷却」技能，故就绪（冷却帧隐藏）就发光、
--     冷却中（冷却帧可见，即技能打出去）就熄灭。每个技能可单独设「常亮」或「就绪后亮 N 秒自动熄灭」，
--     按专精保存（见 CG.GetDuration / CG.SetDuration）。
--   · 是否在冷却通过【C_Spell.GetSpellCooldown(sid).isActive】判定——12.x 新增的 NeverSecret 布尔：
--     冷却激活(含GCD与真实冷却)为 true，完全就绪(startTime/duration=0)为 false。读取/布尔判断均安全，
--     绝不触发 12.x 的「secret number 比较」报错（冷却帧 GetCooldownTimes 返回的 start/duration 是 secret，
--     不可算术比较）。施放后整段冷却高亮熄灭，冷却结束才重新亮起，无闪烁。
--   · 刷新采用事件驱动（参考 VFlow 的 SpellStateWatcher）：监听 ACTIONBAR_UPDATE_COOLDOWN /
--     SPELL_UPDATE_COOLDOWN / SPELL_UPDATE_CHARGES 等，用 dispatchFrame 把同帧多次事件合并为一次
--     评估，去掉原 0.2s 轮询 ticker，更省 CPU、更跟手。
--   · 单一配置开关「是否启用冷却高亮提醒」，存于 ActionbarEnhancedDB.cooldownGlow.enabled，
--     存档为角色级（## SavedVariablesPerCharacter），故每个角色独立保存、互不干扰。
--   · 动作条切换（翻页/姿态/载具/额外动作条）通过事件重评估，发光跟随按钮当前指向的技能。

local BAR = ActionbarEnhanced
if not BAR then return end

local CG = {}
BAR.CooldownGlow = CG

-- 取得 LibCustomGlow（LibStub 在 CooldownGlow 加载前已由 .toc 先加载）
local LCG = LibStub and LibStub("LibCustomGlow-1.0", true)
CG._LCG = LCG


-- =========================================================
-- 配置开关（存盘于 ActionbarEnhancedDB.cooldownGlow.enabled，默认开启）
-- 账号级 SavedVariables → 战网账号共享生效。
-- =========================================================
function CG.EnsureDB()
    ActionbarEnhancedDB = ActionbarEnhancedDB or {}
    ActionbarEnhancedDB.cooldownGlow = ActionbarEnhancedDB.cooldownGlow or {}
    if ActionbarEnhancedDB.cooldownGlow.enabled == nil then
        ActionbarEnhancedDB.cooldownGlow.enabled = true
    end
end

function CG.IsEnabled()
    return ActionbarEnhancedDB and ActionbarEnhancedDB.cooldownGlow
        and ActionbarEnhancedDB.cooldownGlow.enabled ~= false
end

function CG.SetEnabled(v)
    CG.EnsureDB()
    ActionbarEnhancedDB.cooldownGlow.enabled = v
    if v then
        CG.Start()
        print("|cff33ccff[ActionbarEnhanced]|r 冷却高亮提醒已【启用】。")
    else
        CG.StopAll()
        print("|cff33ccff[ActionbarEnhanced]|r 冷却高亮提醒已【关闭】。")
    end
end

-- =========================================================
-- 读取 CDM「已启用」的技能冷却 spellID 集合
--   注意：GetCooldownViewerCategorySet 返回的是该类别下【所有已知】技能 cooldownID，
--   不等于"用户已启用显示"。真正"已启用"=CDM viewer 屏幕上正在显示的 item frame。
--   用户拖到"不显示"分组的技能不会出现在 viewer 的 active items 里，自然被排除。
-- =========================================================
-- 只取 CDM【主冷却 / Main cooldowns】(Enum.CooldownViewerCategory.Essential) 分组里、
-- 且用户在 CDM 设置中实际【启用显示】的技能发光。
--
-- ⚠️ 关键：不能用 GetCooldownViewerCategorySet 取全部分类成员——它返回的是该分类下
--   【所有已学】技能（含用户在 CDM 里设为「不显示」的），无法体现用户隐藏过滤。
--   正确来源是 EssentialCooldownViewer 这个全局 viewer 的 active item frame：
--   只有用户真正启用显示的技能才会出现在 itemFramePool 的 active 列表里
--   （参考 VFlow 的 BuffScanner / StyleLayout：扫 viewer.itemFramePool:EnumerateActive()，
--   每个 frame 挂 cooldownID → GetCooldownViewerCooldownInfo → spellID）。
--   这样「只启用灰烬觉醒」就能精准做到只有它发光。
--   冷启动（重载后 viewer 尚未登记 active item）时 active 列表为空 → 不发光，
--   由登录后延迟重评估（C_Timer.After）与后续冷却事件补齐，不会长时间空白。
--   ❌ 绝不可回退 GetCooldownViewerCategorySet(Essential)：那会返回全分类【所有已学】技能
--      （含用户故意未监控的），导致「CDM 监控为空时所有技能都发光」。

-- 从单个 cooldownID 解析出用于匹配的 spellID：优先 linkedSpellIDs[1]（VFlow 同款顺序），
-- 其次 overrideSpellID，最后 spellID，覆盖天赋/形态变体导致的动作条 spellID 不一致。
local function ResolveSpellID(info)
    if not info then return nil end
    if info.linkedSpellIDs and info.linkedSpellIDs[1] then
        return info.linkedSpellIDs[1]
    end
    return info.overrideSpellID or info.spellID
end

-- 扫 EssentialCooldownViewer 当前实际显示的 item frame（= 用户在 CDM 启用的主冷却技能）
local function GetTrackedFromViewer()
    local set = {}
    local viewer = _G.EssentialCooldownViewer
    if not viewer or not viewer.itemFramePool or not viewer.itemFramePool.EnumerateActive then
        return set
    end
    for frame in viewer.itemFramePool:EnumerateActive() do
        local cid = frame and frame.cooldownID
        if cid then
            local ok, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cid)
            if ok and info then
                local sid = ResolveSpellID(info)
                if sid and sid > 0 then set[sid] = true end
                -- 仍补充所有关联 spellID，避免个别变体漏匹配
                if info.linkedSpellIDs then
                    for _, lsid in ipairs(info.linkedSpellIDs) do
                        if lsid and lsid > 0 then set[lsid] = true end
                    end
                end
            end
        end
    end
    return set
end

-- 始终以 EssentialCooldownViewer 的 active item 为准（= 用户在 CDM 实际启用的主冷却技能）。
-- 绝不可用 GetCooldownViewerCategorySet 兜底"全部分类成员"——那会返回该分类下【所有已学】
-- 技能（含用户故意未监控的），导致"CDM 监控为空时所有技能都发光"（bug #3）。
-- 用户把某技能从 CDM 监控里移除 → 它不在 active item 中 → 不再发光，符合预期。
-- 冷启动（viewer 尚未建立 item frame）时返回空集，由登录后延迟重评估（C_Timer.After）
-- 与后续冷却事件补齐，不会长时间空白。
-- ⚡ 性能：Evaluate 在战斗中随冷却事件频繁触发，若每次都调 GetTrackedFromViewer() 全量扫描
--   EssentialCooldownViewer 的 active item（每个帧一次 GetCooldownViewerCooldownInfo pcall），
--   会成为最大 CPU 开销。改用缓存 CG._trackedCache：仅由 0.5s ticker（ComputeTracked）刷新，
--   Evaluate / 配置面板直接复用缓存，避免每事件重复扫描。
CG._trackedCache = CG._trackedCache or {}

-- 重新扫描 EssentialCooldownViewer 刷新缓存，并返回当前签名（排序拼接 spellID）。
local function ComputeTracked()
    local set = GetTrackedFromViewer()
    CG._trackedCache = set
    local ids = {}
    for sid in pairs(set) do
        ids[#ids + 1] = sid
    end
    table.sort(ids)
    return table.concat(ids, ",")
end

-- 取当前 CDM【主冷却】分组实际启用的技能集合（复用缓存；缓存为空时回退一次实时扫描，兼容冷启动）。
local function GetTrackedSpellIDs()
    if not next(CG._trackedCache) then
        return GetTrackedFromViewer()
    end
    return CG._trackedCache
end
-- 暴露给配置面板：取当前 CDM【主冷却】分组实际启用的技能集合
CG.GetTrackedSpellIDs = GetTrackedSpellIDs

-- CDM【主冷却】当前实际启用技能集合的签名（排序拼接 spellID），由缓存推导。
-- 用户在 CDM 主冷却分组里【增删法术】会改变该集合，但这类改动不会触发冷却事件，
-- 故由 0.5s ticker 比对签名检测变化并重评估（见文件尾部 ticker）。
function CG.GetTrackedSignature()
    local ids = {}
    for sid in pairs(CG._trackedCache) do
        ids[#ids + 1] = sid
    end
    table.sort(ids)
    return table.concat(ids, ",")
end

-- 某 spellID 的冷却信息（start/duration/enabled），兼容两种返回形态：
--   · 旧客户端全局 GetSpellCooldown：三返回值 (start, duration, enabled)
--   · 12.x C_Spell.GetSpellCooldown：返回 CooldownInfo 表 {startTime, duration, isEnabled, modRate, ...}
-- ⚠️ 12.0+ 全局 GetSpellCooldown 已被移除/隐藏（直接调用报 "attempt to call a nil value"），必须优先用 C_Spell。
local GetSpellCD = (C_Spell and C_Spell.GetSpellCooldown) or GetSpellCooldown

local function SpellCDVals(spellID)
    if not spellID or not GetSpellCD then return nil end
    local ok, a, b, c = pcall(GetSpellCD, spellID)
    if not ok then return nil end
    if type(a) == "table" then
        return a.startTime, a.duration, (a.isEnabled and 1 or 0), a.isActive
    end
    return a or 0, b or 0, c or 0
end

local function IsSpellReady(spellID)
    if not spellID or not GetSpellCD then return false end
    local ok, a, b, c = pcall(GetSpellCD, spellID)
    if not ok then return false end
    if type(a) == "table" then
        -- 12.x CooldownInfo：startTime/duration 是 secret number，禁止算术/比较；用 isActive 判定
        if a.isEnabled == false then return false end
        return a.isActive == false
    end
    -- 旧客户端：三返回值 (start, duration, enabled)
    local start, duration, enabled = a, b, c
    if enabled == 0 then return false end
    if not duration or duration <= 0 then return true end  -- 无冷却 = 就绪
    local now = GetTime()
    return now >= (start + duration)
end

-- 扫描所有动作条按钮（玩家主动作条 + 多动作条）；不扫 Stance/Pet（其 action 与技能 spellID 不直接对应）
local ACTION_BAR_PREFIXES = {
    "ActionButton",
    "MultiBarBottomLeftButton",
    "MultiBarBottomRightButton",
    "MultiBarRightButton",
    "MultiBarLeftButton",
}

-- 取按钮当前指向的 spellID。
-- 直接 spell 类型：返回 id。
-- 宏类型：解析宏内第一个法术（玩家常把带条件的技能放进宏，必须解析才能匹配 CDM 追踪列表）。
--   12.x: C_Macro.GetMacroSpell；旧客户端: GetMacroSpell（均返回 name, spellID, ...）。
-- flyout / item / 其他类型：返回 nil（无法稳定落到单一按钮发光）。
local function GetButtonSpellID(btn)
    if not btn.action then return nil end
    local ok, at, id = pcall(GetActionInfo, btn.action)
    if not ok or not at or not id then return nil end
    if at == "spell" then
        return (id > 0) and id or nil
    elseif at == "macro" then
        if not (id and id > 0) then return nil end
        -- 1) 按宏书索引解析宏内法术（多法术宏 / 旧客户端）
        local sid
        if C_Macro and C_Macro.GetMacroSpell then
            local _, spellID = C_Macro.GetMacroSpell(id)
            sid = spellID
        elseif GetMacroSpell then
            local _, spellID = GetMacroSpell(id)
            sid = spellID
        end
        -- 2) 现代客户端单 /cast 宏：GetActionInfo 直接把 spellID 作为 id 返回，
        --    GetMacroSpell(id) 解析失败（不存在该宏索引）。此时若 id 本身是真实法术则直接采用。
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

-- 当前正在发光的按钮（反向索引便于停止）
CG._glowing = CG._glowing or {}     -- [button] = spellID
CG._expiry = CG._expiry or {}       -- [sid] = 到期时间戳（限时高亮用）；nil = 常亮
CG._wasCd = CG._wasCd or {}         -- [sid] = 上一次评估是否处于冷却（上升沿检测用）
CG._timers = CG._timers or {}       -- [sid] = 兜底 C_Timer 句柄（到点强制重评估熄灭）

-- 前向声明：ScheduleEvaluate 在文件后部（事件驱动刷新段）用 local 定义，但本文件
-- SetExpiry 等逻辑在它之前就需要引用。Lua 中「声明点之前」的同名引用会被编译为【全局】
-- （此处全局不存在 → nil 报错）；故先在此声明 local，后部定义时直接赋值给这个 local，
-- 使 SetExpiry / ticker 里的引用都正确指向局部函数。
local ScheduleEvaluate

local function ProcGlowStart(btn)
    if not LCG then return end
    -- ⚠️ 关键防叠层：LibCustomGlow 每次 ProcGlow_Start 都会新建一张 _ProcGlowBAR 发光帧，
    --   不会复用/顶替上一张（key 仅用于 Stop 查找，不是"同 key 替换"）。若重复 Start
    --   而不先 Stop，发光帧会逐层叠加、越来越厚（用户反馈的"叠层越来越厚重"根因）。
    --   因此每次 Start 前先确保旧帧已移除：能查到就 Stop 一次（幂等），再 Start 新帧。
    if btn then
        pcall(LCG.ProcGlow_Stop, btn, "BAR")
    end
    LCG.ProcGlow_Start(btn, { key = "BAR", startAnim = true, color = { 0.3, 1.0, 0.4, 1 }, scale = 0.8 })
end

local function ProcGlowStop(btn)
    if not LCG then return end
    -- ⚠️ 必须与 ProcGlowStart 的 key 一致（"BAR"）→ 否则 ProcGlow_Stop 查 r["_ProcGlow"] 找不到
    --    r["_ProcGlowBAR"]，返回 nil 不释放 → 发光帧永久残留（"一直高亮" 的真正根因）。
    LCG.ProcGlow_Stop(btn, "BAR")
end

-- 停止单个按钮发光并清理状态
local function StopGlow(btn)
    ProcGlowStop(btn)
    CG._glowing[btn] = nil
end

-- 判定按钮是否处于「冷却」中（停止高亮用）。
-- 用 isActive（NeverSecret 布尔：含 GCD 与真实冷却为 true，就绪为 false）排除纯 GCD：
--   isActive=true 且 isOnGCD=false → 真实冷却中 → 熄灭高亮；
--   isActive=true 且 isOnGCD=true  → 仅 GCD（施放其他技能触发）→ 保持高亮，避免"用任意技能高亮闪灭 1~2 秒"。
-- ⚠️ startTime/duration 是 secret number，绝不能算术/比较/tostring（会抛 secret 报错）；只用这两个布尔。
local function IsOnCooldown(btn, sid)
    if not sid then return false end
    if not GetSpellCD then
        -- 极旧客户端兜底（无 C_Spell.GetSpellCooldown）：依赖冷却帧可见性
        if btn and btn.cooldown and btn.cooldown:IsShown() then return true end
        if btn and btn.chargeCooldown and btn.chargeCooldown:IsShown() then return true end
        return false
    end
    local ok, cd = pcall(GetSpellCD, sid)
    if ok and type(cd) == "table" then
        -- 真实冷却（非纯 GCD）才熄灭；纯 GCD 保持高亮
        if cd.isActive and not cd.isOnGCD then return true end
        return false
    end
    -- pcall 失败（如法术不存在）→ 按未冷却处理，保持高亮，避免误灭
    return false
end

-- 当前专精 ID（无专精返回 0）
local function GetCurrentSpecID()
    local idx = GetSpecialization()
    if idx and idx > 0 then
        return GetSpecializationInfo(idx) or 0
    end
    return 0
end

-- 设置某技能的限时到期时间；dur<=0 表示常亮（无到期）。
-- 同时安排一个「到点兜底」timer：限时到点时即便没有冷却事件触发，也强制重评估熄灭。
local function SetExpiry(sid, dur)
    if dur and dur > 0 then
        CG._expiry[sid] = GetTime() + dur
        if CG._timers[sid] then
            pcall(CG._timers[sid].Cancel, CG._timers[sid])
            CG._timers[sid] = nil
        end
        CG._timers[sid] = C_Timer.After(dur, function()
            CG._timers[sid] = nil
            ScheduleEvaluate()
        end)
    else
        CG._expiry[sid] = nil
        -- 改回常亮时，取消之前为该技能注册的兜底 timer，避免它到点仍触发重评估
        if CG._timers[sid] then
            pcall(CG._timers[sid].Cancel, CG._timers[sid])
            CG._timers[sid] = nil
        end
    end
end

-- 对外：读取/写入某技能的高亮时长（按当前专精保存）。
--   N = 0 / 缺省 = 常亮；1~5 = 就绪后亮 N 秒自动熄灭。
function CG.GetDuration(sid)
    if not (ActionbarEnhancedDB and ActionbarEnhancedDB.cooldownGlow) then return 0 end
    local cg = ActionbarEnhancedDB.cooldownGlow
    local specID = GetCurrentSpecID()
    local durs = cg.specs and cg.specs[specID] and cg.specs[specID].durations
    return (durs and durs[sid]) or 0
end

function CG.GetDurations(specID)
    CG.EnsureDB()
    local cg = ActionbarEnhancedDB.cooldownGlow
    cg.specs = cg.specs or {}
    local spec = cg.specs[specID] or {}
    cg.specs[specID] = spec
    spec.durations = spec.durations or {}
    return spec.durations
end

function CG.SetDuration(sid, n)
    CG.EnsureDB()
    local durs = CG.GetDurations(GetCurrentSpecID())
    if not n or n == 0 then
        durs[sid] = nil
    else
        durs[sid] = n
    end
    -- 配置变更即时生效：直接让该技能进入新的时长状态（常亮→限时立即开始计时；
    -- 限时→常亮立即取消计时并恢复常亮），不依赖 Evaluate 的 _wasCd/_expiry 判断，
    -- 也不依赖「先做动作」才触发。随后强制一次重评估。
    SetExpiry(sid, n or 0)
    ScheduleEvaluate()
end

-- 重评估：遍历动作条按钮 → 取按钮自身 spellID → CDM【主冷却】白名单过滤
--   → 就绪发光：在「主冷却」分组里、且当前就绪（冷却帧隐藏）的技能按钮发光；
--     进入真实冷却（非纯 GCD，即「技能打出去了」）立即熄灭；施放其他技能触发的纯 GCD 不影响。
--   → 高亮时长：常亮（dur=0）一直亮到施放；限时（dur=N）就绪瞬间亮、N 秒后自动熄灭（即使仍就绪）。
-- 用「按钮自身 spellID」做匹配，避免 CDM spellID 与动作条 spellID 不一致导致的匹配失败。
function CG.Evaluate()
    if not CG.IsEnabled() then return end

    local now = GetTime()

    -- 1) CDM【主冷却】白名单 + 当前专精的时长表（仅用于过滤/查时长，不反查按钮）
    local tracked = GetTrackedSpellIDs()
    local cg = ActionbarEnhancedDB.cooldownGlow
    local durs = (cg.specs and cg.specs[GetCurrentSpecID()] and cg.specs[GetCurrentSpecID()].durations) or {}

    -- 2) 遍历所有动作条按钮
    local shouldGlow = {}
    for _, prefix in ipairs(ACTION_BAR_PREFIXES) do
        for i = 1, 12 do
            local btn = _G[prefix .. i]
            if btn and btn:IsShown() and btn.action then
                local sid = GetButtonSpellID(btn)
                if sid and sid > 0 and tracked[sid] then
                    local onCd = IsOnCooldown(btn, sid)
                    if onCd then
                        -- 进入/处于冷却（技能打出去）：立即熄灭，清到期与待触发 timer，记录冷却态
                        CG._expiry[sid] = nil
                        if CG._timers[sid] then
                            pcall(CG._timers[sid].Cancel, CG._timers[sid])
                            CG._timers[sid] = nil
                        end
                        CG._wasCd[sid] = true
                    else
                        -- 就绪：按「时长配置」维护到期时间
                        --   · 上升沿（刚转好）/ 首见即就绪 → 设到期（开始计时）
                        --   · 当前无到期（运行时由常亮改为限时）→ 立即开始计时
                        --   · 限时已设（steady 状态 / 已到点）→ 不重置，沿用
                        local dur = durs[sid] or 0
                        if dur > 0 then
                            if CG._wasCd[sid] or CG._wasCd[sid] == nil or not CG._expiry[sid] then
                                SetExpiry(sid, dur)
                            end
                        else
                            CG._expiry[sid] = nil
                        end
                        CG._wasCd[sid] = false
                        local exp = CG._expiry[sid]
                        if exp and now > exp then
                            shouldGlow[btn] = false        -- 限时已到：不再亮（即使仍就绪）
                        else
                            shouldGlow[btn] = true
                            if not CG._glowing[btn] then
                                ProcGlowStart(btn)
                                CG._glowing[btn] = sid
                            end
                        end
                    end
                end
            end
        end
    end

    -- 3) 停止发光：按钮不再应发光（指向改变 / 不再被主冷却追踪 / 进入冷却 / 限时到点）即熄灭
    for btn in pairs(CG._glowing) do
        if not shouldGlow[btn] then
            StopGlow(btn)
        end
    end

end

-- 停止所有发光（关闭开关 / 卸载评估时）
function CG.StopAll()
    if not LCG then return end
    for btn in pairs(CG._glowing) do
        LCG.ProcGlow_Stop(btn, "BAR")
    end
    CG._glowing = {}
    -- 清理限时状态：取消待触发 timer，清空到期与冷却态缓存
    for sid, t in pairs(CG._timers) do
        pcall(t.Cancel, t)
        CG._timers[sid] = nil
    end
    for sid in pairs(CG._expiry) do CG._expiry[sid] = nil end
    for sid in pairs(CG._wasCd) do CG._wasCd[sid] = nil end
end

-- 事件驱动刷新（参考 VFlow 的 SpellStateWatcher）：
-- 用 dispatchFrame 把「同一帧内」的多次冷却/动作条事件合并成一次 Evaluate，
-- 既避免 0.2s 轮询 ticker 的开销，又比逐事件立即评估更省（每帧至多评估一次）。
local dirty = false
local dispatchFrame = CreateFrame("Frame")
dispatchFrame:Hide()
dispatchFrame:SetScript("OnUpdate", function(self)
    self:Hide()
    dirty = false
    if CG.IsEnabled() then CG.Evaluate() end
end)

ScheduleEvaluate = function()
    if dirty then return end
    dirty = true
    dispatchFrame:Show()
end

function CG.Start()
    if not LCG then
        -- 不再静默失败：用户能在聊天框直接看到这条，避免「没报错也没高亮」的困惑
        print("|cff33ccff[ActionbarEnhanced]|r 错误：LibCustomGlow 未加载，冷却高亮不可用（检查 Libs/LibCustomGlow-1.0 是否正确加载）")
        return
    end
    ComputeTracked()        -- 启动时先刷新一次 CDM 主冷却缓存，避免首评为空
    ScheduleEvaluate()
end

-- =========================================================
-- 事件：动作条切换 / 冷却变化 → 重评估
-- =========================================================
local evFrame = CreateFrame("Frame")
CG._evFrame = evFrame
evFrame:RegisterEvent("PLAYER_LOGIN")
evFrame:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
evFrame:RegisterEvent("ACTIONBAR_PAGE_CHANGED")
evFrame:RegisterEvent("UPDATE_BONUS_ACTIONBAR")
evFrame:RegisterEvent("UPDATE_VEHICLE_ACTIONBAR")
evFrame:RegisterEvent("UPDATE_POSSESS_BAR")
evFrame:RegisterEvent("ACTIONBAR_UPDATE_COOLDOWN")
evFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
evFrame:RegisterEvent("SPELL_UPDATE_CHARGES")   -- 充能技能冷却变化
evFrame:RegisterEvent("SPELLS_CHANGED")
evFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
evFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
evFrame:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")

evFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        CG.EnsureDB()
        if CG.IsEnabled() then
            CG.Start()
            -- 登录后延迟一次重评估：CDM viewer 的 active item 可能在登录瞬间尚未登记
            -- （冷启动），延后补一次让发光能正常出现，避免「启用却没亮」的空白期。
            if C_Timer and C_Timer.After then
                C_Timer.After(1.0, function()
                    if CG.IsEnabled() then ScheduleEvaluate() end
                end)
                -- 二次延迟：防 viewer 在 1s 时仍未就绪的极端冷启动（避免迟迟不亮）
                C_Timer.After(3.0, function()
                    if CG.IsEnabled() then ScheduleEvaluate() end
                end)
            end
    else
        -- 开关关闭时不发光（无需其他处理）
    end
    else
        -- 动作条切换 / 冷却变化 / 天赋变动：合并到下一帧统一评估（同帧多次事件只评估一次）
        ScheduleEvaluate()
    end
end)

-- 供配置面板 / 外部刷新入口
function CG.RefreshAll()
    CG.Evaluate()
end

-- 检测用户在 CDM【主冷却】分组里增删法术：这类改动不会改变按钮冷却状态，
-- 因此冷却事件不会被触发、事件驱动的 Evaluate 不会自跑，导致新增技能不发光、
-- 移除的技能继续亮。用一个低频 ticker 比对 tracked 集合签名，变化即重评估，
-- 让动作条实际发光状态与 CDM 主冷却成员保持同步。
local lastTrackedSig = ""
-- 每 0.5s 在此【唯一】重新扫描一次 CDM 主冷却成员（刷新缓存 + 取签名），
-- Evaluate 不再每次扫描，冷却事件高频时省下大量 GetCooldownViewerCooldownInfo pcall。
C_Timer.NewTicker(0.5, function()
    local sig = ComputeTracked()
    if not CG.IsEnabled() then
        -- 开关关闭时不发光；同步签名避免下次开启瞬间误触发
        lastTrackedSig = sig
        return
    end
    local need = false
    -- 1) CDM 主冷却成员变化 → 重评估（新增/移除技能）
    if sig ~= lastTrackedSig then
        lastTrackedSig = sig
        need = true
    end
    -- 2) 限时到期双保险：玩家「不做任何动作」时不会触发冷却事件，仅靠 C_Timer.After
    --    兜底 timer 唤醒重评估；若它偶发未触发，这里每隔 0.5s 检测到期并强制熄灭，
    --    确保「就绪后亮 N 秒」必然到点熄灭（最多延迟 0.5s），不必等玩家使用技能。
    if not need then
        local now = GetTime()
        for _, exp in pairs(CG._expiry) do
            if exp and now > exp then
                need = true
                break
            end
        end
    end
    if need then
        ScheduleEvaluate()
    end
end)


