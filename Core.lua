-- ButtonAurasReborn/Core.lua
-- Phase 0+1: 读取 CDM（Cooldown Manager）里"已启用的增益"，供配置 GUI 选择。
--
-- 数据源：扫描 CDM 增益查看器（BuffIconCooldownViewer / BuffBarCooldownViewer）
--   的【当前帧】——viewer:GetItemFrames()。
--   关键：CDM 只为玩家在 Cooldown Manager 里【实际启用】的追踪增益创建 item frame，
--   不管该增益当前是否在身上。因此"帧里出现的"= "已启用的"，这与 vflow /
--   CDMButtonAuras 的可选列表来源完全一致。
--   （配置集 GetCooldownViewerCategorySet 会返回分类下全部条目，含未启用的——已弃用。）
--   spellID 经 GetCooldownViewerCooldownInfo 解析；名称/图标取自 C_Spell.GetSpellInfo（非 unit auras）。

ButtonAurasReborn = ButtonAurasReborn or {}
local BAR = ButtonAurasReborn

-- 运行时：从 CDM 帧读到的玩家增益（每次重新扫描重建）
-- spellID -> { spellID, name, icon }
BAR.knownBuffs = BAR.knownBuffs or {}

-- spellID -> CDM 帧的 cooldownID（用于解析 spellID / 配置列表）
BAR.cdIDBySpell = BAR.cdIDBySpell or {}

-- spellID -> 对应的 CDM item frame（真正的数据来源）
-- 剩余时间/层数不在 GetCooldownViewerCooldownInfo 里（对"追踪型增益"它只给元数据），
-- 而在 frame 自身的 auraDataUnit / auraInstanceID 字段上，再经 C_UnitAuras 取得。
-- 不随 Rescan 清空：由扫描 / 实时 hook 持续刷新（frame 引用是活的，tick 时实时读字段）。
BAR.frameBySpell = BAR.frameBySpell or {}

-- 配置存盘（指向 SavedVariables）
BAR.db = nil

-- 安全判断 secret value（12.0+ 受限内容会返回 secret，不可比较/存盘）
local function IsSecret(v)
    if type(v) ~= "number" then return false end
    local ok, res = pcall(function() return issecretvalue and issecretvalue(v) end)
    return ok and res
end

-- 从 CDM 返回的 info 解析出可用的 spellID
-- 优先级：linkedSpellIDs[1] > overrideSpellID > spellID
local function ResolveSpellID(info)
    if not info then return nil end
    local linked = info.linkedSpellIDs and info.linkedSpellIDs[1]
    if linked and linked > 0 and not IsSecret(linked) then return linked end
    if info.overrideSpellID and info.overrideSpellID > 0 and not IsSecret(info.overrideSpellID) then return info.overrideSpellID end
    if info.spellID and info.spellID > 0 and not IsSecret(info.spellID) then return info.spellID end
    return nil
end

-- 把某个 spellID 写入 knownBuffs（不重复覆盖名称/图标）
local function RegisterBuff(spellID)
    if not spellID or IsSecret(spellID) then return end
    local okInfo, spellInfo = pcall(C_Spell.GetSpellInfo, spellID)
    if not okInfo or not spellInfo or not spellInfo.name then return end

    local b = BAR.knownBuffs[spellID]
    if not b then
        b = { spellID = spellID, name = spellInfo.name, icon = spellInfo.iconID }
        BAR.knownBuffs[spellID] = b
    else
        b.name = spellInfo.name
        b.icon = spellInfo.iconID or b.icon
    end
end

-- =========================================================
-- 数据源：扫描 CDM 增益查看器的当前帧（= 已启用的追踪增益）
-- =========================================================
local VIEWER_NAMES = { "BuffIconCooldownViewer", "BuffBarCooldownViewer" }

