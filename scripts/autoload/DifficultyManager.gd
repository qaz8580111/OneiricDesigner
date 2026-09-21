## DifficultyManager.gd - 难度曲线管理单例
## 职责：随游戏时间动态提升难度，控制敌人属性缩放、生成节奏、精英怪频率、波次事件
## 继承：Node（作为全局单例运行）
## 设计意图：
##   1. roguelike的压力曲线：难度随时间线性爬升，迫使玩家在成长与生存间保持节奏
##   2. 数据驱动调参：所有缩放系数均为常量，集中在文件顶部，调平衡无需改动逻辑
##   3. 缩放只作用于"实例副本"：绝不修改共享的.tres资源，避免跨局/跨实例串扰
##   4. 波次事件（趣味性/随机性）：每N级触发一次敌潮，制造高压时刻与爽点
## 数据流：本类每帧推进等级并广播difficulty_changed/wave_started →
##         GameWorld/Enemy在生成敌人时调用get_*_mult()/apply_to_enemy_data()完成属性缩放
extends Node

## ========== 信号定义（用于与其他节点通信） ==========

## 难度提升信号：难度等级变化时发出（HUD更新难度显示、GameWorld调整节奏）
## 参数：new_level - 新难度等级（从1开始）
signal difficulty_changed(new_level: int)

## 波次开始信号：触发敌潮事件时发出（GameWorld批量刷怪、HUD显示警告）
## 参数：wave_number - 波次序号（第几波），spawn_count - 本波建议刷怪数量
signal wave_started(wave_number: int, spawn_count: int)

## ========== 调参常量（难度曲线的核心配置，集中管理便于平衡调整） ==========

## 每提升1级难度所需时间（秒）：110秒一级（落在用户要求的100~120秒区间内）
## 旧值70s→110s：配合"难度上限压缩到10级"的改造，让整局节奏落在15~20分钟
## 满级总耗时 ≈ 110 * 9 = 990秒 ≈ 16.5分钟（不含终极BOSS战）
const LEVEL_INTERVAL: float = 110.0

## 难度等级硬上限：10级封顶（用户要求：把原来的30级曲线压缩进10级）
## 达到上限后难度曲线停止爬升，游戏交给 StageDirector 的终极关卡收尾
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

## ========== 成员变量（运行时数据） ==========

## 当前难度等级（从1开始，游戏开始后随时间提升；开局档可通过 set_start_level() 调整）
var level: int = 1

## 登塔增幅系数（无尽模式专用）：由 TowerManager 每层递增写入，1.0=未登塔
## 设计：难度曲线本身在10级封顶，登塔阶段的"继续变强"改由此系数承担——
##       它只参与属性缩放（血量/伤害/移速），不改变任何上限（敌人数量上限保持恒定）
var tower_multiplier: float = 1.0

## 已配置的开局起始等级（Settings 界面设置后生效，下次新游戏从这里起步）
## 默认=1（新手标准）；值范围 1~10（过大开局会直接秒杀玩家）
var _configured_start_level: int = 1

## 本局已进行的游戏时间（秒），仅游戏进行中累计
var _elapsed: float = 0.0

## 下一次难度提升的时间点（秒）
var _next_level_time: float = LEVEL_INTERVAL

## 已触发的波次计数（用于wave_started信号的序号参数）
var _wave_count: int = 0

## ========== 生命周期方法 ==========

## _ready() - 进入场景树时初始化
## 工作：
##   1. 从 settings.cfg 加载玩家保存的难度档（这样即便从未打开设置界面也会用保存的难度开局）
##   2. 连接 game_started 信号
func _ready() -> void:
	## 先加载保存的难度档 → 映射到起始等级
	_load_start_level_from_config()
	## 监听游戏开始信号：每局开始时重置难度状态
	GameManager.game_started.connect(_on_game_started)

## _process() - 每帧检查难度提升条件（仅游戏进行中计时）
func _process(delta: float) -> void:
	## 只在游戏进行时累计时间（暂停/菜单/结算时冻结难度曲线）
	if not GameManager.is_playing():
		return
	## 已达难度上限：曲线停止爬升，直接跳过（不再累计时间，省去无意义运算）
	if level >= MAX_LEVEL:
		return
	## 累计游戏时间
	_elapsed += delta
	## 检查是否到达难度提升时间点（while处理极端情况下的连升）
	## 循环内必须二次判断上限：_advance_level() 封顶后会直接return、不再推进
	## _next_level_time，若此处不break将导致死循环卡死整个游戏
	while _elapsed >= _next_level_time:
		if level >= MAX_LEVEL:
			break
		_advance_level()

