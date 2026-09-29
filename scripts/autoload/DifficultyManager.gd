## DifficultyManager.gd - 难度曲线管理单例
## 职责：按"阶段 Boss 门槛"提升难度，控制敌人属性缩放、生成节奏、精英怪频率、波次事件
## 继承：Node（作为全局单例运行）
## 设计意图：
##   1. 难度与阶段强绑定（用户定制规则）：每次难度提升都必须先击败当前阶段的守门 Boss，
##      难度不再随时间自动爬升——"打倒 Boss"是唯一的升级途径，Boss 不倒下就永远卡在当前难度
##   2. 三档难度模式（用户定制规则）：普通/困难/专家三档，全局统一从难度1开局；
##      普通=基线，困难=在基线之上叠加"HARD_* 倍率"，专家=与困难数值一致（无专属机制）
##   3. 数据驱动调参：所有缩放系数均为常量，集中在文件顶部，调平衡无需改动逻辑
##   4. 缩放只作用于"实例副本"：绝不修改共享的.tres资源，避免跨局/跨实例串扰
##   5. 波次事件（趣味性/随机性）：每N级触发一次敌潮，制造高压时刻与爽点
## 数据流：StageDirector 在击败阶段 Boss 时调用 advance_by_boss() → 等级+1 并广播
##         difficulty_changed/wave_started → GameWorld/Enemy 生成敌人时调用
##         get_*_mult()/apply_to_enemy_data() 完成属性缩放
extends Node

## ========== 信号定义（用于与其他节点通信） ==========

## 难度提升信号：难度等级变化时发出（HUD更新难度显示、GameWorld调整节奏）
## 参数：new_level - 新难度等级（从1开始）
signal difficulty_changed(new_level: int)

## 波次开始信号：触发敌潮事件时发出（GameWorld批量刷怪、HUD显示警告）
## 参数：wave_number - 波次序号（第几波），spawn_count - 本波建议刷怪数量
signal wave_started(wave_number: int, spawn_count: int)

## ========== 难度模式（三档，用户定制规则） ==========

## 难度模式枚举（与 Settings.gd DIFFICULTY_KEYS 顺序严格一致）
##   NORMAL(0) - 普通：完全沿用既有难度曲线，不叠加任何模式倍率（基线）
##   HARD(1)   - 困难：在基线之上叠加 HARD_* 倍率（伤害/血量×2，速度轴小幅提升，掉率下调）
##   EXPERT(2) - 专家：数值与困难一致（无专属机制）
enum DifficultyMode { NORMAL = 0, HARD = 1, EXPERT = 2 }

## 困难档：敌人血量倍率（用户要求：普通数值的 2 倍）
const HARD_HEALTH_MULT: float = 2.0
## 困难档：敌人伤害倍率（用户要求：普通数值的 2 倍）
const HARD_DAMAGE_MULT: float = 2.0
## 困难档：敌人移速倍率（速度轴"适当增加"，避免直接翻倍导致无法走位）
const HARD_MOVE_SPEED_MULT: float = 1.15
## 困难档：敌人子弹飞行速度倍率（速度轴"适当增加"）
const HARD_BULLET_SPEED_MULT: float = 1.15
## 困难档：敌人攻速倍率（>1 表示攻击更频繁，内部换算为冷却缩短）
const HARD_ATTACK_SPEED_MULT: float = 1.1
## 困难档：掉落系数（<1 表示"爆率适当下降"，作用于掉落概率 drop_chance）
const HARD_DROP_MULT: float = 0.6

## ========== 调参常量（难度曲线的核心配置，集中管理便于平衡调整） ==========

## 难度等级硬上限：10级封顶（用户要求：把原来的30级曲线压缩进10级）
## 达到上限后难度曲线停止爬升，游戏交给 StageDirector 的终极关卡收尾
## 与 StageDirector.MAX_STAGE 语义对齐：难度等级 == 阶段号（严格一一对应）
const MAX_LEVEL: int = 10

