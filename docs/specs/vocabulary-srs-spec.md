# OpenKoto 单词本与间隔重复(SRS)统一规范 v1

> 本文档是桌面端(textlingo-desktop,Rust/React)与 iOS(openkoto-ios,Swift)单词本功能的**跨端契约**:
> 数据模型、FSRS-6 调度算法、复习事件日志、统计口径与云同步预留。
> 两端实现必须通过同一份黄金用例 `docs/specs/fixtures/fsrs_golden_v1.json`(容差见 fixture 内 `tolerance`)。
> 修改本规范必须同步重新生成 fixture(`script/fsrs-golden/`)并让双端测试通过。

关联实现:
- Rust 引擎:`textlingo-desktop/src-tauri/src/fsrs.rs`
- Swift 引擎:`openkoto-ios/Packages/OpenKotoKit/Sources/OKSRS/FSRS.swift`
- TS 只读镜像(保持率标色用):`textlingo-desktop/src/lib/srs.ts`
- 参考实现:ts-fsrs 5.4.1 长期调度模式(`enable_short_term=false`、`enable_fuzz=false`)

## 1. 数据模型

### 1.1 FavoriteVocabulary(单词卡片)

| 字段 | 类型 | 语义 |
|---|---|---|
| id | UUID 字符串(iOS 存小写) | 客户端生成,跨端唯一 |
| word | string | 词形原文 |
| normalized_word | string | 去重键:`trim + lowercase`(iOS 另加 NFKC,见 §1.4) |
| meaning / usage / explanation? / example? / reading? | string | 释义、用法、讲解、例句、读音 |
| source_article_id? / source_article_title? | | 来源文章(id 可空;标题为快照,文章删除后保留) |
| 词包成员 | 桌面 `pack_ids: string[]`(JSON 内嵌);iOS `word_pack_membership` 关系表 | 逻辑等价;二期同步统一为集合操作 |
| srs_state | `"new" \| "learning" \| "review"` | 状态覆盖层,见 §2.6 |
| **stability** | f64 | FSRS 记忆稳定性;**0 = 未初始化**(new 卡) |
| **difficulty** | f64 | FSRS 难度 ∈ [1,10];0 = 未初始化 |
| **scheduler_version** | string? | `"fsrs6"`;桌面端 `None` 表示未迁移(触发一次性种子,§4) |
| **suspended_at** | RFC3339? | 非空 = 已掌握/暂停复习;队列排除(§3),恢复时置空、FSRS 状态原样保留 |
| due_date | `"YYYY-MM-DD"`(本地日期) | 到期日;天粒度 |
| last_reviewed_at | RFC3339? | 最近一次复习时刻(UTC) |
| review_count | int | 累计复习次数 |
| created_at / updated_at | RFC3339 / datetime | updated_at 桌面端 v1 暂缺,iOS 必有(同步预留) |
| *(冻结)* ease_factor / repetitions / interval_days | | 桌面端保留旧 SM-2 字段以便回滚,**不再更新**;iOS 不存在 |

### 1.2 WordPack(词包)

字段同桌面 `types.rs::WordPack`:id/name/description?/cover_url?/author?/language_from?/language_to?/tags[]/version?/created_at/updated_at/is_system。
系统默认词包 `system-ungrouped`("未分组")不可删除;卡片至少属于一个词包。

### 1.3 ReviewEvent(复习事件,append-only)

复习事件是**不可变**的:只追加、不修改、不随卡片删除而删除(未来同步以事件为单元重放)。

| 字段 | 类型 | 语义 |
|---|---|---|
| id | UUID | 事件 id(幂等键) |
| card_id | UUID/string | 所属卡片 |
| reviewed_at | RFC3339(UTC) | 复习时刻 |
| date_local | `"YYYY-MM-DD"` | 复习时的本地日期(统计与重放的天粒度依据) |
| grade | int 1..4 | Again=1 / Hard=2 / Good=3 / Easy=4(§2.5) |
| elapsed_days | int ≥0 | 距上次复习的本地日期差(§2.7) |
| previous_state | `"new" \| "learning" \| "review"` | 复习前状态(统计"今日新学"依据) |
| scheduler_version | string | `"fsrs6"` |
| desired_retention | f64 | 本次复习使用的期望保持率 |
| result_stability / result_difficulty / result_interval_days / result_state | | 复习后的结果快照(调试与冲突校验用;重放时以输入为准) |

存储形态:
- 桌面:`favorites/review_log/YYYY-MM.jsonl`(按 reviewed_at 的本地年月分文件),一行一个事件;读取时跳过无法解析的行。
- iOS:`review_log` 表;`vocabulary_id` 建索引但**不建外键**(事件必须在卡片删除后存活);`date_local` 建索引。

### 1.4 去重规则

