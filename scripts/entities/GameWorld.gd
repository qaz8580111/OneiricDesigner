## GameWorld.gd - 游戏世界管理脚本
## 职责：管理敌人生成、子弹创建、道具掉落、玩家交互等核心游戏逻辑
## 继承：Node2D（Godot 4的2D节点，作为游戏世界容器）
## 节点结构：GameWorld(Node2D, 由Main._spawn_game_elements实例化) → 运行时动态挂载 Player/Enemy/Bullet/PickUp
## 系统交互：
##   - 信号：player.shot → 创建子弹；enemy.killed/drops_generated → 移除计数/生成拾取物；
##           bullet.destroyed → 管理列表移除；DifficultyManager.wave_started → 敌潮批量刷怪
##   - 组：从"player"组查找玩家；给敌人加"enemy"/"normal_enemy"/"elite_enemy"组
##   - 单例：DifficultyManager(难度缩放/动态上限)、InputManager(E键拾取)、RandomManager(随机)、RunStats(统计)
## 数据流：_process计时刷怪(屏幕四边外随机点) → 敌人AI移动/射击 → 子弹命中 → 死亡掉落 → PickUp吸附/手动拾取 → 玩家成长
## 设计意图：实体管理中枢——持有全部实体列表(_enemies/_bullets/_pickups)负责生成、信号路由与清理；
##           实体间不互相持有引用，靠组与信号松耦合通信
extends Node2D

## ========== 预加载资源（避免运行时加载延迟） ==========

## 子弹数据资源类，用于配置子弹属性（伤害、速度、形态、特效等）
const BulletDataClass = preload("res://scripts/resources/bullet/BulletData.gd")

## 敌人数据资源类，用于配置敌人属性
const EnemyDataClass = preload("res://scripts/resources/enemy/EnemyData.gd")

## 掉落道具数据资源类，用于配置道具属性和效果
const DropItemClass = preload("res://scripts/resources/enemy/DropItem.gd")

## 主题包资源类（ThemeManager.theme_changed 信号的负载类型）
const GameThemeClass = preload("res://scripts/resources/skin/GameTheme.gd")

## 神庙场景预加载（高级怪死亡后概率生成）
const TEMPLE_SCENE: PackedScene = preload("res://scenes/gameplay/Temple.tscn")

## 中央商店脚本预加载（5分钟后在竞技场中心生成，永久存在；纯脚本实例化，无.tscn）
const SHOP_SCRIPT = preload("res://scripts/entities/Shop.gd")

## 竞技场尺寸/碰撞层/边缘预警常量（墙坐标、刷怪钳制、红光距离的单一数据源）
const ArenaConfigClass = preload("res://scripts/world/ArenaConfig.gd")

## ========== 敌人数据池预加载（18种敌人，带权重） ==========
## 键：敌人数据资源路径，值：生成权重（权重越大越常见）
const ENEMY_POOL: Dictionary = {
	"res://data/enemy/slime_data.tres":      15,  # 史莱姆 - 最常见
	"res://data/enemy/goblin_data.tres":     14,  # 哥布林 - 常见
	"res://data/enemy/bat_data.tres":        13,  # 蝙蝠 - 常见
	"res://data/enemy/scout_data.tres":      10,  # 快速斥候
	"res://data/enemy/skeleton_data.tres":   10,  # 骷髅
	"res://data/enemy/spider_data.tres":      8,  # 毒蜘蛛
	"res://data/enemy/archer_data.tres":      7,  # 骷髅弓手
	"res://data/enemy/ghoul_data.tres":       6,  # 食尸鬼
	"res://data/enemy/wraith_data.tres":      5,  # 幽灵
	"res://data/enemy/firemage_data.tres":    4,  # 火焰法师
	"res://data/enemy/bomber_data.tres":      4,  # 自爆僵尸
	"res://data/enemy/thundermage_data.tres": 3,  # 闪电法师
	"res://data/enemy/hunter_data.tres":      3,  # 虚空猎人
	"res://data/enemy/sniper_data.tres":      2,  # 长弓狙击手
	"res://data/enemy/rocketeer_data.tres":   2,  # 火箭兵
	"res://data/enemy/knight_data.tres":      2,  # 黑暗骑士
	"res://data/enemy/tank_data.tres":        1,  # 石头傀儡 - 最稀有
}

## ========== 运行时缓存的敌人数据 ==========
var _enemy_pool_data: Array[EnemyDataClass] = []
var _enemy_pool_weights: Array[float] = []
var _enemy_pool_total_weight: float = 0.0

## ========== 导出变量（编辑器可配置） ==========

## 敌人生成间隔（秒），控制敌人出现频率
@export var enemy_spawn_interval: float = 2.0

## 屏幕上同时存在的最大敌人数（基础值），防止敌人过多导致性能问题
## 实际上限由 DifficultyManager.get_max_enemies() 按难度递增，10级封顶于100只
@export var max_enemies: int = 70

## ========== 精英怪配置 ==========

## 精英怪生成间隔（秒），比普通怪更长
@export var elite_spawn_interval: float = 15.0

## 屏幕上同时存在的最大精英怪数
@export var max_elite_enemies: int = 3

## 精英怪数据资源（配置精英怪的属性、掉落等）
@export var elite_enemy_data: EnemyDataClass = null

## ========== 刷怪总开关（终极关卡用） ==========

## 常规刷怪总开关：false = 暂停一切常规刷怪（普通/精英/波次/直播事件）
## 设计意图：终极关卡需要"清场后只面对终极 BOSS"，业务刷怪链路必须整体静默；
##          仅在 _spawn_enemy() 咽喉点拦截，切面自建实体（StageDirector 直接 add_child）不受影响
var spawning_enabled: bool = true

## ========== 中央商店配置 ==========