## 敌人血量成长系数：每级+18%（乘算叠加）
const HEALTH_MULT_PER_LEVEL: float = 0.18
## 敌人血量成长上限：最高4倍（防止后期血量膨胀到打不动）
const HEALTH_MULT_MAX: float = 4.0

## 敌人伤害成长系数：每级+10%（乘算叠加）
const DAMAGE_MULT_PER_LEVEL: float = 0.10
## 敌人伤害成长上限：最高3倍
const DAMAGE_MULT_MAX: float = 3.0

## 敌人移速成长系数：每级+4%（小幅成长，避免追不上导致失去威胁）
const SPEED_MULT_PER_LEVEL: float = 0.04
## 敌人移速成长上限：最高1.6倍
const SPEED_MULT_MAX: float = 1.6

## 刷怪间隔压缩系数：每级-5%（旧值-7%，放缓让前期刷怪不会太快变密集）
const SPAWN_ACCEL_PER_LEVEL: float = 0.05
## 刷怪间隔下限（秒）：再快也不低于0.4秒一只（性能保护）
const SPAWN_INTERVAL_MIN: float = 0.4

## 同屏敌人上限成长：每级+4只（配合基础上限70只，10级恰好爬到硬上限100只）
const MAX_ENEMIES_PER_LEVEL: int = 4
## 同屏敌人硬上限：100只（用户要求，替代旧的140只，兼顾性能与体验）
const MAX_ENEMIES_HARD_CAP: int = 100

## 精英怪刷新间隔压缩系数：每级-5%（精英怪越出越频繁）
const ELITE_ACCEL_PER_LEVEL: float = 0.05
## 精英怪刷新间隔下限（秒）
const ELITE_INTERVAL_MIN: float = 6.0

## 敌潮波次间隔：每5级难度触发一次波次事件
const WAVE_EVERY_N_LEVELS: int = 5
## 波次基础刷怪数量（实际数量还会随难度等级增长）
const WAVE_BASE_COUNT: int = 8
## 每级难度为波次追加的刷怪数量
const WAVE_COUNT_PER_LEVEL: int = 1

## 掉落价值成长系数：每级+6%（难度越高，碎片/道具收益越高，风险回报对等）
const DROP_VALUE_PER_LEVEL: float = 0.06
## 掉落价值成长上限：最高2倍
const DROP_VALUE_MULT_MAX: float = 2.0

## 敌人攻击冷却下限（秒）：登塔"攻速增幅"换算为冷却缩短后不得低于此值，
## 防止极高层数下同帧内重复触发攻击导致弹幕瞬间饱和（可玩性与性能双保护）
const MIN_ATTACK_COOLDOWN: float = 0.25

## ========== 成员变量（运行时数据） ==========

## 当前难度等级（从1开始，与"当前阶段"严格一一对应）
## 唯一提升途径：StageDirector 在击败阶段守门 Boss 后调用 advance_by_boss()
## 每局恒从 1 开局（用户规则：已取消"起始阶段"机制，档位差异改由难度模式倍率承担）
var level: int = 1

## 登塔增幅系数组（无尽模式专用）：由 TowerManager 每层递增写入，1.0=未登塔
## 设计：难度曲线本身在10级封顶，登塔阶段的"继续变强"改由这组系数承担——
##       它们只参与属性缩放，绝不改变任何上限（敌人数量上限保持恒定）
## 键名约定（与 TowerManager 的 FLOOR_*_BONUS 常量一一对应）：
##   "health" / "damage"                            - 血量 / 伤害（耐力轴，涨幅大）
##   "attack_speed" / "move_speed" / "bullet_speed" - 攻速 / 移速 / 弹速（速度轴，涨幅小）
## 注意 attack_speed 的语义是"攻速倍数"：值越大攻击越频繁，内部换算为冷却缩短
var tower_mults: Dictionary = {
	"health": 1.0,
	"damage": 1.0,
	"attack_speed": 1.0,
	"move_speed": 1.0,
	"bullet_speed": 1.0,
}

## 本局生效的难度模式（DifficultyMode 枚举值，0=普通/1=困难/2=专家）
## 由 _on_game_started() 从配置快照读取并锁定——对局进行中修改配置不影响本局
var difficulty_mode: int = DifficultyMode.NORMAL

