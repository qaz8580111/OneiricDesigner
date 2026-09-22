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

## 护盾三选一面板场景脚本（纯代码构建UI，与技能三选一同款紧凑底栏样式）
const SHIELD_CHOICE_PANEL_SCRIPT = preload("res://scripts/ui/ShieldChoicePanel.gd")

## 弹道构型三选一面板场景脚本（纯代码构建UI，与技能三选一同款紧凑底栏样式）
const SHOT_PATTERN_CHOICE_PANEL_SCRIPT = preload("res://scripts/ui/ShotPatternChoicePanel.gd")

## 装备护盾数据资源类（data/equipment/*.tres 类型校验用）
const ShieldEquipmentDataClass = preload("res://scripts/resources/equipment/ShieldEquipmentData.gd")

## 弹道构型资源类（data/bullet/pattern/*.tres 类型校验用）
const BulletShotPatternClass = preload("res://scripts/resources/bullet/BulletShotPattern.gd")

## 护盾装备池目录（数据驱动扫描，与 Shop._random_shield 同源）
## 新增护盾类型只需放入 .tres，护盾三选一自动纳入候选
const SHIELD_POOL_DIR: String = "res://data/equipment"

## 护盾三选一给出的候选数量（池中以随机不重复方式抽取，不足时给出实际数量）
const SHIELD_CHOICE_COUNT: int = 3

## 弹道构型池目录（数据驱动扫描，与 BulletData.shot_pattern 同源）
## 新增构型只需放入 .tres，弹道构型三选一自动纳入候选（无需改代码）
const SHOT_PATTERN_POOL_DIR: String = "res://data/bullet/pattern"

## 弹道构型三选一给出的候选数量（池中以随机不重复方式抽取，不足时给出实际数量）
const SHOT_PATTERN_CHOICE_COUNT: int = 3

## 玩家最多同时持有的技能类（子弹特效词条）种类数（满5种后拾取新技能会随机替换旧技能）
const MAX_EFFECT_SKILL_TYPES: int = 5

## 玩家最多同时持有的属性类（纯数值词条）种类数（满3种后拾取新属性会随机替换旧属性）
## 说明：属性类与技能类数量上限各自独立计算，互不影响
const MAX_ATTRIBUTE_SKILL_TYPES: int = 3

## ========== 神庙强化碎片消耗（累加计价） ==========

## 神庙强化首次消耗的梦境碎片数（第一次400）
const TEMPLE_BOOST_BASE_COST: int = 400

## 神庙强化每次消耗的增量（第二次500、第三次600……每次+100）
const TEMPLE_BOOST_COST_STEP: int = 100

## 融合技能固定消耗的梦境碎片数（约为强化起步价的3~4倍，属"攒一会儿即可实现"的大件）
const FUSE_SKILL_COST: int = 1500

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
##   shield_max_mult（装备护盾耐久上限乘算，EquipmentShieldComponent消费）
##   shield_regen_mult（装备护盾回盾速度乘算，EquipmentShieldComponent消费）
##   hp_regen（每秒核心血回复量，PlayerHealthController消费）
##   invincible_mult（受击无敌时间乘算，CoreHealthComponent消费）
## 值含义：乘算类初始1.0，词条增量累加（如+0.15/层）；加值类初始0
var player_stats: Dictionary = {
	"damage_mult": 1.0,
	"bullet_speed_mult": 1.0,
	"fire_rate_mult": 1.0,
	"move_speed_mult": 1.0,
	"max_hp_bonus": 0,
	"shield_max_mult": 1.0,
	"shield_regen_mult": 1.0,
	"hp_regen": 0,
	"invincible_mult": 1.0,
}

## 各词条已叠加层数（upgrade_id → 层数，控制max_stacks上限）
var _upgrade_stacks: Dictionary = {}

## ========== 神庙强化 / 融合技能运行时状态 ==========

## 神庙强化已执行次数（每次强化消耗累加：第1次400、第2次500……）
## 跨神庙累计，游戏开始重置
var _temple_boost_count: int = 0

## 当前融合技能记录（玩家身上最多同时一个）
## 结构：{ "a_id": String, "b_id": String, "level": int }
##   a_id/b_id = 被融合的两个技能类词条 upgrade_id；level = 融合时二者较高等级
## 空字典 = 当前无融合技能
var _fused_skill: Dictionary = {}

## ========== 词条池 ==========

## 所有加载的词条数据（UpgradeData数组）
var _upgrade_pool: Array = []