local function GetViewerFrames(viewer)
    if not viewer then return nil end
    if viewer.GetItemFrames then
        local ok, frames = pcall(viewer.GetItemFrames, viewer)
        if ok and frames then return frames end
    end
    if viewer.itemFramePool and viewer.itemFramePool.EnumerateActive then
        local ok, iter = pcall(viewer.itemFramePool.EnumerateActive, viewer.itemFramePool)
        if ok and iter then
            local t = {}
            for f in iter do t[#t + 1] = f end
            return t
        end
    end
    return nil
end

local function FrameCooldownID(frame)
    if not frame then return nil end
    local cdID = frame.cooldownID
    if not cdID and frame.cooldownInfo then
        cdID = frame.cooldownInfo.cooldownID
    end
    if not cdID and frame.GetCooldownID then
        local ok, id = pcall(frame.GetCooldownID, frame)
        if ok then cdID = id end
    end
    return cdID
end

-- 钩住某个 CDM item frame 的 RefreshData（暴雪驱动、战斗中照常触发）。
-- 在【暴雪的刷新上下文】里读 aura 数据并更新覆盖层，避免本插件 OnUpdate 在战斗中
-- 读受保护数据导致的 taint 隐藏（"进战斗消失"的根因）。spellID 走我们写在
-- frame 上的非 secret 字段 __BARSpellID，绝不读 secret 的 frame.auraSpellID。
local function HookViewerItem(item)
    if not item or item.__BARHooked then return end
    item.__BARHooked = true
    hooksecurefunc(item, "RefreshData", function()
        if not item.__BARSpellID then return end
        if BAR.UpdateOverlayForSpell then
            BAR.UpdateOverlayForSpell(item.__BARSpellID, item)
        end
    end)
end

local function ScanViewerFrames()
    for _, viewerName in ipairs(VIEWER_NAMES) do
        local viewer = _G[viewerName]
        local frames = GetViewerFrames(viewer)
        if frames then
            for _, frame in ipairs(frames) do
                local cdID = FrameCooldownID(frame)
                if cdID then
                    local ok, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cdID)
                if ok and info then
                    local spellID = ResolveSpellID(info)
                    if spellID and not IsSecret(spellID) then
                        RegisterBuff(spellID)
                        BAR.cdIDBySpell[spellID] = cdID
                        -- 把 spellID 记到 frame 上（我们自己写的非 secret 字段），
                        -- 供 FindFrameForSpell 实时匹配——绝不读 secret 的 frame.auraSpellID。
                        frame.__BARSpellID = spellID
                        -- 钩住该 CDM item 的 RefreshData，战斗中暴雪刷新时驱动覆盖层更新
                        HookViewerItem(frame)
                    end
                end
                end
            end
        end
    end
end

-- 动态查找当前正在显示该 spellID 的 CDM item frame。
-- 不用 BAR.frameBySpell 的静态缓存：战斗中 CDM 可能把同一个 frame 对象复用去显示别的 buff，
-- 静态引用会失效；此处每次实时遍历活动帧，用我们写在 frame 上的非 secret 字段 __BARSpellID 匹配，
-- 绝不读 secret 的 frame.auraSpellID（tainted 代码一比较就崩）。
function BAR.FindFrameForSpell(spellID)
    for _, viewerName in ipairs(VIEWER_NAMES) do
        local viewer = _G[viewerName]
        local frames = GetViewerFrames(viewer)
        if frames then
            for _, frame in ipairs(frames) do
                if frame.__BARSpellID and frame.__BARSpellID == spellID then
                    return frame
                end
            end
        end
    end
    return nil
end

-- 主入口：重新扫描 CDM 已启用的增益
function BAR.Rescan()
    if not C_CooldownViewer or not C_CooldownViewer.GetCooldownViewerCooldownInfo then
        if BAR.OnBuffsChanged then BAR.OnBuffsChanged() end
        return
    end
    wipe(BAR.knownBuffs)
    ScanViewerFrames()
    if BAR.RefreshAllOverlays then BAR.RefreshAllOverlays() end
    if BAR.OnBuffsChanged then BAR.OnBuffsChanged() end
end

-- 增量 hook：新帧出现时实时加入（覆盖加载后 CDM 布局变化的情况）
local hooked = {}
local function EnsureHooks()
    for _, name in ipairs(VIEWER_NAMES) do
        if not hooked[name] then
            local v = _G[name]
            if v and v.OnAcquireItemFrame then
                hooksecurefunc(v, "OnAcquireItemFrame", function(_, f)
                    local cdID = FrameCooldownID(f)
                    if cdID then
                        local ok, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cdID)
                        if ok and info then
                        local spellID = ResolveSpellID(info)
                        if spellID and not IsSecret(spellID) then
                            RegisterBuff(spellID)
                            BAR.cdIDBySpell[spellID] = cdID
                            -- 记到 frame 上（非 secret 字段），供 FindFrameForSpell 实时匹配
                            f.__BARSpellID = spellID
                            -- 钩住该 CDM item 的 RefreshData，战斗中暴雪刷新时驱动覆盖层更新
                            HookViewerItem(f)
                            -- 立即更新一次（首次出现即有数据则显示）
                            if BAR.UpdateOverlayForSpell then BAR.UpdateOverlayForSpell(spellID, f) end
                            if BAR.OnBuffsChanged then BAR.OnBuffsChanged() end
                        end
                        end
                    end
                end)
                hooked[name] = true
            end
        end
    end
