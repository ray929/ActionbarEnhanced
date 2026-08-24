# Secret 环境下的光环状态检测（KiraUI Bone Shield 方案分析）

> 本文档记录第三方插件 **KiraUI-Plugin**（v1.14，`KiraUI-Plugin_BoneShield.lua`）在 12.1 Secret Values
> 限制下实现「鲜血 DK 骨盾层数阈值语音提醒」的完整方案，供本项目借鉴。
> 内容核实自：
> - `E:\Games\Wow\_retail_\Interface\AddOns\KiraUI-Plugin\KiraUI-Plugin_BoneShield.lua`（源码逐行分析）
> - `Gethe/wow-ui-source` `live` 分支 `Blizzard_CooldownViewer/CooldownViewer.lua`（关键 API 源码核实）
> - 暴雪官方论坛错误报告 + SuaviUI changelog（`isActive` 可为 secret 的旁证）
>
> 核实日期：2026-08-24。⚠️ 12.x 变化快，实际开发前若版本已更新，请重新核实。

---

## 一、问题定义

骨盾（Bone Shield, 195181）剩余时间与层数都是光环数据，大秘境/副本内全部 secret：

- `C_UnitAuras.GetPlayerAuraBySpellID` 标注 `RequiresNonSecretAura`，key 内拿不到 `applications` / `expirationTime`。
- CDM 图标上的层数数字也救不了：暴雪是把 secret 值直接 `SetText` 进 FontString，`GetText()` 读回的是
  **secret 字符串**——唯一能诚实回答的是"有没有文本"（KiraUI ShiningLight 模块就用这个二值技巧：
  有文本 = ≥2 层，无文本 = 1 层）。

KiraUI 的目标：`层数 < 5`（失去骨匣 Ossuary 增益）或 `剩余时间 ≤ N 秒` 时发光 + 播语音，**key 内必须工作**。

## 二、五条核心通道（全部 combat-safe）

### 通道 1：代理光环（Ossuary 模式）——层数阈值转化为关联光环存在性

**这是全方案最巧的一步。** 骨盾层数不可读，但骨匣（Ossuary, 219786）是一个**恰好层数 ≥5 时才存在的增益**：

```
"骨盾层数 < 5 吗？"  ≡  "我身上有骨匣增益吗？"
```

后一个问题不需要读任何光环**数值**，只需要判断光环**存在性**（见通道 2）。KiraUI 在注释里明确记录了
演进：第一版直接读层数（secret，key 内永不触发，纯摆设）→ 改成 Ossuary 存在性判断。

适用条件：目标机制存在一个"阈值触发型关联光环"（天赋/被动在阈值处施加或移除的另一个 buff）。
典型例子：骨盾↔骨匣（5 层）、毁灭术地狱之火相关阈值被动等。若存在，这是**成本最低的阈值判断路线**
（对比本项目 B+ 方案的多 slot 克隆阈值变色：那是不存在代理光环时的通用解，但 25 层+3 阈值 ≈ 101 slot）。

### 通道 2：`IsActive()` —— 暴雪特权代码算好的明文布尔

CDM item frame（`CooldownViewerItemMixin`）上有方法 `IsActive()`，返回 `self.isActive` 字段。
暴雪源码核实（live 分支）：

```lua
function CooldownViewerItemMixin:RefreshActive()
    self:SetIsActive(self:ShouldBeActive());   -- 暴雪特权代码调用
end
function CooldownViewerBuffItemMixin:ShouldBeActive()
    if not CooldownViewerItemMixin.ShouldBeActive(self) then return false end
    if self:IsExpired() then ... end           -- IsExpired 读 auraDataCached（暴雪自己读，合法）
    return true;
end
function CooldownViewerItemMixin:SetIsActive(active)
    self.isActive = active;                    -- 落盘为明文布尔
end
function CooldownViewerItemMixin:IsActive()
    return self.isActive;                      -- addon 可调用
end
```

