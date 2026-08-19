-- ActionbarEnhanced/Preset.lua
-- 预设显示模块：追踪【不在 CDM 里的光环】（CDM 不渲染 → 没有可 reparent 的对象）。
--
-- 12.1 现实（已核实官方 API 文档 + Patch 12.1.0/API_changes）：
--   · 大地之盾(974/383648)、天怒(462854)不在 CDM 追踪集，且大地之盾已被暴雪
--     移出 "never secret" 白名单 → 战斗中(及副本/M+/PvP 受限场景)插件用
--     C_UnitAuras 自建查询一律读到 secret/空，【任何插件都无法在战斗中读取】。
--     （旧版能显示是因为 12.0.7 白名单还在，12.1 已移除，非代码改坏。）
--
-- 本模块改用 12.1 官方安全通道：【AuraContainer】（暴雪渲染层）：
--   · 每个预设一个容器(CustomAuraContainerTemplate)，按 includeSpellIDs 过滤光环；
--     光环数据由暴雪【特权】读取（AuraContainerPublicAuraSource），addon 零读取、
--     零 secret/taint 问题 → 战斗中照常显示与更新。
--   · 容器内 AuraButton 由暴雪驱动：倒计时(SetCooldownFromDurationObject)、
--     层数(SetApplicationCount)、显隐(ApplyVisibility)——addon 不读任何字段。
--   · addon 只负责两件事：把容器定位到动作条按钮上方（屏幕坐标、零锚依赖），
--     以及在 initializeFrame 回调里创建并注册子控件（必须 parent 到 AuraButton）。
--   · 容器一经创建【绝不 Hide→Show 切换】：Hide 会注销 UNIT_AURA 事件注册，重新 Show 触发
--     OnShow_Intrinsic→UpdateAllAuras→FullAuraRebuild——该全量重建在战斗中(secret)解析光环失败，
--     光环帧被清空后要等下一次 UNIT_AURA（通常=脱战）才恢复。按钮找不到时改为「停靠屏幕外」
--     （ParkContainer）：IsVisible 保持 true，事件注册与倒计时持续在线，切回瞬时恢复。
--   · 武器附魔走 item enchant 通道（非 unit aura），12.1 战斗中不受限，
--     自建 Cooldown 由 1 秒 ticker 刷新（不挂每帧 OnUpdate）。
--
-- 用法：基本配置「常见职业技能持续时间显示」为全局开关（默认开启）；
--       SELF_BUFFS 按当前职业自动启用；额外预设写 PRESETS；无需改其他代码。

local BAR = ActionbarEnhanced
if not BAR then return end

local Preset = {}
BAR.Preset = Preset

Preset.debug = (ActionbarEnhancedDB and ActionbarEnhancedDB.presetDebug) or false
                 -- 诊断开关：游戏内输入 /preset debug 切换详细日志（存盘持久化，reload 不丢）

-- 共用 Settings.lua 的样式配置（字体 / 字号 / 描边 / 配色）
local S = BAR.Settings or {}

-- =========================================================
-- 预设数据（用户编辑区）
-- =========================================================
-- 预设支持两种类型：
--
-- 类型 A：unit aura（光环）——12.1 AuraContainer 暴雪渲染层，战斗中也能显示
--   auraSpellID   : 要追踪的【光环法术ID】（单个 number，或 {id1,id2} 数组，任一命中即显示）
--   actionSpellID : 覆盖显示到哪个技能按钮（该技能的法术ID；该技能必须放在动作条上）
--   unit(可选)/filter(可选) : "player" / "HELPFUL"(默认)
--
-- 类型 B：武器临时附魔（weaponEnchant）— item enchant 通道（非 unit aura），【12.1 战斗中也能显示】
--   presetType    : 必须写 "weaponEnchant"
--   enchantID     : 武器附魔 ID
--   actionSpellID : 覆盖显示到哪个技能按钮（施放技能的法术ID）
--   enchantName(可选): 兼容字段（新方案按 enchantID 匹配，不再用名字）
--
-- 【按职业自动启用】SELF_BUFFS：玩家自身职业技能产生的 buff 的「光环→法术」映射，
--   提取自 BuffReminders/Data/Buffs.lua 的 self 表（含萨满武器附魔、盗贼涂毒、圣骑武器仪式等；
--   已排除药水/食物/磨刀石等消耗品，以及姿态/形态/开关态等非时限光环），
--   另内置各职业常见减伤/爆发技能的持续时间光环（ID 已按 12.x 正式服 wowhead 核实，注释标注光环≠技能的特例）。
--   运行时按当前职业过滤，只给当前角色建容器。
--
-- 【手动追加】PRESETS：SELF_BUFFS 未覆盖、需要手动加的预设写这里。