## 商店出现时间（秒）：游戏进行满 5 分钟后在竞技场中心生成，之后永久存在不消失
const SHOP_SPAWN_TIME: float = 300.0

## ========== 节点引用（使用 @onready 延迟初始化） ==========

## 玩家引用，用于传递给敌人生成时使用
@onready var player: CharacterBody2D = null

## 边界红色预警遮罩（距墙<200px时由_process推高modulate.alpha）
@onready var _edge_warning_rect: TextureRect = $VignetteLayer/EdgeWarning

## 常驻黑色暗角遮罩（纹理在_ready中代码生成，静态不变）
@onready var _dark_vignette_rect: TextureRect = $VignetteLayer/DarkVignette

## 红色预警当前alpha（向目标值平滑插值，避免突现/突灭）
var _edge_warning_alpha: float = 0.0

## ========== 场景预加载（避免运行时重复加载） ==========

## 子弹场景预加载
var BULLET_SCENE: PackedScene = preload("res://scenes/gameplay/Bullet.tscn")

## 敌人场景预加载
var ENEMY_SCENE: PackedScene = preload("res://scenes/gameplay/Enemy.tscn")

## 拾取物场景预加载
var PICKUP_SCENE: PackedScene = preload("res://scenes/gameplay/PickUp.tscn")

## ========== 配置数据 ==========

## 默认子弹数据（玩家发射子弹时使用），可在编辑器中覆盖
@export var default_bullet_data: BulletDataClass = null

## ========== 成员变量（运行时数据） ==========

## 敌人生成计时器，递减到0时生成新敌人
var _spawn_timer: float = 0.0

## 当前场景中存活的敌人数
var _enemy_count: int = 0

## 场景中所有敌人的管理列表
var _enemies: Array[CharacterBody2D] = []

## 场景中所有子弹的管理列表
var _bullets: Array[Area2D] = []

## 场景中所有拾取物的管理列表
var _pickups: Array[Area2D] = []

## 场景中所有神庙的管理列表（高级怪死亡概率生成，交互后消失）
var _temples: Array[Area2D] = []

## 中央商店节点（全局唯一，5分钟后生成，永久存在）
var _shop: Area2D = null

## 商店是否已生成（防止每帧重复生成）
var _shop_spawned: bool = false

## ========== 精英怪成员变量 ==========

## 精英怪生成计时器，递减到0时生成新精英怪
var _elite_spawn_timer: float = 0.0

## 当前场景中存活的精英怪数
var _elite_enemy_count: int = 0

## ========== 信号定义（用于与其他节点通信） ==========

## 游戏结束时发出此信号（玩家死亡）
signal game_over()

## ========== 生命周期方法 ==========

## _ready() - 节点进入场景树时调用一次，用于初始化
func _ready() -> void:
	## 如果默认子弹数据为空，创建默认子弹数据
	if default_bullet_data == null:
		default_bullet_data = BulletDataClass.new()
	
	## 初始化精英怪数据（如果配置了精英怪但没有数据，创建默认精英怪数据）
	_initialize_elite_enemy_data()
	
	## 初始化敌人池（加载所有敌人数据，为随机生成做准备）
	_initialize_enemy_pool()
	
	## 查找玩家并连接信号
	_find_player()

	## ========== 主题系统接入（背景色随主题切换） ==========
	## 启动时应用当前主题的世界背景色（无主题时保持场景默认深灰蓝）
	if ThemeManager and ThemeManager.current_theme != null:
		_apply_theme_background(ThemeManager.current_theme)
	## 监听主题热切换：设置界面换主题时背景即时跟随（无需重开局）
	if ThemeManager and not ThemeManager.theme_changed.is_connected(_on_theme_changed):
		ThemeManager.theme_changed.connect(_on_theme_changed)

	## 监听难度波次信号：敌潮事件触发时批量刷怪（趣味性/高压时刻）
	## 数据流：DifficultyManager难度升级 → wave_started信号 → 此回调 → 波次刷怪
	if DifficultyManager:
		DifficultyManager.wave_started.connect(_on_wave_started)

	## ========== 直播互动系统接入 ==========
	## 连接 LiveBridgeManager 信号：直播事件（进房/弹幕/礼物）→ 生成敌人
	## 数据流：B站WSS → 桥接进程(Node.js) → LiveBridgeManager(autoload) → 信号 → 此回调 → 刷怪
	## 判空保护：LiveBridgeManager 可能未注册或被禁用，此时游戏照常运行（纯离线模式）
	if LiveBridgeManager:
		## 游客进入直播间 → 生成弱敌（默认史莱姆）
		LiveBridgeManager.viewer_entered.connect(_on_live_viewer_entered)
		## 收到弹幕 → 仅通知（默认不生成敌人，可扩展为弹幕显示/关键词触发）
		LiveBridgeManager.danmu_received.connect(_on_live_danmu)
		## 收到礼物 → 按礼物价值/名称生成对应强度的敌人
		LiveBridgeManager.gift_received.connect(_on_live_gift)
		## 清空上一局残留的事件队列（防止重开局时旧事件涌入）
		LiveBridgeManager.clear_queue()

	## 代码生成暗角渐变纹理（常驻黑暗角 + 边界红色预警，无需任何美术资源）
	_setup_vignette_textures()

## ========== 主题背景应用（视差三层：纯色底 + 可选远景平铺图 + 1:1网格层） ==========

