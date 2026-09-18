## UpgradeManager.gd - 升级词条管理单例
## 职责：管理词条池加载、三选一随机抽取、词条应用（技能宝石/神庙共用入口）
## 继承：Node（作为全局单例运行）
## 设计意图：
##   1. 三选一统一入口：全游戏获得新技能词条的唯一途径——手动按E拾取技能宝石，
##      调 open_level_up_choice() 弹面板由玩家自选；神庙"随机技能"选项不再给新技能，
##      改为随机强化一个已拥有技能 +1~3 级（可突破5级上限，最高到8级）；
##      碎片只是收集计数（HUD+结算），与技能/升级完全无关（旧"碎片即经验"已删）
##   2. 数据驱动扩展：自动扫描 data/upgrades/ 目录加载词条，
##      新增词条只需创建.tres文件，无需修改任何代码
##   3. 特效词条复用已有的16种子弹特效.tres，把特效系统接入局内成长
extends Node

## ========== 预加载资源 ==========

## 词条数据资源类
const UpgradeDataClass = preload("res://scripts/resources/upgrade/UpgradeData.gd")

## 三选一面板场景脚本（纯代码构建UI，无需.tscn）
const LEVEL_UP_PANEL_SCRIPT = preload("res://scripts/ui/LevelUpPanel.gd")

## 玩家最多同时持有的技能类（子弹特效词条）种类数（满5种后拾取新技能会随机替换旧技能）
const MAX_EFFECT_SKILL_TYPES: int = 5

## 玩家最多同时持有的属性类（纯数值词条）种类数（满2种后拾取新属性会随机替换旧属性）
## 说明：属性类与技能类数量上限各自独立计算，互不影响
const MAX_ATTRIBUTE_SKILL_TYPES: int = 2

## ========== 信号定义 ==========

## 词条应用信号：玩家选定词条后发出（HUD/日志等监听）
## 参数：upgrade - 被应用的词条数据
signal upgrade_applied(upgrade: Resource)

## 已获得词条集合变化信号：层数增加时发出（GameHUD刷新buff图标栏与层数角标）
## 参数：acquired - 当前已获得词条信息数组（元素为{id,name,rarity,stacks,max}字典）
signal upgrades_changed(acquired: Array)

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

## 面板专用 CanvasLayer（隔离 Camera2D 的 canvas_transform，保证面板不受相机偏移影响）
var _overlay_layer: CanvasLayer = null

## 排队等待的升级次数（面板显示期间又触发升级时，排队等待当前面板关闭后再展示）
var _pending_upgrades: int = 0

## ========== 生命周期方法 ==========

## _ready() - 进入场景树时初始化
func _ready() -> void:
	## 扫描并加载所有词条资源
	_load_upgrade_pool()
	## 监听游戏开始信号：每局开始时重置升级状态
	GameManager.game_started.connect(_on_game_started)

## 重置本局升级状态（响应GameManager.game_started）
func _on_game_started() -> void:
	## 重置层数/属性/选择状态为初始值
	is_choosing = false
	_pending_upgrades = 0
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

## ========== 三选一抽取与选择流程 ==========