- `normalized_word`:`trim` + `lowercase`。iOS 侧额外做 NFKC 兼容合成(全角/半角、假名兼容形);桌面端 v1 暂不做 NFKC,列为二期收敛项。
- 桌面:全局按 `normalized_word` 去重,重复添加时合并 pack_ids、回填空字段(现行 `add_favorite_vocabulary_cmd` 行为)。
- iOS:按 `(normalized_word, source_article_id)` 唯一。
- 两种口径的收敛(以桌面全局口径为准)列为二期同步 RFC 事项。

## 2. FSRS-6 调度算法(长期模式)

**参考实现 ts-fsrs 5.4.1;所有常量与求值顺序以本节为准,黄金用例是最终裁判。**

### 2.1 常量

```
PARAMS(w0..w20,ts-fsrs 5.4.1 default_w):
[0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194, 0.001,
 1.8722, 0.1666, 0.796, 1.4835, 0.0614, 0.2629, 1.6483, 0.6014,
 1.8729, 0.5425, 0.0912, 0.0658, 0.1542]

S_MIN = 0.001          // 稳定性下限
MAX_INTERVAL = 36500   // 间隔与稳定性上限(天)
DESIRED_RETENTION 默认 0.9,允许范围 [0.70, 0.97](设置 UI 提供 0.80/0.85/0.90/0.95)
SCHEDULER_VERSION = "fsrs6"
```

### 2.2 数值约定

```
round8(x) = round(x * 1e8) / 1e8    // 四舍五入到 8 位小数(正数半进;参考 JS Math.round)
clamp(x, lo, hi) = min(max(x, lo), hi)
decay  = -w20                                  // = -0.1542
factor = round8(0.9^(1/decay) - 1)             // = 0.98034649
```

`round8` 在下述公式中的出现位置必须与本规范逐一对应(与 ts-fsrs 完全一致),否则黄金用例在长链后会漂移出容差。

### 2.3 可提取性(保持率)与间隔

```
retrievability(t, S) = round8((1 + factor * t / S) ^ decay)     // t ≥ 0(天,可为小数);t=0 → 1
interval_modifier(r) = round8((r^(1/decay) - 1) / factor)        // r = desired_retention;r=0.9 → 1.0
next_interval(S)     = clamp(max(1, round(S * interval_modifier)), 1, MAX_INTERVAL)   // round 半进
```

### 2.4 记忆状态更新(单档位)

```
init_stability(g)  = max(w[g-1], 0.1)
init_difficulty(g) = round8(w4 - e^((g-1)*w5) + 1)               // 初始化时再 clamp(·, 1, 10)

linear_damping(Δd, d)     = round8(Δd * (10 - d) / 9)
mean_reversion(init, cur) = round8(w7 * init + (1 - w7) * cur)
next_difficulty(d, g):
    Δd = -w6 * (g - 3)
    d' = d + linear_damping(Δd, d)
    return clamp(mean_reversion(init_difficulty(4), d'), 1, 10)   // init_difficulty(4) 不 clamp(可为负)

next_recall_stability(d, s, r, g) =                               // g ∈ {2,3,4}
    round8(clamp(s * (1 + e^w8 * (11 - d) * s^(-w9) * (e^((1-r)*w10) - 1)
                       * (g==2 ? w15 : 1) * (g==4 ? w16 : 1)),
                 S_MIN, MAX_INTERVAL))

next_forget_stability(d, s, r) =                                  // g == 1
    round8(clamp(w11 * d^(-w12) * ((s+1)^w13 - 1) * e^((1-r)*w14),
                 S_MIN, MAX_INTERVAL))

next_memory_state(s, d, elapsed, g):                              // 长期模式
    if s == 0 and d == 0:                                         // new 卡首评
        return { S: init_stability(g), D: clamp(init_difficulty(g), 1, 10) }
    r = retrievability(elapsed, s)
    if g == 1:
        S' = clamp(round8(s), S_MIN, next_forget_stability(d, s, r))   // 即 min(s, S_forget)
    else:
        S' = next_recall_stability(d, s, r, g)                    // elapsed=0 时 r=1 → S'=round8(s)(不变)
    D' = next_difficulty(d, g)
    return { S: S', D: D' }
```

### 2.5 一次复习(完整步骤,含跨档位排序修正)

**必须同时计算全部 4 个档位再取所选档**——间隔有跨档位约束:

```
review(s, d, elapsed, chosen_grade, desired_retention):
    for g in [1, 2, 3, 4]:
        state[g] = next_memory_state(s, d, elapsed, g)
        ivl[g]   = next_interval(state[g].S)          // 用 desired_retention 的 modifier
    // 排序修正(顺序执行):
    ivl[1] = min(ivl[1], ivl[2])
    ivl[2] = max(ivl[2], ivl[1] + 1)
    ivl[3] = max(ivl[3], ivl[2] + 1)
    ivl[4] = max(ivl[4], ivl[3] + 1)
    g = chosen_grade
    return { stability: state[g].S, difficulty: state[g].D,
             interval_days: ivl[g], srs_state: g == 1 ? "learning" : "review" }
```

