-- ButtonAurasReborn/Options.lua
-- 配置 GUI：在暴雪设置面板中列出从 CDM 捕获到的玩家增益，每行可绑定到原生动作条按钮。

local BAR = ButtonAurasReborn
if not BAR then return end

-- 读取某绑定的时间位置（未设置返回 "默认"）
local function GetTimePos(spellID)
    local b = BAR.db and BAR.db.bindings and BAR.db.bindings[spellID]
    if type(b) == "table" and b.timePos then return b.timePos end
    return "默认"
end

-- 注册设置面板（画布分类）
local panel = CreateFrame("Frame")
panel.name = "ButtonAurasReborn"

local addonName = "ButtonAurasReborn"
local category = Settings.RegisterCanvasLayoutCategory(panel, "ButtonAurasReborn")
-- 注意：不要覆盖 category.ID，RegisterCanvasLayoutCategory 已自动分配数字 ID
-- 之后用 Settings.OpenToCategory(category.ID) 打开（参数为数字）
Settings.RegisterAddOnCategory(category)

-- 打开本插件设置面板（供 Addon Compartment / 斜杠命令调用）
local function OpenSettings()
    Settings.OpenToCategory(category.ID)
end

-- 将插件快捷方式加入小地图旁的 Addon Compartment 框架
-- 图标取自 .toc 的 ## IconTexture（内置齿轮图标，体现技能冷却/设置主题）
local icon = C_AddOns.GetAddOnMetadata(addonName, "IconTexture")
AddonCompartmentFrame:RegisterAddon({
    text = C_AddOns.GetAddOnMetadata(addonName, "Title") or addonName,
    icon = icon,
    registerForAnyClick = true,
    notCheckable = true,
    func = OpenSettings,
    funcOnEnter = function(button)
        MenuUtil.ShowTooltip(button, function(tooltip)
            tooltip:SetText(C_AddOns.GetAddOnMetadata(addonName, "Title") or addonName, 1, 1, 1)
            tooltip:AddLine("点击打开设置面板")
        end)
    end,
    funcOnLeave = function(button)
        MenuUtil.HideTooltip(button)
    end,
})

-- 标题
local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 16, -16)
title:SetText("ButtonAurasReborn")

-- 操作按钮
local refreshBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
refreshBtn:SetSize(110, 22)
refreshBtn:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -32, -16)
refreshBtn:SetText("刷新列表")
refreshBtn:SetScript("OnClick", function()
    if BAR.Rescan then BAR.Rescan() end
    BAR.BuildList()
end)

-- 状态文本 不需要 我手动注释了
-- local status = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
-- status:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 16, 10)

-- 当前配置所属专精（切专精时实时更新），放在标题下方、列表上方
-- 不需要显示这部分 我手动注释了
-- local specLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
-- specLabel:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -36)
-- function BAR.RefreshSpecLabel()
--     local name = "通用"
--     local ok, idx = pcall(GetSpecialization)
--     if ok and idx and idx ~= 0 then
--         local _, sname = pcall(GetSpecializationInfo, idx)
--         if sname then name = sname end
--     end
--     specLabel:SetText("当前配置专精：" .. name)
-- end
-- BAR.RefreshSpecLabel()

-- 自动发现系统开关（与手动绑定系统【独立】，由 AutoCDM.lua 实现）
-- 勾选后自动显示 CDM 追踪的全部增益（无需手动绑定），文字按归属上色（自己绿/别人红/层数黄）。
-- 注意：AutoCDM.lua 已在 TOC 中先于本文件加载，故此处可直接读取 BAR.AutoCDM。
local autoChk = CreateFrame("CheckButton", nil, panel)
autoChk:SetSize(18, 18)
autoChk:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
autoChk:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
autoChk:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
autoChk:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight")
autoChk:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
if BAR.AutoCDM then
    BAR.AutoCDM.EnsureDB()
    autoChk:SetChecked(BAR.AutoCDM.IsEnabled())
end
local autoLbl = autoChk:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
autoLbl:SetPoint("LEFT", autoChk, "RIGHT", 6, 0)
autoLbl:SetText("自动发现（基于CDMButtonAuras修改而得）")
autoChk:SetScript("OnClick", function()
    if BAR.AutoCDM then BAR.AutoCDM.SetEnabled(autoChk:GetChecked()) end
end)

-- 冷却高亮提醒开关（由 CooldownGlow.lua 实现，存 ButtonAurasRebornDB.cooldownGlow.enabled）
-- 读取 CDM 已启用的技能冷却，冷却完成时给对应动作条按钮 Proc Glow。
-- 注意：CooldownGlow.lua 已在 TOC 中先于本文件加载，故此处可直接读取 BAR.CooldownGlow。
local glowChk = CreateFrame("CheckButton", nil, panel)
glowChk:SetSize(18, 18)
glowChk:SetPoint("TOPLEFT", autoChk, "BOTTOMLEFT", 0, -8)
glowChk:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
glowChk:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
glowChk:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight")
glowChk:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
if BAR.CooldownGlow then
    BAR.CooldownGlow.EnsureDB()
    glowChk:SetChecked(BAR.CooldownGlow.IsEnabled())
