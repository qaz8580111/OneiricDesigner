## UpgradeManager.gd - 升级词条管理单例
## 职责：管理词条池加载、三选一随机抽取、词条应用、等级/经验（碎片）系统
## 继承：Node（作为全局单例运行）
## 设计意图：
##   1. 补全"梦境碎片→升级"的核心循环：碎片即经验，达到阈值自动弹出三选一面板
##   2. 数据驱动扩展：自动扫描 data/upgrades/ 目录加载词条，
##      新增词条只需创建.tres文件，无需修改任何代码
##   3. 特效词条复用已有的16种子弹特效.tres，把特效系统接入局内成长
extends Node

## ========== 预加载资源 ==========

## 词条数据资源类
const UpgradeDataClass = preload("res://scripts/resources/upgrade/UpgradeData.gd")

## 三选一面板场景脚本（纯代码构建UI，无需.tscn）
const LEVEL_UP_PANEL_SCRIPT = preload("res://scripts/ui/LevelUpPanel.gd")

## ========== 信号定义 ==========

## 等级提升信号：升级时发出（HUD更新等级显示）
## 参数：new_level - 新等级
signal level_up(new_level: int)

## 经验变化信号：碎片累计变化时发出（HUD更新经验条）
## 参数：current_exp - 当前经验（碎片），needed - 距下一级所需
signal exp_changed(current_exp: int, needed: int)

## 词条应用信号：玩家选定词条后发出（HUD/日志等监听）
## 参数：upgrade - 被应用的词条数据
signal upgrade_applied(upgrade: Resource)

## ========== 等级与经验（碎片即经验） ==========

## 当前等级（从1开始）
var level: int = 1

## 当前经验（累计获得的梦境碎片数，不消耗）
var exp_total: int = 0

## 下一级所需经验：10 + 8*(等级-1)，等级越高升级越慢
var next_level_cost: int = 10

## 是否正在三选一选择中（Main.gd据此屏蔽ESC暂停，防止UI冲突）
var is_choosing: bool = false

## ========== 玩家属性（词条累积的乘算/加成） ==========

## 玩家属性字典（词条stat_modifiers按约定键名累加到这里）
## 键名约定与UpgradeData.stat_modifiers一致：
##   damage_mult（子弹伤害乘算）/ bullet_speed_mult（弹速乘算）
##   fire_rate_mult（射速乘算）/ move_speed_mult（移速乘算）
##   max_hp_bonus（核心血上限加值，整数）
## 值含义：乘算类初始1.0，词条增量累加（如+0.15/层）；加值类初始0
var player_stats: Dictionary = {
	"damage_mult": 1.0,
	"bullet_speed_mult": 1.0,
	"fire_rate_mult": 1.0,
	"move_speed_mult": 1.0,
	"max_hp_bonus": 0,
}

## 各词条已叠加层数（upgrade_id → 层数，控制max_stacks上限）
var _upgrade_stacks: Dictionary = {}

## ========== 词条池 ==========

## 所有加载的词条数据（UpgradeData数组）
var _upgrade_pool: Array = []

## 三选一面板实例（选择期间存在，选择后销毁）
var _panel: Control = null

## ========== 生命周期方法 ==========

## _ready() - 进入场景树时初始化
func _ready() -> void:
	## 扫描并加载所有词条资源
	_load_upgrade_pool()
	## 监听游戏开始信号：每局开始时重置升级状态
	GameManager.game_started.connect(_on_game_started)

## 重置本局升级状态（响应GameManager.game_started）
func _on_game_started() -> void:
	## 重置等级/经验/层数/属性为初始值
	level = 1
	exp_total = 0
	next_level_cost = 10
	is_choosing = false
	player_stats = {
		"damage_mult": 1.0,
		"bullet_speed_mult": 1.0,
		"fire_rate_mult": 1.0,
		"move_speed_mult": 1.0,
		"max_hp_bonus": 0,
	}
	_upgrade_stacks.clear()
	## 关闭可能残留的选择面板
	_close_panel()

## ========== 词条池加载 ==========

## 扫描data/upgrades/目录加载所有词条.tres
## 使用DirAccess动态扫描（而非硬编码列表），保证可扩展性：
## 新增词条只需放入.tres文件，重启即生效
func _load_upgrade_pool() -> void:
	_upgrade_pool.clear()
	var dir_path: String = "res://data/upgrades"
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		push_warning("UpgradeManager: 无法打开词条目录 " + dir_path)
		return

	## 遍历目录下所有文件
	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while file_name != "":
		## 只处理.tres资源文件
		if not dir.current_is_dir() and file_name.ends_with(".tres"):
			var resource: Resource = load(dir_path + "/" + file_name)
			## 校验资源类型（防止误放其他资源导致崩溃）
			if resource is UpgradeDataClass:
				_upgrade_pool.append(resource)
			else:
				push_warning("UpgradeManager: " + file_name + " 不是UpgradeData类型，已跳过")
		file_name = dir.get_next()
	dir.list_dir_end()
	print("UpgradeManager: 已加载 %d 条升级词条" % _upgrade_pool.size())

