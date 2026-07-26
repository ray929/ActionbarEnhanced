-- CDMEnhanced/Options.lua
-- 配置 GUI：基于 Ace3（AceConfig + AceConfigDialog），独立窗口，不依赖暴雪新设置系统。
-- ⚠️ 为什么不用暴雪 Settings.RegisterCanvasLayout*：
--    canvas-layout 子页面在 12.x 里 manualPanel 永远不让自己 IsVisible() 变 true（OnShow 也不触发），
--    导致自动刷新根本无法触发（多次尝试 OpenToCategory 钩子 / 轮询 IsVisible 全部失效）。
--    改用 AceConfigDialog 独立窗口后，窗口是普通 frame，刷新可靠，彻底绕开该 bug。
-- 入口仅 Addon Compartment（无 slash 命令）。

local BAR = CDMEnhanced
if not BAR then return end

local ADDON_FOLDER = "CDMEnhanced"
local addonName = C_AddOns.GetAddOnMetadata(ADDON_FOLDER, "Title") or "CDM Enhanced"

local AceConfig = LibStub("AceConfig-3.0")
local AceConfigDialog = LibStub("AceConfigDialog-3.0")
local AceConfigRegistry = LibStub("AceConfigRegistry-3.0")
local AceGUI = LibStub("AceGUI-3.0")

-- 读取某绑定的时间位置（未设置返回 "默认"）
local function GetTimePos(spellID)
    local b = BAR.db and BAR.db.bindings and BAR.db.bindings[spellID]
    if type(b) == "table" and b.timePos then return b.timePos end
    return "默认"
end

local function GetStackPos(spellID)
    local b = BAR.db and BAR.db.bindings and BAR.db.bindings[spellID]
    if type(b) == "table" and b.stackPos then return b.stackPos end
    return "默认"
end

local POS_VALUES = { ["默认"] = "默认", ["上"] = "上", ["下"] = "下", ["左"] = "左", ["右"] = "右" }

-- 自定义 AceGUI 控件「图标 + 位置 + 绑定」同一行：
--   放大的图标（可悬停显示暴雪原生法术 tooltip） + 位置下拉 + 绑定技能输入框，三者 Flow 横向并排。
--   以 dialogControl 挂在 description 选项上；AceConfig 对 description 会调用 widget:SetText(options.name)，
--   故在 SetText 里解析 name（编码为 "spellID\1 icon"）并构建子控件。
AceGUI:RegisterWidgetType("CDMIconRow", function()
    local widget = AceGUI:Create("SimpleGroup")
    widget.type = "CDMIconRow"
    -- AceConfigDialog 对 description 类型会无条件调用 control:SetFontObject(...)，
    -- 而 SimpleGroup 基类没有该方法 → 触发 "attempt to call a nil value"。挂一个空实现规避。
    widget.SetFontObject = function() end
    widget.SetText = function(self, text)
        self:ReleaseChildren()
        local sid, icon = (text or ""):match("^([^\001]+)\001([^\001]+)$")
        sid = sid and tonumber(sid)
        icon = icon and tonumber(icon)
        self:SetLayout("Flow")
        self:SetFullWidth(true)
        -- 放大的图标（悬停显示暴雪原生法术 tooltip）
        if icon then
            local ic = AceGUI:Create("Icon")
            ic:SetImage(icon, 4 / 64, 60 / 64, 4 / 64, 60 / 64)
            ic:SetImageSize(32, 32)
            ic:SetWidth(46)
            ic:SetHeight(40)
            -- Icon 控件默认把 image 锚在 TOP(-5)，在 Flow 顶部对齐下会被压到中下方（偏下）。
            -- 改在控件内居中，使其与同行的下拉/输入框整体垂直对齐。
            ic.image:ClearAllPoints()
            ic.image:SetPoint("CENTER", ic.frame, "CENTER", 0, 0)
            if sid then
                ic:SetCallback("OnEnter", function(w)
                    GameTooltip:SetOwner(w.frame, "ANCHOR_RIGHT")
                    GameTooltip:SetSpellByID(sid)
                    GameTooltip:Show()
                end)
                ic:SetCallback("OnLeave", function()
                    GameTooltip:Hide()
                end)
            end
            self:AddChild(ic)
        end
        -- 位置下拉
        local pos = AceGUI:Create("Dropdown")
        pos:SetLabel("时间位置")
        pos:SetList(POS_VALUES)
        pos:SetValue(GetTimePos(sid))
        pos:SetWidth(100)
        pos:SetCallback("OnValueChanged", function(_, _, v)
            BAR.SetBindingOption(sid, "timePos", v)
            if BAR.RefreshAllOverlays then BAR.RefreshAllOverlays() end
        end)
        self:AddChild(pos)
        -- 层数位置下拉（与时间位置一致的 默认/上/下/左/右）
        local spos = AceGUI:Create("Dropdown")
        spos:SetLabel("层数位置")
        spos:SetList(POS_VALUES)
        spos:SetValue(GetStackPos(sid))
        spos:SetWidth(100)
        spos:SetCallback("OnValueChanged", function(_, _, v)
            BAR.SetBindingOption(sid, "stackPos", v)
            if BAR.RefreshAllOverlays then BAR.RefreshAllOverlays() end
        end)
        self:AddChild(spos)
        -- 绑定技能输入框（回车提交；留空提交 = 取消绑定）
        local bs = BAR.GetBoundSpell and BAR.GetBoundSpell(sid)
        local edit = AceGUI:Create("EditBox")
        edit:SetLabel("绑定技能")
        edit:SetText(bs and BAR.GetSpellDisplayName(bs) or "")
        edit:SetWidth(150)
        edit:SetCallback("OnEnterPressed", function(w)
            local val = w:GetText()
            val = val and strtrim(val) or ""
            if val == "" then
                BAR.SetBoundSpell(sid, nil)
            else
                local resolved = BAR.ParseSpellInput and BAR.ParseSpellInput(val)
                if not resolved then
                    print("|cffff6666[CDMEnhanced]|r 无法识别技能：" .. val)
                else
                    BAR.SetBoundSpell(sid, resolved)
                end
            end
            if BAR.RefreshAllOverlays then BAR.RefreshAllOverlays() end
        end)
        self:AddChild(edit)
    end
    return widget
end, 1)

