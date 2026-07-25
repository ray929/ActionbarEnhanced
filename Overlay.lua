-- ButtonAurasReborn/Overlay.lua
-- 把"已绑定"的 CDM 增益的【剩余时间(按自身/别人buff/debuff 染色,左下)】与【层数(粉红,左上)】渲染到原生动作条按钮上（字号/颜色取自 Settings，均带重描边）。
--
-- ⚠️ 战斗中数据来源（踩过的坑，已修正）：
--   C_UnitAuras.GetAuraDataByAuraInstanceID 返回的 duration/expirationTime/applications
--   全部是【secret 值】，addon 代码一旦读取/比较/相减就会在战斗中报错
--   （"attempt to compare ... secret number ... tainted"），导致「战斗中不显示，脱战才显示」。
--   正确做法（与 CDMButtonAuras 一致，绝不自己读 secret 数字做算术）：
--     - 时间：C_UnitAuras.GetAuraDuration(unit, instanceID) 拿到 DurationObject，
--             直接交给 Cooldown 控件的 SetCooldownFromDurationObject（暴雪内部读 secret，addon 不碰数字）。
--     - 层数：C_UnitAuras.GetAuraApplicationDisplayCount(unit, instanceID) 是【非 secret】的显示访问器，
--             直接 SetText（返回普通数字/字符串，可安全 tonumber 比较）。
--   数据真正来自 CDM item frame 的 frame.auraDataUnit / frame.auraInstanceID。
-- 仅暴雪原生动作条按钮；绑定条隐藏时信息不显示（GetRect() 守卫，绝不锚到按钮）。
-- 覆盖层只渲染文字，不画增益图标（满足"图标不显示"）。
-- 中央调试显示（旧 /bar center）已移除。
--
-- ⚠️ 刷新机制（"进战斗消失"的第二类坑，已修正）：
--   早期用本插件自己的 OnUpdate 每 0.1s 读受保护 aura 数据并改写"挂在安全动作按钮上的子帧"，
--   进战斗后 combat-lockdown 的 taint 复检会把覆盖层整片隐藏、脱战才恢复。
--   现改为 hook 每个 CDM item 的 RefreshData（暴雪驱动、战斗中照常触发），
--   在【暴雪的刷新上下文】里读 aura 数据并更新覆盖层（与 CDMButtonAuras 同款战斗安全机制）。
--   倒计时本身由 Cooldown 控件自己动画，无需我们每帧刷。

local BAR = ButtonAurasReborn
if not BAR then return end

local unpack = unpack or table.unpack

-- 样式（字号/字体/颜色）统一取自 Settings.lua，集中管理
local S = BAR.Settings

-- spellID -> { buttonName, button, cd, stackText }
local overlays = {}

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

-- 给 Cooldown 的【内置倒计时数字】上字体/颜色（tullaCTC 在 12.x/Midnight 的验证做法）。
-- 关键：cd:SetCountdownFont(路径,字号,描边) 签名是错的（该 API 只吃字体对象名字符串），
--       SetTimerTextColor 在 12.x 不存在——两者都会静默失败 → 字体/颜色退回默认白色。
-- 正确：cd:GetCountdownFontString() 拿到内置 FontString，直接 SetFont + SetTextColor。
-- 该 FontString 要等冷却真正运行、暴雪渲染出数字后才存在，故每次更新后都调一次（幂等、廉价）。
local function StyleCountdown(cd, color)
    local fs = cd.GetCountdownFontString and cd:GetCountdownFontString()
    if not fs then return end
    -- 时间字号：默认基础上大 10%，并按按钮缩放 r（手动容器在 UIParent 坐标系，
    -- 需 ×r 才与 AutoCDM 的按钮子帧字号视觉一致）
    local r = cd.__BARr or 1
    fs:SetFont(S.FONT, math.max(1, math.floor(S.FONT_SIZE * 1.1 * r + 0.5)), S.OUTLINE)
    if color then fs:SetTextColor(color[1], color[2], color[3]) end