## 所有加载的护盾装备数据（ShieldEquipmentData数组，护盾三选一候选来源）
var _shield_pool: Array = []

## 所有加载的弹道构型数据（BulletShotPattern数组，弹道构型三选一候选来源）
var _shot_pattern_pool: Array = []

## 三选一面板实例（选择期间存在，选择后销毁；技能/属性/护盾/构型三选一共用，同一时刻只会有一个）
var _panel: Control = null

## 面板专用 CanvasLayer（隔离 Camera2D 的 canvas_transform，保证面板不受相机偏移影响）
var _overlay_layer: CanvasLayer = null

## 排队等待的"特效技能"三选一次数（面板显示期间又触发时排队，当前面板关闭后再展示）
var _pending_upgrades: int = 0

## 排队等待的"属性技能"三选一次数（同上，与技能书掉落完全分离）
var _pending_attribute_choices: int = 0

## 排队等待的"护盾"三选一次数（同上）
var _pending_shield_choices: int = 0

## 排队等待的"弹道构型"三选一次数（同上）
var _pending_shot_pattern_choices: int = 0

## ========== 生命周期方法 ==========

## _ready() - 进入场景树时初始化
func _ready() -> void:
	## 扫描并加载所有词条资源
	_load_upgrade_pool()
	## 扫描并加载所有护盾装备资源（护盾三选一候选池）
	_load_shield_pool()
	## 扫描并加载所有弹道构型资源（弹道构型三选一候选池）
	_load_shot_pattern_pool()
	## 监听游戏开始信号：每局开始时重置升级状态
	GameManager.game_started.connect(_on_game_started)

## 重置本局升级状态（响应GameManager.game_started）
func _on_game_started() -> void:
	## 重置层数/属性/选择状态为初始值
	is_choosing = false
	_pending_upgrades = 0
	_pending_attribute_choices = 0
	_pending_shield_choices = 0
	_pending_shot_pattern_choices = 0
	player_stats = {
		"damage_mult": 1.0,
		"bullet_speed_mult": 1.0,
		"fire_rate_mult": 1.0,
		"move_speed_mult": 1.0,
		"max_hp_bonus": 0,
		"shield_max_mult": 1.0,
		"shield_regen_mult": 1.0,
		"hp_regen": 0,
		"invincible_mult": 1.0,
	}
	_upgrade_stacks.clear()
	## 重置神庙强化计数与融合技能状态
	_temple_boost_count = 0
	_fused_skill = {}
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

## 扫描 data/equipment/ 目录加载所有护盾装备（护盾三选一候选池）
## 与 _load_upgrade_pool 同款数据驱动：新增护盾只需放入 .tres，重启即生效，无需改代码
func _load_shield_pool() -> void:
	_shield_pool.clear()
	var dir: DirAccess = DirAccess.open(SHIELD_POOL_DIR)
	if dir == null:
		push_warning("UpgradeManager: 无法打开护盾目录 " + SHIELD_POOL_DIR)
		return

	## 遍历目录下所有文件
	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while file_name != "":
		## 只处理.tres资源文件
		if not dir.current_is_dir() and file_name.ends_with(".tres"):
			var resource: Resource = load(SHIELD_POOL_DIR + "/" + file_name)
			## 校验资源类型（防止误放其他装备资源导致崩溃）
			if resource is ShieldEquipmentDataClass:
				_shield_pool.append(resource)
			else:
				push_warning("UpgradeManager: " + file_name + " 不是ShieldEquipmentData类型，已跳过")
		file_name = dir.get_next()
	dir.list_dir_end()
	print("UpgradeManager: 已加载 %d 件护盾装备" % _shield_pool.size())

## 扫描 data/bullet/pattern/ 目录加载所有弹道构型（弹道构型三选一候选池）
## 与 _load_shield_pool 同款数据驱动：新增构型只需放入 .tres，重启即生效，无需改代码
func _load_shot_pattern_pool() -> void:
	_shot_pattern_pool.clear()
	var dir: DirAccess = DirAccess.open(SHOT_PATTERN_POOL_DIR)
	if dir == null:
		push_warning("UpgradeManager: 无法打开弹道构型目录 " + SHOT_PATTERN_POOL_DIR)
		return

	## 遍历目录下所有文件
	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while file_name != "":
		## 只处理.tres资源文件
		if not dir.current_is_dir() and file_name.ends_with(".tres"):
			var resource: Resource = load(SHOT_PATTERN_POOL_DIR + "/" + file_name)
			## 校验资源类型（防止误放其他资源导致崩溃）
			if resource is BulletShotPatternClass:
				_shot_pattern_pool.append(resource)
			else:
				push_warning("UpgradeManager: " + file_name + " 不是BulletShotPattern类型，已跳过")
		file_name = dir.get_next()
	dir.list_dir_end()
	print("UpgradeManager: 已加载 %d 种弹道构型" % _shot_pattern_pool.size())