local SELF_BUFFS = {
    -- 死亡骑士 DEATHKNIGHT（减伤/爆发；光环=技能同ID）
    { class = "DEATHKNIGHT", auraSpellID = 48792, actionSpellID = 48792 },  -- 冰封之韧（减伤）
    { class = "DEATHKNIGHT", auraSpellID = 48707, actionSpellID = 48707 },  -- 反魔法护罩（减伤）
    { class = "DEATHKNIGHT", auraSpellID = 55233, actionSpellID = 55233 },  -- 吸血鬼之血（自保）
    { class = "DEATHKNIGHT", auraSpellID = 51271, actionSpellID = 51271 },  -- 冰霜之柱（爆发）
    { class = "DEATHKNIGHT", auraSpellID = 49039, actionSpellID = 49039 },  -- 巫妖之躯
    -- 恶魔猎手 DEMONHUNTER（减伤/爆发）
    { class = "DEMONHUNTER", auraSpellID = 212800, actionSpellID = 212800 }, -- 疾影（减伤）
    { class = "DEMONHUNTER", auraSpellID = 162264, actionSpellID = 191427 }, -- 恶魔变形（光环 162264 → 技能 191427，爆发/减伤）
    -- 猎人 HUNTER（减伤/爆发）
    { class = "HUNTER", auraSpellID = 212431, actionSpellID = 212431 , unit = "target", filter = "HARMFUL" },    -- 爆炸射击
    { class = "HUNTER", auraSpellID = 186265, actionSpellID = 186265 },  -- 灵龟守护（减伤）
    { class = "HUNTER", auraSpellID = 264735, actionSpellID = 264735 },  -- 优胜劣汰（减伤）
    { class = "HUNTER", auraSpellID = 385540, actionSpellID = 109304 },  -- 意气风发（减伤）
    { class = "HUNTER", auraSpellID = 19574, actionSpellID = 19574 },    -- 狂野怒火（爆发）
    { class = "HUNTER", auraSpellID = 288613, actionSpellID = 288613 },    -- 百发百中（爆发）
    { class = "HUNTER", auraSpellID = 34477, actionSpellID = 34477 },    -- 误导(生效前)
    { class = "HUNTER", auraSpellID = 35079, actionSpellID = 34477 },    -- 误导(生效后)
    { class = "HUNTER", auraSpellID = 257622, actionSpellID = 257620 },    -- 技巧射击绑多重射击
    { class = "HUNTER", auraSpellID = 6197, actionSpellID = 6197 },    -- 鹰眼术
    -- 武僧 MONK（减伤/爆发）
    { class = "MONK", auraSpellID = 122278, actionSpellID = 122278 },    -- 躯不坏（减伤）
    { class = "MONK", auraSpellID = 122783, actionSpellID = 122783 },    -- 散魔功（减伤）
    { class = "MONK", auraSpellID = 115176, actionSpellID = 115176 },    -- 禅悟冥想（引导减伤）
    { class = "MONK", auraSpellID = 116680, actionSpellID = 116680 },    -- 雷光聚神茶（爆发）
    { class = "MONK", auraSpellID = 137639, actionSpellID = 137639 },    -- 风火雷电（爆发）
    -- 萨满 SHAMAN
    { class = "SHAMAN", auraSpellID = 1219480, actionSpellID = 114050 },    -- 升腾
    { class = "SHAMAN", auraSpellID = 383648, actionSpellID = 974 },      -- 大地之盾（光环 383648 → 技能 974）
    { class = "SHAMAN", auraSpellID = 462854, actionSpellID = 462854 },   -- 天怒（光环=技能）
    { class = "SHAMAN", auraSpellID = 192106, actionSpellID = 192106 },   -- 闪电之盾
    { class = "SHAMAN", auraSpellID = 52127, actionSpellID = 52127 },     -- 水之护盾
    { class = "SHAMAN", auraSpellID = 546, actionSpellID = 546 },     -- 水上行走
    { class = "SHAMAN", auraSpellID = 6196, actionSpellID = 6196 },     -- 视界术
    { class = "SHAMAN", presetType = "weaponEnchant", enchantID = 5400, actionSpellID = 318038, enchantName = "Flametongue" },      -- 火舌武器
    { class = "SHAMAN", presetType = "weaponEnchant", enchantID = 5401, actionSpellID = 33757, enchantName = "Windfury" },          -- 风怒武器
    { class = "SHAMAN", presetType = "weaponEnchant", enchantID = 6498, actionSpellID = 382021, enchantName = "Earthliving Weapon" }, -- 大地生命武器
    { class = "SHAMAN", presetType = "weaponEnchant", enchantID = 7528, actionSpellID = 457481, enchantName = "Tidecaller's Guard" }, -- 唤潮者护卫
    { class = "SHAMAN", auraSpellID = 108271, actionSpellID = 108271 },  -- 星界转移（减伤）
    { class = "SHAMAN", auraSpellID = 191634, actionSpellID = 191634 },  -- 风暴守护者（爆发）
    { class = "SHAMAN", auraSpellID = 2825, actionSpellID = 2825 },      -- 嗜血（团队急速）
    { class = "SHAMAN", auraSpellID = 32182, actionSpellID = 32182 },    -- 英勇（团队急速，联盟版）
    { class = "SHAMAN", auraSpellID = 188389, actionSpellID = 470057, unit = "target", filter = "HARMFUL" },
    { class = "SHAMAN", auraSpellID = 188389, actionSpellID = 470411, unit = "target", filter = "HARMFUL" },
    -- 盗贼 ROGUE（武器涂毒：光环 = 技能 同 ID）
    { class = "ROGUE", auraSpellID = 381664, actionSpellID = 381664 },  -- 增效毒药 Amplifying
    { class = "ROGUE", auraSpellID = 2823, actionSpellID = 2823 },      -- 致命毒药 Deadly
    { class = "ROGUE", auraSpellID = 315584, actionSpellID = 315584 },  -- 即时毒药 Instant
    { class = "ROGUE", auraSpellID = 8679, actionSpellID = 8679 },      -- 致伤毒药 Wound
    { class = "ROGUE", auraSpellID = 381637, actionSpellID = 381637 },  -- 萎缩毒药 Atrophic
    { class = "ROGUE", auraSpellID = 5761, actionSpellID = 5761 },      -- 麻痹毒药 Numbing
    { class = "ROGUE", auraSpellID = 3408, actionSpellID = 3408 },      -- 减速毒药 Crippling
    -- 盗贼 ROGUE（减伤/爆发；光环=技能同ID）
    { class = "ROGUE", auraSpellID = 31224, actionSpellID = 31224 },     -- 斗篷（减伤）
    { class = "ROGUE", auraSpellID = 5277, actionSpellID = 5277 },       -- 闪避（减伤）
    { class = "ROGUE", auraSpellID = 1966, actionSpellID = 1966 },       -- 佯攻（AoE减伤）
    { class = "ROGUE", auraSpellID = 185311, actionSpellID = 185311 },   -- 猩红之瓶（自疗）
    { class = "ROGUE", auraSpellID = 1856, actionSpellID = 1856 },       -- 消失（保命）
    { class = "ROGUE", auraSpellID = 13750, actionSpellID = 13750 },     -- 冲动（爆发）
    { class = "ROGUE", auraSpellID = 185422, actionSpellID = 185422 },   -- 影舞步（敏锐爆发）
    { class = "ROGUE", auraSpellID = 121471, actionSpellID = 121471 },   -- 暗影之刃（爆发）
    -- 法师 MAGE
    { class = "MAGE", auraSpellID = 1459, actionSpellID = 1459 },        -- 奥术智慧（团队增益）
    { class = "MAGE", auraSpellID = 210126, actionSpellID = 1459 },      -- 奥术魔宠（buff 210126 → 奥术智慧 1459）
    -- 法师 MAGE（减伤/爆发；光环=技能同ID）
    { class = "MAGE", auraSpellID = 45438, actionSpellID = 45438 },      -- 寒冰屏障（减伤）
    { class = "MAGE", auraSpellID = 11426, actionSpellID = 11426 },      -- 寒冰护体（减伤）
    { class = "MAGE", auraSpellID = 12042, actionSpellID = 12042 },      -- 奥术强化（爆发）
    { class = "MAGE", auraSpellID = 12472, actionSpellID = 12472 },      -- 冰冷血脉（爆发）
    { class = "MAGE", auraSpellID = 190319, actionSpellID = 190319 },    -- 燃烧（火法爆发）
    -- 术士 WARLOCK
    { class = "WARLOCK", auraSpellID = 196099, actionSpellID = 108503 }, -- 牺牲魔典
    { class = "WARLOCK", auraSpellID = 104773, actionSpellID = 104773 }, -- 不灭决心（减伤）
    { class = "WARLOCK", auraSpellID = 108416, actionSpellID = 108416 }, -- 黑暗契约（减伤）
    -- 战士 WARRIOR
    { class = "WARRIOR", auraSpellID = 6673, actionSpellID = 6673 },     -- 战斗怒吼（团队增益）
    -- 战士 WARRIOR（减伤/爆发；光环=技能同ID）
    { class = "WARRIOR", auraSpellID = 871, actionSpellID = 871 },       -- 盾墙（防战减伤）
    { class = "WARRIOR", auraSpellID = 18499, actionSpellID = 18499 },       -- 狂暴之怒
    { class = "WARRIOR", auraSpellID = 97463, actionSpellID = 97462 },       -- 集结呐喊
    { class = "WARRIOR", auraSpellID = 1160, actionSpellID = 1160 , unit = "target", filter = "HARMFUL" },       -- 挫志怒吼
    { class = "WARRIOR", auraSpellID = 12323, actionSpellID = 12323 , unit = "target", filter = "HARMFUL" },       -- 刺耳怒吼
    { class = "WARRIOR", auraSpellID = 386071, actionSpellID = 386071 , unit = "target", filter = "HARMFUL" },       -- 瓦解怒吼
    { class = "WARRIOR", auraSpellID = 12975, actionSpellID = 12975 },   -- 破釜沉舟（防战减伤）
    { class = "WARRIOR", auraSpellID = 23920, actionSpellID = 23920 },   -- 法术反射（减伤）
    { class = "WARRIOR", auraSpellID = 184364, actionSpellID = 184364 }, -- 狂怒回复（自疗）
    { class = "WARRIOR", auraSpellID = 190456, actionSpellID = 190456 }, -- 无视苦痛（防战吸收）
    { class = "WARRIOR", auraSpellID = 1719, actionSpellID = 1719 },     -- 鲁莽（爆发）
    { class = "WARRIOR", auraSpellID = 107574, actionSpellID = 107574 }, -- 天神下凡（爆发）
    { class = "WARRIOR", auraSpellID = 227847, actionSpellID = 227847 }, -- 剑刃风暴（爆发）
    { class = "WARRIOR", auraSpellID = 260708, actionSpellID = 260708 }, -- 横扫攻击（爆发）
    -- 德鲁伊 DRUID
    { class = "DRUID", auraSpellID = 1126, actionSpellID = 1126 },       -- 野性印记（团队增益，432661 为 NPC 版）
    -- 德鲁伊 DRUID（减伤/爆发；光环=技能同ID）
    { class = "DRUID", auraSpellID = 22812, actionSpellID = 22812 },     -- 树皮术（减伤）
    { class = "DRUID", auraSpellID = 61336, actionSpellID = 61336 },     -- 生存本能（减伤）
    { class = "DRUID", auraSpellID = 192081, actionSpellID = 192081 },   -- 铁鬃（熊减伤）
    { class = "DRUID", auraSpellID = 22842, actionSpellID = 22842 },     -- 狂暴回复（自疗）
    { class = "DRUID", auraSpellID = 106951, actionSpellID = 106951 },   -- 狂暴（爆发）
    { class = "DRUID", auraSpellID = 102558, actionSpellID = 102558 },   -- 化身:丛林之王（熊爆发）
    { class = "DRUID", auraSpellID = 5217, actionSpellID = 5217 },       -- 猛虎之怒（猫爆发）
    { class = "DRUID", auraSpellID = 33891, actionSpellID = 33891 },     -- 化身:生命之树（奶爆发）
    -- 牧师 PRIEST
    { class = "PRIEST", auraSpellID = 21562, actionSpellID = 21562 },    -- 真言术韧（团队增益）
    { class = "PRIEST", auraSpellID = 586, actionSpellID = 586 },    -- 渐隐术
    { class = "PRIEST", auraSpellID = 10060, actionSpellID = 10060 },    -- 能量灌注
    { class = "PRIEST", auraSpellID = 19236, actionSpellID = 19236 },    -- 绝望祷言
    { class = "PRIEST", auraSpellID = 17, actionSpellID = 17 },    -- 真言术盾
    { class = "PRIEST",  auraSpellID = 121557, actionSpellID = 121536 }, -- 羽毛
    { class = "PRIEST", auraSpellID = 589, actionSpellID = 589, unit = "target", filter = "HARMFUL" }, -- 暗影术痛
    -- 牧师 PRIEST（减伤/爆发；光环=技能同ID）
    { class = "PRIEST", auraSpellID = 33206, actionSpellID = 33206 },    -- 痛苦压制（减伤）
    { class = "PRIEST", auraSpellID = 47788, actionSpellID = 47788 },    -- 守护之魂（减伤/保命）
    { class = "PRIEST", auraSpellID = 47585, actionSpellID = 47585 },    -- 消散（暗牧减伤）
    { class = "PRIEST", auraSpellID = 15286, actionSpellID = 15286 },    -- 吸血鬼拥抱（自疗）
    { class = "PRIEST", auraSpellID = 64843, actionSpellID = 64843 },    -- 神圣赞美诗（团队治疗）


    -- 圣骑士 PALADIN（武器仪式）
    { class = "PALADIN", presetType = "weaponEnchant", enchantID = 7144, actionSpellID = 433583 }, -- 裁决仪式（buff 433584）
    { class = "PALADIN", presetType = "weaponEnchant", enchantID = 7143, actionSpellID = 433568 }, -- 圣化仪式（buff 433550）
    -- 圣骑士 PALADIN（减伤/爆发；光环=技能同ID）
    { class = "PALADIN", auraSpellID = 642, actionSpellID = 642 },       -- 圣盾术（减伤）
    { class = "PALADIN", auraSpellID = 498, actionSpellID = 498 },       -- 圣佑术（减伤）
    { class = "PALADIN", auraSpellID = 31850, actionSpellID = 31850 },   -- 炽热防御者（防骑减伤）
    { class = "PALADIN", auraSpellID = 86659, actionSpellID = 86659 },   -- 远古列王守卫（减伤）
    { class = "PALADIN", auraSpellID = 31884, actionSpellID = 31884 },   -- 复仇之怒（爆发）
    { class = "PALADIN", auraSpellID = 105809, actionSpellID = 105809 }, -- 神圣复仇者（防骑爆发）
    -- 唤魔者 EVOKER（增辉协调：黑 403264 / 铜 403265 二选一）
    { class = "EVOKER", auraSpellID = { 403264, 403265 }, actionSpellID = 403208 },
    -- 唤魔者 EVOKER 青铜龙祝福（团队增益，光环为多阶段变体）
    { class = "EVOKER", auraSpellID = { 381732, 381741, 381746, 381748, 381749, 381750, 381751, 381752, 381753, 381754, 381756, 381757, 381758 }, actionSpellID = 364342 },
    -- 唤魔者 EVOKER（减伤/爆发；光环=技能同ID）
    { class = "EVOKER", auraSpellID = 363916, actionSpellID = 363916 },  -- 黑曜石鳞片（减伤）
    { class = "EVOKER", auraSpellID = 357170, actionSpellID = 357170 },  -- 时间膨胀（团队减伤）
    { class = "EVOKER", auraSpellID = 357210, actionSpellID = 357210 },  -- 深呼吸（爆发）
}