## 打开三选一选择面板（升级触发入口）
## 流程：抽取3个可用词条 → 显示紧凑底栏面板（不暂停游戏）→ 玩家选择 → 应用 → 关闭
## 队列设计：面板显示期间又触发升级（玩家边战斗边捡宝石/神庙交互）时，排队等待，
##           当前面板关闭后自动展示下一组选项，避免连续弹出多个面板
func open_level_up_choice() -> void:
	## 正在选择中：排队等待，不重复打开
	if is_choosing:
		_pending_upgrades += 1
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
		_pending_upgrades = 0
		return

	## 从词条池抽取3个可用词条
	var choices: Array = _roll_three_upgrades()
	## 池子耗尽时跳过选择（直接放行，不做任何暂停）
	if choices.is_empty():
		is_choosing = false
		_process_pending()
		return

	## 不暂停游戏：玩家可边战斗边选择，紧凑底栏面板不影响游戏画面

	## 创建专用 CanvasLayer 作为面板父节点
	## CanvasLayer 有独立 transform，不受 Camera2D 影响 → 面板始终位于屏幕底部
	_overlay_layer = CanvasLayer.new()
	_overlay_layer.name = "LevelUpOverlay"
	## CanvasLayer layer 越大越在上层显示
	## 层级参考：默认 Main/HUD=0，StageDirector切面UI=10，Boss狂暴金边=100
	## 升级/神庙面板是用户即时交互，必须最显眼 → 设 layer=50（在 HUD 和 StageDirector 之上）
	_overlay_layer.layer = 50
	get_tree().root.add_child(_overlay_layer)

	## 创建三选一面板（挂到 CanvasLayer 下）
	_panel = LEVEL_UP_PANEL_SCRIPT.new()
	_overlay_layer.add_child(_panel)
	## 连接选择信号：玩家选定词条后应用并关闭
	_panel.upgrade_chosen.connect(_on_upgrade_chosen)
	## 连接取消信号：玩家按B/ESC放弃本次三选一，直接关闭面板不应用词条
	_panel.upgrade_cancelled.connect(_on_upgrade_cancelled)

	## 注册选择上下文：不暂停战斗（移动/射击保留），仅额外放行D-Pad/方向键+确认，
	## push自带0.2s屏蔽期，防止升级瞬间残留的攻击/交互键直接选中卡片
	InputManager.push_context("LEVEL_UP_CHOICE")

	## 初始化面板显示（传入候选词条）
	_panel.setup(choices)

## 从词条池按稀有度加权抽取3个不重复的可用词条
## 过滤规则：
##   1. 叠加层数未达上限（全局统一5级，满级词条不再出现）
## 说明：特效词条重复获得时按effect_id去重（不重复挂载），改为调用已拥有特效实例的
##       add_stack() 叠层成长——每级放大该特效的关键参数（成长策略见各特效子类
##       _on_stack_grown），与属性词条一样遵循5级上限规则
## 返回：最多3个UpgradeData数组（池子不足时返回实际数量）
func _roll_three_upgrades() -> Array:
	## 第一步：过滤出当前可用词条
	var available: Array = []
	for upgrade in _upgrade_pool:
		## 检查叠加层数上限
		var stacks: int = _upgrade_stacks.get(upgrade.upgrade_id, 0)
		if stacks >= upgrade.max_stacks:
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
	## 应用所选词条
	apply_upgrade(upgrade)
	## 关闭面板
	_close_panel()
	## 处理排队中的升级或检查连升
	_process_pending()

## 玩家取消三选一的回调（响应LevelUpPanel.upgrade_cancelled）
## 语义：放弃本次拾取——不应用词条、不处理排队升级，直接关闭面板并解锁选择状态。
##       排队计数一并清零，避免残留计数导致后续升级被"跳过"或"多跳"。
func _on_upgrade_cancelled() -> void:
	_pending_upgrades = 0
	_close_panel()
	is_choosing = false

## 处理排队升级：有排队则展示下一组选项，无排队则解锁并检查碎片是否够再升
func _process_pending() -> void:
	if _pending_upgrades > 0:
		## 还有排队的升级，展示下一组选项（is_choosing保持true）
		_pending_upgrades -= 1
		_do_open_level_up_choice.call_deferred()
	else:
		## 无排队，解锁选择状态
		is_choosing = false

## 关闭并销毁选择面板（连同 CanvasLayer 一起清理）
func _close_panel() -> void:
	## 条件注销选择上下文：仅当栈顶确实是本面板上下文时才pop。
	## 跨场景重开（Main.reset_context）后栈已被重置，无条件pop会破坏新栈
	if InputManager and InputManager.get_current_context() == "LEVEL_UP_CHOICE":
		InputManager.pop_context()
	if _panel != null and is_instance_valid(_panel):
		_panel.queue_free()
	_panel = null
	if _overlay_layer != null and is_instance_valid(_overlay_layer):
		_overlay_layer.queue_free()
	_overlay_layer = null

## ========== 词条应用 ==========