## ========== 三选一抽取与选择流程 ==========

## 打开三选一选择面板（特效技能书拾取触发入口）
## 流程：抽取3个可用特效技能词条 → 显示紧凑底栏面板（不暂停游戏）→ 玩家选择 → 应用 → 关闭
## 语义：本面板只提供"特效技能"（bullet_effect非空），属性技能由 open_attribute_skill_choice 独立处理
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

	## 从词条池抽取3个可用特效技能词条（want_effect=true）
	var choices: Array = _roll_three_upgrades(true)
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

## ========== 护盾三选一抽取与选择流程 ==========

## 打开护盾三选一选择面板（拾取护盾掉落物的触发入口）
## 流程：随机抽3面护盾 → 显示紧凑底栏面板（不暂停游戏）→ 玩家选择 → 装备 → 关闭
## 队列设计：与技能三选一共用 is_choosing 锁；面板显示期间又拾取到护盾掉落物时排队，
##           当前面板关闭后自动展示下一组候选，避免连续弹出多个面板
func open_shield_choice() -> void:
	## 正在选择中：排队等待，不重复打开
	if is_choosing:
		_pending_shield_choices += 1
		return
	## 立即上锁（防止同帧多次触发），实际打开延迟到帧末
	is_choosing = true
	_do_open_shield_choice.call_deferred()

## 实际创建护盾选择面板（延迟一帧后执行，避开物理回调的当前帧）
func _do_open_shield_choice() -> void:
	## 延迟期间状态可能已变化（重开局/游戏结束）：is_choosing被重置则取消本次打开
	if not is_choosing:
		return
	## 延迟期间游戏可能已结束（玩家死亡）：取消本次护盾选择
	if GameManager.current_state == GameManager.GameState.GAME_OVER:
		is_choosing = false
		_pending_shield_choices = 0
		return

	## 从护盾池随机抽取候选护盾
	var choices: Array = _roll_shields()
	## 池子为空（未配置 data/equipment/*.tres）时跳过选择，不做任何暂停
	if choices.is_empty():
		is_choosing = false
		_process_pending()
		return

	## 不暂停游戏：玩家可边战斗边选择，紧凑底栏面板不影响游戏画面

	## 创建专用 CanvasLayer 作为面板父节点（独立 transform，面板始终位于屏幕底部）
	_overlay_layer = CanvasLayer.new()
	_overlay_layer.name = "ShieldChoiceOverlay"
	## layer=50 与技能三选一同级（在 HUD 和 StageDirector 之上，用户即时交互必须最显眼）
	_overlay_layer.layer = 50
	get_tree().root.add_child(_overlay_layer)

	## 创建护盾三选一面板（挂到 CanvasLayer 下）
	_panel = SHIELD_CHOICE_PANEL_SCRIPT.new()
	_overlay_layer.add_child(_panel)
	## 连接选择信号：玩家选定护盾后真正装备并关闭
	_panel.shield_chosen.connect(_on_shield_chosen)
	## 连接取消信号：玩家按B/ESC放弃本次三选一，直接关闭面板不装备护盾
	_panel.shield_cancelled.connect(_on_shield_cancelled)

	## 复用 LEVEL_UP_CHOICE 上下文：护盾三选一所需的放行输入与技能三选一完全一致
	## （移动/射击/交互保留 + LT/RT扳机/方向键导航 + A确认 + B取消），
	## push自带0.2s屏蔽期，防止拾取瞬间残留的交互键直接选中卡片
	InputManager.push_context("LEVEL_UP_CHOICE")

	## 初始化面板显示（传入候选护盾）
	_panel.setup(choices)

## 从护盾池随机抽取候选护盾（不重复）
## 返回：最多 SHIELD_CHOICE_COUNT 个ShieldEquipmentData数组（池子不足时返回实际数量）
func _roll_shields() -> Array:
	if _shield_pool.is_empty():
		return []
	## 复制一份池子用于抽取，抽中即移除，保证3个候选互不重复
	var pool: Array = _shield_pool.duplicate()
	var picks: Array = []
	var count: int = mini(SHIELD_CHOICE_COUNT, pool.size())
	for i in range(count):
		var idx: int = RandomManager.randi_range(0, pool.size() - 1)
		picks.append(pool[idx])
		pool.remove_at(idx)
	return picks