-- 配置表（顶层：说明 + 「基本配置」子页面 + 「手动配置光环」子页面）
local options = {
    name = addonName,
    type = "group",
    args = {
        desc = {
            type = "description",
            name = "基于暴雪冷却管理器（CDM）的增益/冷却可视化增强。",
            order = 1,
        },
        basic = {
            type = "group",
            name = "基本配置",
            order = 2,
            args = {
                autoCDM = {
                    type = "toggle",
                    name = "光环自动发现（自动在动作条上显示 CDM 增益）",
                    order = 1,
                    width = "full",
                    get = function() return BAR.AutoCDM and BAR.AutoCDM.IsEnabled() end,
                    set = function(_, v) if BAR.AutoCDM then BAR.AutoCDM.SetEnabled(v) end end,
                },
                cooldownGlow = {
                    type = "toggle",
                    name = "冷却高亮提醒（技能冷却完成时对应动作条按钮高亮）",
                    order = 2,
                    width = "full",
                    get = function() return BAR.CooldownGlow and BAR.CooldownGlow.IsEnabled() end,
                    set = function(_, v) if BAR.CooldownGlow then BAR.CooldownGlow.SetEnabled(v) end end,
                },
            },
        },
        manual = {
            type = "group",
            name = "手动配置光环",
            order = 10,
            args = {},
        },
    },
}