## ========== 经验与等级系统 ==========

## 添加经验（碎片）——由Player.add_dream_fragment转发调用
## 数据流：敌人掉落碎片 → 玩家拾取 → add_dream_fragment → 此方法 → 检查升级
## 参数：amount - 本次增加的碎片数
func add_exp(amount: int) -> void:
	## 只在游戏中生效
	if not GameManager.is_playing():
		return
	exp_total += amount
	## 广播经验变化（HUD更新经验条）
	exp_changed.emit(exp_total, next_level_cost)
	## 检查是否达到升级阈值（while处理一次拾取跨多级的情况）
	while exp_total >= next_level_cost:
		exp_total -= next_level_cost
		level += 1
		next_level_cost = 10 + 8 * (level - 1)
		## 上报统计（结算面板展示本局达到的最高等级）
		RunStats.report_level(level)
		level_up.emit(level)
		## 触发三选一选择（升级的核心奖励）
		open_level_up_choice()

## 获取当前升级进度（0.0~1.0，HUD经验条使用）
## 返回：经验进度比例
func get_exp_progress() -> float:
	if next_level_cost <= 0:
		return 1.0
	return clamp(float(exp_total) / float(next_level_cost), 0.0, 1.0)

## ========== 三选一抽取与选择流程 ==========

## 打开三选一选择面板（升级触发入口）
## 流程：暂停游戏 → 随机抽3个可用词条 → 显示面板 → 玩家选择 → 应用 → 恢复游戏
## 健壮性设计：本方法可能从物理回调链路触发（碎片拾取→add_exp→此方法），
## 直接修改场景树/暂停会触发"flushing queries"错误，因此实际操作延迟一帧执行
func open_level_up_choice() -> void:
	## 防止重复打开（连升时会多次触发）
	if is_choosing:
		return
	## 立即上锁（防止同帧多次触发），实际打开延迟到帧末
	is_choosing = true
	_do_open_level_up_choice.call_deferred()

## 实际创建选择面板（延迟一帧后执行，避开物理回调的当前帧）
func _do_open_level_up_choice() -> void:
	## 延迟期间状态可能已变化（重开局/游戏结束）：is_choosing被重置则取消本次打开
	if not is_choosing:
		return
	## 延迟期间游戏可能已结束（玩家死亡）：取消本次升级选择
	if GameManager.current_state == GameManager.GameState.GAME_OVER:
		is_choosing = false
		return

	## 从词条池抽取3个可用词条
	var choices: Array = _roll_three_upgrades()
	## 池子耗尽时跳过选择（直接放行，不做任何暂停）
	if choices.is_empty():
		is_choosing = false
		return

	## 暂停游戏（复用GameManager的暂停系统，世界停止但UI可交互）
	GameManager.pause_game()

	## 创建三选一面板（纯代码构建，挂到根节点保证在暂停时可见可交互）
	_panel = LEVEL_UP_PANEL_SCRIPT.new()
	_panel.process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().root.add_child(_panel)
	## 连接选择信号：玩家选定词条后应用并关闭
	_panel.upgrade_chosen.connect(_on_upgrade_chosen)

	## 初始化面板显示（传入候选词条）
	_panel.setup(choices)

