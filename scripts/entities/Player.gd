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

## ========== 导出变量（编辑器可配置） ==========

## 玩家移动速度（像素/秒）
@export var speed: float = 150.0

## 射击冷却时间（秒），控制射速
## 初始0.8秒一颗，前期节奏适中；通过升级词条（fire_rate_mult）逐步提升到中后期速度
@export var shoot_cooldown: float = 0.8

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

## ========== 成员变量（运行时数据） ==========

## 通用角色动画器组件（应用皮肤时创建；null=未启用动画——无皮肤回退占位时保持原样）
var animator: CharacterAnimatorClass = null

## 玩家当前拥有的梦境碎片数量
var dream_fragment: int = 0

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

## 玩家血量/护盾状态变化时发出此信号
## 参数：state - 包含当前生存状态的字典
signal health_changed(state: Dictionary)

## ========== 生命周期方法 ==========

## _ready() - 节点进入场景树时调用一次，用于初始化
func _ready() -> void:
	## 初始化梦境碎片为0
	dream_fragment = 0
	
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

	## 监听升级词条应用信号：任何词条应用后重新同步属性到自身
	## 数据流：UpgradeManager.apply_upgrade → upgrade_applied信号 → 此回调 → 同步移速/射速/弹属性
	if UpgradeManager:
		UpgradeManager.upgrade_applied.connect(_on_upgrade_applied)

	## 初始同步一次（兜底：若词条在玩家实例化之前已应用，也能拿到正确属性）
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

## 词条应用信号回调（响应UpgradeManager.upgrade_applied）
## 参数：upgrade - 被应用的词条（特效词条已由UpgradeManager直接调用apply_bullet_effect，
##        此处只需同步属性词条带来的数值变化）
func _on_upgrade_applied(_upgrade: Resource) -> void:
	## 重新同步全部属性（同步成本低，统一处理最简单可靠）
	_sync_upgrade_stats()

## 追加子弹特效（词条特效/BUFF的统一入口，由UpgradeManager调用）
## 数据流：UpgradeManager.apply_upgrade(特效词条) → 此方法 → 追加到私有子弹副本
## 参数：effect - 子弹特效资源（data/bullet/effect/下的.tres）
func apply_bullet_effect(effect: Resource) -> void:
	## 空特效或副本未初始化时拒绝
	if effect == null or _private_bullet_data == null:
		return
	## 按effect_id去重：同一特效只能拥有一次（重复追加会多次触发）
	if has_bullet_effect(effect.effect_id if "effect_id" in effect else ""):
		return
	## 追加到私有子弹副本的特效列表（每发子弹都会携带）
	_private_bullet_data.effects.append(effect)
	## 播放获得特效音效（区别于普通拾取的强化感）
	if AudioManager:
		AudioManager.play("buff_pickup", 0.8)

## 查询是否已拥有某子弹特效（UpgradeManager三选一去重过滤用）
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

## 应用核心血量上限加值（UpgradeManager血量词条调用）
## 数据流：UpgradeManager.apply_upgrade(max_hp_bonus词条) → 此方法 → 血量组件扩容
## 参数：amount - 上限增加值（同时立即治疗等量血量）
func apply_max_hp_bonus(amount: int) -> void:
	## 非法增量或控制器缺失时拒绝
	if amount <= 0 or health_controller == null:
		return
	## 查找核心血量组件并调用扩容方法（has_method检查保证健壮性）
	var core_comp: Node = health_controller.get_node_or_null("CoreHealthComponent")
	if core_comp != null and core_comp.has_method("expand_max_hp"):
		core_comp.expand_max_hp(float(amount))

## 拾取技能书（青绿宝珠BUFF道具，手动按E拾取后由DropItem.apply调用）
## 数据流：敌人掉落技能书 → 玩家手动按E拾取 → DropItem.apply → 此方法
## 设计意图：技能书=立即获得一次"三选一"升级机会（打开与经验升级完全相同的选择面板，
##           由玩家自选词条），而非随机直接塞一个——玩家对Build有控制权，体验与捡碎片升级一致，
##           不会再出现"捡了书却莫名获得技能"的困惑。open_level_up_choice自带is_choosing锁与
##           _pending_upgrades排队：连捡多本或与经验升级同时触发时会依次排队弹出，不会叠加/丢帧
## 参数：item_id - 道具id（预留：未来可区分不同品质技能书），value - 数值（预留扩展）
func add_buff(item_id: String, value: int) -> void:
	if UpgradeManager:
		UpgradeManager.open_level_up_choice()

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

		var border_color: Color = Color(1.0, 0.9, 0.3, 0.0)
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

		## 闪烁动画：淡入→停留→淡出→销毁
		var tw: Tween = border_parent.create_tween()
		tw.set_parallel(true)
		tw.tween_property(border_parent, "modulate:a", 1.0, 0.3)
		tw.tween_property(border_parent, "modulate:a", 0.0, 1.2)\
			.set_delay(0.8)
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
		var hp_before: float = state_before.get("core_hp", 0)
		var shield_before: int = state_before.get("shield_segments", 0)

		## 调用健康控制器处理伤害（先扣分段护盾，再扣核心血）
		health_controller.apply_damage(remaining, "unknown")

		## 记录受伤后的状态
		var state_after: Dictionary = health_controller.get_survival_state()
		var is_invincible: bool = state_after.get("is_invincible", false)
		var shield_after: int = state_after.get("shield_segments", 0)
		var hp_after: float = state_after.get("core_hp", 0)

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

## 装备护盾（拾取 EQUIPMENT 类型掉落物时由 DropItem.apply 调用）
## 参数：shield_data - 护盾装备数据资源
func equip_shield(shield_data: Resource) -> void:
	if equipment_shield != null and equipment_shield.has_method("equip"):
		equipment_shield.equip(shield_data)
		if AudioManager:
			AudioManager.play_2d("buff_pickup", global_position, 0.8)

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
	## 碎片=纯收集计数（HUD显示+结算统计），与技能/升级完全无关——
	## 获得技能词条仅两条途径：手动按E拾取技能宝石、神庙"随机技能"（均走三选一面板）

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