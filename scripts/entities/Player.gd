## Player.gd - 玩家角色核心脚本
## 职责：管理玩家移动、射击、血量、梦境碎片等核心逻辑
## 继承：CharacterBody2D（Godot 4的2D物理角色节点）
## 节点结构：Player(CharacterBody2D) → Sprite2D(外观) / Hitbox(Area2D, 敌人贴身接触判定) / HealthController(Node)
##           HealthController → ShieldComponent(护盾拦截) + CoreHealthComponent(核心血/无敌帧/死亡判定)
## 系统交互：
##   - 组：加入"player"组，供敌人追踪、拾取物吸附、GameWorld/Main 查找玩家
##   - 信号：shot → GameWorld._on_player_shot 创建子弹（Main._spawn_game_elements 也会连接一份）；
##           health_changed/critical_state_active/player_died 由 HealthController 转发后再次广播给 UI
##   - 单例：InputManager(输入) / AudioManager(音效) / UpgradeManager(词条) / RunStats(统计) 均为自动加载全局
## 碰撞层：本体 layer=1(玩家层)/mask=3；Hitbox layer=1/mask=8（检测敌方子弹层）——敌人子弹 mask=1 即打玩家
## 设计意图：玩家只负责移动/射击/成长，子弹创建外包给 GameWorld（只发信号），伤害结算外包给 HealthController
extends CharacterBody2D

## ========== 预加载资源（避免运行时加载延迟） ==========

## 子弹数据资源类，用于配置子弹属性（伤害、速度、形态、特效等）
const BulletDataClass = preload("res://scripts/resources/bullet/BulletData.gd")

## 角色皮肤资源类（主题系统：皮肤决定外观+动画参数）
const CharacterSkinClass = preload("res://scripts/resources/skin/CharacterSkin.gd")

## 主题包资源类（ThemeManager.theme_changed 信号的负载类型）
const GameThemeClass = preload("res://scripts/resources/skin/GameTheme.gd")

## 通用角色动画器组件（驱动呼吸/弹跳/攻击/受击动画）
const CharacterAnimatorClass = preload("res://scripts/components/CharacterAnimator.gd")

## 浮动伤害数字组件（玩家受伤时弹出，直播增强）
const DamageNumberClass = preload("res://scripts/components/DamageNumber.gd")

## 竞技场常量（相机limit边界必须与物理墙同源，改战场大小时只改ArenaConfig）
const ArenaConfigClass = preload("res://scripts/world/ArenaConfig.gd")

## 装备组件（RPG装备系统：管理6槽装备，聚合词条/特效/护盾/主动技能；无 class_name 走 preload）
const EquipmentComponentClass = preload("res://scripts/components/EquipmentComponent.gd")

## 背包组件（RPG装备系统：持有拾取到的装备，提供穿戴/卸下入口；无 class_name 走 preload）
const BackpackComponentClass = preload("res://scripts/components/BackpackComponent.gd")

## ========== 导出变量（编辑器可配置） ==========

## 玩家移动速度（像素/秒）；初始180，前期走位更轻快（原150上调约20%）
@export var speed: float = 180.0

## 射击冷却时间（秒），控制射速
## 初始0.6秒一颗，前期火力更密集（原0.8）；通过升级词条（fire_rate_mult）逐步提升到中后期速度
@export var shoot_cooldown: float = 0.6

## 玩家子弹配置（决定子弹伤害、速度、形态、特效等）
@export var bullet_data: BulletDataClass = null

## ========== 节点引用（使用 @onready 延迟初始化） ==========

## 玩家精灵节点，用于显示玩家外观
@onready var sprite: Sprite2D = $Sprite2D

## 玩家碰撞检测区域，用于检测敌人碰撞
@onready var hitbox: Area2D = $Hitbox

## 健康控制器节点，管理护盾和核心血量系统
@onready var health_controller: Node = $HealthController

## 装备护盾组件节点（独立于分段护盾，额外吸收伤害+特效触发）
@onready var equipment_shield: Node2D = $EquipmentShieldComponent

## 相机节点（挂CameraShake.gd；受击时按伤害幅度调用shake()，has_method防御无脚本场景）
@onready var _camera: Camera2D = $Camera2D

## ========== 成员变量（运行时数据） ==========

## 通用角色动画器组件（应用皮肤时创建；null=未启用动画——无皮肤回退占位时保持原样）
var animator: CharacterAnimatorClass = null

## 玩家当前拥有的梦境碎片数量
var dream_fragment: int = 0

## 玩家当前拥有的"装备碎片"（下标 = EquipmentData.Slot，值为持有数量）
## 用途：分解装备时按槽位堆叠产出，可在商店合成同槽位装备（保底稀有）
var equipment_fragments: Array[int] = [0, 0, 0, 0, 0, 0]

## 是否启用自动射击（默认开启）
var auto_shoot: bool = true

## 射击冷却计时器，递减到0时可再次射击
var _shoot_timer: float = 0.0

## 当前瞄准方向（每物理帧由_update_aim刷新；移动朝向与子弹方向共用，保证二者一致）
var _aim_direction: Vector2 = Vector2.RIGHT

## 手柄玩家是否曾拨动右摇杆（false时瞄准回退到移动方向/默认右向，避免开火乱射）
var _has_joy_aim: bool = false

## 玩家原始颜色，用于受伤后恢复显示
var _original_color: Color = Color.WHITE

## 无敌闪烁计数，控制闪烁次数
var _blink_count: int = 0

## 无敌闪烁计时器，控制闪烁频率
var _blink_timer: Timer = null

## ========== 升级词条系统（roguelike成长集成） ==========

## 基础移速（词条乘算前的原始值，speed会被词条动态修改）
var _base_speed: float = 0.0

## 基础射击冷却（词条乘算前的原始值，shoot_cooldown会被词条动态修改）
var _base_shoot_cooldown: float = 0.0

## 私有子弹数据副本（关键设计：导出的bullet_data是全局共享的.tres资源，
## 词条追加特效/修改伤害必须作用于私有副本，否则会污染所有子弹配置和下一局游戏）
var _private_bullet_data: BulletDataClass = null

## 基础子弹伤害（词条乘算基准，词条只修改私有副本的damage）
var _base_bullet_damage: int = 0

## 基础子弹速度（词条乘算基准，词条只修改私有副本的speed）
var _base_bullet_speed: float = 0.0

## 最近一次攻击者（Enemy/Bullet 节点引用，用于装备护盾判定阵营/类型）
var _last_attacker: Node = null

## 最近一次攻击上下文（is_bullet/direction/bullet_data 等）
var _last_attack_context: Dictionary = {}

## ========== 装备系统（RPG化成长：属性/特效/护盾/弹道构型统一挂载到装备） ==========

## 装备组件（6槽管理；由 _ready 动态创建并 add_child）
var _equipment: Node = null

## 背包组件（持有拾取到的装备；由 _ready 动态创建并 add_child）
var _backpack: Node = null

## 减伤率（0~0.9）：装备词条 damage_reduction 汇总值，take_damage 最前统一打折
var _damage_reduction: float = 0.0

## 装备提供的全部主动技能（EquipmentActiveSkill；可同时持有多件装备的技能，按穿戴顺序排列）
var _active_skills: Array[Resource] = []