## 玩家选定护盾的回调（响应ShieldChoicePanel.shield_chosen）
## 参数：shield - 选定的护盾装备数据
func _on_shield_chosen(shield: Resource) -> void:
	## 交给玩家真正装备（同类型叠层/不同类型替换逻辑由 EquipmentShieldComponent 负责，保持不变）
	var player: Node2D = _get_player()
	if player != null and player.has_method("equip_shield"):
		player.equip_shield(shield)
	## 关闭面板
	_close_panel()
	## 处理排队中的三选一（技能/护盾）
	_process_pending()

## 玩家取消护盾三选一的回调（响应ShieldChoicePanel.shield_cancelled）
## 语义：放弃本次拾取——不装备任何护盾，直接关闭面板并解锁选择状态，
##       四类排队计数（特效技能/属性技能/护盾/构型）一并清零，
##       避免残留计数导致后续三选一"跳过"或"多跳"
func _on_shield_cancelled() -> void:
	_pending_upgrades = 0
	_pending_attribute_choices = 0
	_pending_shield_choices = 0
	_pending_shot_pattern_choices = 0
	_close_panel()
	is_choosing = false

## ========== 属性技能三选一抽取与选择流程 ==========

## 打开属性技能三选一选择面板（拾取属性技能书的触发入口）
## 流程：从属性词条中抽3个 → 显示紧凑底栏面板（不暂停游戏）→ 玩家选择 → 应用 → 关闭
## 说明：与特效技能三选一共用 is_choosing 锁、LEVEL_UP_CHOICE 上下文与 LevelUpPanel 面板，
##       仅候选池不同（只含属性词条，不含特效技能），保证"属性技能书只给属性技能"
func open_attribute_skill_choice() -> void:
	## 正在选择中：排队等待，不重复打开
	if is_choosing:
		_pending_attribute_choices += 1
		return
	## 立即上锁（防止同帧多次触发），实际打开延迟到帧末
	is_choosing = true
	_do_open_attribute_skill_choice.call_deferred()

## 实际创建属性技能选择面板（延迟一帧后执行，避开物理回调的当前帧）
func _do_open_attribute_skill_choice() -> void:
	## 延迟期间状态可能已变化（重开局/游戏结束）：is_choosing被重置则取消本次打开
	if not is_choosing:
		return
	## 延迟期间游戏可能已结束（玩家死亡）：取消本次属性技能选择
	if GameManager.current_state == GameManager.GameState.GAME_OVER:
		is_choosing = false
		_pending_attribute_choices = 0
		return

	## 只抽取属性词条（want_effect=false），与特效技能完全分离
	var choices: Array = _roll_three_upgrades(false)
	## 池子耗尽时跳过选择（直接放行，不做任何暂停）
	if choices.is_empty():
		is_choosing = false
		_process_pending()
		return

	## 不暂停游戏：玩家可边战斗边选择，紧凑底栏面板不影响游戏画面

	## 创建专用 CanvasLayer 作为面板父节点（独立 transform，面板始终位于屏幕底部）
	_overlay_layer = CanvasLayer.new()
	_overlay_layer.name = "AttributeSkillChoiceOverlay"
	## layer=50 与其余三选一同级（在 HUD 和 StageDirector 之上，用户即时交互必须最显眼）
	_overlay_layer.layer = 50
	get_tree().root.add_child(_overlay_layer)

	## 复用技能三选一面板：属性词条的图标/名称/等级展示方式与特效技能一致
	_panel = LEVEL_UP_PANEL_SCRIPT.new()
	_overlay_layer.add_child(_panel)
	## 连接选择信号：玩家选定属性词条后应用并关闭
	_panel.upgrade_chosen.connect(_on_attribute_skill_chosen)
	## 连接取消信号：玩家按B/ESC放弃本次三选一，直接关闭面板不应用词条
	_panel.upgrade_cancelled.connect(_on_attribute_skill_cancelled)

	## 复用 LEVEL_UP_CHOICE 上下文：所需放行输入与其余三选一完全一致
	InputManager.push_context("LEVEL_UP_CHOICE")

	## 初始化面板显示（传入候选属性词条）
	_panel.setup(choices)