## 重置本局难度状态（响应GameManager.game_started）
## 算法：先重置状态 → 再基于 _configured_start_level 快速跳跃到目标开局等级
##   - 目标等级=1：正常开局，无需跳级
##   - 目标等级=4：先 time 前进(4-1)*LEVEL_INTERVAL → 连续 _advance_level() 三次 → 从4继续
## 这样做的好处：
##   * 跳跃过程会正确触发 difficulty_changed 信号、波次判定、难度缩放同步
##   * _elapsed、_next_level_time、_wave_count 全部状态连续、符合预期
func _on_game_started() -> void:
	## ---- 基础重置 ----
	level = 1
	_elapsed = 0.0
	_next_level_time = LEVEL_INTERVAL
	_wave_count = 0
	## 登塔增幅复位：每局从无增幅开始（TowerManager 会在无尽模式登塔时重新赋值）
	tower_multiplier = 1.0

	## ---- 跳跃到配置的开局难度 ----
	var target: int = clampi(_configured_start_level, 1, MAX_LEVEL)
	if target > 1:
		## 先把累计时间 "拨快"，等于已经经历了(target-1)个难度周期
		_elapsed = float(target - 1) * LEVEL_INTERVAL
		## 用 while 连续 _advance_level()，每次都正确走完整信号/波次流程
		while level < target:
			_advance_level()
		## 到达目标后，下一难度时间点 = 当前累计时间 + 一个周期（从目标点继续正常计时）
		_next_level_time = _elapsed + LEVEL_INTERVAL

## ========== 外部 API（Settings.gd / Main.gd 使用） ==========

## 设置开局起始等级（Settings 界面点击应用后调用）
## 参数：start_level - 下次新游戏的起始难度等级（1~MAX_LEVEL，越大约猛）
func set_start_level(start_level: int) -> void:
	_configured_start_level = clampi(start_level, 1, MAX_LEVEL)
	## 同时保存到 settings.cfg（确保关闭游戏再打开仍然记得）
	_save_start_level_to_config()
	print("[DifficultyManager] 配置开局难度等级 = ", _configured_start_level)

## ========== 配置文件读写（与 Settings 共享 user://settings.cfg 的 difficulty 字段） ==========

## 难度档→起始等级映射表（必须与 Settings.gd DIFFICULTY_START_LEVELS 保持完全一致）
## 设计：两文件分开定义同一组映射，避免循环依赖；任一修改时必须同步另一处
const _DIFFICULTY_START_LEVELS: Array[int] = [1, 2, 4, 7]

## 从 user://settings.cfg 读取 difficulty (0~3) 并转为起始等级
## 调用时机：DifficultyManager._ready() → 首次 autoload 启动时读一次
func _load_start_level_from_config() -> void:
	var config := ConfigFile.new()
	var err: int = config.load("user://settings.cfg")
	if err == OK:
		## 读取难度档（0=简单/1=普通/2=困难/3=专家），默认普通档
		var difficulty_idx: int = int(config.get_value("Settings", "difficulty", 1))
		## 映射到起始等级，越界兜底为普通档(level=2)
		if difficulty_idx >= 0 and difficulty_idx < _DIFFICULTY_START_LEVELS.size():
			_configured_start_level = _DIFFICULTY_START_LEVELS[difficulty_idx]
		else:
			_configured_start_level = 2
	else:
		## 首次启动无配置 → 使用普通档开局（业界通用默认）
		_configured_start_level = 2
	print("[DifficultyManager] 读取到起始等级配置 = ", _configured_start_level)

