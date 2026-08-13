-- ActionbarEnhanced/Manual.lua
-- 手动绑定系统（全栈）：原 Core.lua（数据/绑定/事件）+ Overlay.lua（渲染）合并而来。
-- 两者仅通过 BAR.* 表通信，合并后局部函数复用同一 upvalue，无任何接口变更（外部调用方无感）。
-- 文件内分两段：第一段=数据扫描/绑定存档/专精配置/事件驱动；第二段=覆盖层渲染。

-- =========================================================
-- 第一段：数据扫描 / 绑定存档 / 专精配置 / 事件驱动（原 Core.lua）
-- =========================================================
-- Phase 0+1: 读取 CDM（Cooldown Manager）里"已启用的增益"，供配置 GUI 选择。
--
-- 数据源：扫描 CDM 增益查看器（BuffIconCooldownViewer / BuffBarCooldownViewer）
--   的【当前帧】——viewer:GetItemFrames()。
--   关键：CDM 只为玩家在 Cooldown Manager 里【实际启用】的追踪增益创建 item frame，
--   不管该增益当前是否在身上。因此"帧里出现的"= "已启用的"，这与 vflow /
--   CDMButtonAuras 的可选列表来源完全一致。
--   （配置集 GetCooldownViewerCategorySet 会返回分类下全部条目，含未启用的——已弃用。）
--   spellID 经 GetCooldownViewerCooldownInfo 解析；名称/图标取自 C_Spell.GetSpellInfo（非 unit auras）。

ActionbarEnhanced = ActionbarEnhanced or {}
local BAR = ActionbarEnhanced

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

-- 安全判断 secret value（12.0+ 受限内容会返回 secret，不可比较/存盘）。
-- 12.1+ 的 secret 值类型可能是 number/boolean/string 等，不能靠 type() 预判
-- （secret 布尔 type() 返回 "boolean"，旧写法 type ~= "number" 会漏判），
-- 统一用 issecretvalue 识别所有类型的 secret 值，pcall 兜底 nil 等输入。
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
    if IsSecret(shown) then return false end
    return not not shown
end

-- 屏幕外容器：把 CDM item frame（图标+背景框整体）移到这里，实现"看不见"，
-- 无需 Hide 任何 region。item 的 Show/Hide 状态不因位置改变 → IsItemShown 激活判断不受影响。
local offscreenFrame = CreateFrame("Frame", nil, UIParent)
offscreenFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -1000, 1000)
offscreenFrame:SetSize(40, 40)
offscreenFrame:Show()

-- 把 CDM item frame 移到屏幕外（记录原 parent，光环消失时 UpdateAuraDisplay 会还原）。
-- 图标、IconOverlay 背景框、MaskTexture 等随 item 一起移走，无需逐个 Hide。
local function MoveItemOffscreen(item)
    if not item then return end
    pcall(function()
        if not item.__BAROrigParent then
            item.__BAROrigParent = item:GetParent()
        end
        item:SetParent(offscreenFrame)
        item:ClearAllPoints()
        item:SetPoint("TOPLEFT", offscreenFrame, "TOPLEFT", 0, 0)
    end)
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