## 各主动技能的冷却剩余时间（秒；下标与 _active_skills 对齐，<=0 表示可用）
var _active_skill_cds: Array[float] = []

## 当前选中的主动技能下标（Q/E 或手柄 LT/RT 前后切换；无技能时无效）
var _active_skill_index: int = 0

## ========== 险胜反馈系统（直播增强："差点死"的紧张感） ==========
## 红血存活计时器：进入红血后累计存活时间，存活5秒以上触发险胜奖励
var _critical_survival_timer: float = 0.0
## 是否处于红血状态（_on_critical_state_active 中同步）
var _is_in_critical: bool = false
## 心跳音效间隔（随红血存活时间缩短：初始0.8秒→最低0.25秒）
var _heartbeat_interval: float = 0.8
## 心跳音效计时（递减到0时播放心跳音）
var _heartbeat_timer: float = 0.0
## 是否已获得险胜奖励（一局红血期间只触发一次）
var _near_death_rewarded: bool = false
## 险胜奖励：临时攻击加成倍率（1.15=+15%攻击力）
const NEAR_DEATH_ATTACK_BONUS: float = 1.15
## 险胜奖励：红血存活阈值（秒，达到后触发奖励）
const NEAR_DEATH_SURVIVAL_THRESHOLD: float = 5.0

## ========== 信号定义（用于与其他节点通信） ==========

## 玩家发射子弹时发出此信号
## 参数：position - 子弹发射位置，direction - 子弹飞行方向，bullet_data - 子弹配置数据
signal shot(position: Vector2, direction: Vector2, bullet_data: BulletDataClass)

## 梦境碎片数量变化时发出此信号
## 参数：amount - 当前梦境碎片总数
signal dream_fragment_changed(amount: int)

## 装备碎片数量变化时发出此信号
## 参数：slot - 槽位（EquipmentData.Slot），amount - 该槽位当前碎片总数
signal equipment_fragment_changed(slot: int, amount: int)

## 玩家血量/护盾状态变化时发出此信号
## 参数：state - 包含当前生存状态的字典
signal health_changed(state: Dictionary)

## ========== 生命周期方法 ==========

## _ready() - 节点进入场景树时调用一次，用于初始化
func _ready() -> void:
	## 初始化梦境碎片为0
	dream_fragment = 0
	## 重置装备碎片（按槽位堆叠，全部清零）
	equipment_fragments = [0, 0, 0, 0, 0, 0]

	## ========== 相机活动边界（竞技场世界坐标） ==========
	## Godot4的Camera2D.limit_*钳制的是"视野边缘"的世界坐标（不是相机中心），
	## 因此直接填物理墙所在的竞技场四边；引擎会自动内缩半个视口，保证不露墙外。
	## 运行时从ArenaConfig注入：Player.tscn里的值仅作编辑器预览兜底，
	## 真正以常量为准，避免日后调整战场尺寸时场景与代码漂移
	if _camera != null:
		_camera.limit_left = -int(ArenaConfigClass.HALF_WIDTH)
		_camera.limit_right = int(ArenaConfigClass.HALF_WIDTH)
		_camera.limit_top = -int(ArenaConfigClass.HALF_HEIGHT)
		_camera.limit_bottom = int(ArenaConfigClass.HALF_HEIGHT)

	## ========== 外观：主题皮肤（优先）→ 占位方块（回退） ==========
	## 数据流：ThemeManager(autoload) 启动时已加载主题 → 此处按需索取玩家皮肤
	## 有皮肤：皮肤生成纹理（内部缓存）+ 创建动画器（呼吸/弹跳/攻击/受击动画）
	## 无皮肤：回退原有蓝色占位方块，保证任何情况下玩家都可显示
	## 防护：ThemeManager 单例异常（解析失败未实例化）时标识符为 null，
	##       直接调用会中断 _ready → 占位纹理逻辑被跳过 → 玩家隐形（已发生的线上事故），
	##       因此必须判空后再调用，保证任何情况下都走到纹理赋值
	var player_skin: CharacterSkinClass = null
	if ThemeManager:
		player_skin = ThemeManager.get_player_skin()
	if player_skin != null:
		_apply_skin(player_skin)
	else:
		_create_placeholder_texture(sprite, Color(0, 0.5, 1, 1), 40, 40)

	## 监听主题热切换信号：设置界面切主题时全场玩家即时换肤（无需重开局）
	## 数据流：ThemeManager.set_theme → theme_changed信号 → 此回调 → 重新应用皮肤
	if ThemeManager and not ThemeManager.theme_changed.is_connected(_on_theme_changed):
		ThemeManager.theme_changed.connect(_on_theme_changed)
	
	## 将玩家添加到"player"组，方便其他节点通过组查找玩家
	if not is_in_group("player"):
		add_to_group("player")
	
	## 保存玩家原始颜色，用于后续受伤后恢复
	_original_color = sprite.modulate
	
	## 连接碰撞检测信号：当有物体进入hitbox区域时触发回调
	if hitbox:
		hitbox.body_entered.connect(_on_hitbox_body_entered)
	
	## 连接健康控制器的信号，监听血量变化、红血状态、死亡事件
	if health_controller:
		if health_controller.has_signal("health_changed"):
			health_controller.connect("health_changed", _on_health_changed)
		if health_controller.has_signal("critical_state_active"):
			health_controller.connect("critical_state_active", _on_critical_state_active)
		if health_controller.has_signal("player_died"):
			health_controller.connect("player_died", _on_player_died)

	## ========== 升级词条系统初始化 ==========

	## 记录基础属性（词条乘算基于这些原始值，避免反复乘算导致数值漂移）
	_base_speed = speed
	_base_shoot_cooldown = shoot_cooldown

	## 创建私有子弹数据副本（词条特效/伤害修改的作用对象）
	_init_private_bullet_data()

	## 创建装备组件（RPG装备系统：管理6槽装备，聚合词条/特效/护盾/主动技能）
	_equipment = EquipmentComponentClass.new()
	_equipment.name = "EquipmentComponent"
	add_child(_equipment)
	_equipment.setup(self)

	## 创建背包组件（持有拾取到的装备；需在装备组件之后创建，以便注入穿戴执行者引用）
	_backpack = BackpackComponentClass.new()
	_backpack.name = "BackpackComponent"
	add_child(_backpack)
	_backpack.setup(self, _equipment)

	## 监听属性重算信号：任一加成来源（旧词条/装备）变化导致 player_stats 重算后重新同步到自身
	## 数据流：UpgradeManager.recompute_stats → stats_recomputed信号 → 此回调 → 同步移速/射速/弹属性
	if UpgradeManager and UpgradeManager.has_signal("stats_recomputed"):
		UpgradeManager.stats_recomputed.connect(_on_stats_recomputed)

	## 初始同步一次（兜底：若词条/装备在玩家实例化之前已生效，也能拿到正确属性）
	_sync_upgrade_stats()

	## ========== 相机接管（修复重开后相机不跟随的bug） ==========
	## Player.tscn中Camera2D已设current=true，但旧玩家free+新玩家add同帧时，
	## Godot 4有时不会自动切换current相机。显式调用make_current确保新相机立即接管。
	var cam: Camera2D = get_node_or_null("Camera2D")
	if cam != null:
		cam.make_current()