end

-- 创建一个"计时器(Cooldown) + 层数(FontString)"显示单元，挂到 parent 上。
-- 计时器用暴雪 secret-safe 的 DurationObject 显示（addon 不读 secret 数字），
-- 层数用非 secret 访问器 GetAuraApplicationDisplayCount 直接 SetText。
-- 覆盖层挂在一个【纯 UIParent 中立容器】上，与动作按钮【零锚依赖】（绝不 SetPoint 到按钮）。
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

    local cd = CreateFrame("Cooldown", nil, container, "CooldownFrameTemplate")
    cd:SetDrawSwipe(false)          -- 不画冷却扫光
    cd:SetDrawEdge(false)
    if cd.SetHideCountdownNumbers then cd:SetHideCountdownNumbers(false) end  -- 显示倒计时数字
    if cd.SetCountdownAbbrevThreshold then cd:SetCountdownAbbrevThreshold(60) end
    -- 计时数字落在按钮【左下】区域；cd 的分区锚点在 PositionOverlay 里按真实容器尺寸设置
    -- （字体/颜色不在这里设——CooldownFrameTemplate 的倒计时 FontString 要等冷却真正运行后
    --   才由暴雪创建，改用 StyleCountdown 在每次更新后拿 GetCountdownFontString 上样式）。
    cd:Hide()

    local stack = container:CreateFontString(nil, "OVERLAY")
    stack:SetTextColor(S.STACK_COLOR[1], S.STACK_COLOR[2], S.STACK_COLOR[3])
    stack:SetJustifyH("LEFT")
    stack:Hide()
    -- 位置/字号留到 PositionOverlay 里按按钮缩放 r 设置（与 AutoCDM 的按钮子帧视觉对齐）

    return cd, stack, container
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
    -- 时间矩形（倒计时数字）：
    --   默认：左下角 62% 框（贴近按钮左下角，与原实现一致）。
    --   上/下/左/右：0.68 方块（比默认大 10%）居中于按钮对应边外 10px。
    --   cw/ch 已含按钮缩放 r，满足"大小按照按钮缩放"。
    if ov.cd then
        ov.cd:ClearAllPoints()
        local pos = (BAR.GetBindingOption and BAR.GetBindingOption(ov.spellID, "timePos")) or "默认"
        if pos ~= "上" and pos ~= "下" and pos ~= "左" and pos ~= "右" then pos = "默认" end
        if pos == "上" then
            ov.cd:SetSize(cw * 0.68, ch * 0.68)
            ov.cd:SetPoint("CENTER", ov.container, "TOP", 0, 10 * r)
        elseif pos == "下" then
            ov.cd:SetSize(cw * 0.68, ch * 0.68)
            ov.cd:SetPoint("CENTER", ov.container, "BOTTOM", 0, -10 * r)
        elseif pos == "左" then
            ov.cd:SetSize(cw * 0.68, ch * 0.68)
            ov.cd:SetPoint("CENTER", ov.container, "LEFT", -10 * r, 0)
        elseif pos == "右" then
            ov.cd:SetSize(cw * 0.68, ch * 0.68)
            ov.cd:SetPoint("CENTER", ov.container, "RIGHT", 10 * r, 0)
        else  -- 默认：左下角 62% 框（贴近按钮左下角，与原实现一致）
            ov.cd:SetPoint("BOTTOMLEFT", ov.container, "BOTTOMLEFT", 1, -6)
            ov.cd:SetPoint("TOPRIGHT", ov.container, "BOTTOMLEFT", cw * 0.62, ch * 0.62 - 7)
        end
        ov.cd.__BARr = r  -- 供 StyleCountdown 按按钮缩放算字号
    end

    -- 层数（与 AutoCDM 对齐：左上 5, -5，字体按按钮缩放 r 放大，与按钮子帧字号视觉一致）
    if ov.stackText then
        ov.stackText:ClearAllPoints()
        ov.stackText:SetPoint("TOPLEFT", ov.container, "TOPLEFT", 5 * r, -5 * r)
        ov.stackText:SetFont(S.FONT, math.max(1, math.floor(S.FONT_SIZE * r + 0.5)), S.OUTLINE)
    end
    return true