end

-- =========================================================
-- 绑定关系：spellID -> 原生动作条按钮全局名（如 "ActionButton3"）
-- 绑定了按钮的增益，在后续阶段才会覆盖到对应按钮上。
-- =========================================================
function BAR.GetBinding(spellID)
    local b = BAR.db and BAR.db.bindings and BAR.db.bindings[spellID]
    if type(b) == "table" then return b.button end
    if type(b) == "string" then return b end
    return nil
end

-- 读取某绑定的显示选项（showTime / showStack），默认 true（显示）
function BAR.GetBindingOption(spellID, key)
    local b = BAR.db and BAR.db.bindings and BAR.db.bindings[spellID]
    if type(b) == "table" then
        if b[key] == nil then return true end
        return b[key]
    end
    return true
end

function BAR.SetBinding(spellID, buttonName)
    if not spellID then return end
    if not BAR.db then BAR.db = {} end
    BAR.db.bindings = BAR.db.bindings or {}
    local cur = BAR.db.bindings[spellID]
    if type(cur) ~= "table" then cur = {} end
    cur.button = (buttonName and buttonName ~= "") and buttonName or nil
    if cur.showTime == nil then cur.showTime = true end
    if cur.showStack == nil then cur.showStack = true end
    BAR.db.bindings[spellID] = cur
    -- 绑定变动后通知覆盖层重建（由 Overlay.lua 注册）
    if BAR.OnBindingsChanged then BAR.OnBindingsChanged() end
end

-- 设置某绑定的显示选项（showTime / showStack）
function BAR.SetBindingOption(spellID, key, val)
    if not spellID or not key then return end
    if not BAR.db then BAR.db = {} end
    BAR.db.bindings = BAR.db.bindings or {}
    local cur = BAR.db.bindings[spellID]
    if type(cur) ~= "table" then cur = {} end
    cur[key] = val
    BAR.db.bindings[spellID] = cur
    if BAR.OnBindingsChanged then BAR.OnBindingsChanged() end
end

-- =========================================================
-- 按「职业专精」存储配置：相同专精读同一份，切换专精即切换配置。
-- 持久化结构：ButtonAurasRebornDB.specs[specID] = { bindings }（bindings[sid] = { button, showTime, showStack }）
--   · specID 取自 GetSpecializationInfo(GetSpecialization())，跨职业唯一；拿不到时用 0（通用/默认槽）。
--   · BAR.db 始终指向「当前专精」的子表；绑定与显示开关都落在此子表，无需其它模块改动。
--   · 外观（时间/层数颜色、字号）为硬代码常量，不分专精、不可配置（见 Overlay.lua）。
-- =========================================================

-- 取当前专精 ID（拿不到回退 0 通用槽）
local function GetCurrentSpecID()
    local ok, specID = pcall(function()
        local idx = GetSpecialization()
        if not idx or idx == 0 then return nil end
        return (select(1, GetSpecializationInfo(idx)))
    end)
    if ok and specID then return specID end
    return 0
end

-- 全新专精的默认配置（仅 bindings；外观为硬代码常量，不分专精）
local function DefaultSpecConfig()
    return { bindings = {} }
end

-- 初始化 specs 表：首次运行时建结构；兼容旧扁平存档，迁移到通用槽 specs[0]。
-- 初始化 specs 表：首次运行时建结构；兼容旧扁平存档，迁移到通用槽 specs[0]。
-- 外观（颜色/字号）现为硬代码常量，不再存盘（旧顶层的 timeColor/stackColor/fontSize 字段清理掉）。
function BAR.InitSpecStorage()
    ButtonAurasRebornDB = ButtonAurasRebornDB or {}
    if not ButtonAurasRebornDB.specs then
        -- 旧结构（顶层 bindings）-> 迁移为通用槽，作为新专精的起步模板
        local legacy = { bindings = ButtonAurasRebornDB.bindings or {} }
        ButtonAurasRebornDB.bindings  = nil
        ButtonAurasRebornDB.timeColor  = nil
        ButtonAurasRebornDB.stackColor = nil
        ButtonAurasRebornDB.fontSize   = nil
        ButtonAurasRebornDB.specs = { [0] = legacy }
    end