## ========== 辅助方法 ==========

## 创建占位纹理（无美术资源时使用）
## 参数：sprite_node - 要设置纹理的Sprite2D节点
##       color - 纹理颜色
##       width - 纹理宽度（像素）
##       height - 纹理高度（像素）
func _create_placeholder_texture(sprite_node: Sprite2D, color: Color, width: int, height: int) -> void:
	## 创建指定尺寸的RGBA8格式图像
	var image: Image = Image.create(width, height, false, Image.FORMAT_RGBA8)
	## 用指定颜色填充整个图像
	image.fill(color)
	## 将图像转换为纹理
	var texture: ImageTexture = ImageTexture.create_from_image(image)
	## 将纹理设置到Sprite2D节点上
	sprite_node.texture = texture

## ========== 主题皮肤系统（一键换肤） ==========

## 应用角色皮肤（首次创建 / 主题热切换时调用）
## 参数：skin - 角色皮肤资源（来自 ThemeManager.get_player_skin()）
func _apply_skin(skin: CharacterSkinClass) -> void:
	## 皮肤为空直接返回（防御）
	if skin == null:
		return
	## PROCEDURAL 模式：把皮肤生成的纹理挂到玩家精灵（皮肤内部缓存，同皮肤共享一张纹理）
	if not skin.has_frames():
		sprite.texture = skin.get_texture()
	## 重置精灵调制色为白色：场景中 Sprite2D 自带蓝色 modulate（旧占位染色），
	## 皮肤纹理颜色已经正确，叠加调制会串色；白调制保证皮肤颜色原样显示
	if not sprite.modulate.is_equal_approx(Color.WHITE):
		sprite.modulate = Color.WHITE
	## 创建/更新动画器（FRAMES 模式会在内部创建 AnimatedSprite2D 并隐藏色块精灵）
	_ensure_animator(skin)
	## 皮肤应用后刷新"原始颜色"基准（受伤闪烁/红血恢复都回到这个颜色）
	_original_color = sprite.modulate

## 获取或创建动画器组件（首次创建，之后复用并重设皮肤）
func _ensure_animator(skin: CharacterSkinClass) -> void:
	## 已有动画器：只需重设皮肤（热切换主题场景）
	if animator != null:
		animator.setup(skin, sprite)
		return
	## 首次：创建动画器组件挂到玩家下（自驱动 _process，不占玩家逻辑帧）
	animator = CharacterAnimatorClass.new()
	animator.name = "CharacterAnimator"
	add_child(animator)
	animator.setup(skin, sprite)

## 主题切换回调（ThemeManager.theme_changed）：全场即时换肤
func _on_theme_changed(theme: GameThemeClass) -> void:
	## 新主题有玩家皮肤才应用（null 时保持当前外观，避免变成隐形）
	if theme != null and theme.player_skin != null:
		_apply_skin(theme.player_skin)

## ========== 升级词条系统集成（roguelike成长核心） ==========

## 创建私有子弹数据副本（_ready时调用一次）
## 设计意图：导出的bullet_data.tres是全局共享资源，duplicate(true)深拷贝出
##          本局私有副本，词条追加特效/修改数值都只作用于副本，局结束自动丢弃
func _init_private_bullet_data() -> void:
	## 有配置时深拷贝（true=递归复制子资源：form/effects都会独立）
	if bullet_data != null:
		_private_bullet_data = bullet_data.duplicate(true)
	else:
		## 无配置时创建默认子弹数据（兜底，保证游戏可玩）
		_private_bullet_data = BulletDataClass.new()
	## 记录基础伤害/速度（词条乘算的基准值，每次同步都从基准算起）
	_base_bullet_damage = _private_bullet_data.damage
	_base_bullet_speed = _private_bullet_data.speed

## 从UpgradeManager同步词条属性到玩家自身
## 数据流：UpgradeManager.player_stats（词条累积）→ 此方法 → 移速/射速/子弹副本
## 同步时机：词条应用信号回调 + _ready兜底
func _sync_upgrade_stats() -> void:
	## 防御：私有副本未初始化时直接返回（_ready顺序保证一般不会发生）
	if _private_bullet_data == null:
		return
	## 读取UpgradeManager累积的玩家属性字典
	var stats: Dictionary = UpgradeManager.player_stats

	## 移速 = 基础移速 × 移速乘算
	speed = _base_speed * float(stats.get("move_speed_mult", 1.0))

	## 射速乘算 → 冷却缩短：冷却 = 基础冷却 / 射速乘算
	## 保底0.05秒：防止极端叠层后冷却趋近0导致每帧都在发射
	var fire_rate_mult: float = float(stats.get("fire_rate_mult", 1.0))
	shoot_cooldown = maxf(_base_shoot_cooldown / maxf(fire_rate_mult, 0.1), 0.05)

	## 子弹伤害乘算（保底1点伤害，防止0伤害废弹）
	_private_bullet_data.damage = maxi(
		int(round(float(_base_bullet_damage) * float(stats.get("damage_mult", 1.0)))), 1)
	## 子弹速度乘算
	_private_bullet_data.speed = _base_bullet_speed * float(stats.get("bullet_speed_mult", 1.0))

	## 减伤率（装备词条 damage_reduction 汇总；take_damage 最前按此打折，钳制上限0.9）
	_damage_reduction = clampf(float(stats.get("damage_reduction", 0.0)), 0.0, 0.9)

	## ========== 下发核心血上限加成（全量重算模型：按目标总量统一增量扩容/缩减） ==========
	## 数据流：UpgradeManager.player_stats.max_hp_bonus → CoreHealthComponent.set_hp_bonus_total
	## 返回本次实际上限变化量：扩容时弹金色"+N"，缩容不提示（避免负面反馈）
	if health_controller != null:
		var core_comp: Node = health_controller.get_node_or_null("CoreHealthComponent")
		if core_comp != null and core_comp.has_method("set_hp_bonus_total"):
			var hp_delta: float = core_comp.set_hp_bonus_total(float(stats.get("max_hp_bonus", 0.0)))
			if hp_delta > 0.5:
				DamageNumberClass.pop(global_position + Vector2(0, -44), int(round(hp_delta)), false, Color(1.0, 0.85, 0.2), "+")

	## ========== 下发装备护盾属性词条（耐久上限/回盾速度） ==========
	if equipment_shield != null and equipment_shield.has_method("apply_stat_modifiers"):
		equipment_shield.apply_stat_modifiers(
			float(stats.get("shield_max_mult", 1.0)),
			float(stats.get("shield_regen_mult", 1.0)))

	## ========== 下发核心血生存属性词条（受击无敌时长/每秒回血） ==========
	if health_controller != null and health_controller.has_method("apply_core_stat_modifiers"):
		health_controller.apply_core_stat_modifiers(
			float(stats.get("invincible_mult", 1.0)),
			float(stats.get("hp_regen", 0.0)))