## 已配置的难度模式（Settings 界面设置后生效，下次新游戏从这里起步）
## 默认=普通（NORMAL）；值范围 0~2，越界由 set_difficulty_mode() 兜底夹取
var _configured_difficulty_mode: int = DifficultyMode.NORMAL

## 已触发的波次计数（用于wave_started信号的序号参数）
var _wave_count: int = 0

## ========== 生命周期方法 ==========

## _ready() - 进入场景树时初始化
## 工作：
##   1. 从 settings.cfg 加载玩家保存的难度模式（这样即便从未打开设置界面也会用保存的难度开局）
##   2. 连接 game_started 信号
func _ready() -> void:
	## 先加载保存的难度模式 → 作为下次新游戏的配置快照
	_load_difficulty_mode_from_config()
	## 监听游戏开始信号：每局开始时重置难度状态
	GameManager.game_started.connect(_on_game_started)

## 重置本局难度状态（响应GameManager.game_started）
## 算法：
##   1. 锁定本局难度模式：把配置快照 _configured_difficulty_mode 拷入 difficulty_mode，
##      之后本局全程使用该模式，对局中改设置不影响正在进行的这一局
##   2. 难度等级恒从 1 开始（用户规则：取消"起始阶段"机制，三档统一从难度1/阶段1开局，
##      仅靠数值倍率与专家机制区分难度，不再有 档位→起始阶段 的跳级映射）
## 注意事项：本函数由 autoload 顺序保证先于 StageDirector._on_game_started 执行，
##          因此 StageDirector 可以在自己的开局回调里直接读 DifficultyManager.level 作为起始阶段，
##          从而保证"难度 == 阶段"从第一帧起就严格挂钩
func _on_game_started() -> void:
	## ---- 基础重置 ----
	_wave_count = 0
	## 登塔增幅复位：每局从无增幅开始（TowerManager 会在无尽模式登塔时重新赋值）
	reset_tower_mults()

	## ---- 锁定本局难度模式 ----
	difficulty_mode = _configured_difficulty_mode

	## ---- 统一从难度1开局（已取消起始阶段机制） ----
	level = 1
	## 广播难度变化信号（HUD更新难度显示；StageDirector 亦以此作为起始阶段）
	difficulty_changed.emit(level)
	## 上报统计（结算面板展示本局达到的最高难度）
	RunStats.report_difficulty(level)

## ========== 外部 API（Settings.gd / Main.gd 使用） ==========

## 设置难度模式（Settings 界面点击应用后调用）
## 语义：只在"开始新游戏"时生效——set 后仅更新配置快照并持久化，不改变正在进行的对局
## 参数：mode - 难度模式（DifficultyMode 枚举值，0=普通/1=困难/2=专家），越界自动夹取到 0~2
func set_difficulty_mode(mode: int) -> void:
	_configured_difficulty_mode = clampi(mode, DifficultyMode.NORMAL, DifficultyMode.EXPERT)
	## 同时保存到 settings.cfg（确保关闭游戏再打开仍然记得）
	_save_difficulty_mode_to_config()
	print("[DifficultyManager] 配置难度模式 = ", _configured_difficulty_mode)

## 获取本局生效的难度模式（DifficultyMode 枚举值）
## 返回：0=普通 / 1=困难 / 2=专家（对局中由 _on_game_started 锁定）
func get_difficulty_mode() -> int:
	return difficulty_mode

## ========== 配置文件读写（与 Settings 共享 user://settings.cfg 的 difficulty_mode 字段） ==========