-- 收集 info 里的全部候选 spellID（去重）。
-- 12.1+：天赋改名场景下光环/技能名不一致（如光环"烈焰震击" vs 按钮"流电炽焰"），
-- 只记一个 ID 会导致 FindFrameForSpell / 按钮匹配失败；全部候选都要留。
local function CollectItemSpellIDs(info)
    local seen, result = {}, {}
    local function add(id)
        if id and id > 0 and not IsSecret(id) and not seen[id] then
            seen[id] = true
            result[#result + 1] = id
        end
    end
    if not info then return result end
    add(info.spellID)
    add(info.overrideSpellID)
    add(info.overrideTooltipSpellID)
    add(info.linkedSpellID)
    if info.linkedSpellIDs then
        for _, id in ipairs(info.linkedSpellIDs) do add(id) end
    end
    return result
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
-- 数据源：扫描 CDM 全部查看器的当前帧（= 已启用的追踪增益/冷却）
-- 12.1+：Essential/Utility 冷却 item 的 cooldownStartTime/cooldownDuration 是暴雪
-- 算好的普通字段（战斗中可用）；BuffIcon/BuffBar 光环 item 只有 auraDataCached（secret 风险）。
-- 四个查看器都要扫，否则配置在 Essential/Utility 的追踪不显示。
-- =========================================================
local VIEWER_NAMES = { "EssentialCooldownViewer", "UtilityCooldownViewer", "BuffIconCooldownViewer", "BuffBarCooldownViewer" }

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
                        -- 把 spellID 候选记到 frame 上（我们自己写的非 secret 字段），
                        -- 供 FindFrameForSpell 实时匹配——绝不读 secret 的 frame.auraSpellID。
                        -- 12.1+：天赋改名场景（光环"烈焰震击" vs 按钮"流电炽焰"）需要全部候选。
                        frame.__BARSpellID = spellID
                        frame.__BARSpellIDs = CollectItemSpellIDs(info)
                        -- 钩住该 CDM item 的 RefreshData，战斗中暴雪刷新时驱动覆盖层更新
                        HookViewerItem(frame)
                    end
                end
                end
            end
        end
    end
end

-- 当前 CDM 查看器【活动帧】里 spellID 的集合签名（排序后拼接）。
-- 用于检测：在官方 CDM 里启用/禁用技能、或活动帧集合变化时，knownBuffs 需要重扫。
-- 活动帧集合在平稳游戏时基本不变（CDM 原地刷新冷却数字），仅启用/禁用/增删追踪技能才变，
-- 因此对它做签名比对触发的 Rescan 极少，开销可控。
function BAR.GetActiveViewerSignature()
    local ids = {}
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
                            ids[#ids + 1] = spellID
                        end
                    end
                end
            end
        end
    end
    table.sort(ids)
    return table.concat(ids, ",")
end

-- 动态查找当前正在显示该 spellID 的 CDM item frame。
-- 不用 BAR.frameBySpell 的静态缓存：战斗中 CDM 可能把同一个 frame 对象复用去显示别的 buff，
-- 静态引用会失效；此处每次实时遍历活动帧，用我们写在 frame 上的非 secret 字段匹配，
-- 绝不读 secret 的 frame.auraSpellID（tainted 代码一比较就崩）。
-- 12.1+：匹配全部候选 __BARSpellIDs（天赋改名场景，如光环"烈焰震击" vs 技能"流电炽焰"）。
function BAR.FindFrameForSpell(spellID)
    for _, viewerName in ipairs(VIEWER_NAMES) do
        local viewer = _G[viewerName]
        local frames = GetViewerFrames(viewer)
        if frames then
            for _, frame in ipairs(frames) do
                if frame.__BARSpellID and frame.__BARSpellID == spellID then
                    return frame
                end
                if frame.__BARSpellIDs then
                    for _, id in ipairs(frame.__BARSpellIDs) do
                        if id == spellID then
                            return frame
                        end
                    end
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
                            f.__BARSpellIDs = CollectItemSpellIDs(info)
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
-- 读取某绑定要扫描的"目标技能"（用户输入的 spellID）；nil = 未绑定
function BAR.GetBoundSpell(spellID)
    local b = BAR.db and BAR.db.bindings and BAR.db.bindings[spellID]
    if type(b) == "table" then
        if b.bindSpell then return b.bindSpell end
    end
    return nil
end

-- 是否已绑定（新模型 bindSpell 或旧模型 button 任一非空）
function BAR.IsBound(spellID)
    local b = BAR.db and BAR.db.bindings and BAR.db.bindings[spellID]
    if type(b) == "table" then
        if b.bindSpell then return true end
        if b.button and b.button ~= "" then return true end
    elseif type(b) == "string" then
        return b ~= ""
    end
    return false
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

-- 把某 CDM 增益(spellID)绑定到"目标技能"（扫描动作条找该技能的按钮并锚定覆盖层）。
-- targetSpellID 为 nil 表示解绑。
-- 绑定不再记具体动作条槽位：运行时扫动作条按技能定位，跟随变形/翻页/槽位变化。
function BAR.SetBoundSpell(spellID, targetSpellID)
    if not spellID then return end
    if not BAR.db then BAR.db = {} end
    BAR.db.bindings = BAR.db.bindings or {}
    local cur = BAR.db.bindings[spellID]
    if type(cur) ~= "table" then cur = {} end
    if targetSpellID then
        cur.bindSpell = targetSpellID
        cur.button = nil   -- 新模型覆盖旧的固定槽位
    else
        cur.bindSpell = nil
        cur.button = nil   -- 解绑
    end
    if cur.showTime == nil then cur.showTime = true end
    if cur.showStack == nil then cur.showStack = true end
    BAR.db.bindings[spellID] = cur
    -- 绑定变动后通知覆盖层重建（OnBindingsChanged 由第二段注册）
    if BAR.OnBindingsChanged then BAR.OnBindingsChanged() end
end

-- 解析用户输入（技能名或 spellID）为 spellID；失败返回 nil
function BAR.ParseSpellInput(text)
    text = strtrim(tostring(text or ""))
    if text == "" then return nil end
    local num = tonumber(text)
    if num then
        local ok, info = pcall(C_Spell.GetSpellInfo, num)
        if ok and info and info.name then return num end
        return nil
    end
    -- 技能名：先试 GetSpellID，再试 GetSpellInfo(name).spellID
    local okID, id = pcall(function() return C_Spell.GetSpellID(text) end)
    if okID and id and id > 0 then
        local ok, info = pcall(C_Spell.GetSpellInfo, id)
        if ok and info and info.name then return id end
    end
    local ok2, info2 = pcall(C_Spell.GetSpellInfo, text)
    if ok2 and info2 and info2.spellID then return info2.spellID end
    return nil
end

-- spellID -> 友好显示名（解析不出则用 ID）
function BAR.GetSpellDisplayName(spellID)
    if not spellID then return "" end
    local ok, info = pcall(C_Spell.GetSpellInfo, spellID)
    if ok and info and info.name then return info.name end
    return tostring(spellID)
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
-- 持久化结构：ActionbarEnhancedDB.specs[specID] = { bindings }（bindings[sid] = { bindSpell, showTime, showStack, timePos, stackPos }）
--   · specID 取自 GetSpecializationInfo(GetSpecialization())，跨职业唯一；拿不到时用 0（通用/默认槽）。
--   · BAR.db 始终指向「当前专精」的子表；绑定与显示开关都落在此子表，无需其它模块改动。
--   · 外观（时间/层数颜色、字号）为硬代码常量，不分专精、不可配置（见 Settings.lua）。
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
    ActionbarEnhancedDB = ActionbarEnhancedDB or {}
    if not ActionbarEnhancedDB.specs then
        -- 旧结构（顶层 bindings）-> 迁移为通用槽，作为新专精的起步模板
        local legacy = { bindings = ActionbarEnhancedDB.bindings or {} }
        ActionbarEnhancedDB.bindings  = nil
        ActionbarEnhancedDB.timeColor  = nil
        ActionbarEnhancedDB.stackColor = nil
        ActionbarEnhancedDB.fontSize   = nil
        ActionbarEnhancedDB.specs = { [0] = legacy }
    end
end

-- 切换到「当前专精」配置槽：BAR.db 指向 specs[specID] 子表。
-- 新专精首次使用从通用槽(0)/默认模板复制起步，各专精数据互不共享。
function BAR.SelectSpec(specID)
    if not ActionbarEnhancedDB or not ActionbarEnhancedDB.specs then return end
    specID = specID or GetCurrentSpecID()
    local specs = ActionbarEnhancedDB.specs
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

-- 从动作条按钮的全局名取得其当前所载技能的 spellID（spell / 单法术宏均可）。
-- 只认暴雪原生动作条（由 GetActionBarButtonNames 提供）；验证 id 是真实法术，避免宏 id 误匹配。
local function GetButtonSpellID(buttonName)
    local btn = _G[buttonName]
    if not btn or not btn.action then return nil end
    local ok, atype, id = pcall(GetActionInfo, btn.action)
    if not ok or not atype or not id then return nil end
    if atype ~= "spell" and atype ~= "macro" then return nil end
    local okInfo, info = pcall(C_Spell.GetSpellInfo, id)
    if okInfo and info and info.name then return id end
    return nil
end

-- 一次性扫描所有动作条，建立 spellID -> 按钮全局名 映射（首个匹配为准）。
-- 仅事件驱动时调用（保存/登录/切条/变形/槽位变化），非每帧，性能无忧。
local function BuildSpellButtonMap()
    local map = {}
    local names = BAR.GetActionBarButtonNames()
    for _, name in ipairs(names) do
        local sid = GetButtonSpellID(name)
        if sid and not map[sid] then map[sid] = name end
    end
    return map
end

-- 解析某 CDM 增益(spellID)覆盖层应锚定的按钮：
--   · 新模型 bindSpell 存在 -> 扫动作条找该技能的按钮（变形/翻页自动跟随）；
--   · 旧模型 button（固定槽位）存在 -> 直接返回（兼容旧存档）；
--   · 均未设置 -> 返回 nil（未绑定/技能不在任何动作条）。
function BAR.ResolveAnchor(spellID)
    if not spellID then return nil end
    local b = BAR.db and BAR.db.bindings and BAR.db.bindings[spellID]
    local bindSpell, legacyButton
    if type(b) == "table" then
        bindSpell = b.bindSpell
        legacyButton = b.button
    elseif type(b) == "string" then
        legacyButton = b
    end
    if bindSpell then
        local map = BuildSpellButtonMap()
        return map[bindSpell]
    end
    if legacyButton and legacyButton ~= "" then return legacyButton end
    return nil
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

-- =========================================================
-- 第二段：覆盖层渲染（原 Overlay.lua）
-- =========================================================
-- 把"已绑定"的 CDM 增益的【剩余时间】与【层数】渲染到原生动作条按钮上。
--
-- ⚠️ 12.1 正确做法（本插件最终方案）：
--   不读任何 aura 数据——把 CDM item frame（BuffIconCooldownViewer）上暴雪已渲染好的
--   倒计时 Cooldown 控件与层数 FontString 直接 reparent 到按钮容器，
--   由暴雪继续驱动（RefreshData → SetCooldown / SetText）。
--   → 战斗中照常显示、零 secret 读取、无 taint。
--   （旧方案 GetAuraDuration / GetAuraDataCached / cooldownStartTime 读数据，
--     12.1 中 aura 为 secret 时对插件 Lua error 或返回 secret 值，已弃用。）
-- 仅暴雪原生动作条按钮；绑定条隐藏时信息不显示（GetRect() 守卫，绝不锚到按钮）。
-- 覆盖层只渲染文字，不画增益图标（满足"图标不显示"）。
-- 中央调试显示（旧 /bar center）已移除。
--
-- ⚠️ 刷新机制（"进战斗消失"的第二类坑，已修正）：
--   早期用本插件自己的 OnUpdate 每 0.1s 读受保护 aura 数据并改写"挂在安全动作按钮上的子帧"，
--   进战斗后 combat-lockdown 的 taint 复检会把覆盖层整片隐藏、脱战才恢复。
--   现改为 hook 每个 CDM item 的 RefreshData（暴雪驱动、战斗中照常触发），
--   在【暴雪的刷新上下文】里 reparent 已渲染对象并更新覆盖层。
--   倒计时本身由 Cooldown 控件自己动画，无需我们每帧刷。

local unpack = unpack or table.unpack

-- 样式（字号/字体/颜色）统一取自 Settings.lua，集中管理
local S = BAR.Settings

-- spellID -> { buttonName, button, cd, stackText }
local overlays = {}

-- =========================================================
-- 发光（glow）辅助：timePos=="发光" 时给按钮 Proc Glow
-- 发光靠项目已加载的 LibCustomGlow-1.0（与 CooldownGlow 的 "BAR" / TrinketGlow 的 "TG" 区分用独立 key）
-- =========================================================
local LCG = LibStub and LibStub("LibCustomGlow-1.0", true)
local MANUAL_GLOW_KEY = "MANUALGLOW"

local function ManualGlowStart(btn)
    if not btn or not LCG or btn.__ManualGlow then return end
    LCG.ProcGlow_Start(btn, { key = MANUAL_GLOW_KEY, startAnim = true, color = S.MANUAL_GLOW_COLOR, scale = 0.8 })
    btn.__ManualGlow = true
end

local function ManualGlowStop(btn)
    if not btn or not LCG or not btn.__ManualGlow then return end
    LCG.ProcGlow_Stop(btn, MANUAL_GLOW_KEY)
    btn.__ManualGlow = false
end

-- 仅接受暴雪原生动作条按钮，排除玩家/插件自定义按钮
local NATIVE_PATTERNS = {
    "^ActionButton%d+$",
    "^MultiBarBottomLeftButton%d+$",
    "^MultiBarBottomRightButton%d+$",
    "^MultiBarRightButton%d+$",
    "^MultiBarLeftButton%d+$",
    "^MultiBar%dButton%d+$",
    "^StanceButton%d+$",
    "^PetActionButton%d+$",
}
local function IsNativeButton(name)
    if not name then return false end
    for _, pat in ipairs(NATIVE_PATTERNS) do
        if name:match(pat) then return true end
    end
    return false
end

-- 创建一个容器：承载从 CDM item frame reparent 进来的已渲染对象
-- （倒计时 Cooldown 控件、层数 FontString）。addon 不创建自己的 Cooldown/文字，
-- 暴雪继续驱动这些对象 → 战斗中照常显示、零 secret 读取。
-- 覆盖层挂在【纯 UIParent 中立容器】上，与动作按钮【零锚依赖】（绝不 SetPoint 到按钮）。
-- 为什么要这么做：若把覆盖层锚到安全动作按钮（即使它挂在 UIParent 上），
-- 非安全帧依赖安全帧会把 taint 传播到动作条按钮 → 进战斗后 combat-lockdown 把整条动作条
-- 判定污染而隐藏覆盖层（"进战斗消失、脱战才恢复"）。
-- 正确做法（本插件最终方案）：容器只挂在 UIParent，位置由 PositionOverlay 用 btn:GetRect()
-- 读取按钮的【屏幕坐标】再相对 UIParent 原点摆放——读取是只读操作不污染安全帧，
-- 且容器与按钮之间没有任何"锚依赖"，taint 无处传播。
local function CreateAuraDisplay(parent)
    local container = CreateFrame("Frame", nil, UIParent)
    container:SetFrameStrata("HIGH")
    container:SetFrameLevel(1000)
    -- 临时尺寸，首次 PositionOverlay 时按按钮真实尺寸重设
    container:SetSize(36, 36)
    container:Hide()
    return container
end

-- 把覆盖层容器定位到动作按钮之上（用屏幕坐标，绝不锚到按钮）。
-- 用 btn:GetRect() 读按钮的屏幕矩形（只读操作，不污染安全帧），再相对 UIParent 的
-- BOTTOMLEFT 原点用 SetPoint 摆放。容器与按钮之间没有任何"锚依赖"关系 →
-- taint 不会传播到安全动作条按钮 → 战斗中不会被 combat-lockdown 隐藏。
-- ⚠️ 缩放换算：GetRect() 返回的是【按钮自身有效缩放坐标系】的值，容器挂在 UIParent
--    用的是【UIParent 有效缩放】。两者缩放不同 → 直接套用会偏移（UIParent 缩放更大时"偏上"）。
--    换算比 r = 按钮有效缩放 / UIParent 有效缩放，位置与尺寸都乘 r 即对齐屏幕像素。
-- 返回 true 表示按钮当前可见（已成功定位），false 表示按钮不可见（调用方应隐藏覆盖层）。
local function PositionOverlay(ov)
    if not ov or not ov.button or not ov.container then return false end
    local btn = ov.button
    local left, bottom, width, height = btn:GetRect()
    if not left then return false end  -- 按钮不可见（如载具/御空术切换）→ 不重定位
    local r = 1
    local bs, ps = btn:GetEffectiveScale(), UIParent:GetEffectiveScale()
    if bs and ps and ps > 0 then r = bs / ps end
    local cw, ch = width * r, height * r
    ov.container:ClearAllPoints()
    ov.container:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left * r, (bottom + height) * r)
    ov.container:SetSize(cw, ch)
    return true
end

-- 战斗安全刷新：把 CDM item frame 上暴雪已渲染的倒计时/层数对象 reparent 到按钮容器。
-- 由暴雪驱动刷新（RefreshData → SetCooldown / SetText），addon 完全不读 aura 数据 →
-- 战斗中照常显示、零 secret。发光模式用 frame:IsShown() 判断激活（普通帧状态，非 secret）。
-- ⚠️ 12.1：绝不读 frame.auraDataCached / GetAuraDuration 等 secret 值。
local function UpdateAuraDisplay(container, frame, showTimeOpt, showStackOpt, spellID, button)
    local ok = pcall(function()
        if not container then return end
        local showTimeAllowed = (showTimeOpt ~= false)
        local showStackAllowed = (showStackOpt ~= false)

        -- 光环不激活（item 被隐藏）→ 隐藏容器、把 item 还原到 CDM 原位置
        if not IsItemShown(frame) then
            container:Hide()
            ManualGlowStop(button)
            pcall(function()
                if frame.__BAROrigParent then
                    frame:SetParent(frame.__BAROrigParent)
                    frame.__BAROrigParent = nil
                    frame:ClearAllPoints()
                end
            end)
            return
        end

        -- 用户要求：时间/层数已搬到按钮，CDM 原图标/背景框无意义 →
        -- 把整个 item frame 移到屏幕外（MoveItemOffscreen，见 glowMode/非发光两处）。
        -- 不 Hide 任何 region；item 的 Show/Hide 状态不因位置改变，IsItemShown 依然有效。

        -- 从 CDM item 拿暴雪已渲染对象
        local cdFrame = frame.GetCooldownFrame and frame:GetCooldownFrame()
        local stacksFS = frame.GetApplicationsFontString and frame:GetApplicationsFontString()

        -- 发光模式判定（timePos=="发光"）：光环激活则发光、隐藏时间；否则熄灭。
        local glowMode = spellID and (BAR.GetBindingOption and BAR.GetBindingOption(spellID, "timePos") == "发光")
        if glowMode then
            container:Hide()
            ManualGlowStart(button)
            -- 发光模式无倒计时/层数 reparent，直接把整个 item 移到屏幕外（图标+背景框消失）
            MoveItemOffscreen(frame)
        else
            ManualGlowStop(button)
            -- reparent 倒计时对象到容器（由暴雪驱动）
            if cdFrame then
                cdFrame:SetParent(container)
                cdFrame:ClearAllPoints()
                local pos = (BAR.GetBindingOption and BAR.GetBindingOption(spellID, "timePos")) or "默认"
                local cw, ch = container:GetSize()
                if pos == "上" then
                    cdFrame:SetSize(cw * 0.68, ch * 0.68)
                    cdFrame:SetPoint("CENTER", container, "TOP", 0, 10)
                elseif pos == "下" then
                    cdFrame:SetSize(cw * 0.68, ch * 0.68)
                    cdFrame:SetPoint("CENTER", container, "BOTTOM", 0, -10)
                elseif pos == "左" then
                    cdFrame:SetSize(cw * 0.68, ch * 0.68)
                    cdFrame:SetPoint("CENTER", container, "LEFT", -10, 0)
                elseif pos == "右" then
                    cdFrame:SetSize(cw * 0.68, ch * 0.68)
                    cdFrame:SetPoint("CENTER", container, "RIGHT", 10, 0)
                else  -- 默认：左下角 62% 框
                    cdFrame:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 1, -6)
                    cdFrame:SetPoint("TOPRIGHT", container, "BOTTOMLEFT", cw * 0.62, ch * 0.62 - 7)
                end
                if showTimeAllowed then
                    cdFrame:Show()
                else
                    cdFrame:Hide()
                end
                -- 去掉冷却扫光（转圈扇形指示）与边缘描边——只留倒计时数字，不要淡淡背景
                -- ⚠️ 暴雪每次 RefreshData 都会 SetDrawSwipe(true)，故每次更新都重新关掉
                cdFrame:SetDrawSwipe(false)
                cdFrame:SetDrawEdge(false)
                -- 应用 Settings 样式（颜色/字号/描边，可在 Settings.lua 修改）。
                -- ⚠️ 倒计时数字 FontString 要等冷却真正运行后暴雪才创建，每次更新都调（幂等）。
                --    无 buff/debuff 判定（不读 secret），时间统一用 S.TIME_COLOR_OTHER_BUFF。
                local cds = cdFrame.GetCountdownFontString and cdFrame:GetCountdownFontString()
                if cds then
                    cds:SetFont(S.FONT, S.FONT_SIZE, S.OUTLINE)
                    cds:SetTextColor(S.TIME_COLOR_OTHER_BUFF[1], S.TIME_COLOR_OTHER_BUFF[2], S.TIME_COLOR_OTHER_BUFF[3])
                end
            end
            -- reparent 层数对象到容器（由暴雪驱动）
            if stacksFS then
                stacksFS:SetParent(container)
                stacksFS:ClearAllPoints()
                local spos = (BAR.GetBindingOption and BAR.GetBindingOption(spellID, "stackPos")) or "默认"
                if spos == "上" then
                    stacksFS:SetPoint("CENTER", container, "TOP", 0, 10)
                elseif spos == "下" then
                    stacksFS:SetPoint("CENTER", container, "BOTTOM", 0, -10)
                elseif spos == "左" then
                    stacksFS:SetPoint("CENTER", container, "LEFT", -10, 0)
                elseif spos == "右" then
                    stacksFS:SetPoint("CENTER", container, "RIGHT", 10, 0)
                else  -- 默认：左上 5, -5
                    stacksFS:SetPoint("TOPLEFT", container, "TOPLEFT", 5, -5)
                end
                stacksFS:SetFont(S.FONT, S.FONT_SIZE, S.OUTLINE)
                stacksFS:SetTextColor(S.STACK_COLOR[1], S.STACK_COLOR[2], S.STACK_COLOR[3])
                if showStackAllowed then
                    stacksFS:Show()
                else
                    stacksFS:Hide()
                end
            end
            -- reparent 完成，倒计时/层数已移出 item → 把整个 item 移到屏幕外（图标+背景框消失）
            MoveItemOffscreen(frame)
            container:Show()
        end
    end)
    if not ok then
        if container then container:Hide() end  -- 兜底：任何 secret/taint 操作失败都不让错误冒泡
        ManualGlowStop(button)
    end