## 属性重算信号回调（响应 UpgradeManager.stats_recomputed）
## 参数：_stats - 重算后的完整属性字典（与 UpgradeManager.player_stats 同源，此处无需直接使用）
func _on_stats_recomputed(_stats: Dictionary) -> void:
	## 重新同步全部属性（同步成本低，统一处理最简单可靠）
	_sync_upgrade_stats()

## 查询是否已拥有某子弹特效（装备特效注入去重过滤用）
## 参数：effect_id - 特效唯一标识（如"explosion"）
## 返回：true表示已拥有
func has_bullet_effect(effect_id: String) -> bool:
	## 副本未初始化或空id时视为未拥有
	if _private_bullet_data == null or effect_id == "":
		return false
	## 遍历特效列表比对effect_id
	for effect in _private_bullet_data.effects:
		if effect != null and effect.effect_id == effect_id:
			return true
	return false

## 给已拥有的特效叠层（重复获得同一特效的装备时调用）
## 数据流：apply_equipment_effect去重分支 → 找到私有副本中已拥有的实例 → add_stack成长
## 设计意图：放大的对象是玩家私有副本中的特效实例（duplicate(true)深拷贝产物），
##           绝不修改共享.tres；子弹发射时duplicate()浅拷贝共享该实例，
##           新参数下一发子弹立即生效；子弹运行时状态全存bullet.meta（互不干扰）
## 参数：effect - 新获得装备携带的特效资源（用其effect_id定位已拥有实例）
func _stack_owned_effect(effect: Resource) -> void:
	var target_id: String = effect.effect_id if "effect_id" in effect else ""
	if target_id == "":
		return
	## 遍历私有副本特效列表，找到同id实例并叠层
	for owned in _private_bullet_data.effects:
		if owned != null and owned.effect_id == target_id:
			## add_stack内部会递增层数并触发_on_stack_grown参数放大
			if owned.has_method("add_stack"):
				owned.add_stack()
			break

## 移除指定子弹特效（EquipmentComponent 卸下携带该特效的装备时调用）
## 数据流：EquipmentComponent._refresh_effects → 此方法 → 从私有子弹副本移除该特效实例
## 参数：effect_id - 特效唯一标识（如"explosion"）
func remove_bullet_effect(effect_id: String) -> void:
	if _private_bullet_data == null or effect_id == "":
		return
	## 倒序遍历，安全移除匹配的特效实例（同一特效只会存在一份）
	for i in range(_private_bullet_data.effects.size() - 1, -1, -1):
		var effect = _private_bullet_data.effects[i]
		if effect != null and effect.effect_id == effect_id:
			_private_bullet_data.effects.remove_at(i)
			break

## 注入装备来源的子弹特效（EquipmentComponent 装备变更时调用）
## 数据流：EquipmentComponent._refresh_effects → 此方法 → 追加到私有子弹副本特效列表
## 已拥有同 id（其他装备提供）→ 叠层成长；卸下装备时由 remove_bullet_effect 精准移除
## 参数：effect - 特效资源（来自 EquipmentData.bullet_effects）
func apply_equipment_effect(effect: Resource) -> void:
	if effect == null or _private_bullet_data == null:
		return
	var eid: String = effect.effect_id if "effect_id" in effect else ""
	if eid == "":
		return
	## 已拥有同 id（其他装备提供）→ 叠层成长
	if has_bullet_effect(eid):
		_stack_owned_effect(effect)
		return
	_private_bullet_data.effects.append(effect)
	if AudioManager:
		AudioManager.play("buff_pickup", 0.8)

## ========== 物理帧更新方法 ==========

## _physics_process() - 每物理帧调用一次（默认60次/秒），用于处理物理相关逻辑
## 为什么不用 _process：move_and_slide 依赖物理步进，物理帧固定步长可保证碰撞检测稳定不穿模
func _physics_process(delta: float) -> void:
	## ---------- 险胜反馈系统（红血存活计时+心跳音效） ----------
	_update_near_death_feedback(delta)

	## 先刷新瞄准方向（键鼠=鼠标指向，手柄=右摇杆），移动朝向与射击共用
	_update_aim()
	## 处理玩家移动
	_move(delta)
	## 处理玩家射击
	_handle_shoot(delta)
	## 处理装备主动技能（冷却推进 + game_skill 输入释放）
	_update_active_skill(delta)

## ========== 险胜反馈系统（直播增强） ==========

## 更新险胜反馈（红血存活计时、心跳音效、险胜奖励触发）
## 在 _physics_process 中每帧调用（物理帧稳定60Hz）
func _update_near_death_feedback(delta: float) -> void:
	## 门禁：只在红血状态 + 游戏进行中时更新
	if not _is_in_critical or not GameManager.is_playing():
		return

	## 累计红血存活时间
	_critical_survival_timer += delta

	## 心跳间隔随存活时间缩短（越久越紧张：0.8秒→最低0.25秒）
	_heartbeat_interval = maxf(0.25, 0.8 - _critical_survival_timer * 0.08)

	## 心跳音效计时器
	_heartbeat_timer -= delta
	if _heartbeat_timer <= 0.0:
		_heartbeat_timer = _heartbeat_interval
		if AudioManager:
			## 心跳音随存活时间升高音高（紧张感累积）
			var hp_ratio: float = health_controller.get_survival_state().get("core", 0) / maxf(health_controller.get_survival_state().get("max_core", 1), 1)
			AudioManager.play("heartbeat", 0.5 + hp_ratio * 0.3, 0.8 + (1.0 - hp_ratio) * 0.4)

	## 触发险胜奖励：红血存活超过阈值且未奖励过
	if not _near_death_rewarded and _critical_survival_timer >= NEAR_DEATH_SURVIVAL_THRESHOLD:
		_near_death_rewarded = true
		_on_near_death_reward()

## 险胜奖励触发回调：临时攻击加成 + 专属音效 + 屏幕金边
func _on_near_death_reward() -> void:
	## 临时攻击加成：修改私有子弹数据的伤害倍率
	## 设计意图：不改 _base_bullet_damage（词条乘算基准），而是给私有副本乘一个临时倍率
	if _private_bullet_data != null:
		_private_bullet_data.damage = int(float(_private_bullet_data.damage) * NEAR_DEATH_ATTACK_BONUS)

	## 险胜专属音效
	if AudioManager:
		AudioManager.play("near_death_reward", 0.9)

	## 屏幕金边闪烁反馈（通过 Camera2D 创建 ColorRect 叠层）
	var cam: Camera2D = get_viewport().get_camera_2d()
	if cam != null:
		## 创建金色边框遮罩（上下左右各20px宽的 ColorRect）
		var border_parent: Control = Control.new()
		border_parent.name = "NearDeathBorder"
		border_parent.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		border_parent.z_index = 1000  ## 顶层显示
		cam.add_child(border_parent)

		## 边框颜色：alpha 必须为 1，可见度统一交给 modulate:a 补间控制
		## （若 color 的 alpha 为 0，则最终透明度 = color.a × modulate.a 恒为 0，金边不可见）
		var border_color: Color = Color(1.0, 0.9, 0.3, 1.0)
		var border_thickness: float = 20.0

		## 上边框
		var top: ColorRect = ColorRect.new()
		top.color = border_color
		top.anchor_right = 1.0
		top.size = Vector2(0, border_thickness)
		border_parent.add_child(top)
		## 下边框
		var bottom: ColorRect = ColorRect.new()
		bottom.color = border_color
		bottom.anchor_top = 1.0
		bottom.anchor_right = 1.0
		bottom.offset_top = -border_thickness
		border_parent.add_child(bottom)
		## 左边框
		var left: ColorRect = ColorRect.new()
		left.color = border_color
		left.size = Vector2(border_thickness, 0)
		left.anchor_bottom = 1.0
		border_parent.add_child(left)
		## 右边框
		var right: ColorRect = ColorRect.new()
		right.color = border_color
		right.anchor_left = 1.0
		right.anchor_bottom = 1.0
		right.offset_left = -border_thickness
		border_parent.add_child(right)

		## 闪烁动画：淡入(0.3s) → 停留(0.8s) → 淡出(1.2s) → 销毁
		## 注意：不能用 set_parallel(true)——并行模式下 tween_callback 会与属性补间同时起步，
		##       导致 queue_free 在动画刚开始时就执行，金边刚出现即消失
		## 初始 modulate 置为全透明，由补间从 0 淡入
		border_parent.modulate = Color(1.0, 1.0, 1.0, 0.0)
		var tw: Tween = border_parent.create_tween()
		tw.tween_property(border_parent, "modulate:a", 1.0, 0.3)
		tw.tween_interval(0.8)
		tw.tween_property(border_parent, "modulate:a", 0.0, 1.2)
		tw.tween_callback(border_parent.queue_free)