## 玩家选定属性词条的回调（响应LevelUpPanel.upgrade_chosen）
## 参数：upgrade - 选定的属性词条数据
func _on_attribute_skill_chosen(upgrade: Resource) -> void:
	## 复用统一应用入口（层数记录/上限替换/属性累加逻辑与技能一致）
	apply_upgrade(upgrade)
	## 关闭面板
	_close_panel()
	## 处理排队中的三选一
	_process_pending()

## 玩家取消属性技能三选一的回调（响应LevelUpPanel.upgrade_cancelled）
## 语义：放弃本次拾取——不应用词条，四类排队计数一并清零后解锁
func _on_attribute_skill_cancelled() -> void:
	_pending_upgrades = 0
	_pending_attribute_choices = 0
	_pending_shield_choices = 0
	_pending_shot_pattern_choices = 0
	_close_panel()
	is_choosing = false

## ========== 弹道构型三选一抽取与选择流程 ==========

## 打开弹道构型三选一选择面板（拾取弹道构型书的触发入口）
## 流程：从构型池抽3个 → 显示紧凑底栏面板（不暂停游戏）→ 玩家选择 → 替换当前弹道 → 关闭
## 语义：区别于技能/属性/护盾的"叠层"，构型选定即整体替换玩家当前弹道（不叠层、无等级）
func open_shot_pattern_choice() -> void:
	## 正在选择中：排队等待，不重复打开
	if is_choosing:
		_pending_shot_pattern_choices += 1
		return
	## 立即上锁（防止同帧多次触发），实际打开延迟到帧末
	is_choosing = true
	_do_open_shot_pattern_choice.call_deferred()

## 实际创建弹道构型选择面板（延迟一帧后执行，避开物理回调的当前帧）
func _do_open_shot_pattern_choice() -> void:
	## 延迟期间状态可能已变化（重开局/游戏结束）：is_choosing被重置则取消本次打开
	if not is_choosing:
		return
	## 延迟期间游戏可能已结束（玩家死亡）：取消本次弹道构型选择
	if GameManager.current_state == GameManager.GameState.GAME_OVER:
		is_choosing = false
		_pending_shot_pattern_choices = 0
		return

	## 从构型池随机抽取候选构型
	var choices: Array = _roll_shot_patterns()
	## 池子为空（未配置 data/bullet/pattern/*.tres）时跳过选择，不做任何暂停
	if choices.is_empty():
		is_choosing = false
		_process_pending()
		return

	## 不暂停游戏：玩家可边战斗边选择，紧凑底栏面板不影响游戏画面

	## 创建专用 CanvasLayer 作为面板父节点（独立 transform，面板始终位于屏幕底部）
	_overlay_layer = CanvasLayer.new()
	_overlay_layer.name = "ShotPatternChoiceOverlay"
	## layer=50 与其余三选一同级（在 HUD 和 StageDirector 之上，用户即时交互必须最显眼）
	_overlay_layer.layer = 50
	get_tree().root.add_child(_overlay_layer)

	## 创建弹道构型三选一面板（挂到 CanvasLayer 下）
	_panel = SHOT_PATTERN_CHOICE_PANEL_SCRIPT.new()
	_overlay_layer.add_child(_panel)
	## 连接选择信号：玩家选定构型后真正替换弹道并关闭
	_panel.shot_pattern_chosen.connect(_on_shot_pattern_chosen)
	## 连接取消信号：玩家按B/ESC放弃本次三选一，直接关闭面板不改变弹道
	_panel.shot_pattern_cancelled.connect(_on_shot_pattern_cancelled)

	## 复用 LEVEL_UP_CHOICE 上下文：所需放行输入与其余三选一完全一致
	InputManager.push_context("LEVEL_UP_CHOICE")

	## 初始化面板显示（传入候选构型）
	_panel.setup(choices)

## 从弹道构型池随机抽取候选构型（不重复，且排除当前已装备的构型）
## 返回：最多 SHOT_PATTERN_CHOICE_COUNT 个BulletShotPattern数组（池子不足时返回实际数量）
## 排除理由：构型单槽位、不叠层、无等级——选中已装备的那一种等于什么都没变（重复获得
##          不会像词条那样升级），属于无效候选，故从池中剔除后再抽；剔除后为空则退回完整池兜底
func _roll_shot_patterns() -> Array:
	if _shot_pattern_pool.is_empty():
		return []
	## 复制一份池子用于抽取，抽中即移除，保证候选互不重复
	var pool: Array = _shot_pattern_pool.duplicate()
	var owned_id: String = _get_owned_pattern_id()
	if not owned_id.is_empty():
		var filtered: Array = []
		for pattern in pool:
			if pattern != null and str(pattern.pattern_id) == owned_id:
				continue
			filtered.append(pattern)
		## 兜底：池中仅此一种时不能返回空候选，否则拾取构型书将无法弹出面板
		if not filtered.is_empty():
			pool = filtered
	var picks: Array = []
	var count: int = mini(SHOT_PATTERN_CHOICE_COUNT, pool.size())
	for i in range(count):
		var idx: int = RandomManager.randi_range(0, pool.size() - 1)
		picks.append(pool[idx])
		pool.remove_at(idx)
	return picks