end
local glowLbl = glowChk:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
glowLbl:SetPoint("LEFT", glowChk, "RIGHT", 6, 0)
glowLbl:SetText("冷却高亮提醒（技能冷却完成时发光）")
glowChk:SetScript("OnClick", function()
    if BAR.CooldownGlow then BAR.CooldownGlow.SetEnabled(glowChk:GetChecked()) end
end)

-- 同步两个开关复选框到「真实的当前存值」：每次面板显示时调用，
-- 避免面板创建时机（ADDON_LOADED）读到的过时/尚未初始化的 DB 导致「钩子打上但实际关闭」的显示错位。
local function SyncToggles()
    if BAR.AutoCDM then
        BAR.AutoCDM.EnsureDB()
        autoChk:SetChecked(BAR.AutoCDM.IsEnabled())
    end
    if BAR.CooldownGlow then
        BAR.CooldownGlow.EnsureDB()
        glowChk:SetChecked(BAR.CooldownGlow.IsEnabled())
    end
end

local manualLbl = autoChk:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
manualLbl:SetPoint("TOPLEFT", glowLbl, "BOTTOMLEFT", 0, -15)
manualLbl:SetText("手动配置")


-- 滚动列表（置于外观+专精标签下方）
local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -90)
scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -32, 28)

local scrollChild = CreateFrame("Frame", nil, scroll)
scroll:SetScrollChild(scrollChild)
panel.scrollChild = scrollChild

local ROW_H = 34
local ICON = 28
panel.rows = {}

local function MakeRow(parent, idx)
    local row = CreateFrame("Button", "BARRow" .. idx, parent)
    row:SetHeight(ROW_H)

    -- 放大后的图标
    row.Icon = row:CreateTexture(nil, "ARTWORK")
    row.Icon:SetSize(ICON, ICON)
    row.Icon:SetPoint("LEFT", 10, 0)

    row.Name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.Name:SetPoint("LEFT", row.Icon, "RIGHT", 10, 0)
    row.Name:SetPoint("RIGHT", row, "RIGHT", -500, 0)
    row.Name:SetJustifyH("LEFT")
    row.Name:SetTextColor(1, 1, 1)

    -- 时间位置下拉（默认 / 上 / 下 / 左 / 右）：驱动 Overlay 的 timePos，立即刷新定位
    -- 时间与层数已改为「绑定即一律显示」，不再提供开关
    local posLabel = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    posLabel:SetPoint("LEFT", row.Name, "RIGHT", 20, 0)
    posLabel:SetText("位置")
    row.PosTime = CreateFrame("Frame", "BARRow" .. idx .. "PosTime", row, "UIDropDownMenuTemplate")
    row.PosTime:SetPoint("LEFT", posLabel, "RIGHT", 4, 0)
    UIDropDownMenu_SetWidth(row.PosTime, 80)
    UIDropDownMenu_JustifyText(row.PosTime, "LEFT")
    row.PosTime.noResize = true
    UIDropDownMenu_Initialize(row.PosTime, function(self, level)
        local sid = row.PosTime.spellID
        local opts = { "默认", "上", "下", "左", "右" }
        for _, o in ipairs(opts) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = o
            info.value = o
            info.func = function()
                BAR.SetBindingOption(sid, "timePos", o)
                UIDropDownMenu_SetText(row.PosTime, o)
                if BAR.RefreshAllOverlays then BAR.RefreshAllOverlays() end
            end
            info.checked = (GetTimePos(sid) == o)
            UIDropDownMenu_AddButton(info, level)
        end
    end)

    -- 绑定动作条按钮的下拉框（位于「位置」左侧）
    row.DropDown = CreateFrame("Frame", "BARRow" .. idx .. "DropDown", row, "UIDropDownMenuTemplate")
    row.DropDown:SetPoint("LEFT", row.Name, "RIGHT", 20, 0)
    UIDropDownMenu_SetWidth(row.DropDown, 130)
    UIDropDownMenu_JustifyText(row.DropDown, "LEFT")
    row.DropDown.noResize = true
    row.DropDown.spellID = nil
    -- 「位置」下拉置于绑定下拉右侧（即绑定在「位置」左边）
    posLabel:SetPoint("LEFT", row.DropDown, "RIGHT", 20, 0)

    UIDropDownMenu_Initialize(row.DropDown, function(self, level, menuList)
        local dropdown = row.DropDown
        local sid = dropdown.spellID

        if level == 1 then
            -- 未绑定
            local info = UIDropDownMenu_CreateInfo()
            info.text = "未绑定"
            info.value = ""
            info.func = function()
                BAR.SetBinding(sid, "")
                UIDropDownMenu_SetText(dropdown, "未绑定")
            end
            info.checked = (BAR.GetBinding(sid) == nil or BAR.GetBinding(sid) == "")
            UIDropDownMenu_AddButton(info, level)

            -- 各动作条分组（二级菜单入口）
            local groups = BAR.GetActionBarButtonGroups()
            for _, grp in ipairs(groups) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = grp.label
                info.value = grp.prefix or grp.label
                info.hasArrow = true
                info.notCheckable = true
                UIDropDownMenu_AddButton(info, level)
            end
        elseif level == 2 then
            -- 二级：某动作条下的具体按钮，显示为纯数字 1..12（值仍为完整按钮名）
            local key = UIDROPDOWNMENU_MENU_VALUE
            local groups = BAR.GetActionBarButtonGroups()
            for _, grp in ipairs(groups) do
                if (grp.prefix or grp.label) == key then
                    for i, g in ipairs(grp.names) do
                        local info = UIDropDownMenu_CreateInfo()
                        info.text = tostring(i)
                        info.value = g
                        info.func = function()
                            BAR.SetBinding(sid, g)
                            UIDropDownMenu_SetText(dropdown, grp.label .. " " .. tostring(i))
                        end
                        info.checked = (BAR.GetBinding(sid) == g)
                        UIDropDownMenu_AddButton(info, level)
                    end
                end
            end
        end
    end)

    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.08)

    return row