调用方随后:`due_date = date_local + interval_days`,`review_count += 1`,`last_reviewed_at = now(UTC)`,写入一条 ReviewEvent。

评分映射(UI 三档 → 引擎四档):**不认识→1(Again),模糊→2(Hard),认识→3(Good)**;4(Easy)引擎支持、当前 UI 不使用。

### 2.6 状态覆盖层

`srs_state` 不参与算法,仅用于队列分组与统计:
- `new`:从未复习(stability == 0);
- 复习后:`chosen_grade == Again ? "learning" : "review"`(FSRS 的 Relearning 概念并入 learning)。

### 2.7 elapsed_days(经过天数)

- `elapsed_days = 复习日 date_local − 上次复习日的本地日期`(由 `last_reviewed_at` UTC 时刻转为**本地日期**后作差),下限 0。
- 首次复习(new 卡)= 0。
- 种子卡(§4)缺失 `last_reviewed_at` 时回退:上次复习日 ≈ `due_date − interval_days(旧值)`;仍无法解析则取 0。
- 同日重复复习:elapsed = 0(长期模式:通过时稳定性不变、难度照常更新;失败时 S ← min(S, S_forget))。

### 2.8 同日巩固步骤(learning steps) — **iOS 已实现,桌面端待跟进**

`next_interval` 的下限是 1 天,照搬到 `due_date` 就意味着**一答错当天再也见不到那张卡**,
而它恰恰是最该再看一遍的。天粒度下的等价物是:没答对就留在今天。

```
due_date = chosen_grade >= Good ? date_local + interval_days : date_local
```

记忆状态(stability / difficulty / srs_state)与 ReviewEvent **一律照常按所选档位写入**,
只有"下次什么时候见"这一项被覆盖。最终那次 Good 会从当时的记忆状态重新算出间隔,
所以调度质量不受损;同日重复复习本来就由 §2.7 定义(elapsed = 0)。

客户端**另可**在一次会话内把没答对的卡插回队列靠后的位置(iOS:Again 隔 3 张、Hard 隔 8 张),
这是纯 UI 行为,不影响任何持久状态——`due_date` 已经保证了退出再进来卡片还在。

## 3. 到期队列与"已掌握"

沿用现行队列语义,仅新增 suspended 过滤:

```
queue(cards, pack_id, date_local, new_limit, review_limit):
    cards = cards where suspended_at == null
    if pack_id != "all": cards = cards where pack_id ∈ pack_ids
    cards = cards where due_date <= date_local      // 或 due_date 非法/为空时视为到期
    (new_learning, review) = partition by srs_state ∈ {new, learning}
    各自按 (due_date, last_reviewed_at) 升序
    return new_learning.take_new(new_limit) ++ review.take(review_limit)
```

每日上限:`srs_daily_new_limit` 默认 20,`srs_daily_review_limit` 默认 100(设置 UI 可改)。

`take_new` — **iOS 已实现,桌面端待跟进**:`new_limit` 只截 `srs_state == "new"` 的卡,
`learning` 全量入队。配合 §2.8:巩固卡的 `last_reviewed_at` 最新、排在组尾,
若一并计入上限就会被当天的新词整批挤掉,同日巩固形同虚设。

**提前复习队列**(可选,iOS 已实现):今日队列清空后按用户请求发一组
`due_date` **严格晚于**今天的卡,按 (due_date, last_reviewed_at) 升序取前 N 张(iOS N = 20)。
坏日期在上面已被算作"到期",这里必须排除,两个队列不重叠。评分走同一条 §2.5 路径,
不做任何特殊处理——提前复习只是 elapsed 小于计划值,长期模式本就正确处理。

"已掌握/暂停":写 `suspended_at = now(UTC)`;恢复时置空。FSRS 状态不动,恢复后按原 due_date 自然回队。

## 4. SM-2 → FSRS 一次性迁移(仅桌面端)

来源:fsrs-rs `memory_state_from_sm2`(Anki 迁移同款),`sm2_retention = 0.9`:

```
seed_from_sm2(interval_days, ease_factor):
    S = max(interval_days, 0.1) / (9 * (1/0.9 - 1))          // ≈ interval_days
    D = clamp(11 - (ease_factor - 1)
                   / (e^w8 * S^(-w9) * (e^((1-0.9)*w10) - 1)), 1, 10)
    // 本公式不做 round8(与 fixture 生成器一致)
```