## 应用词条到玩家（三选一选定 / BUFF道具随机获得 的统一入口）
## 参数：upgrade - 要应用的词条数据
func apply_upgrade(upgrade: Resource) -> void:
	if upgrade == null:
		return
	## 等级上限钳制：词条池中的真实技能/属性到达 max_stacks（5级）后不再叠层。
	## 商店 / 三选一 / 开局授予均走此入口，因此"商店购买的技能"不会突破5级；
	## 神庙"随机技能"强化走 _boost_upgrade（不经此入口），可突破上限（理论最高8级）。
	if _is_pool_skill(upgrade) and _upgrade_stacks.get(upgrade.upgrade_id, 0) >= upgrade.max_stacks:
		return
	## 数量上限（技能类与属性类各自独立计算）：
	##   技能类（特效词条）最多 MAX_EFFECT_SKILL_TYPES 种，满后拾取新技能随机替换一个旧技能；
	##   属性类（纯数值词条）最多 MAX_ATTRIBUTE_SKILL_TYPES 种，满后拾取新属性随机替换一个旧属性。
	## 仅当本次应用的是"词条池中的真实技能"、且是"尚未拥有的新技能"时才触发同类替换；
	## 已拥有技能的叠加升级、以及神庙"属性强化"等临时词条（不入池）均不触发替换。
	if _is_pool_skill(upgrade) and not _upgrade_stacks.has(upgrade.upgrade_id):
		if upgrade.is_effect_upgrade():
			if _get_held_skill_count(true) >= MAX_EFFECT_SKILL_TYPES:
				_replace_random_skill(true)
		else:
			if _get_held_skill_count(false) >= MAX_ATTRIBUTE_SKILL_TYPES:
				_replace_random_skill(false)
	## 记录叠加层数
	_upgrade_stacks[upgrade.upgrade_id] = _upgrade_stacks.get(upgrade.upgrade_id, 0) + 1
	## 记录统计（本局获得词条数）
	RunStats.add_upgrade_taken()
	## 广播已获得词条变化（HUD刷新buff图标与层数角标）
	upgrades_changed.emit(get_acquired_upgrades())

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

## ========== 神庙"随机技能"强化（新增需求） ==========

## 随机强化一个已拥有技能（神庙"随机技能"选项用，替代旧的三选一面板）
## 规则：从已持有技能中随机选一个，等级 +amount（1~3）级；
##       突破5级上限（满级5级后继续强化，理论最高可到8级）；
##       特效词条逐级 add_stack 成长、属性词条逐级累加，均复用词条自身成长逻辑
## 返回：是否强化成功（无已拥有技能时返回 false，神庙保留不消失）
func boost_random_skill(amount: int) -> bool:
	if amount <= 0:
		return false
	## 收集当前已持有的真实技能（仅词条池技能，排除神庙临时词条）
	var held_ids: Array = []
	for uid in _upgrade_stacks.keys():
		if _find_upgrade_by_id(uid) != null:
			held_ids.append(uid)
	if held_ids.is_empty():
		return false
	## 随机抽一个已拥有技能强化
	var uid: String = String(held_ids[RandomManager.randi_range(0, held_ids.size() - 1)])
	var upgrade: Resource = _find_upgrade_by_id(uid)
	if upgrade == null:
		return false
	_boost_upgrade(upgrade, amount)
	return true

## 对指定技能一次性叠加 amount 级（突破 max_stacks 上限）
## 说明：与 apply_upgrade 的单级叠加逻辑一致，但这里跳过"技能种类上限替换"判断
##       （操作对象是已拥有技能，不会新增技能种类），统计与信号只触发一次
## 参数：upgrade - 被强化的词条数据；amount - 叠加等级数（1~3）
func _boost_upgrade(upgrade: Resource, amount: int) -> void:
	## 一次性累加层数（突破上限，不做 max_stacks 钳制）
	_upgrade_stacks[upgrade.upgrade_id] = _upgrade_stacks.get(upgrade.upgrade_id, 0) + amount
	## 统计（神庙一次选项强化记 1 次词条获得）
	RunStats.add_upgrade_taken()
	## 广播层数变化（HUD 刷新 buff 图标与层数角标）
	upgrades_changed.emit(get_acquired_upgrades())

	if upgrade.is_effect_upgrade():
		## 特效词条：逐级调用 apply_bullet_effect（已拥有时走 add_stack 成长）
		var player: Node2D = _get_player()
		if player != null and player.has_method("apply_bullet_effect"):
			for i in range(amount):
				player.apply_bullet_effect(upgrade.bullet_effect)
	else:
		## 属性词条：逐级累加到玩家属性字典
		for i in range(amount):
			for key in upgrade.stat_modifiers.keys():
				player_stats[key] = player_stats.get(key, 1.0 if key.ends_with("_mult") else 0) + upgrade.stat_modifiers[key]
				## 生命上限词条每级都需要立即生效（扩容+治疗）
				if key == "max_hp_bonus":
					var player: Node2D = _get_player()
					if player != null and player.has_method("apply_max_hp_bonus"):
						player.apply_max_hp_bonus(int(upgrade.stat_modifiers[key]))

	## 广播词条应用信号（与 apply_upgrade 保持一致）
	upgrade_applied.emit(upgrade)
	## 应用音效
	if AudioManager:
		AudioManager.play_2d("upgrade_pick", _get_player().global_position if _get_player() != null else Vector2.ZERO, 0.8)