## 从 user://settings.cfg 读取 difficulty_mode (0~2) 作为难度模式配置快照
## 调用时机：DifficultyManager._ready() → 首次 autoload 启动时读一次
## 说明：旧版键名为 "difficulty"（起始阶段选择遗留），此处直接忽略旧键 → 回落默认普通，
##       避免旧索引 0/1/2/3 与新三档语义错位
func _load_difficulty_mode_from_config() -> void:
	var config := ConfigFile.new()
	var err: int = config.load("user://settings.cfg")
	if err == OK:
		## 读取难度模式（0=普通/1=困难/2=专家），默认普通档
		var mode_idx: int = int(config.get_value("Settings", "difficulty_mode", DifficultyMode.NORMAL))
		_configured_difficulty_mode = clampi(mode_idx, DifficultyMode.NORMAL, DifficultyMode.EXPERT)
	else:
		## 首次启动无配置 → 使用普通档开局（业界通用默认）
		_configured_difficulty_mode = DifficultyMode.NORMAL
	print("[DifficultyManager] 读取到难度模式配置 = ", _configured_difficulty_mode)

## 把当前 _configured_difficulty_mode 写回 settings.cfg
## 调用时机：set_difficulty_mode() 被外部设置之后，持久化到磁盘
func _save_difficulty_mode_to_config() -> void:
	var config := ConfigFile.new()
	## 加载失败也能写：ConfigFile 空对象就是空配置，保存会创建新文件
	config.load("user://settings.cfg")
	config.set_value("Settings", "difficulty_mode", _configured_difficulty_mode)
	config.save("user://settings.cfg")

## ========== 难度提升核心逻辑 ==========

## 提升一级难度（唯一入口，由 StageDirector 在击败阶段守门 Boss 后调用）
## 调用时机：StageDirector._on_boss_killed() → 击败守门 Boss 的那一帧
## 已达 MAX_LEVEL 时直接返回（难度10封顶，之后交给终极关卡/登塔机制）
## 说明：难度与阶段一一对应——本函数被调用的同时，StageDirector 会推进到下一阶段，
##       因此"难度+1"与"进入下一阶段"永远是同一件事
func advance_by_boss() -> void:
	## 难度封顶判断（终极关卡阶段：难度停在上限，改由 StageDirector/TowerManager 提供压力）
	if level >= MAX_LEVEL:
		return
	## 等级+1（== 阶段号+1）
	level += 1
	## 广播难度变化信号（HUD更新难度显示）
	difficulty_changed.emit(level)
	## 上报统计（结算面板展示本局达到的最高难度）
	RunStats.report_difficulty(level)
	## 播放难度提升音效（全局播放，位置无关；if判空为防御性写法，容错单例未就绪的极端情况）
	if AudioManager:
		AudioManager.play("difficulty_up", 0.6)
	## 波次事件判定：每到 WAVE_EVERY_N_LEVELS 的整数倍等级触发敌潮
	## 设计意图：固定节拍+递增规模，制造规律性的高压时刻，玩家可以预期并准备
	## 注意：升级只发生在击败 Boss 之后，所以"进入阶段5/10的瞬间"会立刻追加一波敌潮，
	##       形成"打完Boss立刻被新怪潮包围"的压迫感（符合用户要求的强绑定节奏）
	if level % WAVE_EVERY_N_LEVELS == 0:
		_wave_count += 1
		## 波次规模：基础8只 + 每难度等级+1只（难度越高潮越猛）
		var spawn_count: int = WAVE_BASE_COUNT + level * WAVE_COUNT_PER_LEVEL
		wave_started.emit(_wave_count, spawn_count)

## ========== 缩放系数查询接口（GameWorld/Enemy在生成敌人时调用） ==========

## 获取敌人血量缩放系数（基于当前难度等级）
## 返回：1.0 ~ HEALTH_MULT_MAX 之间的乘算系数
func get_health_mult() -> float:
	return minf(1.0 + HEALTH_MULT_PER_LEVEL * (level - 1), HEALTH_MULT_MAX)

## 获取敌人伤害缩放系数
## 返回：1.0 ~ DAMAGE_MULT_MAX 之间的乘算系数
func get_damage_mult() -> float:
	return minf(1.0 + DAMAGE_MULT_PER_LEVEL * (level - 1), DAMAGE_MULT_MAX)

## 获取敌人移速缩放系数
## 返回：1.0 ~ SPEED_MULT_MAX 之间的乘算系数
func get_speed_mult() -> float:
	return minf(1.0 + SPEED_MULT_PER_LEVEL * (level - 1), SPEED_MULT_MAX)