## 应用主题的世界外观（启动/主题切换时调用）
## 数据流：GameTheme.bg_color → BgLayer/Background(ColorRect)
##         GameTheme.bg_texture → BgLayer/BgTexture(TextureRect平铺，null则隐藏)
##         GameTheme.grid_color/grid_major_color → ArenaBackground/ParallaxSetup(Layer2网格shader)
## 参数：theme - 主题包资源（含背景色/网格色/可选背景纹理）
func _apply_theme_background(theme: GameThemeClass) -> void:
	## 主题缺失时静默跳过（保持场景默认外观，绝不因主题系统崩溃）
	if theme == null:
		return
	## 1) 纯色底（同步背景色；引擎清屏色已由 ThemeManager 统一设置，双重保险不露灰底）
	var bg_rect: ColorRect = get_node_or_null("BgLayer/Background")
	if bg_rect != null:
		bg_rect.color = theme.bg_color
	## 2) 可选远景平铺图：有纹理→显示并注入（TextureRect自身配置为TILE+repeat），无纹理→隐藏
	var bg_tex_rect: TextureRect = get_node_or_null("BgLayer/BgTexture")
	if bg_tex_rect != null:
		bg_tex_rect.texture = theme.bg_texture
		bg_tex_rect.visible = theme.bg_texture != null
	## 3) 视差Layer2网格（与世界1:1移动的参照物）：经ParallaxSetup门面注入shader配色
	var parallax: ParallaxBackground = get_node_or_null("ArenaBackground")
	if parallax != null and parallax.has_method("set_grid_colors"):
		parallax.set_grid_colors(theme.grid_color, theme.grid_major_color)

## 主题切换回调（ThemeManager.theme_changed）：背景即时跟随新主题
func _on_theme_changed(theme: GameThemeClass) -> void:
	_apply_theme_background(theme)

## ========== 屏幕暗角与边界红光（纯代码纹理，零美术资源） ==========

## 生成两张径向渐变纹理并挂到VignetteLayer：常驻黑暗角 + 边界红色预警
## GradientTexture2D(FILL_RADIAL)以纹理中心为圆心，圆外自动保持末色→四角也被覆盖
func _setup_vignette_textures() -> void:
	## ---- 常驻轻微黑暗角：提升画面纵深，中心透明、四边alpha最高约0.4 ----
	var dark_gradient := Gradient.new()
	dark_gradient.set_color(0, Color(0.0, 0.0, 0.0, 0.0))
	dark_gradient.add_point(0.68, Color(0.0, 0.0, 0.0, 0.0))
	dark_gradient.set_color(dark_gradient.get_point_count() - 1, Color(0.0, 0.0, 0.0, 0.4))
	var dark_texture := GradientTexture2D.new()
	dark_texture.gradient = dark_gradient
	dark_texture.width = 256   ## 256小图拉伸全屏即可，渐变是连续信号无锯齿
	dark_texture.height = 256
	dark_texture.fill = GradientTexture2D.FILL_RADIAL
	dark_texture.fill_from = Vector2(0.5, 0.5)  ## 圆心：屏幕中心
	dark_texture.fill_to = Vector2(0.5, 0.0)    ## 半径：到纹理顶边（四角落圆外保持末色）
	_dark_vignette_rect.texture = dark_texture

	## ---- 边界红色预警：中心透明，90%半径处开始泛红，边缘alpha最高约0.85 ----
	## 最终屏幕alpha由EdgeWarning.modulate.a二次控制（贴墙也不超过WARN_MAX_ALPHA=0.5）
	var red_gradient := Gradient.new()
	red_gradient.set_color(0, Color(1.0, 0.05, 0.0, 0.0))
	red_gradient.add_point(0.62, Color(1.0, 0.05, 0.0, 0.0))
	red_gradient.add_point(0.9, Color(1.0, 0.08, 0.05, 0.55))
	red_gradient.set_color(red_gradient.get_point_count() - 1, Color(1.0, 0.1, 0.08, 0.85))
	var red_texture := GradientTexture2D.new()
	red_texture.gradient = red_gradient
	red_texture.width = 256
	red_texture.height = 256
	red_texture.fill = GradientTexture2D.FILL_RADIAL
	red_texture.fill_from = Vector2(0.5, 0.5)
	red_texture.fill_to = Vector2(0.5, 0.0)
	_edge_warning_rect.texture = red_texture
	_edge_warning_rect.modulate.a = 0.0

## 每帧更新边界红光：计算玩家到最近一面物理墙的距离，<200px时线性推高红色alpha
## 参数：delta - 帧间隔（秒），用于alpha平滑速率（每秒最多变化2.0）
func _update_edge_warning(delta: float) -> void:
	## 玩家未就绪/已释放时跳过（重开局窗口期）
	if player == null or not is_instance_valid(player):
		return
	var p: Vector2 = player.global_position
	## 到左/右/上/下四面墙的距离取最小值（竞技场以原点为中心）
	var dist_x: float = minf(p.x + ArenaConfigClass.HALF_WIDTH, ArenaConfigClass.HALF_WIDTH - p.x)
	var dist_y: float = minf(p.y + ArenaConfigClass.HALF_HEIGHT, ArenaConfigClass.HALF_HEIGHT - p.y)
	var dist_to_wall: float = minf(dist_x, dist_y)
	## 进入预警距离：贴墙→0.5，200px处→0，线性过渡
	var target_alpha: float = 0.0
	if dist_to_wall < ArenaConfigClass.WARN_DISTANCE:
		target_alpha = (1.0 - dist_to_wall / ArenaConfigClass.WARN_DISTANCE) \
				* ArenaConfigClass.WARN_MAX_ALPHA
	## 向目标值平滑逼近（每秒2.0档变化率，约0.25秒完成淡入淡出）
	_edge_warning_alpha = move_toward(_edge_warning_alpha, target_alpha, delta * 2.0)
	_edge_warning_rect.modulate.a = _edge_warning_alpha

## ========== 敌人池初始化 ==========