## ========== 技能种类上限与随机替换（新增需求） ==========

## 判断给定词条是否为"词条池中的真实技能"（区别于神庙"属性强化"等临时构造词条）
## 真实技能才受"最多持有N种"限制（技能类5种 / 属性类2种各自计算）；临时词条不入池，不参与计数与替换
## 参数：upgrade - 待判断的词条资源
## 返回：true表示真实技能，false表示临时词条
func _is_pool_skill(upgrade: Resource) -> bool:
	if upgrade == null:
		return false
	for u in _upgrade_pool:
		if u == upgrade or u.upgrade_id == upgrade.upgrade_id:
			return true
	return false

## 统计当前已持有的某类真实技能种类数（仅计数词条池中的技能，排除神庙临时词条）
## 参数：want_effect - true=技能类(特效词条) / false=属性类(纯数值词条)
## 返回：该类已持有技能种类数
func _get_held_skill_count(want_effect: bool) -> int:
	var count: int = 0
	for uid in _upgrade_stacks.keys():
		var u: Resource = _find_upgrade_by_id(uid)
		if u != null and u.is_effect_upgrade() == want_effect:
			count += 1
	return count

## 随机替换一个已持有的某类技能（该类数量上限触发时调用）
## 参数：want_effect - true=技能类(特效词条) / false=属性类(纯数值词条)
## 数据流：apply_upgrade 检测到该类上限且拾取同类新技能 → 此方法随机选一个同类已持有技能移除
func _replace_random_skill(want_effect: bool) -> void:
	var held_skills: Array = []
	for uid in _upgrade_stacks.keys():
		var u: Resource = _find_upgrade_by_id(uid)
		if u != null and u.is_effect_upgrade() == want_effect:
			held_skills.append(uid)
	if held_skills.is_empty():
		return
	var index: int = RandomManager.randi_range(0, held_skills.size() - 1)
	_remove_upgrade(held_skills[index])

## 移除指定技能的全部层数，并回退其对玩家属性/子弹特效的影响（随机替换的核心清理逻辑）
## 参数：upgrade_id - 要移除的技能唯一标识
func _remove_upgrade(upgrade_id: String) -> void:
	var stacks: int = int(_upgrade_stacks.get(upgrade_id, 0))
	if stacks <= 0:
		return
	var upgrade: Resource = _find_upgrade_by_id(upgrade_id)
	if upgrade == null:
		## 找不到数据时仅清除层数记录，避免残留无效技能
		_upgrade_stacks.erase(upgrade_id)
		return
	if upgrade.is_effect_upgrade():
		## 特效技能：从玩家私有子弹副本移除该特效实例
		var effect = upgrade.bullet_effect
		var effect_id: String = ""
		if effect != null and "effect_id" in effect:
			effect_id = effect.effect_id
		var player: Node2D = _get_player()
		if player != null and player.has_method("remove_bullet_effect"):
			player.remove_bullet_effect(effect_id)
	else:
		## 属性技能：按层数回退属性累加
		for key in upgrade.stat_modifiers.keys():
			var key_name: String = String(key)
			var default_val: float = 1.0 if key_name.ends_with("_mult") else 0.0
			var current: float = float(player_stats.get(key_name, default_val))
			player_stats[key_name] = current - float(upgrade.stat_modifiers[key_name]) * float(stacks)
			## 生命上限技能需要同步缩减实际血量上限（扩容的反向操作）
			if key_name == "max_hp_bonus":
				var reduction: int = int(float(upgrade.stat_modifiers[key_name]) * float(stacks))
				var player: Node2D = _get_player()
				if reduction > 0 and player != null and player.has_method("remove_max_hp_bonus"):
					player.remove_max_hp_bonus(reduction)
	## 移除层数记录
	_upgrade_stacks.erase(upgrade_id)