end

-- 战斗安全刷新：
--   - 时间：交给 Cooldown 控件（基于 CDM frame 的 auraDataUnit/auraInstanceID；
--            GetAuraDuration 返回 DurationObject 由暴雪内部显示，addon 不碰 secret 数字）。
--   - 层数：用 GetAuraApplicationDisplayCount（CDMButtonAuras 同款、战斗中可用、非 secret 访问器），
--            直接 SetText 原始返回值；>1 判断放进 pcall，避免任何 secret 比较导致 taint 崩溃。
--            （本客户端中 frame.Applications.Applications:GetText() 返回 secret 字符串，不能用。）
-- 永久型增益（如风之舞 9 层）GetAuraDuration 返回 nil → 不显时间，但层数照常显。
-- showTimeOpt / showStackOpt：该绑定的显示开关（false=不显示）；nil 视为显示。
local function UpdateAuraDisplay(cd, stack, frame, showTimeOpt, showStackOpt)
    local showTimeAllowed = (showTimeOpt ~= false)
    local showStackAllowed = (showStackOpt ~= false)
    local unit = frame and frame.auraDataUnit
    local instID = frame and frame.auraInstanceID
    -- 取 debuff 判定（仅读非 secret 的 isHarmful 布尔，pcall 兜底）用于 buff/debuff 配色
    -- ⚠️ 不能用 auraType 字符串比对：新客户端 auraType 是 Enum 数字，比对永远失败 → 全误判成 buff。
    local isHarmful
    if unit and instID then
        local ok, data = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, unit, instID)
        if ok and data then isHarmful = data.isHarmful end
    end

    local showTime = false
    if showTimeAllowed and unit and instID then
        local ok, durObj = pcall(C_UnitAuras.GetAuraDuration, unit, instID)
        if ok and durObj then
            cd:SetCooldownFromDurationObject(durObj, true)
            cd:Show()
            StyleCountdown(cd, S.GetTimeColor(unit, isHarmful))  -- 按自身/别人buff/debuff 上色
            showTime = true
        end
    end
    if not showTime then cd:Hide() end

    -- 层数：用 GetAuraApplicationDisplayCount（CDMButtonAuras 同款、战斗中可用、非 secret 访问器）。
    -- 直接 SetText 原始返回值；>1 的判断整个放进 pcall，避免任何 secret 字符串比较导致 taint 崩溃。
    -- 注意：frame.Applications.Applications:GetText() 在本客户端返回 secret 字符串，绝不能取/比较。
    -- 颜色统一为粉红（S.STACK_COLOR）。
    local showStack, stackVal = false, nil
    if showStackAllowed and unit and instID then
        -- 与 AutoCDM 对齐：只要光环存在（cnt ~= nil）就显示原始层数（含 "1"），不隐藏单层的 1。
        -- 旧逻辑用 n > 1 闸门，导致不可叠加/单层光环（如痛击）的层数永不显示，与 AutoCDM 行为不一致。
        local okC, cnt = pcall(C_UnitAuras.GetAuraApplicationDisplayCount, unit, instID)
        if okC and cnt ~= nil then
            showStack = true
            stackVal = cnt
        end
    end
    if showStack then
        stack:SetText(stackVal)
        stack:SetTextColor(S.STACK_COLOR[1], S.STACK_COLOR[2], S.STACK_COLOR[3])
        stack:Show()
    else
        stack:Hide()
    end
end