**原理**：secret 光环数据由暴雪特权代码消费，产出的派生布尔写在普通字段上——addon 读的是派生结果
而非原始数据，全程合法。这与本项目"通道 A reparent"（搬暴雪渲染好的控件）是同族思想：**让暴雪做
secret 运算，addon 只取非 secret 的输出**。

KiraUI 的读取顺序（层层兜底）：
1. `pcall(f.IsActive, f)` → 非 secret 且 `type == 'boolean'` → 直接相信（实测 key 内 2 层时读到
   正确的明文 `false`）；
2. 否则退回帧可见性：`IsShown` + `GetAlpha >= 0.05`（暴雪只画活跃光环的图标，值 secret 时依然成立）；
3. 配合"proven"弱表：帧必须**见过亮**才被相信（见 §三-3）。

⚠️ **`isActive` 偶尔持有 secret 值**：暴雪论坛错误报告（"attempt to compare field 'isActive' (a
secret value)"）与 SuaviUI changelog 均有记载。所以 `issecretvalue` 检查不可省。

另：CDM item frame 的 `GetSpellID()` 在受限环境**可能返回 secret number**，直接 `==` 比较 hard-error
（KiraUI ShiningLight 注释明确踩过）——凡是从 CDM 帧上读出的任何值，先 `issecretvalue` 再比较。

### 通道 3：`GetChildren()` 持有帧 —— 对抗"隐藏即消失"

暴雪源码核实：

```lua
function CooldownViewerMixin:GetItemFrames()
    return self:GetItemContainerFrame():GetLayoutChildren();  -- 只收集 IsShown 的 region
end
```

而 buff item 的 `ShouldBeShown()` 在光环失活时 `SetShown(false)`。两个事实叠加：**光环掉落的瞬间，
帧恰好从 `GetItemFrames()` 里消失**——按帧列表重建的方案会在"最有信息量的那一刻"丢失目标帧，
症状是"警告永不触发"或反向的"7 层时残留掉层发光"。

正解（KiraUI）：
- 用 `viewer:GetChildren()`（不论显隐全返回）找到目标帧后**永久持有**，每 tick 轮询帧本身；
- 每次读取**重验身份**（`GetCooldownID` + `CooldownMatches`）：帧是池化的，释放后可能换装别的技能，
  身份不符则丢弃（宁可"未知"，不可"答错"）；
- 只增不减的扫描（`AddTarget` 去重追加），列表永不因扫描清空。

本项目 §5 已有"别用 GetItemFrames（池化 churn）"的结论，但当时只踩了过渡态变空的问题；KiraUI 补充的
语义是：**光环失活 → 帧隐藏 → 从 GetItemFrames 消失**是稳态行为而非过渡态。凡需要读"光环掉落后的
帧状态"（如发光对账、失活提醒），必须 GetChildren 持有 + 轮询。

### 通道 4：施法时钟 —— `UNIT_SPELLCAST_SUCCEEDED` 全环境可读

自己施法的 `UNIT_SPELLCAST_SUCCEEDED`（unit=player）**在 key 内依然可读**（它是施法事件不是光环
数据）。KiraUI 据此完全绕开 secret 的 `expirationTime`：

```
任意刷新技能落地 → expire = GetTime() + 30（自设时长）
真实 expirationTime 可读时（野外/大部分团本）→ 以真值为准校正时钟
```

配套细节：
- 时钟耗尽但图标仍亮（`IsActive` 为真）→ 说明被未监控的来源刷新了且真值不可读 → **收声不猜**
  （stand down），下一次被跟踪的施法重新开窗；
- "图标熄灭"读数有 **0.5s 宽限期**（池重建瞬间帧可能闪读 inactive，直接杀时钟会掉警告）；
- 声音 `soundArmed` 单向触发 + 高于阈值自动重新武装，任何来源的刷新（不只被跟踪的施法）都能恢复警报。

### 通道 5：学习型刷新法术列表 —— 观测对账代替硬编码

硬编码刷新列表的 bug：某天赋新增刷新技能不在表内 → 时钟照倒数、buff 实际很长 → 发光滞留到时钟归零。
加长列表治标不治本（下个天赋又漏）。