-- 手动追加的预设（SELF_BUFFS 之外的写这里；自动的来自上方 SELF_BUFFS）
local PRESETS = {
    -- { auraSpellID = 123456, actionSpellID = 123, unit = "player", filter = "HELPFUL" },
    -- { presetType = "weaponEnchant", enchantID = 5400, actionSpellID = 318038 },
    -- 种族技能（与职业无关，如矮人石像形态）也写这里、不设 class：
    -- 运行时 UpdatePresetAura 的 IsPlayerSpell(20594) 会自动过滤——只有会该技能的种族才生效，
    -- 其余种族返回 false 直接跳过，不会误建容器/刷屏。
    { auraSpellID = 65116, actionSpellID = 20594 }, -- 石像形态（光环 65116 → 技能 20594，矮人种族）
}

-- 运行时生效的预设 = PRESETS(手动) + 按当前职业过滤的 SELF_BUFFS(自动)，去重
local ACTIVE_PRESETS = {}

local function PresetKey(p)
    if p.presetType == "weaponEnchant" then
        return "E" .. tostring(p.enchantID) .. "_" .. tostring(p.actionSpellID)
    end
    local id = p.auraSpellID
    if type(id) == "table" then
        local parts = {}
        for _, v in ipairs(id) do parts[#parts + 1] = tostring(v) end
        return "A" .. table.concat(parts, ",") .. "_" .. tostring(p.actionSpellID)
    end
    return "A" .. tostring(id) .. "_" .. tostring(p.actionSpellID)
end

local function BuildActivePresets(classToken)
    wipe(ACTIVE_PRESETS)
    local seen = {}
    local function add(p)
        local key = PresetKey(p)
        if not seen[key] then
            seen[key] = true
            ACTIVE_PRESETS[#ACTIVE_PRESETS + 1] = p
        end
    end
    for _, p in ipairs(PRESETS) do add(p) end
    if classToken then
        for _, p in ipairs(SELF_BUFFS) do
            if p.class == classToken then add(p) end
        end
    end
end

-- =========================================================
-- 工具函数
-- =========================================================
-- 安全判断 secret 值（12.1 受限内容返回 secret，不可比较/运算/布尔测试）
local function IsSecret(v)
    local ok, res = pcall(function() return issecretvalue and issecretvalue(v) end)
    return ok and res
end

-- 格式化光环 ID（支持单个 number 或 {id1,id2} 数组）用于日志/状态显示
local function FmtAuraID(id)
    if type(id) == "table" then return table.concat(id, "/") end
    return tostring(id)
end

-- 复用 AutoCDM 的按钮查找：按法术名找到原生动作条按钮
local function FindActionButtonForSpellName(name)
    if not name then return end
    local barNames = (ActionButtonUtil and ActionButtonUtil.ActionBarButtonNames) or {}
    for _, actionBar in ipairs(barNames) do
        if type(actionBar) == "string" then
            for i = 1, (NUM_ACTIONBAR_BUTTONS or 12) do
                local btn = _G[actionBar .. i]
                -- 只匹配【可见】的按钮：MultiBarLeft/MultiBarRight 等左右动作条共享 action 槽位，
                -- 同一技能会同时命中左右两个按钮，隐藏栏的按钮 GetActionInfo 也返回该技能，
                -- 若不跳过隐藏按钮，会错误匹配到隐藏栏（导致"拖到右栏却显示在左栏/不显示"）。
                if btn and btn:IsShown() then
                    -- 不判断 btn.action（对齐官方 GetActionButtonBySpellID），MultiBar 按钮
                    -- 的 action 可能为 nil/特殊，直接 GetActionInfo 更稳（nil 时返回 nil 安全跳过）
                    local _, actionSpellID = GetActionInfo(btn.action)
                    if actionSpellID then
                        -- 直接 GetSpellName(actionSpellID)，【不要】GetBaseSpell 重定向：
                        -- GetBaseSpell 会把部分法术重定向成异名基础法术，导致名字匹配失败
                        -- （AutoCDM 的 63cafe4 已踩过此坑，见其"去掉 GetBaseSpell 重定向"）。
                        local actionSpellName = C_Spell.GetSpellName(actionSpellID)
                        if name == actionSpellName then
                            return btn
                        end
                    end
                end
            end
        end
    end
    for i = 1, (NUM_SPECIAL_BUTTONS or 10) do
        local stanceBtn = StanceBar and StanceBar.actionButtons and StanceBar.actionButtons[i]
        if stanceBtn then
            local stanceSpellID = select(4, GetShapeshiftFormInfo(stanceBtn:GetID()))
            if stanceSpellID then
                local stanceSpellName = C_Spell.GetSpellName(stanceSpellID)
                if name == stanceSpellName then
                    return stanceBtn
                end
            end
        end
    end
end

-- =========================================================
-- 类型 A：unit aura —— 12.1 AuraContainer 暴雪渲染层
-- =========================================================
-- 重设 AuraButton 内倒计时框锚点（统一【相对锚定 btn】）。
-- ⚠️ 绝不绝对锚定 UIParent：cd 的 parent 是 AuraButton（Forbidden Aspect），
--    战斗中(secret)对其 SetPoint 可能被拦截抛错 → 停靠时容器挪走而 cd 滞留原位（数字不消失）。
--    相对锚定 btn 后，btn 由暴雪 flow layout 相对 container 定位 → 挪容器全链自动跟随。
--    容器尺寸被 flow layout 异步覆盖(≈1x1)的错位由「btn 固定尺寸（见 SetupAuraButton）+
--    PositionContainer 每秒重设容器/btn 尺寸」纠正，不再依赖 cd 绝对锚定。
local function LayoutAuraChildren(p)
    local cd, btn = p.cd, p.auraButton
    if not cd or not btn then return end
    local ok, w, h = pcall(btn.GetSize, btn)
    if not ok or not w or w <= 0 then w, h = 36, 36 end
    pcall(function()
        cd:ClearAllPoints()
        cd:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 1, -6)
        cd:SetPoint("TOPRIGHT", btn, "BOTTOMLEFT", w * 0.62, h * 0.62 - 7)
    end)
end

-- 把容器定位到动作按钮之上（屏幕坐标，绝不锚到按钮；含缩放换算）。
-- 容器是 addon 创建的普通 Frame，SetPoint/SetSize 均可安全调用。
-- ⚠️ 位置(SetPoint)可缓存；尺寸(SetSize)与子控件布局每次都要重做——
--    AuraContainer 的 flow layout 会在光环变化时异步覆盖容器尺寸(OnLayoutComplete→SetSize)，
--    若把 SetSize/子控件布局也缓存跳过，尺寸被覆盖后不再纠正 → 倒计时框错位。
local function PositionContainer(container, btn, p)
    if not container or not btn then return false end
    local left, bottom, width, height = btn:GetRect()
    if not left then
        if Preset.debug and p then
            local btnName = btn.GetName and btn:GetName() or "?"
            local okShown, shown = pcall(function() return btn:IsShown() end)
            print(("|cff33ccff[Preset]|r 光环%s → 按钮%s 定位失败(GetRect=nil, IsShown=%s)"):format(FmtAuraID(p.auraSpellID), tostring(btnName), tostring(okShown and shown)))
        end
        return false
    end
    local r = 1
    local bs, ps = btn:GetEffectiveScale(), UIParent:GetEffectiveScale()
    if bs and ps and ps > 0 then r = bs / ps end
    -- 仅位置变化时才重新 SetPoint（省 ClearAllPoints+SetPoint）
    if not p or p._rectL ~= left or p._rectB ~= bottom or p._rectW ~= width or p._rectH ~= height then
        if Preset.debug and p then
            local btnName = btn.GetName and btn:GetName() or "?"
            print(("|cff33ccff[Preset]|r 光环%s → 按钮%s rect=(%.0f,%.0f,%.0f,%.0f) r=%.3f"):format(FmtAuraID(p.auraSpellID), tostring(btnName), left, bottom, width, height, r))
        end
        container:ClearAllPoints()
        container:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left * r, (bottom + height) * r)
        if p then
            p._rectL, p._rectB, p._rectW, p._rectH = left, bottom, width, height
        end
    end
    -- 尺寸与子控件布局每次重做（对抗暴雪 flow layout 的异步尺寸覆盖：
    -- OnLayoutComplete 会按内容收缩容器；容器被收缩→我们重设→稳定）。
    -- btn 尽力升到按钮尺寸（36 初始 → 按钮实际大小），包 pcall——
    -- initializeFrame 之外对 AuraButton 的 SetSize 可能被 Forbidden 拦截，
    -- 失败保持 36×36（仅倒计时区域略小，不影响可见性），下次脱战自愈。
    container:SetSize(width * r, height * r)
    if p and p.auraButton then
        pcall(p.auraButton.SetSize, p.auraButton, width * r, height * r)
    end
    LayoutAuraChildren(p)
    return true
