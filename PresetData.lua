-- ActionbarEnhanced/PresetData.lua
-- 预设法术/光环配置（用户编辑区）：从 Preset.lua 外提独立维护。
-- 主逻辑（Preset.lua）可整体回退/重构而不动配置；改预设只需编辑本文件。
-- 数据格式说明见下方注释；Preset.lua 通过 BAR.PresetData 读取。

local BAR = ActionbarEnhanced
if not BAR then return end

BAR.PresetData = {}

-- =========================================================
-- 预设数据（用户编辑区）
-- =========================================================
-- 预设支持两种类型：
--
-- 类型 A：unit aura（光环）——12.1 AuraContainer 暴雪渲染层，战斗中也能显示
--   auraSpellID   : 要追踪的【光环法术ID】（单个 number，或 {id1,id2} 数组，任一命中即显示）
--   actionSpellID : 覆盖显示到哪个技能按钮（该技能的法术ID；该技能必须放在动作条上）
--   unit(可选)/filter(可选) : "player" / "HELPFUL"(默认)
--   ⚠️ 目标身上的减益必须写 filter = "HARMFUL|PLAYER"（|PLAYER=只追踪玩家自己施放的）——
--      只写 "HARMFUL" 会把别人施加的同名减益也显示到你的技能按钮上（2026-08-19 烈焰震击踩坑）
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

BAR.PresetData.SELF_BUFFS = {
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
    { class = "HUNTER", auraSpellID = 212431, actionSpellID = 212431 , unit = "target", filter = "HARMFUL|PLAYER" },    -- 爆炸射击
    { class = "HUNTER", auraSpellID = 186265, actionSpellID = 186265 },  -- 灵龟守护（减伤）
    { class = "HUNTER", auraSpellID = 264735, actionSpellID = 264735 },  -- 优胜劣汰（减伤）
    { class = "HUNTER", auraSpellID = 385540, actionSpellID = 109304 },  -- 意气风发（减伤）
    { class = "HUNTER", auraSpellID = 19574, actionSpellID = 19574 },    -- 狂野怒火（爆发）
    { class = "HUNTER", auraSpellID = 288613, actionSpellID = 288613 },    -- 百发百中（爆发）
    { class = "HUNTER", auraSpellID = 34477, actionSpellID = 34477 },    -- 误导(生效前)
    { class = "HUNTER", auraSpellID = 35079, actionSpellID = 34477 },    -- 误导(生效后)
    { class = "HUNTER", auraSpellID = 257622, actionSpellID = 257620 },    -- 技巧射击绑多重射击
    { class = "HUNTER", auraSpellID = 6197, actionSpellID = 6197 },    -- 鹰眼术
    { class = "HUNTER", auraSpellID = 321297, actionSpellID = 321297 },    -- 野兽之眼
    -- 武僧 MONK（减伤/爆发）
    { class = "MONK", auraSpellID = 122278, actionSpellID = 122278 },    -- 躯不坏（减伤）
    { class = "MONK", auraSpellID = 122783, actionSpellID = 122783 },    -- 散魔功（减伤）
    { class = "MONK", auraSpellID = 115176, actionSpellID = 115176 },    -- 禅悟冥想（引导减伤）
    { class = "MONK", auraSpellID = 116680, actionSpellID = 116680 },    -- 雷光聚神茶（爆发）
    { class = "MONK", auraSpellID = 137639, actionSpellID = 137639 },    -- 风火雷电（爆发）
    { class = "MONK", auraSpellID = 120954, actionSpellID = 115203 },    -- 壮胆酒
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
    { class = "WARRIOR", auraSpellID = 1160, actionSpellID = 1160 , unit = "target", filter = "HARMFUL|PLAYER" },       -- 挫志怒吼
    { class = "WARRIOR", auraSpellID = 12323, actionSpellID = 12323 , unit = "target", filter = "HARMFUL|PLAYER" },       -- 刺耳怒吼
    { class = "WARRIOR", auraSpellID = 386071, actionSpellID = 386071 , unit = "target", filter = "HARMFUL|PLAYER" },       -- 瓦解怒吼
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
    { class = "PALADIN", auraSpellID = 156322, actionSpellID = 156322 }, -- 神圣之火
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
BAR.PresetData.PRESETS = {
    -- { auraSpellID = 123456, actionSpellID = 123, unit = "player", filter = "HELPFUL" },
    -- { presetType = "weaponEnchant", enchantID = 5400, actionSpellID = 318038 },
    -- 种族技能（与职业无关，如矮人石像形态）也写这里、不设 class：
    -- 运行时 UpdatePresetAura 的 IsPlayerSpell(20594) 会自动过滤——只有会该技能的种族才生效，
    -- 其余种族返回 false 直接跳过，不会误建容器/刷屏。
    { auraSpellID = 65116, actionSpellID = 20594 }, -- 石像形态（光环 65116 → 技能 20594，矮人种族）
}