## 初始化敌人池：加载所有敌人的tres数据，缓存权重
func _initialize_enemy_pool() -> void:
	_enemy_pool_data.clear()
	_enemy_pool_weights.clear()
	_enemy_pool_total_weight = 0.0
	
	for path in ENEMY_POOL.keys():
		var weight: float = float(ENEMY_POOL[path])
		if weight <= 0:
			continue
		## 加载资源
		var enemy_data: EnemyDataClass = load(path)
		if enemy_data != null:
			_enemy_pool_data.append(enemy_data)
			_enemy_pool_total_weight += weight
			_enemy_pool_weights.append(_enemy_pool_total_weight)

## 从敌人池中按权重随机选择一种敌人数据
## 算法：权重前缀和——_enemy_pool_weights[i]存前i+1项累积权重，r∈[0,总权重)落在哪段即选哪种
##       （权重大的敌人占区间更宽，被选概率更高）；池容量小，O(n)线性扫描即可
## 返回：随机选择的EnemyData；池子为空则返回null
func _pick_random_enemy_data() -> EnemyDataClass:
	if _enemy_pool_data.is_empty() or _enemy_pool_total_weight <= 0:
		return null
	var r: float = randf() * _enemy_pool_total_weight
	for i in range(_enemy_pool_weights.size()):
		if r <= _enemy_pool_weights[i]:
			return _enemy_pool_data[i]
	return _enemy_pool_data[_enemy_pool_data.size() - 1]

## ========== 玩家查找与信号连接 ==========

## 初始化精英怪数据（如果配置了精英怪但没有数据，创建默认精英怪数据）
func _initialize_elite_enemy_data() -> void:
	## 如果已经配置了精英怪数据，直接使用
	if elite_enemy_data != null:
		return
	
	## 创建默认精英怪数据
	elite_enemy_data = EnemyDataClass.new()
	elite_enemy_data.enemy_id = "elite_default"
	elite_enemy_data.enemy_name = "Elite Enemy"
	elite_enemy_data.speed = 180.0
	elite_enemy_data.wander_speed = 100.0
	elite_enemy_data.wander_interval = 3.0
	elite_enemy_data.max_health = 20
	elite_enemy_data.damage = 12
	elite_enemy_data.detection_range = 500.0
	elite_enemy_data.attack_range = 200.0
	elite_enemy_data.attack_cooldown = 1.5
	elite_enemy_data.placeholder_color = Color(1, 0.5, 0, 1)
	elite_enemy_data.placeholder_size = Vector2(36, 36)
	elite_enemy_data.is_elite = true
	elite_enemy_data.elite_prefix = "★"
	
	## 添加随机掉落道具
	_add_elite_drops()

## 为精英怪添加随机掉落道具
func _add_elite_drops() -> void:
	if elite_enemy_data == null:
		return
	
	## 创建大型梦境碎片掉落（50%概率掉落；碎片类型默认自动吸附，auto_adsorb=false 不改变类型默认）
	var fragment_drop: DropItemClass = DropItemClass.new()
	fragment_drop.item_id = "elite_fragment"
	fragment_drop.item_name = "Large Dream Fragment"
	fragment_drop.item_type = DropItemClass.ItemType.DREAM_FRAGMENT
	fragment_drop.value = 20
	fragment_drop.drop_chance = 0.5
	fragment_drop.is_rare = false
	fragment_drop.auto_adsorb = false
	elite_enemy_data.drop_items.append(fragment_drop)

	## 创建大型回血道具掉落（30%概率掉落；血包类型默认自动吸附，auto_adsorb=false 不改变类型默认）
	var health_drop: DropItemClass = DropItemClass.new()
	health_drop.item_id = "elite_health"
	health_drop.item_name = "Large Health Pack"
	health_drop.item_type = DropItemClass.ItemType.HEALTH
	health_drop.value = 30
	health_drop.drop_chance = 0.3
	health_drop.is_rare = false
	health_drop.auto_adsorb = false
	elite_enemy_data.drop_items.append(health_drop)

	## 创建攻击增益道具（技能宝石）掉落（15%概率掉落，稀有；BUFF类型默认手动按E拾取，
	## 拾取后打开三选一面板由玩家自选词条）
	var buff_drop: DropItemClass = DropItemClass.new()
	buff_drop.item_id = "elite_buff_attack"
	buff_drop.item_name = "Power Boost"
	buff_drop.item_type = DropItemClass.ItemType.BUFF
	buff_drop.value = 5
	buff_drop.drop_chance = 0.15
	buff_drop.is_rare = true
	buff_drop.auto_adsorb = false
	elite_enemy_data.drop_items.append(buff_drop)

## 查找玩家并连接相关信号
func _find_player() -> void:
	## 从"player"组查找玩家
	var players: Array[Node] = get_tree().get_nodes_in_group("player")
	if players.size() > 0:
		player = players[0] as CharacterBody2D
		
		## 连接玩家射击信号：当玩家发射子弹时触发回调
		if player.has_signal("shot"):
			player.connect("shot", _on_player_shot)
		
		## 连接玩家死亡信号：优先连接player.killed，否则连接HealthController.player_died
		if player.has_signal("killed"):
			player.connect("killed", _on_player_killed)
		else:
			var health_controller: Node = player.get_node_or_null("HealthController")
			if health_controller != null and health_controller.has_signal("player_died"):
				health_controller.connect("player_died", _on_player_killed)

## ========== 帧更新方法 ==========

## _process() - 每帧调用一次，用于处理非物理相关逻辑
func _process(delta: float) -> void:
	## 处理普通敌人生成
	_spawn_enemies(delta)

	## 处理精英敌人生成
	_spawn_elite_enemies(delta)

	## 处理中央商店生成（5分钟后在竞技场中心生成一次）
	_update_shop_spawn()

	## 处理手动拾取输入（按E键拾取道具）
	_handle_manual_pickup()

	## 更新边界红色预警（玩家接近物理墙时屏幕四边泛红）
	_update_edge_warning(delta)