## 处理玩家移动逻辑
## 参数：delta - 帧间隔时间（秒），用于确保移动速度不受帧率影响
func _move(delta: float) -> void:
	## 从InputManager获取玩家输入方向（WASD或方向键）
	var input_dir: Vector2 = InputManager.get_movement()
	
	## 如果有输入，将向量归一化（确保斜向移动速度不超过单方向）
	if input_dir != Vector2.ZERO:
		input_dir = input_dir.normalized()
	
	## 设置玩家速度向量
	velocity = input_dir * speed
	## 执行移动并处理碰撞（Godot内置的物理移动方法）
	move_and_slide()

	## ---------- 动画状态同步（有动画器时） ----------
	if animator != null:
		## 移动/待机切换：有输入即弹跳，无输入回呼吸
		animator.set_moving(input_dir != Vector2.ZERO)
		## 朝向跟随当前瞄准方向（键鼠=准星侧，手柄=右摇杆指向），双设备体验统一
		if absf(_aim_direction.x) > 0.1:
			animator.set_facing(_aim_direction.x)

## 更新瞄准方向（每物理帧先于移动/射击执行）
## 设备分流规则：
##   1. 右摇杆有效偏转 → 手柄瞄准，缓存摇杆方向（拨过一次后持续保留，回中不丢失）
##   2. 手柄设备但右摇杆回中 → 沿用缓存方向；从未拨过时回退到移动方向/默认右向
##   3. 键鼠设备 → 玩家指向鼠标的世界坐标（原版逻辑）
## 设备类型由 InputManager 事件驱动自动切换，玩家无需手动选模式
func _update_aim() -> void:
	## 分支1：右摇杆正在偏转（is_aim_active已做径向死区过滤）
	if InputManager.is_aim_active():
		_aim_direction = InputManager.get_aim_vector().normalized()
		_has_joy_aim = true
		return
	## 分支2：手柄设备且摇杆回中——保留上次瞄准，不擅自改向
	if InputManager.current_device == "joypad":
		if not _has_joy_aim:
			## 首次未拨右摇杆：移动中朝移动方向瞄准，静止时默认朝右
			var move_vec: Vector2 = InputManager.get_movement()
			if move_vec != Vector2.ZERO:
				_aim_direction = move_vec.normalized()
		return
	## 分支3：键鼠——瞄准鼠标世界位置；鼠标与玩家重合时保持上一次方向（normalized零向量防护）
	var mouse_dir: Vector2 = get_global_mouse_position() - global_position
	if mouse_dir.length() > 0.001:
		_aim_direction = mouse_dir.normalized()

## 处理玩家射击逻辑
## 参数：delta - 帧间隔时间（秒）
func _handle_shoot(delta: float) -> void:
	## 递减射击冷却计时器
	_shoot_timer -= delta
	
	## 判断是否应该射击
	## 自动射击模式：冷却完成后自动射击，无需按下按键（射击方向仍跟随当前瞄准）
	## 手动射击模式：按住鼠标左键/手柄X键，或手柄右摇杆保持偏转（双摇杆射击惯例：拨摇杆即开火）
	var should_shoot: bool = false
	if auto_shoot:
		should_shoot = _shoot_timer <= 0.0
	else:
		var trigger_held: bool = InputManager.is_action_pressed_safe("game_shoot") \
			or InputManager.is_aim_active()
		should_shoot = _shoot_timer <= 0.0 and trigger_held
	
	## 如果应该射击，执行射击动作
	if should_shoot:
		_shoot()
		## 重置冷却计时器
		_shoot_timer = shoot_cooldown

## 设置自动射击模式（对外接口）
## 参数：enabled - 是否启用自动射击
func set_auto_shoot(enabled: bool) -> void:
	auto_shoot = enabled

## 执行射击动作
func _shoot() -> void:
	## 射击方向使用每帧刷新的瞄准方向（键鼠=鼠标指向，手柄=右摇杆指向），
	## 方向来源统一在_update_aim分流，此处不再直接读取鼠标
	var direction: Vector2 = _aim_direction
	
	## 播放射击音效（带随机音高避免重复）
	if AudioManager:
		AudioManager.play_2d("player_shoot", global_position, 0.75, randf_range(0.95, 1.08))

	## 播放攻击动画（射击后坐脉冲：前倾+放大回弹，强化开火手感）
	if animator != null:
		animator.play_attack()
	
	## 发出shot信号，通知GameWorld创建子弹（包含子弹配置数据）
	## 关键：传递私有子弹副本（词条修改的伤害/速度/特效都在副本上），
	##       GameWorld会再duplicate一份给子弹实例，共享.tres永远不会被修改
	shot.emit(global_position, direction, _private_bullet_data)

## ========== 血量与伤害系统 ==========