end

-- 切换到「当前专精」配置槽：BAR.db 指向 specs[specID] 子表。
-- 新专精首次使用从通用槽(0)/默认模板复制起步，各专精数据互不共享。
function BAR.SelectSpec(specID)
    if not ButtonAurasRebornDB or not ButtonAurasRebornDB.specs then return end
    specID = specID or GetCurrentSpecID()
    local specs = ButtonAurasRebornDB.specs
    if not specs[specID] then
        local base = specs[0] or DefaultSpecConfig()
        specs[specID] = CopyTable and CopyTable(base) or DefaultSpecConfig()
    end
    -- 绑定数据：旧字符串格式 -> 转 table，并补默认显示选项（showTime/showStack 默认显示）
    local cfg = specs[specID]
    cfg.bindings = cfg.bindings or {}
    for sid, v in pairs(cfg.bindings) do
        if type(v) == "string" then
            cfg.bindings[sid] = { button = v, showTime = true, showStack = true }
        elseif type(v) == "table" then
            if v.showTime == nil then v.showTime = true end
            if v.showStack == nil then v.showStack = true end
        end
    end

    BAR.db = cfg
    BAR.currentSpecID = specID

    -- 配置切换后即时生效：重建覆盖层 + 同步显示 + 刷新面板
    if BAR.RebuildOverlays then BAR.RebuildOverlays() end
    if BAR.RefreshAllOverlays then BAR.RefreshAllOverlays() end
    if BAR.RefreshSpecLabel then BAR.RefreshSpecLabel() end
    if BAR.RefreshOptionsIfOpen then BAR.RefreshOptionsIfOpen() end
end

-- 已知原生动作条分组（prefix -> 中文标签），仅暴雪原生条
-- 顺序即菜单中「动作条1..8」的序号；已去掉姿态条 / 宠物条
local BAR_BAR_GROUPS = {
    { label = "动作条1", prefix = "ActionButton" },
    { label = "动作条2", prefix = "MultiBarBottomLeftButton" },
    { label = "动作条3", prefix = "MultiBarBottomRightButton" },
    { label = "动作条4", prefix = "MultiBarLeftButton" },
    { label = "动作条5", prefix = "MultiBarRightButton" },
    { label = "动作条6", prefix = "MultiBar5Button" },
    { label = "动作条7", prefix = "MultiBar6Button" },
    { label = "动作条8", prefix = "MultiBar7Button" },
}