## ========== 敌人生成系统 ==========

## 处理敌人生成逻辑
## 参数：delta - 帧间隔时间（秒）
func _spawn_enemies(delta: float) -> void:
	## 动态上限：同屏敌人上限随难度等级增长（DifficultyManager内部有硬上限保护）
	var dynamic_max: int = DifficultyManager.get_max_enemies(max_enemies)

	## 如果当前敌人数量已达上限，不生成新敌人
	if _enemy_count >= dynamic_max:
		return

	## 递减敌人生成计时器
	_spawn_timer -= delta

	## 如果计时器归零，生成新敌人
	if _spawn_timer <= 0.0:
		_spawn_enemy()
		## 动态间隔：刷新间隔随难度等级压缩（越打越快，下限0.4秒）
		_spawn_timer = DifficultyManager.get_spawn_interval(enemy_spawn_interval)

## 生成单个敌人
## 参数：is_elite - 是否为精英怪, override_data - 外部指定的敌人数据（直播事件用，null=随机/精英池）
func _spawn_enemy(is_elite: bool = false, override_data: EnemyDataClass = null) -> void:
	## 刷怪总开关：终极关卡期间暂停一切常规刷怪
	## 单点拦截即覆盖全部刷怪路径（普通/精英/波次/直播事件），无需逐处加门禁
	if not spawning_enabled:
		return
	## 实例化敌人节点
	var enemy: CharacterBody2D = ENEMY_SCENE.instantiate()

	## 设置敌人生成位置（竞技场四边内侧的随机点）
	## 固定竞技场5760×3840：敌人必须在墙内刷出，否则会被物理墙永久挡在场外；
	## margin=100保证距墙有缓冲，相机被limit限制在场内时多数出生点仍在视野外
	var margin: float = 100.0
	var half_w: float = ArenaConfigClass.HALF_WIDTH
	var half_h: float = ArenaConfigClass.HALF_HEIGHT
	var side: int = RandomManager.randi_range(0, 3)  ## 随机选择生成边（上/右/下/左）

	## 根据随机选择的边设置敌人位置（坐标相对GameWorld原点，即竞技场中心）
	match side:
		0:
			## 上边：X在墙内全段随机，Y贴近顶墙内侧
			enemy.position = Vector2(
				RandomManager.randf_range(-half_w + margin, half_w - margin), -half_h + margin)
		1:
			## 右边：X贴近右墙内侧，Y在墙内全段随机
			enemy.position = Vector2(
				half_w - margin, RandomManager.randf_range(-half_h + margin, half_h - margin))
		2:
			## 下边：X在墙内全段随机，Y贴近底墙内侧
			enemy.position = Vector2(
				RandomManager.randf_range(-half_w + margin, half_w - margin), half_h - margin)
		3:
			## 左边：X贴近左墙内侧，Y在墙内全段随机
			enemy.position = Vector2(
				-half_w + margin, RandomManager.randf_range(-half_h + margin, half_h - margin))

	## 直播事件/外部指定敌人数据优先：用 override_data 覆盖随机池
	## 数据流：LiveBridgeManager 信号 → spawn_live_enemy(path) → _spawn_enemy(false, data) → 此分支
	if override_data != null:
		## 同样 deep duplicate + 难度缩放（保证直播敌人与当前难度同步，不会太弱或太强）
		var live_copy: EnemyDataClass = override_data.duplicate(true)
		DifficultyManager.apply_to_enemy_data(live_copy, is_elite)
		enemy.enemy_data = live_copy
		## 组标记：按 is_elite 分组，与业务敌人同标准
		if is_elite:
			enemy.add_to_group("elite_enemy")
		else:
			enemy.add_to_group("normal_enemy")
	## 如果是精英怪且有精英怪数据配置，应用精英怪数据
	elif is_elite and elite_enemy_data != null:
		## 关键：deep duplicate私有副本后再难度缩放
		## elite_enemy_data是共享资源，直接缩放会污染后续所有精英怪
		var elite_copy: EnemyDataClass = elite_enemy_data.duplicate(true)
		## 应用当前难度缩放（is_elite=true使用温和缩放，避免双重量叠秒杀玩家）
		DifficultyManager.apply_to_enemy_data(elite_copy, true)
		enemy.enemy_data = elite_copy
		## 添加精英怪组标记
		enemy.add_to_group("elite_enemy")
	else:
		## 普通敌人：从池中随机选择敌人数据（让敌人种类丰富）
		var rand_data: EnemyDataClass = _pick_random_enemy_data()
		if rand_data != null:
			## 关键：deep duplicate私有副本后再难度缩放
			## duplicate(true)递归复制子弹数据/掉落物等子资源，
			## 缩放修改（血量/伤害/子弹/掉落价值）不会污染共享.tres
			var data_copy: EnemyDataClass = rand_data.duplicate(true)
			## 应用当前难度缩放（血量/伤害/移速/子弹/掉落价值）
			DifficultyManager.apply_to_enemy_data(data_copy, false)
			enemy.enemy_data = data_copy
		## 添加普通敌人组标记
		enemy.add_to_group("normal_enemy")
	
	## 通用敌人组（供特效、查找、阵营判定等使用）
	enemy.add_to_group("enemy")

	## 将敌人添加到场景树中
	add_child(enemy)
	## 将敌人添加到管理列表
	_enemies.append(enemy)
	
	## 根据类型增加对应计数
	if is_elite:
		_elite_enemy_count += 1
	else:
		_enemy_count += 1

	## 连接敌人死亡信号：当敌人死亡时触发回调（绑定敌人实例和是否精英标记）
	enemy.killed.connect(_on_enemy_killed.bind(enemy, is_elite))
	## 连接敌人掉落信号：当敌人生成掉落物时触发回调
	enemy.drops_generated.connect(_on_enemy_drops_generated)