## 玩家受到伤害时调用（对外接口）
## 伤害拦截顺序：装备护盾（EquipmentShieldComponent）→ 分段护盾（ShieldComponent）→ 核心血量
## 参数：amount - 伤害数值
func take_damage(amount: float) -> void:
	## ---------- 减伤机制（装备词条 damage_reduction）：所有伤害在拦截前统一打折 ----------
	## 钳制上限0.9：防止叠满减伤后完全免伤导致游戏失去挑战性
	if _damage_reduction > 0.0:
		amount *= (1.0 - clampf(_damage_reduction, 0.0, 0.9))

	var remaining: float = amount
	var shield_absorbed: float = 0.0  ## 护盾吸收的伤害量（用于蓝色数字显示）
	var core_damage: float = 0.0      ## 核心血扣减的伤害量（用于红色数字显示）

	## 装备护盾优先吸收（独立于分段护盾，最先拦截）
	if equipment_shield != null and equipment_shield.has_method("has_shield") and equipment_shield.has_shield():
		var before: float = remaining
		remaining = equipment_shield.absorb_damage(amount, _last_attacker, _last_attack_context)
		shield_absorbed += before - remaining  ## 装备护盾吸收的部分

	## 装备护盾吸收后仍有剩余伤害 → 交给分段护盾/核心血量
	if remaining > 0.0 and health_controller:
		## 记录受伤前的状态，用于检测是否刚进入无敌状态
		var state_before: Dictionary = health_controller.get_survival_state()
		var was_invincible: bool = state_before.get("is_invincible", false)
		var hp_before: float = state_before.get("core", 0.0)
		var shield_before: int = state_before.get("shield", 0)

		## 调用健康控制器处理伤害（先扣分段护盾，再扣核心血）
		health_controller.apply_damage(remaining, "unknown")

		## 记录受伤后的状态
		var state_after: Dictionary = health_controller.get_survival_state()
		var is_invincible: bool = state_after.get("is_invincible", false)
		var shield_after: int = state_after.get("shield", 0)
		var hp_after: float = state_after.get("core", 0.0)

		## 计算分段护盾吸收了多少（简化：remaining - 核心血实际扣减）
		core_damage = hp_before - hp_after
		shield_absorbed += remaining - core_damage  ## 分段护盾吸收的部分

		## 护盾破碎音效
		if shield_after == 0 and shield_before > 0:
			if AudioManager:
				AudioManager.play_2d("shield_break", global_position, 0.95)
		## 玩家扣血音效（核心血量变化）
		elif core_damage > 0.0:
			if AudioManager:
				AudioManager.play_2d("player_hurt", global_position, 0.9)
			## 核心血量受击：播放受击动画（FRAMES 模式切到 hit 槽位，PROCEDURAL 模式触发抖动）
			if animator != null:
				animator.play_hit_shake()

		## 如果刚进入无敌状态，启动闪烁效果
		if is_invincible and not was_invincible:
			_start_invincible_blink()

	## ---------- 弹出伤害数字（直播增强：让观众看清受伤构成） ----------
	## 核心血扣减：红色，大伤害时 is_crit=true 放大
	if core_damage > 0.0:
		var is_big_damage: bool = core_damage > 15.0  ## 玩家被打15+就算大伤害
		DamageNumberClass.pop(global_position + Vector2(0, -20), int(core_damage), is_big_damage, Color(1.0, 0.3, 0.2))
	## 护盾吸收：蓝色（让玩家知道护盾在挡伤害）
	if shield_absorbed > 0.0:
		DamageNumberClass.pop(global_position + Vector2(-15, -30), int(shield_absorbed), false, Color(0.4, 0.7, 1.0))

	## ---------- 受击镜头震动（幅度随伤害缩放） ----------
	## 核心血受伤：强度=伤害/20映射到0.15~0.9（2点小伤轻震，15+大伤接近满震），持续0.28s
	## 仅护盾吸收未掉血：小幅轻震0.22/0.16s，告知"被打中但挡住了"
	if _camera != null and _camera.has_method("shake"):
		if core_damage > 0.0:
			_camera.shake(clampf(core_damage / 20.0, 0.15, 0.9), 0.28)
		elif shield_absorbed > 0.0:
			_camera.shake(0.22, 0.16)

## 恢复核心血量（对外接口）
## 参数：amount - 恢复的血量值
func heal(amount: float) -> void:
	if health_controller:
		health_controller.heal_core(amount)
		## 治疗音效
		if AudioManager:
			AudioManager.play_2d("player_heal", global_position, 0.7)

## 恢复护盾段数（对外接口）
## 参数：segments - 要恢复的护盾段数
func heal_shield(segments: int) -> void:
	if health_controller:
		health_controller.heal_shield(segments)

## ========== 装备护盾系统 ==========

## 设置最近攻击者信息（Bullet.gd / Enemy.gd 在调用 take_damage 前调用）
## 参数：attacker - 攻击者节点，context - 上下文字典
func set_last_attacker(attacker: Node, context: Dictionary = {}) -> void:
	_last_attacker = attacker
	_last_attack_context = context

## 装备护盾（由 EquipmentComponent 盾牌槽数据变化时下发 / 商店购买护盾调用）
## 参数：shield_data - 护盾装备数据资源
func equip_shield(shield_data: Resource) -> void:
	if equipment_shield != null and equipment_shield.has_method("equip"):
		equipment_shield.equip(shield_data)
		if AudioManager:
			AudioManager.play_2d("buff_pickup", global_position, 0.8)

## 强化当前装备护盾叠层（神庙「强化装备」选项随机命中"护盾"类时由
## UpgradeManager.enhance_random_equipped_equipment 调用）
## 参数：amount - 叠加层数（固定1），突破3层上限
## 返回：是否强化成功（无装备护盾时返回 false）
func boost_shield_stack(amount: int) -> bool:
	if equipment_shield != null and equipment_shield.has_method("add_stack"):
		return equipment_shield.add_stack(amount)
	return false

## 查询当前是否已装备护盾（神庙「强化装备」命中护盾类前的候选校验用）
## 说明：区别于 EquipmentShieldComponent.has_shield()（耐久>0才算有盾），
##       此处只判断"是否装备了护盾数据"——护盾破碎(耐久0)时仍可被神庙强化并补满耐久
## 返回：true=已装备护盾，false=未装备
func has_equipped_shield() -> bool:
	return equipment_shield != null \
			and equipment_shield.has_method("get_shield_data") \
			and equipment_shield.get_shield_data() != null

## 卸下当前装备护盾（装备系统盾牌槽卸下/替换时由 EquipmentComponent 调用）
func unequip_equipped_shield() -> void:
	if equipment_shield != null and equipment_shield.has_method("unequip"):
		equipment_shield.unequip()

## ========== 装备与背包对外接口（供掉落/商店/UI 调用） ==========

## 获取装备组件（UI 装备面板查询已穿装备/主动技能）
## 返回：EquipmentComponent 节点；未初始化时 null
func get_equipment_component() -> Node:
	return _equipment

## 获取背包组件（UI 背包面板增删查询）
## 返回：BackpackComponent 节点；未初始化时 null
func get_backpack() -> Node:
	return _backpack

## 把一件装备放入背包（拾取掉落物/商店购买装备时调用）
## 参数：data - EquipmentData 装备实例
## 返回：true=放入成功；false=背包已满或组件缺失
func add_equipment_to_backpack(data: Resource) -> bool:
	if _backpack == null or not _backpack.has_method("add_item"):
		return false
	var ok: bool = _backpack.add_item(data)
	if ok and AudioManager:
		AudioManager.play_2d("buff_pickup", global_position, 0.8)
	return ok

## 穿戴背包中指定下标的装备（UI 背包面板点击穿戴时调用）
## 参数：index - 背包物品下标（0-based）
## 返回：true=穿戴成功
func equip_equipment_from_backpack(index: int) -> bool:
	if _backpack == null or not _backpack.has_method("equip_from_backpack"):
		return false
	return _backpack.equip_from_backpack(index)