## 读取玩家当前已装备构型的 pattern_id（未装备/无玩家时返回空串）
## 说明：按 pattern_id 比对而非资源引用——玩家处持有的是私有子弹副本里的引用，
##       用 ID 比对可避免深拷贝导致引用不同而漏排除
func _get_owned_pattern_id() -> String:
	var player: Node2D = _get_player()
	if player == null or not player.has_method("get_shot_pattern"):
		return ""
	var owned: Resource = player.get_shot_pattern()
	if owned == null:
		return ""
	return str(owned.pattern_id)

## 玩家选定弹道构型的回调（响应ShotPatternChoicePanel.shot_pattern_chosen）
## 参数：pattern - 选定的弹道构型资源
func _on_shot_pattern_chosen(pattern: Resource) -> void:
	## 交给玩家替换当前弹道（构型不叠层，选定即生效）
	var player: Node2D = _get_player()
	if player != null and player.has_method("equip_shot_pattern"):
		player.equip_shot_pattern(pattern)
	## 关闭面板
	_close_panel()
	## 处理排队中的三选一
	_process_pending()

## 玩家取消弹道构型三选一的回调（响应ShotPatternChoicePanel.shot_pattern_cancelled）
## 语义：放弃本次拾取——不改变弹道，四类排队计数一并清零后解锁
func _on_shot_pattern_cancelled() -> void:
	_pending_upgrades = 0
	_pending_attribute_choices = 0
	_pending_shield_choices = 0
	_pending_shot_pattern_choices = 0
	_close_panel()
	is_choosing = false

## 从词条池按稀有度加权抽取3个不重复的可用词条（按类别过滤）
## 参数：want_effect - true 只抽特效技能词条（bullet_effect非空）；false 只抽属性词条
## 过滤规则：
##   1. 叠加层数未达上限（全局统一5级，满级词条不再出现）
##   2. 类别匹配：is_effect_upgrade() == want_effect（特效技能与属性技能完全分离）
## 说明：特效词条重复获得时按effect_id去重（不重复挂载），改为调用已拥有特效实例的
##       add_stack() 叠层成长——每级放大该特效的关键参数（成长策略见各特效子类
##       _on_stack_grown），与属性词条一样遵循5级上限规则
## 返回：最多3个UpgradeData数组（池子不足时返回实际数量）
func _roll_three_upgrades(want_effect: bool) -> Array:
	## 第一步：过滤出当前可用词条（层数未满 + 类别匹配）
	var available: Array = []
	for upgrade in _upgrade_pool:
		## 类别过滤：特效技能书只给特效词条、属性技能书只给属性词条，二者互不混入
		if upgrade.is_effect_upgrade() != want_effect:
			continue
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
##       四类排队计数（特效技能/属性技能/护盾/构型）一并清零，
##       避免残留计数导致后续升级被"跳过"或"多跳"。
func _on_upgrade_cancelled() -> void:
	_pending_upgrades = 0
	_pending_attribute_choices = 0
	_pending_shield_choices = 0
	_pending_shot_pattern_choices = 0
	_close_panel()
	is_choosing = false

## 处理排队三选一：依次消化 特效技能 → 属性技能 → 护盾 → 弹道构型；均无排队则解锁
## 链路：任一三选一面板关闭（选定/取消）后调用，实现"当前面板关闭后再展示下一组选项"
func _process_pending() -> void:
	if _pending_upgrades > 0:
		## 还有排队的特效技能，展示下一组词条选项（is_choosing保持true）
		_pending_upgrades -= 1
		_do_open_level_up_choice.call_deferred()
		return
	if _pending_attribute_choices > 0:
		## 特效技能已清空，还有排队的属性技能选择，展示下一组属性选项
		_pending_attribute_choices -= 1
		_do_open_attribute_skill_choice.call_deferred()
		return
	if _pending_shield_choices > 0:
		## 词条类已清空，还有排队的护盾选择，展示下一组护盾选项
		_pending_shield_choices -= 1
		_do_open_shield_choice.call_deferred()
		return
	if _pending_shot_pattern_choices > 0:
		## 护盾已清空，还有排队的弹道构型选择，展示下一组构型选项
		_pending_shot_pattern_choices -= 1
		_do_open_shot_pattern_choice.call_deferred()
		return
	## 无排队，解锁选择状态
	is_choosing = false