## ========== 精英怪生成系统 ==========

## 处理精英敌人生成逻辑
## 参数：delta - 帧间隔时间（秒）
func _spawn_elite_enemies(delta: float) -> void:
	## 如果没有精英怪数据配置，不生成精英怪
	if elite_enemy_data == null:
		return
	
	## 如果当前精英怪数量已达上限，不生成新精英怪（上限也随难度小幅放宽）
	if _elite_enemy_count >= max_elite_enemies:
		return

	## 递减精英怪生成计时器
	_elite_spawn_timer -= delta

	## 如果计时器归零，生成新精英怪
	if _elite_spawn_timer <= 0.0:
		_spawn_enemy(true)
		## 动态间隔：精英怪刷新随难度等级压缩（下限6秒）
		_elite_spawn_timer = DifficultyManager.get_elite_spawn_interval(elite_spawn_interval)

## ========== 中央商店系统 ==========

## 检测并生成中央商店（游戏满5分钟后一次性生成，之后永久存在不消失）
## 时间源：RunStats.elapsed_time 仅在本局游戏进行中累计，暂停/菜单/结算期间自然冻结，
##         因此"5分钟"严格等于实际战斗时长，符合需求且无需额外计时器
func _update_shop_spawn() -> void:
	if _shop_spawned:
		return
	if RunStats and RunStats.elapsed_time >= SHOP_SPAWN_TIME:
		_shop_spawned = true
		_spawn_shop()

## 生成中央商店：实例化纯脚本节点，置于竞技场正中心 Vector2.ZERO
func _spawn_shop() -> void:
	var shop: Area2D = SHOP_SCRIPT.new() as Area2D
	add_child(shop)
	shop.global_position = Vector2.ZERO
	## 重置物理插值，避免商店从原点外的初始位置平滑滑向中心（与拾取物/神庙同规则）
	if shop.has_method("reset_physics_interpolation"):
		shop.reset_physics_interpolation()
	_shop = shop

## ========== 道具拾取系统 ==========

## 处理手动拾取输入（玩家按E键：优先与神庙交互，其次拾取道具）
func _handle_manual_pickup() -> void:
	## 如果没有按下交互键，直接返回
	if not InputManager.is_action_just_pressed_safe("game_interact"):
		return

	## 如果玩家为空，直接返回
	if player == null:
		return

	## 优先级1：检查神庙（玩家在范围内时优先与神庙交互）
	for temple in _temples:
		## 检查神庙是否有必要的方法
		if temple.has_method("is_player_in_range") and temple.has_method("interact"):
			## 如果玩家在神庙交互范围内，打开神庙选项面板
			if temple.is_player_in_range():
				temple.interact(player)
				return

	## 优先级2：检查中央商店（优先级低于神庙，高于拾取物）
	if _shop != null and is_instance_valid(_shop) \
			and _shop.has_method("is_player_in_range") and _shop.has_method("interact"):
		## 玩家在商店交互范围内时进入商店（进入后由 Shop 负责暂停游戏）
		if _shop.is_player_in_range():
			_shop.interact(player)
			return

	## 优先级3：遍历所有拾取物，查找玩家附近可手动拾取的道具
	## 性能优化：先用global_position.distance_to快速预筛选，跳过远距拾取物
	## 旧逻辑每帧对所有_pickups调用has_method×2+is_player_in_range（内部又算距离），
	## 拾取物多时（百级）每帧上百次方法调用+距离计算；预筛选只用一次distance_to
	var player_pos: Vector2 = player.global_position
	for pickup in _pickups:
		## 快速距离预筛选：超过200像素一定不在拾取范围内，跳过
		## （拾取范围通常50~100像素，200像素安全余量）
		if pickup.global_position.distance_to(player_pos) > 200.0:
			continue
		## 检查拾取物是否有必要的方法
		if pickup.has_method("is_player_in_range") and pickup.has_method("pickup"):
			## 如果玩家在拾取范围内，执行拾取
			if pickup.is_player_in_range():
				pickup.pickup(player)
				break

## ========== 神庙系统 ==========

## 生成神庙（高级怪死亡掷骰命中后由Enemy调用）
## 参数：position - 神庙生成位置（敌人死亡位置）
func spawn_temple(position: Vector2) -> void:
	## 只在游戏中生效
	if not GameManager.is_playing():
		return

	## 全局唯一规则：同一时间只存在一座神庙。新神庙出现时，
	## 旧神庙（未进入/未交互）立即消散消失——先快照列表再逐个清理，避免遍历中改数组
	for old_temple in _temples.duplicate():
		if not is_instance_valid(old_temple):
			continue
		## 优先走消散接口（播放淡出动画并自动清理面板/上下文）；无接口则直接释放
		if old_temple.has_method("despawn"):
			old_temple.despawn()
		else:
			old_temple.queue_free()

	## 实例化神庙节点
	var temple: Area2D = TEMPLE_SCENE.instantiate()
	## 添加到场景树
	add_child(temple)
	## 设置神庙位置（敌人死亡位置，添加少量随机偏移避免重叠）
	temple.global_position = position + Vector2(
		RandomManager.randf_range(-15, 15),
		RandomManager.randf_range(-15, 15)
	)
	## 重置物理插值（避免神庙从原点滑向生成位置）
	if temple.has_method("reset_physics_interpolation"):
		temple.reset_physics_interpolation()

	## 加入管理列表
	_temples.append(temple)
	## 连接移除信号：神庙从场景树移除时自动清理列表
	temple.tree_exiting.connect(_on_temple_tree_exiting.bind(temple))

## 神庙被移除时的回调（响应temple.tree_exiting信号）
## 参数：temple - 被移除的神庙实例
func _on_temple_tree_exiting(temple: Area2D) -> void:
	if temple in _temples:
		_temples.erase(temple)