end

local function MakeOverlay(spellID, buttonName)
    local btn = _G[buttonName]
    if not btn then return nil end
    local container = CreateAuraDisplay(btn)
    local ov = { buttonName = buttonName, button = btn, container = container, spellID = spellID }
    PositionOverlay(ov)
    return ov
end

-- 根据当前 bindings 重建覆盖层集合（绑定变动 / 登录 / 切条 / 变形 / 槽位变化时调用）。
-- 锚定不再依赖写死槽位：对每个绑定技能，运行时扫动作条按"目标技能"解析按钮，
-- 变形/翻页后槽位内容变化也能自动跟随（时间/层数刷新链路与此完全解耦，不受影响）。
function BAR.RebuildOverlays()
    if not BAR.db then return end
    local bindings = BAR.db.bindings or {}
    local map = BuildSpellButtonMap()  -- 一次性扫描所有动作条

    -- 解析某绑定应锚定的按钮名（与 BAR.ResolveAnchor 同逻辑，但复用已构建的 map）
    local function anchorFor(sid)
        local b = bindings[sid]
        local bindSpell, legacyButton
        if type(b) == "table" then
            bindSpell = b.bindSpell
            legacyButton = b.button
        elseif type(b) == "string" then
            legacyButton = b
        end
        if bindSpell then return map[bindSpell] end
        if legacyButton and legacyButton ~= "" then return legacyButton end
        return nil
    end

    -- 移除：已解绑 / 目标无效 / 非原生按钮 的覆盖层
    for sid, ov in pairs(overlays) do
        local target = anchorFor(sid)
        if not target or target == "" or not IsNativeButton(target) or not _G[target] then
            if ov.container then ov.container:Hide() end
            ManualGlowStop(ov.button)
            overlays[sid] = nil
        end
    end

    -- 新增 / 切换目标 的覆盖层
    for sid, v in pairs(bindings) do
        local target = anchorFor(sid)
        if target and target ~= "" and IsNativeButton(target) then
            local ov = overlays[sid]
            if not ov or ov.buttonName ~= target then
                if ov then
                    if ov.container then ov.container:Hide() end
                    ManualGlowStop(ov.button)
                end
                overlays[sid] = MakeOverlay(sid, target)
            end
        end
    end