## 卸下指定槽位的装备并放回背包（UI 装备面板点击卸下时调用）
## 参数：slot - 槽位（EquipmentData.Slot）
## 返回：true=卸下成功
func unequip_equipment_slot(slot: int) -> bool:
	if _backpack == null or not _backpack.has_method("unequip_to_backpack"):
		return false
	return _backpack.unequip_to_backpack(slot)

## ========== 装备主动技能系统（第五维度：弹道构型做成带冷却的主动技） ==========

## 设置当前装备提供的全部主动技能（EquipmentComponent 装备变更时下发）
## 参数：skills - EquipmentActiveSkill 资源数组（按穿戴顺序；可空=无技能）
## 设计意图：主动技能不再"同时只生效一个"——每件携带技能的装备各贡献一个，
##          玩家用 Q/E 或手柄 LT/RT 在技能间前后切换，每个技能拥有独立冷却
func set_active_skills(skills: Array) -> void:
	_active_skills.clear()
	_active_skill_cds.clear()
	for skill in skills:
		if skill == null:
			continue
		_active_skills.append(skill)
		## 新技能初始冷却清零：换上即可用，避免沿用旧技能的剩余冷却
		_active_skill_cds.append(0.0)
	## 选中下标复位并夹取到合法范围（技能数变化后旧下标可能越界）
	_active_skill_index = 0
	if not _active_skills.is_empty():
		_active_skill_index = clampi(_active_skill_index, 0, _active_skills.size() - 1)

## 获取全部主动技能（HUD 技能栏展示用）
## 返回：EquipmentActiveSkill 数组（无技能为空数组）
func get_active_skills() -> Array[Resource]:
	return _active_skills

## 获取当前选中的主动技能（HUD 高亮/释放用）
## 返回：EquipmentActiveSkill 资源；无技能或下标越界时 null
func get_active_skill() -> Resource:
	if _active_skill_index < 0 or _active_skill_index >= _active_skills.size():
		return null
	return _active_skills[_active_skill_index]

## 获取当前选中的主动技能下标（HUD 高亮用）
## 返回：0 起下标；无技能时返回 0
func get_active_skill_index() -> int:
	return _active_skill_index

## 获取指定下标主动技能的冷却剩余比例（HUD 冷却遮罩用）
## 参数：index - 技能下标
## 返回：0.0=冷却完毕可释放，1.0=刚进入冷却；越界返回 0.0
func get_active_skill_cooldown_ratio_at(index: int) -> float:
	if index < 0 or index >= _active_skills.size() or index >= _active_skill_cds.size():
		return 0.0
	var cd: float = maxf(float(_active_skills[index].cooldown), 0.1)
	return clampf(float(_active_skill_cds[index]) / cd, 0.0, 1.0)

## 获取当前选中主动技能的冷却剩余比例（HUD 冷却遮罩用）
## 返回：0.0=冷却完毕可释放，1.0=刚进入冷却
func get_active_skill_cooldown_ratio() -> float:
	return get_active_skill_cooldown_ratio_at(_active_skill_index)

## 获取指定下标主动技能的冷却剩余秒数（HUD 倒计时文字用）
## 参数：index - 技能下标
## 返回：剩余秒数；越界返回 0.0
func get_active_skill_cooldown_remaining_at(index: int) -> float:
	if index < 0 or index >= _active_skill_cds.size():
		return 0.0
	return maxf(float(_active_skill_cds[index]), 0.0)

## 获取当前选中主动技能的冷却剩余秒数（HUD 倒计时文字用）
func get_active_skill_cooldown_remaining() -> float:
	return get_active_skill_cooldown_remaining_at(_active_skill_index)

## 更新主动技能（每物理帧调用：推进全部冷却 + 切换选中 + 检测 game_skill 释放）
## 参数：delta - 帧间隔时间（秒）
func _update_active_skill(delta: float) -> void:
	## 冷却推进（逐个推进，<=0 表示可用）
	for i in _active_skill_cds.size():
		if _active_skill_cds[i] > 0.0:
			_active_skill_cds[i] = maxf(_active_skill_cds[i] - delta, 0.0)
	## 无技能 / 非游戏进行中 → 不响应输入（神庙/商店面板会暂停游戏，天然屏蔽误触发）
	if _active_skills.is_empty() or not GameManager.is_playing():
		return
	## 多技能时前后切换选中：Q/E 或手柄 LT/RT（game_choice_prev/next，GAMEPLAY 已放行）
	## 输入经 InputManager 读取（禁止业务层直接读 Input），消费后释放
	if _active_skills.size() > 1:
		if InputManager.is_action_just_pressed_safe("game_choice_prev"):
			_switch_active_skill(-1)
		elif InputManager.is_action_just_pressed_safe("game_choice_next"):
			_switch_active_skill(1)
	## 释放当前选中技能（冷却中按下不产生任何效果）
	if InputManager.is_action_just_pressed_safe("game_skill"):
		_cast_active_skill()

## 切换当前选中的主动技能（环绕循环）
## 参数：step - 步进方向（-1=上一个 / +1=下一个）
func _switch_active_skill(step: int) -> void:
	var count: int = _active_skills.size()
	if count <= 1:
		return
	## 手动取模保证下标始终落在 [0, count)
	_active_skill_index = (_active_skill_index + step + count) % count

## 释放当前选中的主动技能：以临时子弹数据（携带技能的弹道构型）发射一次
## 设计：复用 shot 信号 + GameWorld.spawn_shot_pattern，无需新增子弹生成通道（解耦核心）
func _cast_active_skill() -> void:
	var skill: Resource = get_active_skill()
	## 技能/构型/子弹副本任一缺失则不释放
	if skill == null or skill.shot_pattern == null or _private_bullet_data == null:
		return
	## 下标越界或仍在冷却中 → 不释放
	if _active_skill_index < 0 or _active_skill_index >= _active_skill_cds.size():
		return
	if _active_skill_cds[_active_skill_index] > 0.0:
		return
	## 进入冷却（下限保护，避免0冷却导致每帧释放）
	_active_skill_cds[_active_skill_index] = maxf(float(skill.cooldown), 0.1)
	## 构造临时子弹数据：深拷贝私有副本（保留伤害/特效），仅替换弹道构型为技能的构型
	## 深拷贝使技能弹道拥有独立特效实例，避免与普通射击共享运行时状态
	var temp_data: BulletDataClass = _private_bullet_data.duplicate(true)
	temp_data.shot_pattern = skill.shot_pattern
	## 技能整轮伤害倍率：放大临时子弹的伤害基数，GameWorld 守恒分配时按放大后的基数分摊到各发
	## （构型形状/发数不变，仅提升整轮强度；倍率为 1.0 时与原行为完全一致）
	var skill_damage_mult: float = maxf(float(skill.damage_multiplier), 1.0)
	temp_data.damage = maxi(
		int(round(float(_private_bullet_data.damage) * skill_damage_mult)), 1)
	## 释放反馈：音效 + 攻击动画
	if AudioManager:
		AudioManager.play_2d("player_shoot", global_position, 0.9)
	if animator != null:
		animator.play_attack()
	## 发出 shot 信号（GameWorld 按 temp_data 的构型生成弹道）
	shot.emit(global_position, _aim_direction, temp_data)

## ========== 梦境碎片系统 ==========