KiraUI 的做法：**在真值可读的环境里观测每一次施法**——施法前一帧读 `expirationTime`，后一帧再读，
被显著推前（>1s）的即判定为刷新技能，写入 profile（`learnedRefresh`），这份知识带进 key 内使用；
已学技能连续 3 次"干净未触发"（30s 重观测窗口）自动遗忘，错误猜测自愈。内置表只作基线、永不遗忘。

## 三、配套工程坑（值得单独记）

1. **覆盖层用 alpha 切换，绝不 Show/Hide**：CDM item 的子帧 Hide 会触发 CDM 布局级联。overlay 永远
   Show，靠 `SetAlpha(0/1)` 开关。发光 overlay 的 `SetFrameLevel` 取**图标自身同级**——CDM 图标本体
   在 ARTWORK 层，层数数字（`Applications` 子帧）和冷却扫描天然高一层，同级 overlay 恰好"盖图标、
   不盖数字"。
2. **类/专精门禁 fail-open**：`UnitClass`/`GetSpecialization` 在受限环境可返回 secret；secret 一律按
   "是本职业"处理（fail-closed 会把功能在它最该工作的场景里静默删掉）。class 不可变，首次明文读取后
   缓存。
3. **"proven"防暗帧诱饵**：EllesmereUI 把不用的暴雪 viewer 帧**停到屏幕外 + alpha=0** 而非 Hide（Hide
   会触发 CDM 重建池）→ 外部看"没画"和"没激活"无法区分。未见过"亮"的帧永远不被相信，防止永久暗帧
   被读成"永久掉 buff"。⚠️ 该机制只用于可见性回退路径，不能套在 `IsActive` 路径上（否则功能整体静默）。
4. **0.1s tick 只在"模块开 + 专精对 + 时钟在跑"时存在**：ticker 与消费者挂钩（同本项目 §10 红线），
   时钟归零/脱战即 `Cancel`。
5. **`GetSpellTexture` 首次可能答 nil**（客户端未缓存法术）：要循环问到有答案为止，一次性的早期询问
   会拿到整个 session 都错的值；宁缺勿错——未知图标就放弃纹理匹配，硬编码 fallback 会错配别的法术。
6. **EllesmereUI 自定义光环帧无任何 spellID 字段**，身份只存在于 EUI 私有池 key 里——唯一可读的是
   图标纹理，靠 `GetTexture() == GetSpellTexture(id)` 匹配（骨盾图标足够独特）。

## 四、与本项目现有通道的关系

| 通道 | 本项目对应 | KiraUI 对应 | 备注 |
|---|---|---|---|
| A. reparent 暴雪控件 | Manual / AutoCDM | （未用，自建 overlay 挂帧上） | 同族：取暴雪渲染产物 |
| B. AuraContainer 特权渲染 | Preset | （未用） | 大地之盾类必 secret 光环的唯一解 |
| B+ 多 slot 克隆阈值 | 无（备选） | （未用） | 通用阈值变色，slot 开销大 |
| C1. 代理光环存在性 | 无 | 骨盾→骨匣 | **有阈值型关联光环时的首选** |
| C2. `IsActive()` 明文布尔 | 无（只用 IsShown） | 全模块门禁 | 比 IsShown 精确：不受编辑模式/EUI alpha-parking 干扰 |
| C3. GetChildren 持有+轮询 | EnumerateActive（active 语义） | Ossuary 帧持有 | 需要读"失活后帧状态"时用 |
| C4. 施法时钟 | 无 | 剩余时间提醒 | `UNIT_SPELLCAST_SUCCEEDED` 全环境可读 |
| C5. 学习型刷新表 | 无 | learnedRefresh | 观测对账，自动发现/遗忘 |

**可借鉴场景**：日后若做"某 buff 剩余 N 秒语音提醒""层数低于阈值报警"类功能，优先按
C1（找代理光环）→ C4（施法时钟）→ B+（多 slot 克隆）的顺序选路线；判定"光环是否存在/激活"
一律优先 `IsActive()`（issecretvalue 兜底）再退可见性。