## 关闭并销毁选择面板（连同 CanvasLayer 一起清理；特效技能/属性技能/护盾/构型三选一共用）
func _close_panel() -> void:
	## 条件注销选择上下文：仅当栈顶确实是本面板上下文时才pop。
	## 跨场景重开（Main.reset_context）后栈已被重置，无条件pop会破坏新栈。
	## 四类三选一均复用 LEVEL_UP_CHOICE 上下文，故此处判断对四类面板同时生效
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

## 随机强化一个已拥有的"技能类"词条（神庙"强化技能"选项用，替代旧的"随机技能"）
## 规则：从已持有的特效词条（技能类，bullet_effect 非空）中随机选一个，等级 +amount（1~3）级；
##       突破5级上限（满级5级后继续强化，理论最高可到8级）；
##       只针对技能类，不再包含属性类（属性类由 boost_random_attribute 单独强化）
## 返回：是否强化成功（无已持有特效技能时返回 false，神庙保留不消失）
func boost_random_skill(amount: int) -> bool:
	if amount <= 0:
		return false
	## 收集当前已持有的真实特效技能（仅词条池技能且为特效类，排除神庙临时词条与属性类）
	var held_ids: Array = []
	for uid in _upgrade_stacks.keys():
		var u: Resource = _find_upgrade_by_id(uid)
		if u != null and u.is_effect_upgrade():
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

## 随机强化一个已拥有的"属性类"词条（神庙"强化属性"选项用）
## 规则：从已持有的属性词条（bullet_effect 为空）中随机选一个，等级 +amount 级；
##       突破5级上限（满级后继续强化）；
##       只针对属性类，与技能类各自独立
## 返回：是否强化成功（无已持有属性技能时返回 false，神庙保留不消失）
func boost_random_attribute(amount: int) -> bool:
	if amount <= 0:
		return false
	## 收集当前已持有的真实属性词条（仅词条池技能且为属性类）
	var held_ids: Array = []
	for uid in _upgrade_stacks.keys():
		var u: Resource = _find_upgrade_by_id(uid)
		if u != null and not u.is_effect_upgrade():
			held_ids.append(uid)
	if held_ids.is_empty():
		return false
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

## ========== 神庙强化碎片消耗（累加计价） ==========

## 获取当前神庙强化的消耗碎片数（累加：第1次400、第2次500、第3次600……）
## 返回：本次强化需消耗的碎片数
func get_temple_boost_cost() -> int:
	return TEMPLE_BOOST_BASE_COST + _temple_boost_count * TEMPLE_BOOST_COST_STEP

## 是否有可强化的技能类词条（"强化技能"选项预检查用）
## 返回：true=存在已持有的特效技能
func has_boostable_skill() -> bool:
	for uid in _upgrade_stacks.keys():
		var u: Resource = _find_upgrade_by_id(uid)
		if u != null and u.is_effect_upgrade():
			return true
	return false

## 是否有可强化的属性类词条（"强化属性"选项预检查用）
## 返回：true=存在已持有的属性词条
func has_boostable_attribute() -> bool:
	for uid in _upgrade_stacks.keys():
		var u: Resource = _find_upgrade_by_id(uid)
		if u != null and not u.is_effect_upgrade():
			return true
	return false

## 尝试扣除神庙强化的碎片（累加计价）
## 规则：扣除成功后才递增计数（失败不计数，神庙保留可重试）
## 参数：player - 玩家节点
## 返回：true=扣除成功，false=碎片不足或玩家无效
func consume_temple_boost(player: Node) -> bool:
	if player == null or not player.has_method("spend_dream_fragment"):
		return false
	var cost: int = get_temple_boost_cost()
	if not player.spend_dream_fragment(cost):
		return false
	_temple_boost_count += 1
	return true

## ========== 神庙"融合技能" ==========

## 判断当前是否具备融合条件（已持有至少2个技能类词条）
## 用途：FuseSkillTempleOption 的 can_select 预检查（碎片足够但技能不足时同样置灰）
## 返回：true=可融合（已持有≥2个特效技能）
func can_fuse_skills() -> bool:
	var held_count: int = 0
	for uid in _upgrade_stacks.keys():
		var u: Resource = _find_upgrade_by_id(uid)
		if u != null and u.is_effect_upgrade():
			held_count += 1
	return held_count >= 2