## 获取缩放后的普通怪刷新间隔
## 参数：base_interval - GameWorld配置的基础间隔
## 返回：压缩后的间隔（不低于SPAWN_INTERVAL_MIN）
func get_spawn_interval(base_interval: float) -> float:
	## 间隔按每级-5%压缩：间隔 = 基础 / (1 + 0.05*(等级-1))
	var compressed: float = base_interval / (1.0 + SPAWN_ACCEL_PER_LEVEL * (level - 1))
	return maxf(compressed, SPAWN_INTERVAL_MIN)

## 获取缩放后的精英怪刷新间隔
## 参数：base_interval - GameWorld配置的基础间隔
## 返回：压缩后的间隔（不低于ELITE_INTERVAL_MIN）
func get_elite_spawn_interval(base_interval: float) -> float:
	var compressed: float = base_interval / (1.0 + ELITE_ACCEL_PER_LEVEL * (level - 1))
	return maxf(compressed, ELITE_INTERVAL_MIN)

## 获取缩放后的同屏敌人上限
## 参数：base_max - GameWorld配置的基础上限（当前为70）
## 返回：上限值（1级=基础上限，逐级+4，10级封顶于 MAX_ENEMIES_HARD_CAP=100）
func get_max_enemies(base_max: int) -> int:
	return mini(base_max + MAX_ENEMIES_PER_LEVEL * (level - 1), MAX_ENEMIES_HARD_CAP)

## 获取掉落物价值缩放系数（碎片/道具收益随难度提升）
## 返回：1.0 ~ DROP_VALUE_MULT_MAX 之间的乘算系数
func get_drop_value_mult() -> float:
	return minf(1.0 + DROP_VALUE_PER_LEVEL * (level - 1), DROP_VALUE_MULT_MAX)

## ========== 难度模式倍率查询（模式倍率在难度曲线之上再叠一层，普通档全为1.0） ==========
## 说明：困难与专家共用同一套数值倍率（专家档当前与困难档完全一致，无专属机制）

## 当前是否处于"困难档及以上"（困难或专家）
## 返回：true 表示需要叠加 HARD_* 数值倍率
func _is_hard_tier() -> bool:
	return difficulty_mode == DifficultyMode.HARD or difficulty_mode == DifficultyMode.EXPERT

## 获取难度模式的敌人血量倍率（普通=1.0，困难/专家=HARD_HEALTH_MULT）
func get_mode_health_mult() -> float:
	return HARD_HEALTH_MULT if _is_hard_tier() else 1.0

## 获取难度模式的敌人伤害倍率（普通=1.0，困难/专家=HARD_DAMAGE_MULT）
func get_mode_damage_mult() -> float:
	return HARD_DAMAGE_MULT if _is_hard_tier() else 1.0

## 获取难度模式的敌人移速倍率（普通=1.0，困难/专家=HARD_MOVE_SPEED_MULT）
func get_mode_move_speed_mult() -> float:
	return HARD_MOVE_SPEED_MULT if _is_hard_tier() else 1.0

## 获取难度模式的敌人子弹飞行速度倍率（普通=1.0，困难/专家=HARD_BULLET_SPEED_MULT）
func get_mode_bullet_speed_mult() -> float:
	return HARD_BULLET_SPEED_MULT if _is_hard_tier() else 1.0

## 获取难度模式的敌人攻速倍率（普通=1.0，困难/专家=HARD_ATTACK_SPEED_MULT；>1 攻击更频繁）
func get_mode_attack_speed_mult() -> float:
	return HARD_ATTACK_SPEED_MULT if _is_hard_tier() else 1.0

## 获取难度模式的掉落倍率（普通=1.0，困难/专家=HARD_DROP_MULT < 1 表示爆率下调）
## 使用方：DropItem.should_drop() 在概率判定时乘以此系数
func get_mode_drop_mult() -> float:
	return HARD_DROP_MULT if _is_hard_tier() else 1.0

