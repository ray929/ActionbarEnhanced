-- ActionbarEnhanced/DisableAutoAddSpells.lua
-- 阻止新学习技能自动添加到动作栏：移植自 DisableAutoAddSpells（luo）。
--
-- 原理（从源头阻止 + 完全可逆，不破坏暴雪全局状态）：
--   零售端「新技能自动入条」由暴雪追踪器 IconIntroTracker 在其 OnEvent 处理
--   SPELL_PUSHED_TO_ACTIONBAR 时完成（payload: spellID, slot, page）。
--   ① 开启时，把 IconIntroTracker 的 OnEvent 脚本替换为包装函数：遇到该事件直接跳过，
--      从源头掐断自动添加；其余事件原样转发。
--   ② 同时自建监听帧兜底：事件触发（非战斗且有 slot）时 PickupAction+ClearCursor 撤销残留。
--   关闭时把 IconIntroTracker 的 OnEvent 还原为原始脚本、反注册监听帧 → 但自动入条
--   实际绑定在客户端【登录会话】上，仅 ReloadUI 不足以恢复，必须小退重新登陆才生效
--   （已实测：禁用后重载无效，小退重登才恢复）。故关闭时弹「小退重新登陆」提示。
--   （早期方案曾把 IconIntroTracker.RegisterEvent 全局置空，导致关闭后无法干净复位，已弃用。）
--
-- 单一开关存于 ActionbarEnhancedDB.disableAutoAdd.enabled（角色级存档，默认启用）。

ActionbarEnhanced = ActionbarEnhanced or {}
local BAR = ActionbarEnhanced
BAR.DisableAutoAdd = BAR.DisableAutoAdd or {}

local MOD = BAR.DisableAutoAdd
MOD._hooked = false        -- 兜底监听帧是否已挂脚本
MOD._trackerHooked = false -- 是否已替换 IconIntroTracker.OnEvent
MOD._origOnEvent = nil      -- 原始 OnEvent 脚本（用于还原）

-- 兜底监听帧：撤销任何仍被推入槽位的技能（taint-safe）
local undoFrame = CreateFrame("Frame")
local function OnSpellPushed(_, _, _, slot)
    if not InCombatLockdown() and slot then
        ClearCursor()
        PickupAction(slot)
        ClearCursor()
    end
end

-- IconIntroTracker 的 OnEvent 包装：开启时跳过 SPELL_PUSHED_TO_ACTIONBAR
local function TrackerOnEvent(self, event, ...)
    if event == "SPELL_PUSHED_TO_ACTIONBAR" and MOD.IsEnabled() then
        return
    end
    if MOD._origOnEvent then
        MOD._origOnEvent(self, event, ...)
    end
end

-- 从源头掐断自动添加：替换 IconIntroTracker.OnEvent（可还原）
local function PatchTracker()
    if MOD._trackerHooked then return end
    if IconIntroTracker then
        MOD._origOnEvent = IconIntroTracker:GetScript("OnEvent")
        IconIntroTracker:SetScript("OnEvent", TrackerOnEvent)
    end
    MOD._trackerHooked = true
end

-- 还原 IconIntroTracker.OnEvent → 自动添加恢复
local function RestoreTracker()
    if not MOD._trackerHooked then return end
    if IconIntroTracker and MOD._origOnEvent then
        IconIntroTracker:SetScript("OnEvent", MOD._origOnEvent)
    end
    MOD._origOnEvent = nil
    MOD._trackerHooked = false
end

-- =========================================================
-- 配置开关（默认启用）
-- =========================================================
function MOD.EnsureDB()
    ActionbarEnhancedDB = ActionbarEnhancedDB or {}
    ActionbarEnhancedDB.disableAutoAdd = ActionbarEnhancedDB.disableAutoAdd or {}
    if ActionbarEnhancedDB.disableAutoAdd.enabled == nil then
        ActionbarEnhancedDB.disableAutoAdd.enabled = true
    end
end

function MOD.IsEnabled()
    return ActionbarEnhancedDB and ActionbarEnhancedDB.disableAutoAdd
        and ActionbarEnhancedDB.disableAutoAdd.enabled ~= false
end

function MOD.Start()
    PatchTracker()
    if not MOD._hooked then
        undoFrame:SetScript("OnEvent", OnSpellPushed)
        MOD._hooked = true
    end
    undoFrame:RegisterEvent("SPELL_PUSHED_TO_ACTIONBAR")
end

function MOD.Stop()
    undoFrame:UnregisterEvent("SPELL_PUSHED_TO_ACTIONBAR")
    RestoreTracker()
end

function MOD.SetEnabled(v)
    MOD.EnsureDB()
    ActionbarEnhancedDB.disableAutoAdd.enabled = v
    if v then
        MOD.Start()
        print("|cff33ccff[ActionbarEnhanced]|r 阻止新技能自动加入动作栏已【启用】。")
    else
        MOD.Stop()
        print("|cff33ccff[ActionbarEnhanced]|r 阻止新技能自动加入动作栏已【关闭】（需小退后生效）。")
        -- 客户端将该行为绑定在【登录会话】上：关闭后仅 ReloadUI 无法恢复自动入条，
        -- 必须小退重新登陆才生效。弹出独立高层级信息框提示（不再提供小退按钮）。
        MOD.ShowRelogHint()
    end
end

-- 关闭后的提示信息框：独立 UIParent 子帧 + 最高 strata（TOOLTIP）+ 高 frame level，
-- 确保显示在设置窗口（AceConfigDialog 常用 FULLSCREEN_DIALOG/DIALOG）之上；
-- 仅一个「知道了」按钮关闭，不提供小退（Logout 做不到从设置内直接触发且不必要）。
local infoFrame = CreateFrame("Frame", "ActionbarEnhancedDisableAddInfo", UIParent, "BackdropTemplate")
infoFrame:SetSize(380, 140)
infoFrame:SetPoint("CENTER")
infoFrame:SetFrameStrata("TOOLTIP")
infoFrame:SetFrameLevel(500)
infoFrame:Hide()
infoFrame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 11, top = 12, bottom = 11 },
})
local infoText = infoFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
infoText:SetPoint("TOP", 0, -22)
infoText:SetWidth(340)
infoText:SetSpacing(4)
infoText:SetText("需小退重新登陆后生效")
local infoBtn = CreateFrame("Button", nil, infoFrame, "UIPanelButtonTemplate")
infoBtn:SetSize(120, 24)
infoBtn:SetPoint("BOTTOM", 0, 16)
infoBtn:SetText("知道了")
infoBtn:SetScript("OnClick", function() infoFrame:Hide() end)

function MOD.ShowRelogHint()
    infoFrame:Show()
end

-- 加载即确保 DB 并依开关应用（PLAYER_LOGIN 时 IconIntroTracker 已存在）
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function()
    MOD.EnsureDB()
    if MOD.IsEnabled() then MOD.Start() end
end)