## 随机融合两个已拥有的"技能类"词条（神庙"融合技能"选项用）
## 规则：
##   1. 从已持有的特效技能中随机选两个不同的 A、B；
##   2. 融合等级 = max(A等级, B等级)（等级取两个中较高的）；
##   3. 效果叠加：两个特效都保留生效，且都提升到融合等级；
##   4. 上限等级依赖融合时取值（不再受 max_stacks 约束，也不会再被"强化技能"强化——
##      源技能已从词条栈移除，boost_random_skill 不会再选中它们）；
##   5. 玩家身上只允许一个融合技能：再次融合会先撤销旧融合技能再生成新的。
## 返回：是否融合成功（已持有特效技能不足2个时返回 false，神庙保留不消失）
func fuse_random_skills() -> bool:
	## 收集当前已持有的特效技能（仅词条栈中的，融合技能不在此处）
	var held_ids: Array = []
	for uid in _upgrade_stacks.keys():
		var u: Resource = _find_upgrade_by_id(uid)
		if u != null and u.is_effect_upgrade():
			held_ids.append(uid)
	if held_ids.size() < 2:
		return false

	## 随机抽两个不同的技能
	var idx_a: int = RandomManager.randi_range(0, held_ids.size() - 1)
	var idx_b: int = RandomManager.randi_range(0, held_ids.size() - 2)
	if idx_b >= idx_a:
		idx_b += 1
	var upgrade_a: Resource = _find_upgrade_by_id(String(held_ids[idx_a]))
	var upgrade_b: Resource = _find_upgrade_by_id(String(held_ids[idx_b]))
	if upgrade_a == null or upgrade_b == null:
		return false

	## 融合等级 = 两者较高等级
	var level_a: int = int(_upgrade_stacks.get(upgrade_a.upgrade_id, 0))
	var level_b: int = int(_upgrade_stacks.get(upgrade_b.upgrade_id, 0))
	var fuse_level: int = maxi(level_a, level_b)

	## 撤销旧融合技能（若有），保证玩家身上只有一个融合技能
	_clear_fused_skill()

	## 记录新融合技能
	_fused_skill = {
		"a_id": upgrade_a.upgrade_id,
		"b_id": upgrade_b.upgrade_id,
		"level": fuse_level,
	}

	## 从词条栈移除源技能：释放技能格子，且不再被"强化技能"选中
	_upgrade_stacks.erase(upgrade_a.upgrade_id)
	_upgrade_stacks.erase(upgrade_b.upgrade_id)

	## 两个特效都提升到融合等级（效果叠加，等级取高）
	_set_effect_to_level(upgrade_a, fuse_level)
	_set_effect_to_level(upgrade_b, fuse_level)

	## 统计与广播
	RunStats.add_upgrade_taken()
	upgrades_changed.emit(get_acquired_upgrades())
	upgrade_applied.emit(upgrade_a)
	return true

## 撤销当前融合技能：移除其两个源特效实例（第二次融合替换前一个时调用）
func _clear_fused_skill() -> void:
	if _fused_skill.is_empty():
		return
	var player: Node2D = _get_player()
	var a: Resource = _find_upgrade_by_id(String(_fused_skill.get("a_id", "")))
	var b: Resource = _find_upgrade_by_id(String(_fused_skill.get("b_id", "")))
	if player != null and player.has_method("remove_bullet_effect"):
		if a != null and a.bullet_effect != null and "effect_id" in a.bullet_effect:
			player.remove_bullet_effect(a.bullet_effect.effect_id)
		if b != null and b.bullet_effect != null and "effect_id" in b.bullet_effect:
			player.remove_bullet_effect(b.bullet_effect.effect_id)
	_fused_skill = {}

## 将指定特效实例提升到目标等级（融合技能用）
## 参数：upgrade - 源技能词条；target_level - 目标等级（融合等级）
func _set_effect_to_level(upgrade: Resource, target_level: int) -> void:
	if upgrade == null or upgrade.bullet_effect == null:
		return
	var player: Node2D = _get_player()
	if player == null or not player.has_method("set_bullet_effect_level"):
		return
	player.set_bullet_effect_level(upgrade.bullet_effect.effect_id, target_level)

## 查询当前融合技能信息（供 HUD/状态面板展示，空字典=无融合技能）
func get_fused_skill() -> Dictionary:
	return _fused_skill

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