## 获取难度显示文本（HUD使用）
## 返回：如"难度 3"
func get_difficulty_label() -> String:
	return "难度 %d" % level

## ========== 登塔增幅接口（无尽模式专用，由 TowerManager 驱动） ==========

## 重置登塔增幅（开局 / 登塔起点调用）：所有轴系数回到 1.0（不额外增强）
func reset_tower_mults() -> void:
	for key in tower_mults:
		tower_mults[key] = 1.0

## 设置登塔增幅系数组（TowerManager 每登一层调用一次）
## 参数：mults - 部分字典，键名见 tower_mults 声明；未包含的键保持原值，
##               单项低于 1.0 会被抬到 1.0（登塔只会更难，不会变简单）
func set_tower_mults(mults: Dictionary) -> void:
	for key in mults:
		if tower_mults.has(key):
			tower_mults[key] = maxf(float(mults[key]), 1.0)

## 获取单轴登塔增幅系数
## 参数：key - 轴键名（health / damage / attack_speed / move_speed / bullet_speed）
## 返回：1.0（未登塔）或更高；未知键返回 1.0（防御性兜底）
func get_tower_mult(key: String) -> float:
	return float(tower_mults.get(key, 1.0))

## ========== 敌人数据缩放应用 ==========

## 将当前难度缩放应用到敌人数据副本上
## 数据流：GameWorld._spawn_enemy → duplicate敌人数据 → 此方法缩放 → 赋给敌人节点
## 关键约定：传入的必须是duplicate()后的副本！本方法会直接修改传入数据的数值，
##           绝不允许对共享的.tres资源调用（否则会污染整个敌人池）
## 参数：enemy_data - 敌人数据副本，is_elite - 是否精英怪（精英怪缩放略温和，
##        因为精英怪本身基础属性就高，双重量叠会导致秒杀玩家）
func apply_to_enemy_data(enemy_data: Resource, is_elite: bool = false) -> void:
	## 空数据直接返回（防御性检查）
	if enemy_data == null:
		return
	## 精英怪使用0.6倍的缩放强度：自身基础高，避免与难度曲线叠加过猛
	var intensity: float = 0.6 if is_elite else 1.0
	## 登塔增幅（无尽模式）按轴独立取值，普通怪/精英怪一视同仁（不再享受精英的温和折扣）
	## 设计意图：血量/伤害是"耐力轴"（可预期、可追赶），攻速/移速/弹速是"速度轴"
	##          （直接压缩玩家容错，必须用远小于耐力轴的涨幅，防止指数放大后玩法崩坏）
	var tower_health: float = get_tower_mult("health")
	var tower_damage: float = get_tower_mult("damage")
	var tower_attack_speed: float = get_tower_mult("attack_speed")
	var tower_move_speed: float = get_tower_mult("move_speed")
	var tower_bullet_speed: float = get_tower_mult("bullet_speed")
	## 难度模式倍率（三档难度）：普通档全为 1.0，困难/专家在此注入 2 倍伤害/血量与速度轴增幅
	var mode_health: float = get_mode_health_mult()
	var mode_damage: float = get_mode_damage_mult()
	var mode_move_speed: float = get_mode_move_speed_mult()
	var mode_bullet_speed: float = get_mode_bullet_speed_mult()
	var mode_attack_speed: float = get_mode_attack_speed_mult()
	## 计算实际应用的各级系数：(1.0 + 难度增量*缩放强度) × 对应轴的登塔系数 × 难度模式倍率
	var health_mult: float = (1.0 + (get_health_mult() - 1.0) * intensity) * tower_health * mode_health
	var damage_mult: float = (1.0 + (get_damage_mult() - 1.0) * intensity) * tower_damage * mode_damage
	var speed_mult: float = (1.0 + (get_speed_mult() - 1.0) * intensity) * tower_move_speed * mode_move_speed

	## 缩放基础属性（使用"in"检查保证对任意EnemyData子类安全）
	if "max_health" in enemy_data:
		enemy_data.max_health = int(ceil(enemy_data.max_health * health_mult))
	if "damage" in enemy_data:
		enemy_data.damage = int(ceil(enemy_data.damage * damage_mult))
	if "speed" in enemy_data:
		enemy_data.speed = enemy_data.speed * speed_mult
	if "wander_speed" in enemy_data:
		enemy_data.wander_speed = enemy_data.wander_speed * speed_mult

	## 缩放攻击冷却：登塔"攻速增幅"与难度模式攻速在此换算为冷却缩短
	## （冷却 = 原冷却 / (攻速倍数 × 模式攻速倍数)）
	## 下限保护 MIN_ATTACK_COOLDOWN：极高层数下冷却不得趋近 0，否则同帧可重复触发攻击，
	## 弹幕会在瞬间饱和。当前所有敌人的基础冷却均 ≥1.0，未登塔时下限不产生任何影响
	if "attack_cooldown" in enemy_data:
		enemy_data.attack_cooldown = maxf(
			enemy_data.attack_cooldown / (tower_attack_speed * mode_attack_speed), MIN_ATTACK_COOLDOWN)

	## 缩放敌人子弹伤害：duplicate子弹数据后修改伤害
	## 注意：EnemyData.duplicate()默认不深拷贝子资源，bullet_data与池内共享，
	##       必须单独duplicate后替换，否则会污染共享子弹数据
	if "bullet_data" in enemy_data and enemy_data.bullet_data != null:
		var bullet_copy: Resource = enemy_data.bullet_data.duplicate()
		## 子弹伤害与碰撞伤害同系数缩放
		if "damage" in bullet_copy:
			bullet_copy.damage = maxi(int(ceil(bullet_copy.damage * damage_mult)), 1)
		## 子弹飞行速度：登塔"弹速增幅"与难度模式弹速独立生效
		## 注意：此链路只覆盖普通攻击弹幕；高级怪的技能弹幕速度配置在 MonsterSkill 中，
		##       不经过 bullet_data，故不受登塔增幅影响（既有行为，保持不变）
		if "speed" in bullet_copy:
			bullet_copy.speed = bullet_copy.speed * tower_bullet_speed * mode_bullet_speed
		## 替换为独立副本（该副本只属于这个敌人实例的数据）
		enemy_data.bullet_data = bullet_copy

	## 缩放掉落价值：遍历掉落物副本，按难度提升碎片/道具价值
	## 设计意图：风险回报对等——难度越高，击杀收益越高，鼓励玩家坚持
	if "drop_items" in enemy_data:
		var drop_mult: float = get_drop_value_mult()
		for drop_item in enemy_data.drop_items:
			if drop_item != null and "value" in drop_item:
				drop_item.value = maxi(int(ceil(drop_item.value * drop_mult)), 1)