-- 动态构建「手动配置光环」列表（紧凑布局）：
--   顶部只写一次说明；每个光环 = 一条分割线(空 header) + 一行左对齐「图标 + 光环名」(description 默认左对齐)
--   + 一行「位置 下拉 / 绑定技能 输入框」(两者均 width=half 并排；输入框自带「确定」按钮，落在该行末尾)。
--   绑定语义 = 绑定某一个技能（覆盖层锚定到该技能的动作条按钮）。
--   ⚠️ AceConfig 的 select/input 标签只能置于控件上方，无法紧贴控件左侧，故采用「标签在上、控件并排一行」。
local function BuildManualArgs()
    local args = {}
    -- 顶部说明：只写一次
    args.intro = {
        type = "description",
        name = "使用技能名或者技能ID绑定位置。",
        order = 0,
        fontSize = "medium",
    }
    local buffs = {}
    for _, b in pairs(BAR.knownBuffs or {}) do buffs[#buffs + 1] = b end
    table.sort(buffs, function(a, b) return (a.name or "") < (b.name or "") end)
    if #buffs == 0 then
        args.empty = {
            type = "description",
            name = "|cff999999（暂无光环：进入战斗或打开 CDM 后稍候会自动出现）|r",
            order = 1,
        }
    end
    for i, b in ipairs(buffs) do
        local sid = b.spellID
        local icon = b.icon or 134400
        local base = i * 10
        -- 分割线（仅线条）
        args["sep_" .. sid] = {
            type = "header",
            name = "",
            order = base,
        }
        -- 图标（放大，悬停出暴雪法术 tooltip）+ 位置下拉 + 绑定技能输入框，三者同一行（自定义控件）
        args["row_" .. sid] = {
            type = "description",
            dialogControl = "CDMIconRow",
            name = sid .. "\001" .. icon,
            order = base + 1,
            width = "full",
        }
    end
    options.args.manual.args = args
end

BuildManualArgs()

AceConfig:RegisterOptionsTable("CDMEnhanced", options)
-- 注：不调用 AddToBlizOptions，避免回到暴雪新设置系统；仅用 AceConfigDialog 独立窗口。

-- 打开配置窗口（供 Addon Compartment 调用）
local function OpenConfig()
    AceConfigDialog:Open("CDMEnhanced")
end

-- 将插件快捷方式加入 Addon Compartment
local icon = C_AddOns.GetAddOnMetadata(ADDON_FOLDER, "IconTexture")
AddonCompartmentFrame:RegisterAddon({
    text = addonName,
    icon = icon,
    registerForAnyClick = true,
    notCheckable = true,
    func = OpenConfig,
    funcOnEnter = function(button)
        MenuUtil.ShowTooltip(button, function(tooltip)
            tooltip:SetText(C_AddOns.GetAddOnMetadata(ADDON_FOLDER, "Title") or addonName, 1, 1, 1)
            tooltip:AddLine("点击打开设置面板")
        end)
    end,
    funcOnLeave = function(button)
        MenuUtil.HideTooltip(button)
    end,
})

-- 自动刷新：检测「CDM 活动帧集合」或「专精」变化，任一变化即重扫 knownBuffs 并重绘。
--   ⚠️ 不能用 knownBuffs 自身数量做比较——它只在 Rescan/OnAcquireItemFrame 时更新，
--      在官方 CDM 里启用/禁用技能并不会触发这两者，导致列表冻结。故改为比对
--      BAR.GetActiveViewerSignature()（CDM 活动帧的真实 spellID 集合）：
--      启用/禁用技能会改变活动帧集合 → 签名变 → Rescan → 列表刷新。
--   即使窗口未打开，NotifyChange 也仅标记脏、下次打开即显示最新；窗口已打开则立即重绘。
local lastSig = nil
local lastSpec = nil
C_Timer.NewTicker(0.5, function()
    local sig = BAR.GetActiveViewerSignature and BAR.GetActiveViewerSignature() or ""
    local idx = GetSpecialization()
    local spec = (idx and idx > 0) and (GetSpecializationInfo(idx)) or 0
    if sig ~= lastSig or spec ~= lastSpec then
        lastSig = sig
        lastSpec = spec
        if BAR.Rescan then BAR.Rescan() end
        BuildManualArgs()
        AceConfigRegistry:NotifyChange("CDMEnhanced")
    end
end)

-- 列表内容变化时若需刷新（数据到达 / 扫描后）
BAR.OnBuffsChanged = function()
    BuildManualArgs()
    AceConfigRegistry:NotifyChange("CDMEnhanced")
end

-- 切专精时由 Core.SelectSpec 调用：重建绑定列表（反映新专精的 bindings）
BAR.RefreshOptionsIfOpen = function()
    BuildManualArgs()
    AceConfigRegistry:NotifyChange("CDMEnhanced")
end