end

-- 把容器停靠到屏幕外（按钮找不到/定位失败时）。
-- ⚠️ 绝不用 container:Hide()：Hide 会注销 UNIT_AURA 注册（ShouldRegisterForDynamicEvents =
--    IsVisible and IsEnabled），重新 Show 触发 OnShow_Intrinsic→UpdateAllAuras→FullAuraRebuild，
--    战斗中(secret)解析光环失败 → 光环帧清空，要等下一次 UNIT_AURA（通常=脱战）才恢复——
--    即「切走动作条再切回、倒计时消失到脱战」的 bug。
--    停靠屏幕外保持 IsVisible=true：事件注册与倒计时持续在线，切回重定位即瞬时恢复。
-- ⚠️ 只挪容器本身（addon 自己的帧，SetPoint 战斗安全）：btn(AuraButton) 由暴雪 flow layout
--    相对 container 定位，cd/fs 相对锚定 btn → 全链自动跟随，战斗中零操作 Forbidden 对象
--    （旧版 cd 绝对锚定 UIParent 需单独挪动，战斗中(secret) SetPoint 被 Forbidden 拦截
--     → 容器走了 cd 滞留原位 = 数字不消失的 bug）。
--    必须清矩形缓存：切回后按钮矩形若恰好与旧缓存相同，PositionContainer 会判"未变"
--    跳过 SetPoint → 容器留在屏幕外。
local function ParkContainer(container, p)
    if p._parked then
        if Preset.debug and not p._parkSkipLogged then
            p._parkSkipLogged = true
            print(("|cff33ccff[Preset]|r 停靠跳过(已停靠) 光环%s"):format(FmtAuraID(p.auraSpellID)))
        end
        return
    end
    if Preset.debug then
        print(("|cff33ccff[Preset]|r 停靠开始 光环%s"):format(FmtAuraID(p.auraSpellID)))
    end
    container:ClearAllPoints()
    container:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", -10000, -10000)
    p._parked = true
    p._parkSkipLogged = nil
    p._rectL, p._rectB, p._rectW, p._rectH = nil, nil, nil, nil
    if Preset.debug then
        print(("|cff33ccff[Preset]|r 停靠完成 光环%s"):format(FmtAuraID(p.auraSpellID)))
    end