## 按 upgrade_id 在词条池中查找词条数据
## 参数：upgrade_id - 词条唯一标识
## 返回：找到返回 UpgradeData，未找到返回 null
func _find_upgrade_by_id(upgrade_id: String) -> Resource:
	for u in _upgrade_pool:
		if u.upgrade_id == upgrade_id:
			return u
	return null

## ========== 随机词条获取（开局技能 / 商店商品） ==========

## 随机获取一个属性类词条（bullet_effect 为空，即纯数值加成词条）
## 用于：开局随机授予一个属性技能、商店"属性类"商品
## 过滤：已满级（层数达到 max_stacks）的词条不再返回，避免商店售出无法升级的满级商品
## 返回：随机可用属性词条；池中无可用属性词条时返回 null
func get_random_attribute_upgrade() -> Resource:
	var candidates: Array = []
	for upgrade in _upgrade_pool:
		if upgrade.bullet_effect != null:
			continue
		if _upgrade_stacks.get(upgrade.upgrade_id, 0) >= upgrade.max_stacks:
			continue
		candidates.append(upgrade)
	if candidates.is_empty():
		return null
	return candidates[RandomManager.randi_range(0, candidates.size() - 1)]

## 随机获取一个特效类词条（bullet_effect 非空，即子弹特效词条）
## 用于：商店"技能类"商品
## 过滤：已满级（层数达到 max_stacks）的词条不再返回，避免商店售出无法升级的满级商品
## 返回：随机可用特效词条；池中无可用特效词条时返回 null
func get_random_effect_upgrade() -> Resource:
	var candidates: Array = []
	for upgrade in _upgrade_pool:
		if upgrade.bullet_effect == null:
			continue
		if _upgrade_stacks.get(upgrade.upgrade_id, 0) >= upgrade.max_stacks:
			continue
		candidates.append(upgrade)
	if candidates.is_empty():
		return null
	return candidates[RandomManager.randi_range(0, candidates.size() - 1)]

## 开局随机授予一个属性类技能（玩家实例化完成后由 Main 调用）
## 规则：仅从属性词条（bullet_effect 为空）中随机一个，走 apply_upgrade 正常应用——
##       计入技能种类、叠加层数与属性字典，与手动拾取技能书获得的新词条完全一致
func grant_random_attribute_upgrade() -> void:
	var upgrade: Resource = get_random_attribute_upgrade()
	if upgrade != null:
		apply_upgrade(upgrade)

## ========== 辅助方法 ==========

## 获取玩家节点（通过player组查找）
## 返回：玩家节点，未找到返回null
func _get_player() -> Node2D:
	var players: Array = get_tree().get_nodes_in_group("player")
	if players.size() > 0:
		return players[0] as Node2D
	return null

## ========== 已获得词条查询（HUD buff 图标栏用） ==========

## 查询指定词条当前层数（三选一面板显示"已有 Lv.N"用）
## 参数：upgrade_id - 词条唯一标识
## 返回：当前层数（0=未获得）
func get_upgrade_stacks(upgrade_id: String) -> int:
	return int(_upgrade_stacks.get(upgrade_id, 0))

## 获取本局已获得的全部词条信息（HUD图标栏数据源）
## 返回：字典数组，元素结构 {id, name, rarity, stacks, max_stacks}
func get_acquired_upgrades() -> Array:
	var result: Array = []
	for upgrade in _upgrade_pool:
		var stacks: int = int(_upgrade_stacks.get(upgrade.upgrade_id, 0))
		if stacks <= 0:
			continue
		result.append({
			"id": upgrade.upgrade_id,
			"name": upgrade.display_name,
			"rarity": upgrade.rarity,
			"stacks": stacks,
			"max_stacks": upgrade.max_stacks,
			"is_effect": upgrade.is_effect_upgrade(),
			"description": upgrade.description,
		})
	return result