## 添加梦境碎片（对外接口）
## 参数：amount - 要添加的碎片数量
func add_dream_fragment(amount: int) -> void:
	## 如果数量小于等于0，不执行任何操作
	if amount <= 0:
		return
	## 累加碎片数量
	dream_fragment += amount
	## 发出信号通知UI更新显示
	dream_fragment_changed.emit(dream_fragment)

	## 上报统计（结算面板展示的碎片总数）
	RunStats.add_fragment(amount)
	## 碎片=纯收集计数（HUD显示+结算统计），与装备成长完全无关——
	## 玩家成长仅一条途径：拾取装备（按 E 入背包后在装备面板穿戴）；

## 扣除梦境碎片（商店购买支付专用）
## 注意：只做货币扣减与HUD刷新，不上报 RunStats（fragments_total 统计的是"累计获得"，
##       不是"当前余额"，扣除不应影响结算的收集总数）
## 参数：amount - 要扣除的碎片数量
## 返回：true=扣除成功，false=余额不足或非法数量
func spend_dream_fragment(amount: int) -> bool:
	if amount <= 0 or dream_fragment < amount:
		return false
	dream_fragment -= amount
	## 发出信号通知UI更新显示
	dream_fragment_changed.emit(dream_fragment)
	return true

## ========== 装备碎片系统（分解产出 / 商店合成消耗） ==========

## 添加装备碎片（分解装备时调用）
## 参数：slot - 槽位（EquipmentData.Slot）；amount - 数量（<=0 或越界时忽略）
func add_equipment_fragment(slot: int, amount: int) -> void:
	if amount <= 0 or slot < 0 or slot >= equipment_fragments.size():
		return
	equipment_fragments[slot] += amount
	equipment_fragment_changed.emit(slot, equipment_fragments[slot])

## 获取指定槽位的装备碎片数量
## 参数：slot - 槽位（EquipmentData.Slot）
## 返回：该槽位持有数量；越界时返回 0
func get_equipment_fragment(slot: int) -> int:
	if slot < 0 or slot >= equipment_fragments.size():
		return 0
	return equipment_fragments[slot]

## 扣除指定槽位的装备碎片（商店合成支付专用）
## 参数：slot - 槽位；amount - 数量
## 返回：true=扣除成功；false=数量非法或碎片不足
func spend_equipment_fragment(slot: int, amount: int) -> bool:
	if amount <= 0 or slot < 0 or slot >= equipment_fragments.size():
		return false
	if equipment_fragments[slot] < amount:
		return false
	equipment_fragments[slot] -= amount
	equipment_fragment_changed.emit(slot, equipment_fragments[slot])
	return true

## 获取玩家当前生存状态（对外接口）
## 返回：包含护盾、核心血、无敌状态等信息的字典
func get_survival_state() -> Dictionary:
	if health_controller:
		return health_controller.get_survival_state()
	return {}

## ========== 信号回调方法 ==========

## 碰撞检测回调：当有物体进入hitbox区域时调用
## 参数：body - 进入区域的物体节点
func _on_hitbox_body_entered(body: Node2D) -> void:
	## 如果进入的物体有on_player_collision方法，调用它
	## 这是敌人碰撞玩家时的处理方式
	if body.has_method("on_player_collision"):
		body.on_player_collision(self)

## 健康状态变化回调：当护盾/核心血变化时调用
## 参数：state - 最新的生存状态字典
func _on_health_changed(state: Dictionary) -> void:
	## 将信号转发给UI等监听者
	health_changed.emit(state)

## 红血状态变化回调：当玩家进入/退出红血状态时调用
## 参数：is_active - 是否处于红血状态
func _on_critical_state_active(is_active: bool) -> void:
	_is_in_critical = is_active
	if is_active:
		## 红血状态：将玩家颜色变为红色，警示玩家
		sprite.modulate = Color(1, 0.3, 0.3, 1)
		## ---------- 险胜系统启动 ----------
		_critical_survival_timer = 0.0
		_heartbeat_interval = 0.8  ## 初始心跳间隔0.8秒
		_heartbeat_timer = 0.0
		_near_death_rewarded = false
		## 播放进入红血的警示音
		if AudioManager:
			AudioManager.play("heartbeat", 0.8, 0.6)
	else:
		## 退出红血：恢复原始颜色
		sprite.modulate = _original_color
		## ---------- 险胜系统重置 + 撤销临时加成 ----------
		if _near_death_rewarded and _private_bullet_data != null:
			## 撤销险胜临时攻击加成（恢复到奖励前的数值）
			_private_bullet_data.damage = int(float(_private_bullet_data.damage) / NEAR_DEATH_ATTACK_BONUS)
		_critical_survival_timer = 0.0
		_near_death_rewarded = false

## 玩家死亡回调：当玩家核心血量归零时调用
func _on_player_died() -> void:
	## 播放死亡动画（FRAMES 模式切到 death 槽位）
	if animator != null:
		animator.play_death()
	## 将玩家颜色变为半透明灰色，表示死亡（PROCEDURAL 模式的 sprite 用；FRAMES 模式下 sprite 隐藏，
	## 序列帧节点的灰化由死亡帧本身表现，此处对 sprite 的设置仅作兼容）
	sprite.modulate = Color(0.5, 0.5, 0.5, 0.5)

## ========== 无敌闪烁效果 ==========

## 启动无敌闪烁效果（受击后闪烁提示玩家处于无敌状态）
func _start_invincible_blink() -> void:
	## 如果精灵节点无效，直接返回
	if not is_instance_valid(sprite):
		return
	
	## 如果已经在闪烁中，防止重复启动
	if _blink_timer != null and is_instance_valid(_blink_timer):
		return
	
	## 重置闪烁计数
	_blink_count = 0
	## 设置初始闪烁颜色（半透明白色）
	sprite.modulate = Color(1, 1, 1, 0.5)
	
	## 创建新的计时器节点
	_blink_timer = Timer.new()
	## 设置闪烁间隔为0.1秒
	_blink_timer.wait_time = 0.1
	## 设置自动启动
	_blink_timer.autostart = true
	## 设置为循环模式（不是一次性）
	_blink_timer.one_shot = false
	## 将计时器添加到场景树
	add_child(_blink_timer)
	
	## 连接计时器超时信号到闪烁回调
	_blink_timer.timeout.connect(_on_blink_timeout)

## 无敌闪烁回调：每0.1秒调用一次，切换颜色
func _on_blink_timeout() -> void:
	## 递增闪烁计数
	_blink_count += 1
	## 设置总共闪烁5次（10次颜色切换，0.5秒总时长）
	var max_blinks: int = 5
	
	## 如果闪烁次数达到上限
	if _blink_count >= max_blinks:
		## 恢复玩家原始颜色
		if is_instance_valid(sprite):
			sprite.modulate = _original_color
		## 清理计时器节点
		if _blink_timer != null and is_instance_valid(_blink_timer):
			_blink_timer.queue_free()
			_blink_timer = null
		return
	
	## 偶数次闪烁：半透明白色
	if _blink_count % 2 == 0:
		sprite.modulate = Color(1, 1, 1, 0.5)
	## 奇数次闪烁：完全不透明
	else:
		sprite.modulate = Color(1, 1, 1, 1)