end

-- initializeFrame 回调：暴雪创建 AuraButton 后，addon 注册子控件。
-- ⚠️ 子控件必须 parent 到 btn（ValidateInboundScriptObject 强制 descendant，
--    InitializeInboundScriptObject 禁止之后改 parent），之后由暴雪驱动内容：
--     · cd  → ApplyDurationCooldown → SetCooldownFromDurationObject（倒计时数字自带）
--     · fs  → ApplyApplicationCount → SetText（层数，>1 才显示）
-- ⚠️ btn 几何【SetSize + SetAllPoints(container) 双保险】（CustomAuraContainerFlowLayoutMixin 源码核实）：
--    · 暴雪 flow layout 的 ApplyElementLayout 会对 slot 帧 ClearAllPoints 后以【单锚点】重锚，
--      SetAllPoints 的锚定派生尺寸随之丢失——必须先有显式 SetSize，否则塌缩 0×0 → 整个预设不可见
--    · SetAllPoints 保证首次布局运行前的过渡期 btn 跟随容器（停靠/挪容器即时跟随）
--    · GetElementSize 读 element:GetSize()——框架不负责 slot 帧尺寸，显式尺寸是唯一可靠来源
--    · 两调用均在 initializeFrame 特权上下文内，仍包 pcall 防御（失败会打印诊断）
local function SetupAuraButton(p, btn)
    if Preset.debug then
        print(("|cff33ccff[Preset]|r 光环帧初始化 光环%s（若战斗中切页后重复出现=暴雪重建了光环帧）"):format(FmtAuraID(p.auraSpellID)))
    end
    local okSize = pcall(btn.SetSize, btn, 36, 36)
    local okAll = pcall(btn.SetAllPoints, btn, p.container)
    if Preset.debug then
        print(("|cff33ccff[Preset]|r 光环%s 帧几何 SetSize=%s SetAllPoints=%s"):format(FmtAuraID(p.auraSpellID), tostring(okSize), tostring(okAll)))
    end
    local cd = CreateFrame("Cooldown", nil, btn)
    cd:SetDrawSwipe(false)
    cd:SetDrawEdge(false)
    cd:SetHideCountdownNumbers(false)
    btn:SetDurationCooldown(cd)
    p.cd = cd
    p.cdStyled = nil  -- 新 cd 的倒计时数字是新 FontString，样式需重新应用
    local fs = btn:CreateFontString(nil, "OVERLAY")
    fs:SetPoint("TOPLEFT", btn, "TOPLEFT", 5, -5)
    fs:SetFont(S.FONT, S.FONT_SIZE, S.OUTLINE)
    local sc = S.STACK_COLOR or { 1, 1, 1 }
    fs:SetTextColor(sc[1], sc[2], sc[3])
    btn:SetApplicationCount(fs)
    p.stacksFS = fs
    p.auraButton = btn
    LayoutAuraChildren(p)
end

-- 为预设创建 AuraContainer（每预设一个容器，独立定位到各自按钮）。
-- 光环过滤用 includeSpellIDs（按 auraData.spellId 精确匹配光环 ID）。
local function InitAuraPreset(p)
    if p.container then return true end
    if p._initFailed then return false end  -- 上次战斗中创建失败 → 等脱战重试
    local unit = p.unit or "player"
    local filter = p.filter or "HELPFUL"

    local container = CreateFrame("AuraContainer", nil, UIParent, "CustomAuraContainerTemplate")
    container:SetFrameStrata("HIGH")
    container:SetFrameLevel(1000)
    container:SetSize(36, 36)
    container:SetUnit(unit)
    container:SetEnabled(true)
    -- ⚠️ 先挂引用：AddAuraSlot 的 initializeFrame 回调【同步】执行，
    --   SetupAuraButton 里要读 p.container 建立关联
    p.container = container

    -- 归一化光环 ID（支持单个 number 或 {id1,id2} 数组，任一命中即显示）
    local auraIDs = p.auraSpellID
    local includeSpellIDs = {}
    if type(auraIDs) == "table" then
        for _, id in ipairs(auraIDs) do includeSpellIDs[id] = true end
    elseif auraIDs then
        includeSpellIDs[auraIDs] = true
    end

    local auraFrame
    local ok = pcall(function()
        auraFrame = container:AddAuraSlot("preset", filter, {
            candidateFilters = { includeSpellIDs = includeSpellIDs },
            initializeFrame = function(btn) SetupAuraButton(p, btn) end,
        })
    end)
    if not ok then
        p._initFailed = true
        p.container = nil
        container:Hide()
        return false
    end
    p.auraFrame = auraFrame
    container:Show()
    return true
end

-- Cooldown 倒计时数字 FontString 要等暴雪首次 SetCooldownFromDurationObject 后才存在，
-- 用低频 ticker 轮询，设置一次字体/颜色后标记完成（幂等、廉价）。
-- ⚠️ 数字 FontString 带 secret aspect，SetFont/SetTextColor 包 pcall 防御；
--    失败【不标记完成】——战斗中(secret)被拦截时保持重试，脱战后成功上色
--    （旧版失败也标记 → 数字永远白色）。
local function ApplyCountdownFont(p)
    local cd = p.cd
    if not cd or p.cdStyled then return end
    local cds = cd.GetCountdownFontString and cd:GetCountdownFontString()
    if not cds then return end
    local unit = p.unit or "player"
    local c = (S.GetTimeColor and S.GetTimeColor(unit, false)) or S.TIME_COLOR_OTHER_BUFF or { 1, 1, 0 }
    local ok = pcall(function()
        cds:SetFont(S.FONT, S.FONT_SIZE, S.OUTLINE)
        cds:SetTextColor(c[1], c[2], c[3])
    end)
    if ok then
        p.cdStyled = true
    end
end