end

-- 不需要 我手动注释了
-- function BAR.UpdateStatus()
--     local total, bound = 0, 0
--     for _ in pairs(BAR.knownBuffs) do total = total + 1 end
--     local binds = BAR.db and BAR.db.bindings
--     if binds then
--         for _, v in pairs(binds) do
--             local bn = (type(v) == "table") and v.button or (type(v) == "string" and v or nil)
--             if bn and bn ~= "" then bound = bound + 1 end
--         end
--     end
--     status:SetText("已捕获 " .. total .. " 个增益 ｜ 已绑定 " .. bound .. " 个按钮")
-- end

function BAR.BuildList()
    if not panel or not panel.scrollChild then return end
    local buffs = {}
    for _, b in pairs(BAR.knownBuffs) do
        buffs[#buffs + 1] = b
    end
    -- 按名称排序
    table.sort(buffs, function(a, b)
        return (a.name or "") < (b.name or "")
    end)

    local child = panel.scrollChild
    local width = scroll:GetWidth() or 660
    child:SetWidth(width)

    local rows = panel.rows
    for i, b in ipairs(buffs) do
        local row = rows[i] or MakeRow(child, i)
        rows[i] = row
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", child, "TOPLEFT", 4, -(i - 1) * ROW_H)
        row:SetPoint("RIGHT", child, "RIGHT", -4, 0)
        row.spellID = b.spellID
        if b.icon then
            row.Icon:SetTexture(b.icon)
            row.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        else
            row.Icon:SetTexture(134400)
        end
        row.Name:SetText(b.name or ("#" .. b.spellID))
        -- 绑定下拉框：记录本行 spellID 并显示当前绑定
        row.DropDown.spellID = b.spellID
        local bound = BAR.GetBinding(b.spellID)
        UIDropDownMenu_SetText(row.DropDown, BAR.GetBarLabelForButton(bound))
        row.PosTime.spellID = b.spellID
        UIDropDownMenu_SetText(row.PosTime, GetTimePos(b.spellID))
        row:SetShown(true)
    end
    -- 隐藏多余的行
    for i = #buffs + 1, #rows do
        rows[i]:Hide()
    end

    child:SetHeight(math.max(1, #buffs * ROW_H + 8))
    --BAR.UpdateStatus()  --不需要显示这部分
end

-- 面板显示时重新扫描并重建列表
panel:SetScript("OnShow", function()
    if BAR.Rescan then BAR.Rescan() end
    BAR.BuildList()
    if BAR.RebuildOverlays then BAR.RebuildOverlays() end
    SyncToggles()   -- 同步开关到真实存值，修正「钩子打上但实际关闭」的显示错位
end)

-- 列表内容变化时，若面板打开则实时刷新
BAR.OnBuffsChanged = function()
    if panel:IsVisible() then BAR.BuildList() end
end

-- 切专精时由 Core.SelectSpec 调用：面板打开则重建绑定列表（反映新专精的 bindings）
BAR.RefreshOptionsIfOpen = function()
    if panel and panel:IsVisible() then BAR.BuildList() end
end

-- 命令：/bar 打开配置；/bar debug 输出已捕获增益；/bar rescan 重新扫描
SLASH_BAR1 = "/bar"
SlashCmdList["BAR"] = function(msg)
    msg = strtrim(msg or "")
    msg = msg:lower()
    if msg == "debug" then
        BAR.DebugPrint()
    elseif msg == "rescan" then
        if BAR.Rescan then BAR.Rescan() end
        print("|cff00ccff[ButtonAurasReborn]|r 已重新扫描 CDM。")
    else
        Settings.OpenToCategory(category.ID)
    end
end