-- 枚举所有原生动作条按钮的全局名（参考 CDMButtonAuras 的遍历方式）
function BAR.GetActionBarButtonNames()
    local names = {}
    local seen = {}
    local maxBtns = NUM_ACTIONBAR_BUTTONS or 12

    local function addPrefix(prefix)
        for i = 1, maxBtns do
            local g = prefix .. i
            if _G[g] and not seen[g] then
                seen[g] = true
                names[#names + 1] = g
            end
        end
    end

    if ActionButtonUtil and ActionButtonUtil.ActionBarButtonNames then
        for _, prefix in ipairs(ActionButtonUtil.ActionBarButtonNames) do
            if type(prefix) == "string" then addPrefix(prefix) end
        end
    end

    -- 兜底：API 缺失 / 返回空时，枚举已知的原生动作条前缀（仅暴雪原生）
    if #names == 0 then
        for _, g in ipairs(BAR_BAR_GROUPS) do addPrefix(g.prefix) end
    end

    return names
end

-- 按动作条分组枚举按钮，供配置面板做二级菜单：
-- 返回 { { label="动作条1", prefix="ActionButton", names={ "ActionButton1", ... } }, ... }
-- 顺序严格遵循 BAR_BAR_GROUPS（即动作条1..8），不含姿态条 / 宠物条。
function BAR.GetActionBarButtonGroups()
    local maxBtns = NUM_ACTIONBAR_BUTTONS or 12
    local groups = {}

    local function collect(prefix)
        local names = {}
        for i = 1, maxBtns do
            local g = prefix .. i
            if _G[g] then names[#names + 1] = g end
        end
        return names
    end

    -- 直接按 BAR_BAR_GROUPS 顺序枚举（已排除姿态条 / 宠物条，且序号即动作条编号）
    for _, g in ipairs(BAR_BAR_GROUPS) do
        local names = collect(g.prefix)
        if #names > 0 then
            groups[#groups + 1] = { label = g.label, prefix = g.prefix, names = names }
        end
    end

    return groups
end

-- 按钮全局名 -> 友好标签（如 "ActionButton5" -> "动作条1 5"），供下拉框显示已绑定项
function BAR.GetBarLabelForButton(name)
    if not name or name == "" then return "未绑定" end
    for _, g in ipairs(BAR_BAR_GROUPS) do
        local pfx = g.prefix
        if string.sub(name, 1, #pfx) == pfx then
            local num = string.sub(name, #pfx + 1)
            return g.label .. " " .. num
        end
    end
    return name
end

-- 简单表 dump（调试用，限制深度避免刷屏）
local function DumpTable(t, prefix, depth)
    if not t or type(t) ~= "table" then return end
    depth = depth or 0
    if depth > 2 then return end
    for k, v in pairs(t) do
        local vtype = type(v)
        local vs
        if vtype == "table" then
            vs = "{...}"
        elseif vtype == "string" then
            vs = '"' .. v .. '"'
        else
            vs = tostring(v)
        end
        print(prefix .. tostring(k) .. " = " .. vs)
        if vtype == "table" and depth < 2 then
            DumpTable(v, prefix .. "  ", depth + 1)
        end
    end
end

-- 调试输出：打印各查看器帧数 + 已捕获的玩家增益
function BAR.DebugPrint()
    print("|cff00ccff[ButtonAurasReborn]|r 诊断：C_CooldownViewer=" .. tostring(not not C_CooldownViewer))
    for _, viewerName in ipairs(VIEWER_NAMES) do
        local viewer = _G[viewerName]
        local frames = GetViewerFrames(viewer)
        local n = frames and #frames or 0
        print("  " .. viewerName .. ": 存在=" .. tostring(not not viewer) .. "  帧数=" .. n)
        if frames then
            for i = 1, math.min(n, 8) do
                local cdID = FrameCooldownID(frames[i])
                local sid = "?"
                if cdID then
                    local ok, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cdID)
                    if ok and info then
                        sid = tostring(info.linkedSpellIDs and info.linkedSpellIDs[1] or info.overrideSpellID or info.spellID)
                    end
                end
                print("    #" .. i .. " cdID=" .. tostring(cdID) .. " spellID=" .. sid)
            end
        end
    end

    local list = {}
    for sid, b in pairs(BAR.knownBuffs) do
        list[#list + 1] = (b.name or "?") .. " (#" .. sid .. ")"
    end
    table.sort(list)
    print("|cff00ccff[ButtonAurasReborn]|r 列表当前显示：" .. #list .. " 个")
    for _, s in ipairs(list) do print("  - " .. s) end

    if #list == 0 then
        print("|cffff6666[ButtonAurasReborn]|r 列表为空：请先在游戏内 Cooldown Manager（法术书→冷却管理）启用至少一个增益，再重载 / 打开面板。")
    end

    -- 额外：dump 第一个增益的原始 info，便于核对字段名（startTime / duration / count / stackCount 等）
    local firstSID
    for sid in pairs(BAR.cdIDBySpell) do firstSID = sid; break end
    if firstSID then
        local cdID = BAR.cdIDBySpell[firstSID]
        local ok, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cdID)
        if ok and info then
            print("|cff00ccff[ButtonAurasReborn]|r 第一个增益 (#" .. firstSID .. ") 原始 info 字段：")
            DumpTable(info, "    ")
        else
            print("|cffff6666[ButtonAurasReborn]|r 无法取得 #" .. tostring(firstSID) .. " 的 info（cdID=" .. tostring(cdID) .. "）。")
        end
        -- 关键：剩余时间/层数真正来自 CDM item frame 的 aura 字段（非 cooldown info）
        local f = BAR.frameBySpell and BAR.frameBySpell[firstSID]
        if f then
            print("|cff00ccff[ButtonAurasReborn]|r 对应 CDM frame 的 aura 字段（时间/层数真正来源）：")
            print("    auraDataUnit = " .. tostring(f.auraDataUnit))
            print("    auraInstanceID = " .. tostring(f.auraInstanceID))
            -- 直接验证战斗安全访问器（与 Overlay 实际使用的完全一致，绝不读 secret 数字）
            if f.auraDataUnit and f.auraInstanceID then
                -- 时间：GetAuraDuration 返回 DurationObject（交给 Cooldown 控件，addon 不读其字段）
                local okD = pcall(C_UnitAuras.GetAuraDuration, f.auraDataUnit, f.auraInstanceID)
                print("    >> GetAuraDuration 成功=" .. tostring(okD) .. "  (DurationObject → SetCooldownFromDurationObject)")
                -- 层数：GetAuraApplicationDisplayCount 是【非 secret】显示访问器，可直接打印
                local okC, cnt = pcall(C_UnitAuras.GetAuraApplicationDisplayCount, f.auraDataUnit, f.auraInstanceID)
                local n = tonumber(cnt)
                print("    >> GetAuraApplicationDisplayCount 成功=" .. tostring(okC)
                    .. "  层数=" .. tostring(cnt)
                    .. (n and n > 1 and "  (将显示)" or "  (<=1 不显示)"))
            end
        else
            print("|cffff6666[ButtonAurasReborn]|r 未找到 #" .. tostring(firstSID) .. " 对应的 CDM frame。")
        end
    end
end

-- 动作条 / 形态 / 页面 / 载具切换事件集合。
-- 御龙术(Dragonriding)切换走 bonus/override bar 机制，未必触发 ACTIONBAR_SLOT_CHANGED，
-- 故同时监听这些事件，统一驱动覆盖层重定位 + 隐藏（解决"动作条切换后数字残留"）。
local actionbarEvents = {
    ACTIONBAR_SLOT_CHANGED       = true,
    ACTIONBAR_PAGE_CHANGED      = true,
    UPDATE_BONUS_ACTIONBAR      = true,
    UPDATE_OVERRIDE_ACTIONBAR   = true,
    UPDATE_SHAPESHIFT_FORM      = true,
    UPDATE_POSSESS_BAR          = true,
    UPDATE_MULTI_CAST_ACTIONBAR = true,
    PLAYER_TALENT_UPDATE        = true,
}

-- 事件驱动
local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("ACTIVE_PLAYER_SPECIALIZATION_CHANGED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
for ev in pairs(actionbarEvents) do frame:RegisterEvent(ev) end

frame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        BAR.InitSpecStorage()   -- 迁移旧扁平结构 -> 按专精存储
        BAR.SelectSpec()        -- 选定当前专精配置槽（设置 BAR.db）

        EnsureHooks()
        C_Timer.After(0.5, function() EnsureHooks(); BAR.Rescan() end)
        C_Timer.After(2.0, function() EnsureHooks(); BAR.Rescan() end)
    elseif event == "PLAYER_ENTERING_WORLD" then
        BAR.SelectSpec()        -- 进场（含 reload）再校准一次当前专精
        C_Timer.After(0.5, function() EnsureHooks(); BAR.Rescan() end)
    elseif event == "ACTIVE_PLAYER_SPECIALIZATION_CHANGED" then
        BAR.SelectSpec()        -- 切换专精 -> 切换配置
    elseif actionbarEvents[event] then
        -- 动作条 / 形态 / 页面 / 载具 / 御龙术切换：重建覆盖层 + 重新同步显示。
        -- 御龙术走 bonus/override bar，未必触发 ACTIONBAR_SLOT_CHANGED，故统一在此处理。
        -- 延迟 0.1s：等动作条布局完成后再读按钮坐标 / 重算匹配，避免切换瞬间取到旧状态。
        C_Timer.After(0.1, function()
            if BAR.RebuildOverlays then BAR.RebuildOverlays() end
            if BAR.RefreshAllOverlays then BAR.RefreshAllOverlays() end
            if BAR.AutoCDM and BAR.AutoCDM.RefreshAll then BAR.AutoCDM.RefreshAll() end
        end)
    elseif event == "PLAYER_REGEN_ENABLED" or event == "PLAYER_REGEN_DISABLED" then
        -- 进出战斗：重新同步一次（战斗中靠 CDM item 的 RefreshData 实时驱动，此处补漏）
        C_Timer.After(0.1, function()
            if BAR.RefreshAllOverlays then BAR.RefreshAllOverlays() end
            if BAR.AutoCDM and BAR.AutoCDM.RefreshAll then BAR.AutoCDM.RefreshAll() end
        end)
    end
end)