local function UpdatePresetAura(p)
    if not p.auraSpellID or not p.actionSpellID then return end
    -- 玩家没学该施放技能（如元素萨满没学水之护盾/闪电之盾）→ 跳过，不追踪不刷屏
    if not IsPlayerSpell(p.actionSpellID) then
        return
    end
    if not InitAuraPreset(p) then return end
    local container = p.container

    -- 解析显示目标按钮（缓存，找不到时 ticker 定期重试；该 actionSpellID 必须放在动作条上）
    -- ⚠️ 缓存自愈（2026-08-19 修「脱战后切页数字滞留」）：翻页后同一按钮换了技能，但
    --    UNIT_AURA 驱动的 RefreshAll 不清缓存；若 p.button 残留旧按钮（翻页过渡期 Find 扫到
    --    旧数据/页面事件漏网），每次刷新都会把容器拉回旧按钮位置 → 倒计时数字常驻不消失。
    --    每 tick 用一次 GetActionInfo 名字比对验证缓存（与 Find 匹配逻辑对称），失效即作废重找。
    --    stance 按钮（action=nil）跳过验证：其内容不随翻页变化，验证反而每 tick 触发全量重扫。
    local actionName = C_Spell.GetSpellName(p.actionSpellID)
    if p.button and p.button.action ~= nil then
        local okA, _, actionSpellID = pcall(GetActionInfo, p.button.action)
        local curName = (okA and actionSpellID) and C_Spell.GetSpellName(actionSpellID) or nil
        if curName ~= actionName then
            -- 诊断（去重）：记录验证失效时刻按钮 action 的实际内容，用于区分
            -- 「按钮已换技能」（正常翻页失效）与「action 指向异常」（外部条插件场景）
            if Preset.debug and not p._verifyFailLogged then
                print(("|cff33ccff[Preset]|r 缓存验证失效 光环%s: btn.action=%s 内容=%s 期望=%s")
                    :format(FmtAuraID(p.auraSpellID), tostring(p.button.action), tostring(curName), tostring(actionName)))
                p._verifyFailLogged = true
            end
            p.button = nil
        end
    end
    if not p.button then
        p.button = FindActionButtonForSpellName(actionName)
    end
    local btn = p.button
    if not btn then
        -- 只提示一次（找到后重置），避免 ticker/重试反复刷屏
        if Preset.debug and not p._btnMissingLogged then
            print(("|cff33ccff[Preset]|r 光环%s → 技能%s 按钮【未找到】parked=%s"):format(FmtAuraID(p.auraSpellID), p.actionSpellID, tostring(p._parked)))
            p._btnMissingLogged = true
        end
        local ok, err = pcall(ParkContainer, container, p)
        if not ok and Preset.debug then
            print(("|cff33ccff[Preset]|r 停靠异常 光环%s: %s"):format(FmtAuraID(p.auraSpellID), tostring(err)))
        end
        return
    end
    p._btnMissingLogged = nil
    p._verifyFailLogged = nil
    if Preset.debug then
        -- 按钮名变化时打印（诊断切页后匹配到了哪个按钮）
        local btnName = btn.GetName and btn:GetName() or tostring(btn)
        if btnName ~= p._lastBtnName then
            print(("|cff33ccff[Preset]|r 光环%s → 匹配到按钮%s"):format(FmtAuraID(p.auraSpellID), tostring(btnName)))
            p._lastBtnName = btnName
        end
    end
    if not PositionContainer(container, btn, p) then
        local ok, err = pcall(ParkContainer, container, p)
        if not ok and Preset.debug then
            print(("|cff33ccff[Preset]|r 停靠异常(定位失败分支) 光环%s: %s"):format(FmtAuraID(p.auraSpellID), tostring(err)))
        end
        return
    end
    p._parked = nil
    -- 容器保持可见以接收 UNIT_AURA（ShouldRegisterForDynamicEvents = IsVisible and IsEnabled）；
    -- AuraButton 的显隐由暴雪 ApplyVisibility 控制（有光环显示、无光环隐藏）。
    -- 正常路径容器从未 Hide，此 Show 幂等无副作用（仅兜底 SetEnabled(false→true) 场景）
    container:Show()
    ApplyCountdownFont(p)
end

-- =========================================================
-- 类型 B：武器临时附魔（weaponEnchant）
--   走 item enchant 通道（非 unit aura），12.1 战斗中也能检测（GetWeaponEnchantInfo 战斗安全）。
--   返回该 enchantID 的【剩余秒数】；未找到返回 nil。
--     · 主路径 GetWeaponEnchantInfo()  —— 直接返回 enchantID + 剩余毫秒到期，/1000 即剩余秒（BuffReminders 实测）
--     · 兜底 C_PaperDollInfo.GetTemporaryEnchantmentInfo —— 12.1 官方替代 API
-- =========================================================
local function GetWeaponEnchantExpiration(enchantID, enchantName)
    -- 主路径：旧 API（用户实测 12.1 仍可用）
    local ok, hasMain, mainExp, _, mainID, hasOff, offExp, _, offID = pcall(GetWeaponEnchantInfo)
    if ok then
        if mainID == enchantID and mainExp then return mainExp / 1000 end
        if offID == enchantID and offExp then return offExp / 1000 end
    end
    -- 兜底：12.1 新 API。返回结构 TemporaryItemEnchantInfo{enchantID, remainingTimeMs, ...}，
    -- 按 enchantID 匹配（注意：结构无 Name 字段，旧代码按名字匹配是错的）
    local function trySlot(slot)
        local fok, info = pcall(C_PaperDollInfo.GetTemporaryEnchantmentInfo, slot)
        if fok and info and info.enchantID == enchantID and info.remainingTimeMs then
            return info.remainingTimeMs / 1000
        end
    end
    for _, slot in ipairs({ 16, 17 }) do  -- INVSLOT_MAINHAND, INVSLOT_OFFHAND
        local sec = trySlot(slot)
        if sec and sec > 0 then return sec end
    end
    return nil
end

-- 武器附魔倒计时【每秒】驱动：GetWeaponEnchantInfo 是【非 aura 通道】，战斗中也能安全读取。
-- 由 1 秒 ticker（Tick → RefreshWeaponEnchants）调用，每秒重算剩余时间并刷新 Cooldown
-- （start=now、duration=剩余秒）。不再挂每帧 OnUpdate——降频省 CPU，1 秒精度对武器附魔足够。
local function EnchantTick(ov)
    local p = ov._preset
    if not p then return end
    local expSec = GetWeaponEnchantExpiration(p.enchantID, p.enchantName)
    if not expSec or expSec <= 0 then
        ov:Hide()
        ov._active = false
        return
    end
    local w, h = ov:GetSize()
    local cd = p.cd
    cd:SetParent(ov)
    cd:ClearAllPoints()
    cd:SetPoint("BOTTOMLEFT", ov, "BOTTOMLEFT", 1, -6)
    cd:SetPoint("TOPRIGHT", ov, "BOTTOMLEFT", w * 0.62, h * 0.62 - 7)
    cd:SetDrawSwipe(false)
    cd:SetDrawEdge(false)
    cd:SetHideCountdownNumbers(false)
    pcall(function() cd:SetCooldown(GetTime(), expSec) end)
    local cds = cd.GetCountdownFontString and cd:GetCountdownFontString()
    if cds then
        cds:SetFont(S.FONT, S.FONT_SIZE, S.OUTLINE)
        local c = S.TIME_COLOR_SELF or { 0.20, 1.00, 0.20 }  -- 自身附魔：鲜绿
        cds:SetTextColor(c[1], c[2], c[3])
    end
    if p.stacksFS then p.stacksFS:Hide() end
    cd:Show()
    ov:Show()
    ov._active = true