## ========== 子弹系统 ==========

## 玩家发射子弹时的回调（响应player.shot信号）
## 参数：position - 子弹发射位置，direction - 子弹飞行方向，bullet_data - 玩家配置的子弹数据
func _on_player_shot(position: Vector2, direction: Vector2, bullet_data: BulletDataClass) -> void:
	## 实例化子弹节点
	var bullet: Area2D = BULLET_SCENE.instantiate()
	## 将子弹添加到场景树中
	add_child(bullet)
	## 设置子弹发射位置
	bullet.global_position = position
	## 重置物理插值：物理插值开启后，add_child后传送必须重置，
	## 否则子弹会从原点(0,0)平滑滑向发射位置（视觉bug）
	if bullet.has_method("reset_physics_interpolation"):
		bullet.reset_physics_interpolation()

	## 复制子弹数据（每个子弹独立一份，避免共享数据被修改）
	## 性能优化：无特效的子弹直接共享原始数据（只读），避免无意义深拷贝
	## 满级技能后子弹可能带16个特效，duplicate(true)深拷贝每个子资源开销大；
	## 无特效子弹的damage/speed在创建后不会被修改，共享安全
	var bullet_data_to_use: BulletDataClass = bullet_data
	if bullet_data_to_use == null:
		bullet_data_to_use = default_bullet_data

	var bullet_data_copy: BulletDataClass
	if bullet_data_to_use.effects.is_empty():
		## 无特效：直接引用共享数据（只读，不会被子弹逻辑修改）
		bullet_data_copy = bullet_data_to_use
	else:
		## 有特效：深拷贝确保特效叠层状态独立（stack_count等运行时字段）
		bullet_data_copy = bullet_data_to_use.duplicate()
	## 设置子弹数据
	if bullet.has_method("set_bullet_data"):
		bullet.set_bullet_data(bullet_data_copy)

	## 设置子弹飞行方向
	bullet.set_direction(direction)
	## 设置子弹所属阵营为"player"（防止误伤玩家）
	bullet.set_owner_group("player")
	## 将子弹添加到管理列表
	_bullets.append(bullet)

	## 连接子弹命中信号：当子弹命中目标时触发回调
	bullet.hit.connect(_on_bullet_hit)
	## 连接子弹销毁信号：当子弹销毁时触发回调（绑定子弹实例）
	bullet.destroyed.connect(_on_bullet_destroyed.bind(bullet))

## 子弹命中目标时的回调（响应bullet.hit信号）
## 参数：bullet - 命中的子弹实例，target - 被命中的目标节点
func _on_bullet_hit(bullet: Area2D, target: Node2D) -> void:
	## 伤害计算已在Bullet.gd中完成，此处仅做额外逻辑处理
	pass

## 子弹销毁时的回调（响应bullet.destroyed信号）
## 参数：bullet - 被销毁的子弹实例
func _on_bullet_destroyed(bullet: Area2D) -> void:
	## 从管理列表中移除子弹
	if bullet in _bullets:
		_bullets.erase(bullet)

## ========== 敌人死亡与掉落 ==========

## 敌人死亡时的回调（响应enemy.killed信号）
## 参数：enemy - 死亡的敌人实例
## 参数：is_elite - 是否为精英怪
func _on_enemy_killed(enemy: CharacterBody2D, is_elite: bool = false) -> void:
	## 从管理列表中移除敌人
	if enemy in _enemies:
		_enemies.erase(enemy)
		## 根据类型减少对应计数
		if is_elite:
			_elite_enemy_count -= 1
		else:
			_enemy_count -= 1
	
	## 上报击杀统计（结算面板展示本局击杀数）
	RunStats.add_kill()
	## 上报连击系统（里程碑触发大字+音效 + 精英/Boss击杀时停）
	var is_big_kill: bool = is_elite or enemy.is_in_group("boss")
	ComboManager.add_kill(enemy.global_position, is_big_kill)

## 波次事件回调（响应DifficultyManager.wave_started）
## 数据流：难度每到5的整数倍 → wave_started信号 → 此回调 → 瞬间涌入一批敌人
## 设计意图：规律性的高压时刻——玩家可预期敌潮，提前走位/清场，制造爽点
## 参数：_wave_number - 波次序号（第几波，预留：可用于波次递增强度），spawn_count - 本波刷怪数
func _on_wave_started(_wave_number: int, spawn_count: int) -> void:
	## 播放敌潮警报音效（全局播放，提示玩家敌潮来袭）
	if AudioManager:
		AudioManager.play("wave_start", 0.8)
	## 批量生成敌人（受同屏上限保护，超出的数量自动跳过）
	for i in range(spawn_count):
		## 动态上限检查：已达上限时停止刷怪（防止瞬时数量爆炸）
		if _enemy_count >= DifficultyManager.get_max_enemies(max_enemies):
			break
		## 生成普通敌人（波次不加精英，精英保持独立节奏）
		_spawn_enemy()

## 敌人掉落道具时的回调（响应enemy.drops_generated信号）
## 参数：position - 掉落位置，drops - 掉落道具列表
func _on_enemy_drops_generated(position: Vector2, drops: Array) -> void:
	## 使用call_deferred延迟生成拾取物，避免在物理回调中修改场景树
	for drop_item in drops:
		if drop_item == null:
			continue
		call_deferred("_spawn_pickup", position, drop_item)