规则(在现有 `migrate_favorite_vocabularies` fix-up 中执行,**以 `scheduler_version == None` 守卫,幂等**):
- `srs_state == "new"` 或 `review_count == 0`:不种子(stability/difficulty 保持 0),仅写 `scheduler_version = "fsrs6"`;
- 否则:`(stability, difficulty) = seed_from_sm2(interval_days, ease_factor)`,写 `scheduler_version`,`due_date` 保持不变;
- 旧字段 ease_factor/repetitions/interval_days 冻结保留(回滚保险),后续复习不再更新。

iOS 无存量用户,不存在迁移。

## 5. 保持率标色

渲染时计算,不落库:

```
R = retrievability(now - last_reviewed_at 的天数(可为小数), stability)
```

| 分档 | 条件 | 语义 | 色值 token |
|---|---|---|---|
| new | srs_state == "new"(无论 R) | 未学 | 中性灰(muted) |
| strong | R ≥ 0.90 | 高于目标保持率 | `--srs-strong`(绿) |
| fading | 0.70 ≤ R < 0.90 | 正在衰减 | `--srs-fading`(琥珀) |
| weak | R < 0.70 | 可能已遗忘 | `--srs-weak`(红) |

suspended 卡片显示置灰,不参与分档展示逻辑(可显示"已掌握"标签)。
iOS 将三个 token 映射到 OKDesignSystem 对应色板;桌面端在 `index.css` 定义明暗双套。

## 6. 统计口径

全部由**事件日志 + 卡片状态**推导,双端同一公式,不另设统计表:

- **今日新学** = 今日(date_local)事件中 `previous_state == "new"` 的**去重卡数**;
- **今日复习** = 今日其余事件的去重卡数(与新学互斥:一张卡当日既有 new 事件又有后续事件时只计入新学);
- **连续打卡** = 从今日(或昨日,若今日尚无事件)向前数,`date_local` 连续每天都有 ≥1 条事件的天数;
- **状态分布** = 卡片按 `已掌握(suspended)` / `new` / `learning` / `review` 分桶计数;
- **今日通过新学 / 今日通过复习**(**iOS 已实现,桌面端待跟进**)= 上面两项各自的子集,
  只保留"今日至少有一条 `grade >= 3(Good)` 事件"的卡。新学/复习的归属沿用同一条判定,
  因此恒有 通过 ≤ 对应总数;
- **今日进度** = 今日**通过**新学 / `srs_daily_new_limit`,今日**通过**复习 / `srs_daily_review_limit`。
  用通过数而非事件数:配合 §2.8,答错的卡当天还会回到队列,在点"认识"之前不该算学完。
  活跃度图、连续打卡等"做了多少事"的口径仍用今日新学/复习,两者并存不互相替代。

## 7. 版本化

- 卡片与事件都带 `scheduler_version`(当前 `"fsrs6"`)。
- 更换调度算法 = 新版本串 + 定义"从事件日志重放或从旧状态种子"的迁移规则,旧事件不改写。
- okpack 导出格式(`openkoto-word-pack-v1`)**不变**:仍不包含任何 SRS 状态,导入一律重置为 new。
- 黄金用例 schema `openkoto-fsrs-golden-v1`;权威文件在 `docs/specs/fixtures/`,iOS 侧为逐字副本(Rust 测试断言两份字节相等)。

## 8. 云同步预留(一期只做地基,协议细节见二期 Sync RFC)

一期落地的同步前置条件:
- 所有实体 UUID 由客户端生成;卡片/词包带 created_at(+ iOS updated_at);
- **复习事件日志 append-only、不可变、独立于卡片生命周期**——未来复习同步 = 推送事件 + 各端重放重算,不做快照 LWW;
- iOS 词包成员用 `word_pack_membership` 关系表(桌面二期从 pack_ids JSON 收敛);
- 同步接口占位:
  - Swift:`protocol SyncEngine: Sendable { func push() async throws; func pull() async throws }` + `NoopSyncEngine`(开源版默认);
  - Rust:`trait SyncEngine { fn push(&self) -> Result<(), String>; fn pull(&self) -> Result<(), String>; }` + `NoopSyncEngine`。
- 明确**不在一期定义**:传输协议、cursor、鉴权、冲突合并细节、墓碑与全量首同——见二期 RFC。

## 9. 黄金用例

- 生成:`cd script/fsrs-golden && npm install && npm run generate`(pin ts-fsrs 5.4.1,离线可重复)。
- 覆盖:四档首评(含排序修正)、按期 Good 长链、遗忘重学、纯 Hard 链、Easy、同日重复、迟到/提前复习、混合评分、期望保持率 0.8/0.95、SM-2 种子(含 interval 0 与 ease 下限)。
- 判定:stability/difficulty/retrievability 容差 1e-6;interval_days 与 state 精确相等。