end

-- 类型 B 覆盖层容器：UIParent 中立容器（与动作按钮【零锚依赖】，绝不 SetPoint 到按钮）。
-- 位置用 btn:GetRect() 读屏幕矩形再摆放（只读，不污染安全帧）。
local function GetOverlay(p)
    if p.overlay then return p.overlay end
    local ov = CreateFrame("Frame", nil, UIParent)
    ov:SetFrameStrata("HIGH")
    ov:SetFrameLevel(1000)
    ov:SetSize(36, 36)
    ov:Hide()
    -- 自建显示层（无 CDM 对象可 reparent）：倒计时 Cooldown + 层数 FontString
    local cd = CreateFrame("Cooldown", nil, ov)
    cd:SetHideCountdownNumbers(false)   -- 显示倒计时数字
    cd:Hide()
    local fs = ov:CreateFontString(nil, "OVERLAY")
    fs:Hide()
    p.overlay = ov
    p.cd = cd
    p.stacksFS = fs
    return ov
end

-- 类型 B 覆盖层定位。overlay 是 addon 自建的普通 Frame，尺寸/位置完全由 addon 控制，
-- 无暴雪异步覆盖 → 坐标未变即可完整跳过 SetPoint/SetSize（每秒 ticker 省去无谓锚点操作）。
local function PositionOverlay(ov, btn, p)
    if not ov or not btn then return false end
    local left, bottom, width, height = btn:GetRect()
    if not left then return false end
    if p and p._rectL == left and p._rectB == bottom and p._rectW == width and p._rectH == height then
        return true  -- 位置未变，跳过重设
    end
    local r = 1
    local bs, ps = btn:GetEffectiveScale(), UIParent:GetEffectiveScale()
    if bs and ps and ps > 0 then r = bs / ps end
    ov:ClearAllPoints()
    ov:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left * r, (bottom + height) * r)
    ov:SetSize(width * r, height * r)
    if p then
        p._rectL, p._rectB, p._rectW, p._rectH = left, bottom, width, height
    end
    return true
end

local function UpdatePresetWeaponEnchant(p)
    if not p.enchantID or not p.actionSpellID then return end
    -- 玩家没学该施放技能（如元素萨满没学风怒/大地生命/唤潮护卫）→ 跳过，不追踪不刷屏
    if not IsPlayerSpell(p.actionSpellID) then
        return
    end
    if not p.button then
        p.button = FindActionButtonForSpellName(C_Spell.GetSpellName(p.actionSpellID))
    end
    local btn = p.button
    if not btn then
        if Preset.debug then print(("|cff33ccff[Preset]|r 武器附魔%s → 技能%s 按钮【未找到】"):format(p.enchantID, p.actionSpellID)) end
        return
    end
    local ov = GetOverlay(p)
    if not PositionOverlay(ov, btn, p) then
        ov:Hide()
        return
    end
    -- 武器附魔走非 aura 通道，战斗安全：由 1 秒 ticker 刷新（即使此刻正处于战斗）
    ov._preset = p
    EnchantTick(ov)   -- 立即填充一次（之后由 Tick → RefreshWeaponEnchants 每秒刷新）
end

-- 武器附魔非 unit aura → 战斗中也能检测；由 1 秒 ticker 刷新剩余时间（不读 aura，零 taint）
local function RefreshWeaponEnchants()
    for _, p in ipairs(ACTIVE_PRESETS) do
        if p.presetType == "weaponEnchant" then
            pcall(UpdatePresetWeaponEnchant, p)
        end
    end
end

-- =========================================================
-- 全量刷新
-- =========================================================
local function UpdatePreset(p)
    if p.presetType == "weaponEnchant" then
        UpdatePresetWeaponEnchant(p)
    else
        UpdatePresetAura(p)
    end
end

local function RefreshAll()
    for _, p in ipairs(ACTIVE_PRESETS) do
        pcall(UpdatePreset, p)
    end
end

-- 低频 ticker：类型 A 重定位容器 + 轮询倒计时字体；类型 B 清理到期/重附魔
local function Tick()
    for _, p in ipairs(ACTIVE_PRESETS) do
        if p.presetType ~= "weaponEnchant" then
            pcall(UpdatePresetAura, p)
        end
    end
    RefreshWeaponEnchants()
end

-- =========================================================
-- 对外接口（供配置面板/诊断调用）
-- =========================================================
function Preset.RefreshAll()
    RefreshAll()
end

-- 全局开关（存于 ActionbarEnhancedDB.presetEnabled，默认开启）
function Preset.IsEnabled()
    ActionbarEnhancedDB = ActionbarEnhancedDB or {}
    if ActionbarEnhancedDB.presetEnabled == nil then
        ActionbarEnhancedDB.presetEnabled = true
    end
    return ActionbarEnhancedDB.presetEnabled == true
end

function Preset.SetEnabled(v)
    ActionbarEnhancedDB = ActionbarEnhancedDB or {}
    ActionbarEnhancedDB.presetEnabled = v
    if v then
        -- 开启：重建生效预设并全量刷新（ticker 在 PLAYER_LOGIN 已常驻，空表安全）
        local _, classToken = UnitClass("player")
        BuildActivePresets(classToken)
        RefreshAll()
    else
        -- 关闭：隐藏已建的容器/覆盖层并清空生效列表
        for _, p in ipairs(ACTIVE_PRESETS) do
            if p.container then p.container:Hide() end
            if p.overlay then p.overlay:Hide() end
        end
        wipe(ACTIVE_PRESETS)
    end
    print("|cff33ccff[ActionbarEnhanced]|r 常见职业技能持续时间显示已"
        .. (v and "【启用】" or "【关闭】") .. "。")
end

-- 类型 A：光环是否激活（AuraButton 显隐由暴雪控制；IsShown 在 12.1 可能返回 secret，防御处理）
local function AuraFrameShown(p)
    local f = p.auraFrame
    if not f then return false end
    local ok, shown = pcall(function() return f:IsShown() end)
    if not ok or IsSecret(shown) then return false end
    return not not shown
end

-- =========================================================
-- 诊断状态（/preset）与调试开关（/preset debug）
-- =========================================================
function Preset.Status()
    print("|cff33ccff[Preset]|r 预设数量:" .. #ACTIVE_PRESETS
        .. (Preset.IsEnabled() and "（全局开启）" or "（全局关闭）"))
    for _, p in ipairs(ACTIVE_PRESETS) do
        local actionName = C_Spell.GetSpellName(p.actionSpellID) or "?"
        local btn = p.button
        if p.presetType == "weaponEnchant" then
            local exp = GetWeaponEnchantExpiration(p.enchantID, p.enchantName)
            print(("  武器附魔%s[%s] → 技能[%s/%s] 按钮:%s 到期:%s 覆盖层:%s")
                :format(
                    p.enchantID,
                    p.enchantName or "?",
                    p.actionSpellID, actionName,
                    btn and "找到" or "未找到",
                    exp and ("%.0f秒"):format(exp) or "无",
                    (p.overlay and p.overlay:IsShown()) and "显示" or "隐藏"))
        else
            -- 诊断增强：按钮名/停靠态/容器锚点坐标/光环帧尺寸（滞留 bug 定位用）
            local btnName = "无"
            if btn then
                btnName = (btn.GetName and btn:GetName()) or "?"
            end
            local cPos = p.container and "无锚点" or "未建"
            if p.container then
                local okP, pt, _rel, relPt, x, y = pcall(p.container.GetPoint, p.container, 1)
                if okP and pt then
                    cPos = ("%s→%s(%.0f,%.0f)"):format(tostring(pt), tostring(relPt), x or 0, y or 0)
                end
            end
            local abSize = ""
            if p.auraButton then
                local okS, w, h = pcall(p.auraButton.GetSize, p.auraButton)
                if okS and w and w > 0 then
                    abSize = (" 光环帧:%.0f×%.0f"):format(w, h)
                else
                    abSize = " 光环帧:0(塌缩!)"
                end
            end
            print(("  光环%s → 技能[%s/%s] 按钮:%s 停靠:%s 容器:%s%s 光环显示:%s")
                :format(
                    FmtAuraID(p.auraSpellID),
                    p.actionSpellID, actionName,
                    btnName,
                    p._parked and "是" or "否",
                    cPos .. (p.container and "" or (p._initFailed and "(建失败等脱战)" or "")),
                    abSize,
                    AuraFrameShown(p) and "显示" or "隐藏"))
        end
    end