## 生成拾取物
## 参数：position - 生成位置，drop_item - 道具数据资源
func _spawn_pickup(position: Vector2, drop_item: Resource) -> void:
	## 实例化拾取物节点
	var pickup: Area2D = PICKUP_SCENE.instantiate()
	## 将拾取物添加到场景树中
	add_child(pickup)
	## 设置拾取物位置（在掉落位置基础上添加随机偏移）
	pickup.global_position = position + Vector2(
		RandomManager.randf_range(-20, 20),
		RandomManager.randf_range(-20, 20)
	)
	## 重置物理插值：避免拾取物从原点滑向掉落位置（物理插值开启后的传送必需）
	if pickup.has_method("reset_physics_interpolation"):
		pickup.reset_physics_interpolation()
	
	## 设置拾取物的道具数据
	if pickup.has_method("set_drop_item"):
		pickup.set_drop_item(drop_item)
	
	## 将拾取物添加到管理列表
	_pickups.append(pickup)
	
	## 连接拾取物移除信号：当拾取物从场景树移除时触发回调（绑定拾取物实例）
	pickup.tree_exiting.connect(_on_pickup_tree_exiting.bind(pickup))

## 拾取物被移除时的回调（响应pickup.tree_exiting信号）
## 参数：pickup - 被移除的拾取物实例
func _on_pickup_tree_exiting(pickup: Area2D) -> void:
	## 从管理列表中移除拾取物
	if pickup in _pickups:
		_pickups.erase(pickup)

## ========== 玩家死亡处理 ==========

## 玩家死亡时的回调（响应player.killed或HealthController.player_died信号）
func _on_player_killed() -> void:
	## 调用GameManager结束游戏（触发game_ended信号，通知Main.gd处理死亡流程）
	GameManager.end_game()

## ========== 直播互动系统：直播事件→生成敌人 ==========

## 生成直播事件敌人（公开接口，供 LiveBridgeManager 信号链路调用）
## 参数：enemy_data_path — EnemyData .tres 资源路径, count — 生成数量,
##       is_elite — 是否精英, display_name — 来源标签（如"辣条怪"，预留日志/UI用）
## 设计意图：复用 _spawn_enemy 的位置/分组/信号/计数逻辑，仅替换数据来源
func spawn_live_enemy(enemy_data_path: String, count: int = 1, \
		is_elite: bool = false, display_name: String = "") -> void:
	## 加载敌人数据资源（路径无效时静默返回，不影响游戏）
	var enemy_data: EnemyDataClass = load(enemy_data_path)
	if enemy_data == null:
		return
	## 按数量循环生成（每次生成前检查同屏上限，防止直播热流刷爆屏幕）
	for i in range(count):
		if is_elite:
			## 精英怪受独立的同屏上限保护
			if _elite_enemy_count >= max_elite_enemies:
				break
		else:
			## 普通敌人受动态上限保护（随难度等级增长）
			if _enemy_count >= DifficultyManager.get_max_enemies(max_enemies):
				break
		## 复用核心刷怪链路：传入 override_data 走直播分支
		_spawn_enemy(is_elite, enemy_data)

## 游客进入直播间回调（响应 LiveBridgeManager.viewer_entered 信号）
## 数据流：B站用户进房 → 桥接 → LiveBridgeManager → viewer_entered 信号 → 此回调
## 参数：uname — 用户名, enemy_path — 敌人数据路径, count — 生成数量, is_elite — 是否精英
func _on_live_viewer_entered(uname: String, enemy_path: String, \
		count: int, is_elite: bool) -> void:
	spawn_live_enemy(enemy_path, count, is_elite, "观众:%s" % uname)

## 弹幕回调（响应 LiveBridgeManager.danmu_received 信号）
## 当前为占位：仅记录日志，不生成敌人（弹幕量大，生成敌人会刷屏）
## 可扩展：弹幕关键词触发特殊事件/弹幕显示在屏幕上方
func _on_live_danmu(_uname: String, _text: String) -> void:
	pass

## 礼物回调（响应 LiveBridgeManager.gift_received 信号）
## 数据流：B站用户送礼 → 桥接解析礼物名/价值 → LiveGiftBinding.resolve() 映射 →
##         gift_received 信号 → 此回调 → 按映射生成对应强度敌人
## 参数：uname — 送礼用户, gift_name — 礼物名, value — 礼物价值(元),
##       enemy_path — 映射的敌人路径, count — 生成数量, is_elite — 是否精英, display_name — 标签
func _on_live_gift(_uname: String, _gift_name: String, _value: float, \
		enemy_path: String, count: int, is_elite: bool, display_name: String) -> void:
	spawn_live_enemy(enemy_path, count, is_elite, display_name)

## ========== 清理方法 ==========

## 清理所有游戏对象（用于场景切换、游戏结束或终极关卡清场）
## 说明：以 "enemy" 组为唯一真源做兜底清场 —— 除 _enemies 管理列表内的业务敌人外，
##      还覆盖不在业务列表内的实体（如 StageDirector 切面自建的 Boss），避免清场残留
func clear_all() -> void:
	## 清理所有敌人（切面自建 Boss 同样挂在 GameWorld 下且带 "enemy" 组标记，一并清掉）
	for child in get_children():
		if child.is_in_group("enemy") and not child.is_queued_for_deletion():
			child.queue_free()
	_enemies.clear()
	_enemy_count = 0
	## 精英计数必须同步归零：否则清场后精英怪会被"幽灵计数"永久卡在上限不再刷新
	_elite_enemy_count = 0

	## 清理所有子弹
	for bullet in _bullets:
		if bullet.is_inside_tree():
			bullet.queue_free()
	_bullets.clear()

	## 清理所有拾取物
	for pickup in _pickups:
		if pickup.is_inside_tree():
			pickup.queue_free()
	_pickups.clear()

	## 清理所有神庙
	for temple in _temples:
		if is_instance_valid(temple) and temple.is_inside_tree():
			temple.queue_free()
	_temples.clear()

	## 清理中央商店
	if _shop != null and is_instance_valid(_shop) and _shop.is_inside_tree():
		_shop.queue_free()
	_shop = null
	_shop_spawned = false