## ========== 神庙掉落系统 ==========

## 神庙固定掉率：1%（用户规则：概率不再随血量/难度/精英波动，保持恒定值）
## 1% = 0.01，即平均每击杀100个高级怪出现一座
const TEMPLE_FIXED_CHANCE: float = 0.01
## 小怪名单（击杀不掉神庙）：slime/bat/goblin/scout/spider
## 扩展说明：新增敌人默认按"高级怪"处理（有神庙掉率），若属于小怪需加入此名单
const TEMPLE_BASIC_MOB_IDS: Array[String] = ["slime", "bat", "goblin", "scout", "spider"]

## 计算击杀指定敌人后神庙的出现概率
## 规则（用户定制）：固定1%，不再随品级/难度/精英波动；小怪不掉神庙
## 参数：enemy_data - 被击杀敌人的数据资源
## 返回：神庙出现概率（0.0 或 TEMPLE_FIXED_CHANCE）
func get_temple_spawn_chance(enemy_data: Resource) -> float:
	if enemy_data == null:
		return 0.0
	## 小怪不掉神庙（用户规则：只有高级怪物才有几率出现神庙）
	if "enemy_id" in enemy_data and enemy_data.enemy_id in TEMPLE_BASIC_MOB_IDS:
		return 0.0
	return TEMPLE_FIXED_CHANCE