local function MakeOverlay(spellID, buttonName)
    local btn = _G[buttonName]
    if not btn then return nil end
    local cd, stack, container = CreateAuraDisplay(btn)
    local ov = { buttonName = buttonName, button = btn, cd = cd, stackText = stack, container = container, spellID = spellID }
    PositionOverlay(ov)
    return ov
end

-- bindings[sid] 兼容两种格式：旧字符串（按钮名）/ 新 table { button=..., showTime=..., showStack=... }
local function BindingButton(v)
    if type(v) == "table" then return v.button end
    if type(v) == "string" then return v end
    return nil
end

-- 根据当前 bindings 重建覆盖层集合（绑定变动时调用）
function BAR.RebuildOverlays()
    if not BAR.db then return end
    local bindings = BAR.db.bindings or {}

    -- 移除：已解绑 / 目标无效 / 非原生按钮 的覆盖层
    for sid, ov in pairs(overlays) do
        local target = BindingButton(bindings[sid])
        if not target or target == "" or not IsNativeButton(target) or not _G[target] then
            if ov.cd then ov.cd:Hide() end
            if ov.stackText then ov.stackText:Hide() end
            if ov.container then ov.container:Hide() end
            overlays[sid] = nil
        end
    end

    -- 新增 / 切换目标 的覆盖层
    for sid, v in pairs(bindings) do
        local target = BindingButton(v)
        if target and target ~= "" and IsNativeButton(target) then
            local ov = overlays[sid]
            if not ov or ov.buttonName ~= target then
                if ov then
                    ov.cd:Hide()
                    ov.stackText:Hide()
                    if ov.container then ov.container:Hide() end
                end
                overlays[sid] = MakeOverlay(sid, target)
            end
        end
    end
end

-- 绑定变动回调（由 Core.SetBinding 触发）
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

-- 由 Core 在 CDM item 的 RefreshData 回调中调用（战斗安全）：
-- spellID 为本插件写在 frame 上的非 secret 字段；frame 即 CDM item（含 auraDataUnit/auraInstanceID）。
function BAR.UpdateOverlayForSpell(spellID, frame)
    local ov = overlays[spellID]
    if not ov then return end
    -- 绑定条不显示（小宠物对战 / 载具 / 御空术等）→ 信息也不显示。
    -- 用 GetRect() 判断可见性（只读，不污染安全帧），不可见则隐藏。
    if not PositionOverlay(ov) then
        ov.cd:Hide()
        ov.stackText:Hide()
        if ov.container then ov.container:Hide() end
        return
    end
    if ov.container then ov.container:Show() end
    local showTime  = BAR.GetBindingOption and BAR.GetBindingOption(spellID, "showTime")
    local showStack = BAR.GetBindingOption and BAR.GetBindingOption(spellID, "showStack")
    UpdateAuraDisplay(ov.cd, ov.stackText, frame, showTime, showStack)
end

-- 一次性重新同步所有覆盖层：登录 / 切换专精 / 动作条变动 / 重新扫描后调用。
-- 通过 FindFrameForSpell 实时查找 CDM frame，再走 UpdateAuraDisplay。
function BAR.RefreshAllOverlays()
    for sid, ov in pairs(overlays) do
        -- 用 GetRect() 判断可见性（只读，不污染安全帧），不可见则隐藏
        if not PositionOverlay(ov) then
            ov.cd:Hide()
            ov.stackText:Hide()
            if ov.container then ov.container:Hide() end
        else
            if ov.container then ov.container:Show() end
            local frame = BAR.FindFrameForSpell and BAR.FindFrameForSpell(sid)
            local showTime  = BAR.GetBindingOption and BAR.GetBindingOption(sid, "showTime")
            local showStack = BAR.GetBindingOption and BAR.GetBindingOption(sid, "showStack")
            UpdateAuraDisplay(ov.cd, ov.stackText, frame, showTime, showStack)
        end
    end
end

-- 首次登录后构建一次（此时 cdID 映射已由 Core 的 Rescan 填充）
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