end

SLASH_BARPRESET1 = "/preset"
SlashCmdList.BARPRESET = function(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if msg == "debug" then
        Preset.debug = not Preset.debug
        ActionbarEnhancedDB = ActionbarEnhancedDB or {}
        ActionbarEnhancedDB.presetDebug = Preset.debug
        print(("|cff33ccff[ActionbarEnhanced]|r 预设调试日志：%s"):format(Preset.debug and "开启" or "关闭"))
        RefreshAll()
    else
        Preset.Status()
    end
end

-- =========================================================
-- 事件
-- =========================================================
-- 动作条/页面/形态/载具/御龙术切换事件集合（对齐 Manual：翻页 PAGE_CHANGED、御龙术 OVERRIDE
-- 等场景不触发 SLOT_CHANGED，需一并监听才能让"切条后数字消失/跟随"及时生效）。
local actionbarEvents = {
    ACTIONBAR_SLOT_CHANGED       = true,
    ACTIONBAR_PAGE_CHANGED       = true,
    UPDATE_BONUS_ACTIONBAR       = true,
    UPDATE_OVERRIDE_ACTIONBAR    = true,
    UPDATE_SHAPESHIFT_FORM       = true,
    UPDATE_POSSESS_BAR           = true,
    UPDATE_MULTI_CAST_ACTIONBAR  = true,
}

local evFrame = CreateFrame("Frame")
local auraRefreshTimer = nil   -- UNIT_AURA 防抖（见事件处理）
evFrame:RegisterEvent("PLAYER_LOGIN")
for ev in pairs(actionbarEvents) do evFrame:RegisterEvent(ev) end
evFrame:RegisterEvent("PLAYER_REGEN_ENABLED")   -- 脱战：重试战斗中建失败的容器/刷新受限光环
evFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")  -- 武器附魔（重附/替换/卸下）立即刷新
evFrame:RegisterEvent("UNIT_INVENTORY_CHANGED")    -- 同上兜底
evFrame:RegisterUnitEvent("UNIT_AURA", "player")
evFrame:RegisterEvent("PLAYER_TARGET_CHANGED")   -- 切目标：unit="target" 的容器需手动刷新

evFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        -- 按当前职业构建生效预设（PRESETS 手动 + SELF_BUFFS 按职业自动过滤）；
        -- 受全局开关「常见职业技能持续时间显示」控制（默认开启）
        local _, classToken = UnitClass("player")
        if Preset.IsEnabled() then
            BuildActivePresets(classToken)
            -- 登录后稍候一帧再刷新，确保动作条按钮已就绪
            C_Timer.After(0, RefreshAll)
        end
        -- 低频 ticker：类型 A 重定位/字体 + 类型 B 清理（AuraContainer 内部自行监听 UNIT_AURA）；
        -- 常驻创建：开关关闭时 ACTIVE_PRESETS 为空、tick 无操作，开关切换无需重建
        C_Timer.NewTicker(1, Tick)
    elseif actionbarEvents[event] then
        -- 动作条/页面/形态/载具/御龙术切换：清缓存 + 延迟重匹配。
        -- ⚠️ 绝不【立即】RefreshAll：ACTIONBAR_PAGE_CHANGED 等事件在 SetActionBarPage 的保护上下文
        --    同步触发，立即操作容器(SetPoint/SetSize)会被 taint/block，导致倒计时框错位/变色/变大小。
        --    改为延迟重试，且每次重试前都清 p.button（否则第一次会把过渡态按钮缓存进 p.button 固化）。
        if Preset.debug then
            local okP, page = pcall(C_ActionBar.GetActionBarPage)
            print(("|cff33ccff[Preset]|r 动作条事件 %s page=%s"):format(event, okP and tostring(page) or "?"))
        end
        local function invalidateButtons()
            for _, p in ipairs(ACTIVE_PRESETS) do
                p.button = nil
                p._lastBtnName = nil
                p._rectL, p._rectB, p._rectW, p._rectH = nil, nil, nil, nil
            end
        end
        invalidateButtons()
        C_Timer.After(0.1, function() invalidateButtons(); RefreshAll() end)
        C_Timer.After(0.5, function() invalidateButtons(); RefreshAll() end)
    elseif event == "UNIT_AURA" then
        -- 仅触发刷新（容器内部已由暴雪监听并驱动 AuraButton；这里负责重定位等）。
        -- ⚠️ 性能：战斗中 UNIT_AURA 连发（buff 逐个刷新/proc），逐次全量 RefreshAll 开销
        --   可观且无必要——AuraButton 显隐由暴雪实时驱动，这里只补重定位，防抖 0.2s 无感。
        if auraRefreshTimer then auraRefreshTimer:Cancel() end
        auraRefreshTimer = C_Timer.NewTimer(0.2, function()
            auraRefreshTimer = nil
            RefreshAll()
        end)
    elseif event == "PLAYER_TARGET_CHANGED" then
        -- 切目标：AuraContainer 不监听目标切换，unit="target" 的容器不会自动跟随，
        -- 需显式触发其重新解析光环（暴雪目标框也是这么做：UpdateAuras→UpdateAllAuras）。
        for _, p in ipairs(ACTIVE_PRESETS) do
            if p.presetType ~= "weaponEnchant" and p.unit == "target" and p.container then
                pcall(function() p.container:UpdateAllAuras() end)
            end
        end
        -- UpdateAllAuras 触发 FullAuraRebuild，flow layout 会在下一帧把容器尺寸覆盖成空布局值
        -- （ApplyFlowLayout 无条件 OnLayoutComplete→SetSize）。延迟一小段后重新定位，
        -- 避免倒计时框短暂错位（否则要等 1 秒 ticker 才纠正）。
        C_Timer.After(0.05, function()
            for _, p in ipairs(ACTIVE_PRESETS) do
                if p.presetType ~= "weaponEnchant" and p.unit == "target" then
                    pcall(UpdatePresetAura, p)
                end
            end
        end)
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- 脱战：解除战斗中建容器失败的限制，重试创建并刷新
        for _, p in ipairs(ACTIVE_PRESETS) do p._initFailed = nil end
        RefreshAll()
    elseif event == "PLAYER_EQUIPMENT_CHANGED" or event == "UNIT_INVENTORY_CHANGED" then
        -- 武器附魔变化：直接刷新（不走 aura 受限逻辑，战斗中也安全）
        RefreshWeaponEnchants()
    end
end)