end

-- 绑定变动回调（由 SetBoundSpell 触发）
BAR.OnBindingsChanged = BAR.RebuildOverlays

-- =========================================================
-- 战斗安全刷新机制（关键，避免"进战斗消失"）
--   不跑本插件自己的 OnUpdate：每帧由插件驱动的裸 OnUpdate 在战斗中读受保护
--   aura 数据并改写"挂在安全动作按钮上的子帧"，会被暴雪 combat-lockdown 的 taint
--   复检判定为污染，整片隐藏；脱战才恢复。
--   改为：hook 每个 CDM item 的 RefreshData（暴雪驱动、战斗中照常触发），
--   在【暴雪的刷新上下文】里读 aura 数据并更新覆盖层（与 CDMButtonAuras 同款）。
--   倒计时本身由 Cooldown 控件自己动画，无需我们每帧刷。
-- =========================================================

-- 由第一段在 CDM item 的 RefreshData 回调中调用（战斗安全）：
-- spellID 为本插件写在 frame 上的非 secret 字段；frame 即 CDM item（含 auraDataUnit/auraInstanceID）。
function BAR.UpdateOverlayForSpell(spellID, frame)
    local ov = overlays[spellID]
    if not ov then return end
    -- 绑定条不显示（小宠物对战 / 载具 / 御空术等）→ 信息也不显示。
    -- 用 GetRect() 判断可见性（只读，不污染安全帧），不可见则隐藏。
    if not PositionOverlay(ov) then
        if ov.container then ov.container:Hide() end
        ManualGlowStop(ov.button)
        return
    end
    -- 时间与层数已改为「绑定即一律显示」，不读取显示开关
    UpdateAuraDisplay(ov.container, frame, true, true, ov.spellID, ov.button)
end

-- 一次性重新同步所有覆盖层：登录 / 切换专精 / 动作条变动 / 重新扫描后调用。
-- 通过 FindFrameForSpell 实时查找 CDM frame，再走 UpdateAuraDisplay。
function BAR.RefreshAllOverlays()
    for sid, ov in pairs(overlays) do
        -- 用 GetRect() 判断可见性（只读，不污染安全帧），不可见则隐藏
        if not PositionOverlay(ov) then
            if ov.container then ov.container:Hide() end
            ManualGlowStop(ov.button)
        else
            local frame = BAR.FindFrameForSpell and BAR.FindFrameForSpell(sid)
            -- 时间与层数已改为「绑定即一律显示」，不读取显示开关
            UpdateAuraDisplay(ov.container, frame, true, true, sid, ov.button)
        end
    end
end

-- 首次登录后构建一次（此时 cdID 映射已由第一段的 Rescan 填充）
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        C_Timer.After(1.0, function()
            BAR.RebuildOverlays()
            if BAR.RefreshAllOverlays then BAR.RefreshAllOverlays() end
        end)
    end
end)