## 把当前 _configured_start_level 反查回难度档索引，写回 settings.cfg
## 调用时机：set_start_level() 被外部设置之后，持久化到磁盘
func _save_start_level_to_config() -> void:
	var config := ConfigFile.new()
	var err: int = config.load("user://settings.cfg")
	## 加载失败也能写：ConfigFile 空对象就是空配置，保存会创建新文件
	var best_idx: int = 1  # 存回普通档兜底
	var best_dist: int = 9999
	## 找到离当前 start_level 最近的难度档索引（反查）
	for i in range(_DIFFICULTY_START_LEVELS.size()):
		var d: int = abs(_DIFFICULTY_START_LEVELS[i] - _configured_start_level)
		if d < best_dist:
			best_dist = d
			best_idx = i
	config.set_value("Settings", "difficulty", best_idx)
	config.save("user://settings.cfg")

## ========== 难度提升核心逻辑 ==========

## 提升一级难度：更新等级、广播信号、按条件触发波次事件
## 已达 MAX_LEVEL 时直接返回（封顶，不再提升也不推进计时，防止等级无限膨胀）
func _advance_level() -> void:
	## 难度封顶判断（双保险：调用方 _process 也会先判断）
	if level >= MAX_LEVEL:
		return
	## 等级+1，并推后下一次提升时间点（基于当前时间累加，避免时间漂移）
	level += 1
	_next_level_time += LEVEL_INTERVAL
	## 广播难度变化信号（HUD更新难度显示）
	difficulty_changed.emit(level)
	## 上报统计（结算面板展示本局达到的最高难度）
	RunStats.report_difficulty(level)
	## 播放难度提升音效（全局播放，位置无关；if判空为防御性写法，容错单例未就绪的极端情况）
	if AudioManager:
		AudioManager.play("difficulty_up", 0.6)
	## 波次事件判定：每到 WAVE_EVERY_N_LEVELS 的整数倍等级触发敌潮
	## 设计意图：固定节拍+递增规模，制造规律性的高压时刻，玩家可以预期并准备
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

## 获取难度显示文本（HUD使用）
## 返回：如"难度 3"
func get_difficulty_label() -> String:
	return "难度 %d" % level

## ========== 登塔增幅接口（无尽模式专用，由 TowerManager 驱动） ==========

## 设置登塔增幅系数（TowerManager 每登一层调用一次）
## 参数：mult - 累计增幅系数（1.0 = 未登塔，逐层按固定百分比累乘）
func set_tower_multiplier(mult: float) -> void:
	## 下限保护：增幅系数不允许低于1.0（登塔只会更难，不会变简单）
	tower_multiplier = maxf(mult, 1.0)

## 获取当前登塔增幅系数
## 返回：1.0（未登塔）或更高
func get_tower_multiplier() -> float:
	return tower_multiplier

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
	## 计算实际应用的各级系数（1.0 + 增量*缩放强度）
	## 登塔增幅在难度曲线之后再乘一次：无尽模式难度10封顶后，唯一继续变强的来源，
	## 且对普通怪/精英怪一视同仁（"全面增幅"，不再享受精英的温和折扣）
	var health_mult: float = (1.0 + (get_health_mult() - 1.0) * intensity) * tower_multiplier
	var damage_mult: float = (1.0 + (get_damage_mult() - 1.0) * intensity) * tower_multiplier
	var speed_mult: float = (1.0 + (get_speed_mult() - 1.0) * intensity) * tower_multiplier

	## 缩放基础属性（使用"in"检查保证对任意EnemyData子类安全）
	if "max_health" in enemy_data:
		enemy_data.max_health = int(ceil(enemy_data.max_health * health_mult))
	if "damage" in enemy_data:
		enemy_data.damage = int(ceil(enemy_data.damage * damage_mult))
	if "speed" in enemy_data:
		enemy_data.speed = enemy_data.speed * speed_mult
	if "wander_speed" in enemy_data:
		enemy_data.wander_speed = enemy_data.wander_speed * speed_mult

	## 缩放敌人子弹伤害：duplicate子弹数据后修改伤害
	## 注意：EnemyData.duplicate()默认不深拷贝子资源，bullet_data与池内共享，
	##       必须单独duplicate后替换，否则会污染共享子弹数据
	if "bullet_data" in enemy_data and enemy_data.bullet_data != null:
		var bullet_copy: Resource = enemy_data.bullet_data.duplicate()
		## 子弹伤害与碰撞伤害同系数缩放
		if "damage" in bullet_copy:
			bullet_copy.damage = maxi(int(ceil(bullet_copy.damage * damage_mult)), 1)
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