## 从词条池按稀有度加权抽取3个不重复的可用词条
## 过滤规则：
##   1. 叠加层数未达上限
##   2. 特效词条未被拥有过（同特效只能拥有一次）
## 返回：最多3个UpgradeData数组（池子不足时返回实际数量）
func _roll_three_upgrades() -> Array:
	## 第一步：过滤出当前可用词条
	var available: Array = []
	var player: Node2D = _get_player()
	for upgrade in _upgrade_pool:
		## 检查叠加层数上限
		var stacks: int = _upgrade_stacks.get(upgrade.upgrade_id, 0)
		if stacks >= upgrade.max_stacks:
			continue
		## 特效词条检查是否已拥有（通过玩家子弹特效的effect_id判断）
		if upgrade.is_effect_upgrade() and player != null and player.has_method("has_bullet_effect"):
			var effect_id: String = upgrade.bullet_effect.effect_id if upgrade.bullet_effect != null else ""
			if effect_id != "" and player.has_bullet_effect(effect_id):
				continue
		available.append(upgrade)

	## 无可用词条（全部满层）时返回空
	if available.is_empty():
		return []

	## 第二步：按稀有度加权随机抽取（不重复）
	## 权重：普通100 / 稀有45 / 史诗18——普通词条保证基础成长，史诗可遇不可求
	var weights: Array = [100.0, 45.0, 18.0]
	var picks: Array = []
	for i in range(3):
		## 计算剩余词条的总权重
		var total_weight: float = 0.0
		for u in available:
			total_weight += weights[u.rarity]
		if total_weight <= 0.0 or available.is_empty():
			break
		## 轮盘赌抽取
		var roll: float = RandomManager.randf() * total_weight
		var cumulative: float = 0.0
		for j in range(available.size()):
			cumulative += weights[available[j].rarity]
			if roll <= cumulative:
				picks.append(available[j])
				## 抽中即从候选移除：保证3个结果互不重复
				available.remove_at(j)
				break
	return picks

## 玩家选定词条的回调（响应LevelUpPanel.upgrade_chosen）
## 参数：upgrade - 选定的词条数据
func _on_upgrade_chosen(upgrade: Resource) -> void:
	## 应用词条
	apply_upgrade(upgrade)
	## 关闭面板并恢复游戏
	_close_panel()
	is_choosing = false
	GameManager.resume_game()
	## 恢复后检查：碎片可能已跨过下一级阈值（连升），再次触发选择
	if exp_total >= next_level_cost:
		add_exp(0)

## 关闭并销毁选择面板
func _close_panel() -> void:
	if _panel != null and is_instance_valid(_panel):
		_panel.queue_free()
	_panel = null

## ========== 词条应用 ==========

## 应用词条到玩家（三选一选定 / BUFF道具随机获得 的统一入口）
## 参数：upgrade - 要应用的词条数据
func apply_upgrade(upgrade: Resource) -> void:
	if upgrade == null:
		return
	## 记录叠加层数
	_upgrade_stacks[upgrade.upgrade_id] = _upgrade_stacks.get(upgrade.upgrade_id, 0) + 1
	## 记录统计（本局获得词条数）
	RunStats.add_upgrade_taken()

	## 特效词条：追加到玩家子弹特效列表
	if upgrade.is_effect_upgrade():
		var player: Node2D = _get_player()
		if player != null and player.has_method("apply_bullet_effect"):
			player.apply_bullet_effect(upgrade.bullet_effect)
	else:
		## 属性词条：按约定键名累积到玩家属性字典
		for key in upgrade.stat_modifiers.keys():
			## 默认值按键名类型区分：乘算键(_mult后缀)缺省1.0、加值键缺省0，首次出现的键也能正确累加
			player_stats[key] = player_stats.get(key, 1.0 if key.ends_with("_mult") else 0) + upgrade.stat_modifiers[key]
			## 生命上限词条需要立即生效（扩容+治疗）
			if key == "max_hp_bonus":
				var player: Node2D = _get_player()
				if player != null and player.has_method("apply_max_hp_bonus"):
					player.apply_max_hp_bonus(upgrade.stat_modifiers[key])

	## 广播词条应用信号
	upgrade_applied.emit(upgrade)
	## 应用音效
	if AudioManager:
		AudioManager.play_2d("upgrade_pick", _get_player().global_position if _get_player() != null else Vector2.ZERO, 0.8)

## BUFF掉落道具的随机词条入口
## 数据流：敌人掉落BUFF → 玩家拾取 → DropItem.apply → player.add_buff → 此方法
## 设计意图：BUFF道具=随机直接获得一个可用词条（不需要三选一，即时奖励）
## 返回：获得的词条数据（无可用词条时返回null）
func grant_random_upgrade() -> Resource:
	## 抽取1个可用词条
	var choices: Array = _roll_three_upgrades()
	if choices.is_empty():
		return null
	## 从抽到的候选中再随机取1个（复用三选一的加权抽取，保证稀有度分布一致）
	var upgrade: Resource = choices[RandomManager.randi_range(0, choices.size() - 1)]
	## 直接应用（不开面板，BUFF是即时奖励）
	apply_upgrade(upgrade)
	return upgrade

## ========== 辅助方法 ==========

## 获取玩家节点（通过player组查找）
## 返回：玩家节点，未找到返回null
func _get_player() -> Node2D:
	var players: Array = get_tree().get_nodes_in_group("player")
	if players.size() > 0:
		return players[0] as Node2D
	return null
