## Enemy.gd - 敌人角色核心脚本
## 职责：管理敌人AI状态机（漫游/追踪/攻击）、移动、射击、血量、掉落等逻辑
## 继承：CharacterBody2D（Godot 4的2D物理角色节点）
## 节点结构：Enemy(CharacterBody2D) → Sprite2D(外观，精英怪含 EliteGlow 发光子节点) / Hitbox(Area2D, 玩家接触判定)
## 系统交互：
##   - 组：由 GameWorld 生成时加入"enemy"+"normal_enemy"/"elite_enemy"（阵营判定/特效查询/统计）
##   - 信号：killed → GameWorld 移除管理列表并计数；drops_generated → GameWorld 生成拾取物；
##           damaged/attacked 预留给受击/攻击动画
##   - 数据：enemy_data.tres 由 GameWorld 深拷贝并难度缩放后注入（apply_to_enemy 覆盖下方导出默认值）
## 碰撞层：本体 layer=2(敌人层)/mask=19（1玩家+2敌人+16竞技场墙）；Hitbox layer=0/mask=1（检测玩家层）
## 设计意图：三态状态机(WANDER/CHASE/ATTACK)按与玩家距离驱动；子弹就地生成
##           （与玩家"只发信号由GameWorld创建"不同——敌人数量多，就地实例化链路最短）
extends CharacterBody2D

## ========== 预加载资源（避免运行时加载延迟） ==========

## 竞技场碰撞掩码常量（世界墙层位单一数据源，与GameWorld.tscn墙体保持一致）
const ArenaConfigClass = preload("res://scripts/world/ArenaConfig.gd")

## 敌人数据资源类，用于加载配置数据
const EnemyDataClass = preload("res://scripts/resources/enemy/EnemyData.gd")

## 子弹数据资源类，用于配置子弹属性
const BulletDataClass = preload("res://scripts/resources/bullet/BulletData.gd")

## 子弹形态资源类，用于配置子弹外观
const BulletFormClass = preload("res://scripts/resources/bullet/BulletForm.gd")

## 子弹场景预加载，避免运行时重复加载导致性能问题
const BULLET_SCENE: PackedScene = preload("res://scenes/gameplay/Bullet.tscn")

## 掉落物数据资源类
const DropItemClass = preload("res://scripts/resources/enemy/DropItem.gd")

## 残影/碎片节点类（对象池管理的高频视觉元素，死亡碎片专用）
const TrailGhostClass = preload("res://scripts/entities/TrailGhost.gd")

## 角色皮肤资源类（主题系统：皮肤决定外观+动画参数）
const CharacterSkinClass = preload("res://scripts/resources/skin/CharacterSkin.gd")

## 主题包资源类（ThemeManager.theme_changed 信号的负载类型）
const GameThemeClass = preload("res://scripts/resources/skin/GameTheme.gd")

## 通用角色动画器组件（驱动呼吸/弹跳/攻击/受击动画）
const CharacterAnimatorClass = preload("res://scripts/components/CharacterAnimator.gd")

## 浮动伤害数字组件（每次命中弹出伤害数字，直播增强）
const DamageNumberClass = preload("res://scripts/components/DamageNumber.gd")

## ========== 静态纹理缓存（性能优化） ==========
## 设计意图：占位纹理按形状逐像素生成（30x30=900次set_pixel）+纹理上传，
##           每次刷怪都重新生成会在波次刷怪时造成明显hitch；
##           同"形状|颜色|尺寸"的敌人共享同一张纹理（static缓存，跨实例复用）
static var _texture_cache: Dictionary = {}

## ========== 导出变量（编辑器可配置） ==========

## 敌人数据资源，包含敌人属性、掉落、子弹配置等（数据与逻辑分离）
@export var enemy_data: EnemyDataClass = null

## 敌人移动速度（追踪玩家时的速度，像素/秒）
@export var speed: float = 100.0

## 敌人漫游速度（无玩家时的随机移动速度，像素/秒）
@export var wander_speed: float = 60.0

## 敌人漫游方向切换间隔（秒）
@export var wander_interval: float = 2.0

## 敌人最大血量
@export var max_health: int = 5

## 敌人当前血量
@export var health: int = 5

## 敌人碰撞玩家时造成的伤害
@export var damage: int = 10

## 敌人检测范围（玩家进入此范围后开始追踪，像素）
@export var detection_range: float = 450.0

## 敌人攻击范围（玩家进入此范围后停止移动并攻击，像素）
@export var attack_range: float = 300.0

## 敌人攻击冷却时间（秒）
@export var attack_cooldown: float = 1.0

## 技能冷却时间（秒，独立于攻击冷却，控制技能释放频率）
@export var skill_cooldown: float = 8.0

## 技能伤害（独立于碰撞伤害，技能子弹/AOE使用此值）
@export var skill_damage: int = 5

## ========== 节点引用（使用 @onready 延迟初始化） ==========

## 敌人精灵节点，用于显示敌人外观
@onready var sprite: Sprite2D = $Sprite2D

## 敌人碰撞检测区域，用于检测玩家碰撞
@onready var hitbox: Area2D = $Hitbox

## ========== 成员变量（运行时数据） ==========

## 玩家引用，用于追踪和攻击
var _player: CharacterBody2D = null

## 通用角色动画器组件（应用皮肤时创建；null=无主题回退占位时保持原样）
var animator: CharacterAnimatorClass = null

## 敌人"逻辑色"（死亡碎片颜色/无形态子弹染色都取此色）
## 初始化自 enemy_data.placeholder_color；应用主题皮肤后跟随皮肤主色
var _body_color: Color = Color(1, 0.2, 0.2, 1)

## 敌人原始颜色，用于受伤后恢复显示
var _original_color: Color = Color.WHITE

## 受击白闪进行中标记（闪烁窗口复用开关）
## 设计意图：高射速连打时同一敌人每秒可被命中数十次，旧实现每次命中都
## new一个0.1秒SceneTreeTimer——高频小对象分配churn + 多个恢复回调竞态错乱；
## 改为"窗口期内复用同一次闪烁"，计时器频率被钳制到最多10次/秒/敌人
var _flash_active: bool = false

## 攻击冷却计时器，递减到0时可再次攻击
var _attack_timer: float = 0.0

## 技能冷却计时器，递减到0时可释放技能（独立于攻击冷却）
var _skill_timer: float = 0.0

## 技能释放中标记（冲锋/传送/自爆等技能执行期间为true，暂停普通AI）
var _skill_active: bool = false

## 死亡标记（防重入：_die()调用后置true，take_damage/_physics_process据此跳过）
## 设计意图：敌人血量归零到call_deferred("queue_free")真正执行之间有一帧间隙，
##           期间子弹仍可命中导致take_damage重复触发_die()，引发重复掉落/异常中断
var _is_dying: bool = false

## AI节流计数器：远距敌人每5物理帧才更新一次_update_state（距离计算+状态切换），
## 近距（CHASE/ATTACK）每帧更新。140敌人×5帧节流=等效28敌人AI开销
## 设计意图：后期140敌人在场，80%在WANDER远距，节流后CPU开销降为1/5
var _ai_throttle_counter: int = 0
const AI_THROTTLE_INTERVAL: int = 5

## ========== 技能HUD（头顶技能名称+冷却进度条） ==========

## 技能名称标签（显示在敌人头顶）
var _skill_name_label: Label = null

## 冷却进度条背景（深色底条）
var _skill_bar_bg: ColorRect = null

## 冷却进度条前景（随冷却递减从右向左缩短）
var _skill_bar_fg: ColorRect = null

## 技能HUD容器（控制整体显隐）
var _skill_hud: Control = null

## 漫游方向切换计时器，递减到0时切换漫游方向
var _wander_timer: float = 0.0

## 当前漫游方向向量
var _wander_direction: Vector2 = Vector2.ZERO

## 当前敌人状态（漫游/追踪/攻击）
var _current_state: EnemyState = EnemyState.WANDER

## ========== 远距碰撞休眠（性能核心优化：修复8分钟后大敌潮卡顿） ==========

## 设计意图（为什么需要）：
##   敌人碰撞 mask=3 含"敌人层"——所有敌人涌向玩家会形成高密度"人堆"，
##   堆内任意两只敌人都在做窄相碰撞解算，成本随堆密度 O(n²) 增长；
##   8分钟后刷怪节奏追上击杀节奏，同屏~140只敌人挤在玩家周围时
##   物理服务器每帧要做上万次圆形窄相检测 → 全画面掉帧。
## 方案（为什么不删敌人间碰撞）：
##   敌人互相推挤是近身玩法的一部分（在玩家周围形成包围圈而非叠成一格），
##   不能直接去掉；但屏幕外的敌人玩家根本看不见，其碰撞纯属白算——
##   远距敌人休眠碰撞（mask=0，直接位移无推挤），接近时恢复完整碰撞。
## 迟滞双阈值：750px 休眠 / 650px 唤醒，两阈值相隔100px防止在边界来回抖动
##   （单阈值下敌人恰好在阈值附近徘徊时每帧切换mask会疯狂触发物理服务器重建配对）

## 触发休眠的距离（与玩家距离超过此值 → 关闭碰撞，纯位移追玩家）
const COLLISION_DORMANT_DISTANCE: float = 750.0

## 恢复唤醒的距离（与玩家距离回到此值内 → 恢复完整碰撞）
const COLLISION_AWAKE_DISTANCE: float = 650.0

## 完整碰撞掩码（玩家层1 + 敌人层2 + 世界墙层16 = 19，与 Enemy.tscn 配置一致；
## 世界墙层位定义在 ArenaConfig，休眠唤醒后敌人仍会被竞技场墙挡住）
const COLLISION_MASK_ACTIVE: int = ArenaConfigClass.MASK_ENTITY_BLOCKING

## 休眠碰撞掩码（仅世界墙16）：关闭敌人间互挤/玩家碰撞（消除O(n²)窄相），
## 但保留对4堵静态墙的碰撞（O(1)成本），防止被击退弹到墙外的敌人唤醒后回不进场
const COLLISION_MASK_DORMANT: int = ArenaConfigClass.MASK_DORMANT

## 当前是否处于碰撞休眠状态（true=mask已切到仅墙16；避免每帧重复写碰撞属性）
var _collision_dormant: bool = false

## ========== 状态枚举（敌人AI状态机） ==========

enum EnemyState {
	WANDER,   ## 漫游状态：无玩家时随机移动
	CHASE,    ## 追踪状态：向玩家方向移动
	ATTACK    ## 攻击状态：停止移动并发射子弹
}

## ========== 信号定义（用于与其他节点通信） ==========

## 敌人死亡时发出此信号
signal killed()

## 敌人受到伤害时发出此信号
## 参数：amount - 受到的伤害数值
signal damaged(amount: int)

## 敌人死亡时生成掉落物后发出此信号
## 参数：position - 掉落位置，drops - 掉落道具列表
signal drops_generated(position: Vector2, drops: Array)

## 敌人攻击时发出此信号
## 参数：direction - 攻击方向
signal attacked(direction: Vector2)

## ========== 生命周期方法 ==========

## _ready() - 节点进入场景树时调用一次，用于初始化
func _ready() -> void:
	## 如果有敌人数据资源，将配置应用到敌人（覆盖默认值）
	if enemy_data != null:
		enemy_data.apply_to_enemy(self)
	
	## 初始化血量为最大值
	health = max_health
	## 初始化攻击冷却计时器为0（立即可以攻击）
	_attack_timer = 0.0
	## 初始化技能冷却计时器为满值（避免敌人一出现就放技能，首回合需等完整冷却）
	_skill_timer = skill_cooldown
	## 初始化漫游计时器为0（立即开始漫游）
	_wander_timer = 0.0
	## 获取初始漫游方向
	_wander_direction = _get_random_direction()
	
	## ========== 外观：主题皮肤（优先）→ 占位纹理（回退） ==========
	## 逻辑色初始化：死亡碎片颜色/无形态子弹染色都取此色（先取数据占位色作默认）
	if enemy_data != null:
		_body_color = enemy_data.placeholder_color

	## 从 ThemeManager 获取本敌人的皮肤：enemy_id 精确匹配 → 主题兜底皮肤 → null
	## 数据流：ThemeManager(autoload)已加载主题 → get_enemy_skin(enemy_id) → 应用
	## 防护：ThemeManager 单例异常（解析失败未实例化）时标识符为 null，
	##       直接调用会中断 _ready → 占位纹理逻辑被跳过 → 敌人隐形（已发生的线上事故），
	##       因此必须判空后再调用，保证任何情况下都走到纹理赋值
	var skin: CharacterSkinClass = null
	if ThemeManager:
		skin = ThemeManager.get_enemy_skin(
			enemy_data.enemy_id if enemy_data != null else "")
	if skin != null:
		## 有皮肤：应用皮肤（纹理+动画器+逻辑色跟随皮肤主色）
		_apply_skin(skin)
	else:
		## 无主题回退：按 EnemyData 的占位尺寸生成形状纹理（原有逻辑）
		var width: int = 30
		var height: int = 30
		if enemy_data != null:
			width = int(enemy_data.placeholder_size.x)
			height = int(enemy_data.placeholder_size.y)
		_create_placeholder_texture(sprite, _body_color, width, height)
		## 精英怪发光（回退路径）
		if enemy_data != null and enemy_data.is_elite:
			_create_elite_glow_effect()

	## 保存敌人原始颜色，用于受伤后恢复
	_original_color = sprite.modulate

	## 监听主题热切换信号：设置界面切主题时全场敌人即时换肤
	## 数据流：ThemeManager.set_theme → theme_changed信号 → 此回调 → 重新索取皮肤
	if ThemeManager and not ThemeManager.theme_changed.is_connected(_on_theme_changed):
		ThemeManager.theme_changed.connect(_on_theme_changed)
	
	## 连接碰撞检测信号：当有物体进入hitbox区域时触发回调
	if hitbox:
		hitbox.body_entered.connect(_on_hitbox_body_entered)

	## 构建技能HUD（头顶技能名称+冷却进度条，仅有技能的高级怪才创建）
	_create_skill_hud()

	## 开启_process驱动HUD更新
	set_process(true)

## ========== 技能HUD构建与更新 ==========

## _create_skill_hud() - 在敌人头顶创建技能名称+冷却进度条
## 只有配置了monster_skill的高级怪才创建HUD，小怪无技能则跳过
func _create_skill_hud() -> void:
	## 无技能配置：不创建HUD
	if enemy_data == null or enemy_data.monster_skill == null:
		return

	var skill: Resource = enemy_data.monster_skill

	## HUD容器：定位在敌人头顶上方
	_skill_hud = Control.new()
	_skill_hud.name = "SkillHUD"
	add_child(_skill_hud)
	## 定位到敌人头顶（sprite上方约-40px处）
	_skill_hud.position = Vector2(-40, -50)
	_skill_hud.set_anchors_and_offsets_preset(Control.PRESET_CENTER)

	## 技能名称标签
	_skill_name_label = Label.new()
	_skill_name_label.text = skill.display_name
	_skill_name_label.add_theme_color_override("font_color", skill.effect_color)
	_skill_name_label.add_theme_font_size_override("font_size", 9)
	_skill_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_skill_name_label.size = Vector2(80, 12)
	_skill_name_label.position = Vector2(0, 0)
	_skill_hud.add_child(_skill_name_label)

	## 冷却进度条背景（深色底条）
	_skill_bar_bg = ColorRect.new()
	_skill_bar_bg.color = Color(0.1, 0.1, 0.15, 0.7)
	_skill_bar_bg.size = Vector2(60, 3)
	_skill_bar_bg.position = Vector2(10, 13)
	_skill_hud.add_child(_skill_bar_bg)

	## 冷却进度条前景（技能主题色，随冷却递减从右向左缩短）
	_skill_bar_fg = ColorRect.new()
	_skill_bar_fg.color = skill.effect_color
	_skill_bar_fg.size = Vector2(60, 3)
	_skill_bar_fg.position = Vector2(10, 13)
	_skill_hud.add_child(_skill_bar_fg)

## 技能HUD刷新节流间隔（秒）：每个敌人每帧做距离判定+进度条更新在LV32后(同屏数十敌人)开销显著，
## 冷却条/显隐以4Hz刷新视觉上完全足够
const SKILL_HUD_REFRESH_INTERVAL: float = 0.25
## 技能HUD刷新节流计时器
var _skill_hud_timer: float = 0.0

## _process() - 节流更新技能HUD（冷却进度条+距离显隐），后期同屏敌人多时显著降低每帧开销
func _process(delta: float) -> void:
	_skill_hud_timer -= delta
	if _skill_hud_timer <= 0.0:
		_skill_hud_timer = SKILL_HUD_REFRESH_INTERVAL
		_update_skill_hud()

## 更新技能HUD状态（冷却进度条宽度+距离显隐）
func _update_skill_hud() -> void:
	if _skill_hud == null or not is_instance_valid(_skill_hud):
		return
	## 玩家不存在或距离过远时隐藏HUD（避免屏幕外敌人HUD占资源）
	if _player == null or not is_instance_valid(_player):
		_skill_hud.visible = false
		return
	var dist: float = global_position.distance_to(_player.global_position)
	## 超过600像素不显示HUD（超出视觉范围）
	_skill_hud.visible = dist < 600.0

	## 更新冷却进度条：进度=剩余冷却/总冷却（1=刚释放，0=冷却完成可再放）
	if skill_cooldown > 0.0 and _skill_bar_fg != null:
		var progress: float = clampf(_skill_timer / skill_cooldown, 0.0, 1.0)
		## 进度条从满到空（冷却中=长条，可释放=空条）
		_skill_bar_fg.size.x = 60.0 * progress

		## 冷却完成时进度条闪烁提示（可释放状态）
		if _skill_timer <= 0.0:
			_skill_bar_fg.color = Color(1.0, 1.0, 0.3, 0.8 + 0.2 * sin(Time.get_ticks_msec() * 0.008))
		else:
			## 恢复正常颜色
			if enemy_data != null and enemy_data.monster_skill != null:
				_skill_bar_fg.color = enemy_data.monster_skill.effect_color

## ========== 辅助方法 ==========

## 创建占位纹理（无美术资源时使用，按形状类型生成：方形/圆形/菱形）
## 性能设计：纹理按"形状|颜色|尺寸"键入静态缓存，同配置敌人共享纹理；
##           首次生成后不再有逐像素循环和纹理上传开销（波次刷怪不卡顿）
## 数据流：enemy_data.get_shape_type() → 缓存查询/首次生成 → ImageTexture → sprite
## 参数：sprite_node - 要设置纹理的Sprite2D节点
##       color - 纹理颜色
##       width - 纹理宽度（像素）
##       height - 纹理高度（像素）
func _create_placeholder_texture(sprite_node: Sprite2D, color: Color, width: int, height: int) -> void:
	## 获取实际形状类型（auto时按enemy_id自动推断，无数据时默认方形）
	var shape: String = "square"
	if enemy_data != null:
		shape = enemy_data.get_shape_type()

	## 缓存键：形状|颜色|宽|高（颜色转html保证不同色不串缓存）
	var cache_key: String = "%s|%s|%d|%d" % [shape, color.to_html(), width, height]
	## 缓存命中：直接复用已有纹理（零生成开销）
	if _texture_cache.has(cache_key):
		sprite_node.texture = _texture_cache[cache_key]
		return

	## 缓存未命中：首次生成纹理
	## 创建透明底图（形状外的像素保持透明，形成轮廓）
	var image: Image = Image.create(width, height, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))

	## 图像中心坐标与判定半径（取宽高较小值的一半，保证形状完整）
	var cx: float = width / 2.0
	var cy: float = height / 2.0
	var radius: float = min(width, height) / 2.0

	## 按形状逐像素填充
	for y in range(height):
		for x in range(width):
			var dx: float = x + 0.5 - cx
			var dy: float = y + 0.5 - cy
			var filled: bool = false
			match shape:
				"circle":
					## 圆形判定：像素到中心的欧氏距离不超过半径
					filled = Vector2(dx, dy).length() <= radius
				"diamond":
					## 菱形判定：像素到中心的曼哈顿距离不超过半径
					filled = absf(dx) + absf(dy) <= radius
				_:
					## 方形判定：矩形范围内全部填充
					filled = true
			if filled:
				image.set_pixel(x, y, color)

	## 将图像转换为纹理并存入缓存（下次同配置敌人直接复用）
	var texture: ImageTexture = ImageTexture.create_from_image(image)
	_texture_cache[cache_key] = texture
	## 将纹理设置到Sprite2D节点上
	sprite_node.texture = texture

## ========== 主题皮肤系统（一键换肤） ==========

## 应用角色皮肤（首次创建 / 主题热切换时调用）
## 参数：skin - 角色皮肤资源（来自 ThemeManager.get_enemy_skin）
func _apply_skin(skin: CharacterSkinClass) -> void:
	## 皮肤为空直接返回（防御）
	if skin == null:
		return
	## PROCEDURAL 模式：把皮肤生成的纹理挂到敌人精灵（皮肤内部缓存，同皮肤共享一张纹理）
	if not skin.has_frames():
		sprite.texture = skin.get_texture()
	## 重置精灵调制色为白色：场景中 Sprite2D 自带红色 modulate（旧占位染色），
	## 皮肤纹理颜色已经正确，叠加调制会串色；白调制保证皮肤颜色原样显示
	if not sprite.modulate.is_equal_approx(Color.WHITE):
		sprite.modulate = Color.WHITE
	## 创建/更新动画器（FRAMES 模式会在内部创建 AnimatedSprite2D 并隐藏色块精灵）
	_ensure_animator(skin)
	## 逻辑色跟随皮肤主色：死亡碎片/无形态子弹染色与外观保持一致
	_body_color = skin.main_color
	## 精英怪发光重建（皮肤纹理已变化，光晕必须跟着换）
	if enemy_data != null and enemy_data.is_elite:
		_create_elite_glow_effect()

## 获取或创建动画器组件（首次创建，之后复用并重设皮肤）
func _ensure_animator(skin: CharacterSkinClass) -> void:
	## 已有动画器：只需重设皮肤（热切换主题场景）
	if animator != null:
		animator.setup(skin, sprite)
		return
	## 首次：创建动画器组件挂到敌人下（自驱动 _process，不占AI逻辑帧）
	animator = CharacterAnimatorClass.new()
	animator.name = "CharacterAnimator"
	add_child(animator)
	animator.setup(skin, sprite)

## 主题切换回调（ThemeManager.theme_changed）：全场敌人即时换肤
func _on_theme_changed(theme: GameThemeClass) -> void:
	## 按新主题重新索取本敌人的皮肤（enemy_id 匹配 → 兜底皮肤）
	## 防护：单例异常时标识符为 null，判空避免回调中断（保持当前外观即可）
	if ThemeManager == null:
		return
	var new_skin: CharacterSkinClass = ThemeManager.get_enemy_skin(
		enemy_data.enemy_id if enemy_data != null else "")
	## 新主题有可用皮肤才应用（null 时保持当前外观，避免变成隐形）
	if new_skin != null:
		_apply_skin(new_skin)

## 创建精英怪发光效果（使精英怪更加醒目）
func _create_elite_glow_effect() -> void:
	if sprite == null:
		return

	## 移除旧的发光节点（主题热切换会重复调用本方法，防止光晕叠加多层）
	var old_glow: Node = sprite.get_node_or_null("EliteGlow")
	if old_glow != null:
		old_glow.queue_free()
		## 同帧内 add_child 前旧节点仍在树上会重名，立即改名规避
		old_glow.name = "EliteGlow_Old"

	## 创建发光精灵作为子节点
	var glow_sprite: Sprite2D = Sprite2D.new()
	glow_sprite.name = "EliteGlow"
	glow_sprite.offset = Vector2.ZERO
	glow_sprite.modulate = Color(1, 0.5, 0, 0.4)
	glow_sprite.scale = Vector2(1.5, 1.5)
	glow_sprite.z_index = -1

	## 发光纹理直接复用敌人自身纹理：
	## 形状（方形/圆形/菱形）与敌人轮廓完全一致，避免方形光晕包裹圆形敌人的违和感
	glow_sprite.texture = sprite.texture
	
	## 将发光精灵添加到敌人节点
	sprite.add_child(glow_sprite)
	
	## 添加呼吸动画（使发光效果有脉动感）
	var tween: Tween = create_tween()
	tween.set_loops()
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(glow_sprite, "scale", Vector2(1.8, 1.8), 1.0)
	tween.tween_property(glow_sprite, "scale", Vector2(1.5, 1.5), 1.0)
	tween.tween_property(glow_sprite, "modulate:a", 0.6, 1.0)
	tween.tween_property(glow_sprite, "modulate:a", 0.3, 1.0)

## ========== 物理帧更新方法 ==========

## _physics_process() - 每物理帧调用一次（默认60次/秒），用于处理敌人AI逻辑
func _physics_process(delta: float) -> void:
	## 死亡后不再执行AI逻辑（_die()到queue_free执行间的一帧间隙内防跑尸体）
	if _is_dying:
		return
	## 如果玩家引用为空，尝试查找玩家
	if _player == null:
		_find_player()
		## 如果仍然找不到玩家，执行漫游逻辑并返回
		if _player == null:
			_handle_wander(delta)
			return
	
	## 递减攻击冷却计时器
	_attack_timer -= delta
	## 递减漫游方向切换计时器
	_wander_timer -= delta
	## 递减技能冷却计时器（独立于攻击冷却）
	_skill_timer -= delta

	## 技能释放中时跳过普通AI（冲锋/传送/自爆等技能需要独占控制权）
	if _skill_active:
		return

	## 技能冷却完成且有技能配置 → 优先释放技能（在普通AI之前）
	if _skill_timer <= 0.0 and enemy_data != null and enemy_data.monster_skill != null:
		if _current_state != EnemyState.WANDER:
			_perform_skill()
			_skill_timer = skill_cooldown

	## 根据与玩家的距离更新当前状态（AI节流：远距敌人每5帧更新一次）
	## 性能优化：140敌人在场时_update_state每帧×140次distance_to+状态切换开销大；
	##           WANDER态敌人远距时不需要每帧精确距离，5帧≈83ms仍够响应状态切换
	_ai_throttle_counter += 1
	if _current_state == EnemyState.WANDER:
		## 远距漫游态：节流更新（每5帧一次）
		if _ai_throttle_counter >= AI_THROTTLE_INTERVAL:
			_ai_throttle_counter = 0
			_update_state()
	else:
		## 近距追踪/攻击态：每帧更新（保证战斗精度）
		_update_state()
	
	## 根据当前状态执行对应逻辑
	match _current_state:
		EnemyState.WANDER:
			_handle_wander(delta)
		EnemyState.CHASE:
			_handle_chase(delta)
		EnemyState.ATTACK:
			_handle_attack(delta)

## ========== 玩家查找方法 ==========

## 查找玩家引用（优先从父节点获取，备用方案从组查找）
func _find_player() -> void:
	## 优先方案：从父节点（GameWorld）获取玩家引用
	## 原因：GameWorld已经持有玩家引用，直接获取更可靠高效
	var parent_node: Node = get_parent()
	if parent_node != null and "player" in parent_node:
		var potential_player: CharacterBody2D = parent_node.player
		if potential_player != null and is_instance_valid(potential_player):
			_player = potential_player
			return
	
	## 备用方案：从"player"组查找玩家
	## 原因：如果父节点没有玩家引用，通过组查找作为兜底
	var players: Array[Node] = get_tree().get_nodes_in_group("player")
	if players.size() > 0:
		_player = players[0] as CharacterBody2D

## ========== 随机方向生成 ==========

## 获取随机方向向量（用于漫游）
func _get_random_direction() -> Vector2:
	## 生成0到2π之间的随机角度
	var angle: float = RandomManager.randf() * TAU
	## 将角度转换为单位向量并返回
	return Vector2(cos(angle), sin(angle)).normalized()

## ========== 状态机更新 ==========

## 根据与玩家的距离更新敌人状态
func _update_state() -> void:
	## 如果玩家为空，保持漫游状态
	if _player == null:
		_current_state = EnemyState.WANDER
		return

	## 计算敌人与玩家之间的距离（使用全局坐标）
	var distance: float = global_position.distance_to(_player.global_position)

	## 远距碰撞休眠判定（每帧利用现成的距离值，零额外开销）
	_update_collision_hibernation(distance)

	## 在攻击范围内 → 切换到攻击状态
	if distance <= attack_range:
		_current_state = EnemyState.ATTACK
	else:
		## 攻击范围外 → 始终切换到追踪状态（无论是否在检测范围内）
		## 设计意图：简化AI逻辑，敌人始终追踪玩家
		_current_state = EnemyState.CHASE

## 更新远距碰撞休眠状态（迟滞双阈值切换，见常量区设计说明）
## 数据流：_update_state 每帧传入与玩家的实时距离 → 与双阈值比较 →
##         跨越阈值时才写一次 collision_mask（同值重复写会被跳过，无属性抖动）
## 参数：distance - 敌人与玩家的当前距离（全局坐标，像素）
func _update_collision_hibernation(distance: float) -> void:
	if _collision_dormant:
		## 休眠中：距离回到唤醒阈值内 → 恢复完整碰撞（重新加入玩家推挤+敌人互挤）
		if distance <= COLLISION_AWAKE_DISTANCE:
			_collision_dormant = false
			collision_mask = COLLISION_MASK_ACTIVE
	else:
		## 活跃中：距离超过休眠阈值 → 关闭碰撞（屏幕外无需推挤，纯位移追玩家）
		if distance > COLLISION_DORMANT_DISTANCE:
			_collision_dormant = true
			collision_mask = COLLISION_MASK_DORMANT

## ========== 状态处理方法 ==========

## 处理漫游状态逻辑
## 参数：delta - 帧间隔时间（秒）
func _handle_wander(delta: float) -> void:
	## 如果漫游计时器归零，切换新的漫游方向
	if _wander_timer <= 0.0:
		_wander_direction = _get_random_direction()
		_wander_timer = wander_interval

	## 设置漫游速度
	velocity = _wander_direction * wander_speed
	## 执行移动并处理碰撞
	move_and_slide()

	## ---------- 动画状态同步（有动画器时） ----------
	if animator != null:
		## 漫游=移动中：播放弹跳/摇摆动画
		animator.set_moving(true)
		## 朝向跟随漫游方向（左右翻转眼睛朝向）
		animator.set_facing(_wander_direction.x)

## 处理追踪状态逻辑
## 参数：delta - 帧间隔时间（秒）
func _handle_chase(delta: float) -> void:
	## 如果玩家为空，直接返回
	if _player == null:
		return

	## 计算从敌人位置指向玩家位置的方向向量并归一化
	var direction: Vector2 = (_player.global_position - global_position).normalized()
	## 设置追踪速度
	velocity = direction * speed
	## 执行移动并处理碰撞
	move_and_slide()

	## ---------- 动画状态同步（有动画器时） ----------
	if animator != null:
		## 追踪=移动中
		animator.set_moving(true)
		## 朝向跟随追踪方向（面朝玩家）
		animator.set_facing(direction.x)

## 处理攻击状态逻辑
## 参数：delta - 帧间隔时间（秒）
func _handle_attack(delta: float) -> void:
	## 攻击时停止移动
	velocity = Vector2.ZERO

	## 如果玩家为空，直接返回
	if _player == null:
		return

	## ---------- 动画状态同步（有动画器时） ----------
	if animator != null:
		## 攻击=静止：切换回待机呼吸动画
		animator.set_moving(false)
		## 攻击时保持面朝玩家
		var face_dir: Vector2 = (_player.global_position - global_position).normalized()
		animator.set_facing(face_dir.x)

	## 如果攻击冷却完成，执行攻击
	if _attack_timer <= 0.0:
		_perform_attack()
		## 重置攻击冷却计时器
		_attack_timer = attack_cooldown

## ========== 攻击实现 ==========

## 执行攻击动作（发射子弹）
func _perform_attack() -> void:
	## 如果玩家为空，直接返回
	if _player == null:
		return
	
	## 计算从敌人位置指向玩家位置的方向向量并归一化
	var direction: Vector2 = (_player.global_position - global_position).normalized()
	
	## 获取子弹数据配置（优先使用敌人数据中的配置）
	var bullet_data: BulletDataClass = null
	if enemy_data != null:
		bullet_data = enemy_data.get_bullet_data()
	## 如果没有配置，使用默认子弹数据
	if bullet_data == null:
		bullet_data = BulletDataClass.new()
		bullet_data.damage = damage
		bullet_data.speed = 300.0
	
	## 根据enemy_id选择不同的射击音效（默认通用enemy_shoot）
	var sfx_name: String = "enemy_shoot"
	if enemy_data != null:
		match enemy_data.enemy_id:
			"archer", "sniper": sfx_name = "archer_shot"
			"rocketeer", "bomber": sfx_name = "rocket_shot"
			"thundermage": sfx_name = "lightning_cast"
			"elite_001": sfx_name = "elite_shot"
			"wraith": sfx_name = "wraith_cast"
			"tank": sfx_name = "tank_shot"
			_: sfx_name = "enemy_shoot"
	## 三元表达式当条件语句用：AudioManager存在才播放（单行完成条件调用，保持此处代码紧凑）
	AudioManager.play_2d(sfx_name, global_position, 0.75) if AudioManager else null

	## ---------- 动画状态同步（有动画器时） ----------
	## 播放攻击动画（前倾+放大脉冲，让"开火"有可读的发力感）
	if animator != null:
		animator.play_attack()
		## 攻击瞬间面朝玩家
		animator.set_facing(direction.x)
	
	## 如果子弹场景未加载，直接返回
	if BULLET_SCENE == null:
		return
	
	## 实例化子弹节点
	var bullet: Area2D = BULLET_SCENE.instantiate()
	
	## 设置子弹数据（伤害、速度等）
	bullet.set_bullet_data(bullet_data)
	## 设置子弹所属阵营为"enemy"（防止误伤友军）
	bullet.set_owner_group("enemy")
	
	## 先禁用碰撞检测（避免刚加入场景树时与发射者自身碰撞）
	bullet.monitoring = false
	
	## 设置子弹碰撞层为8（敌人子弹层）
	bullet.collision_layer = 8
	## 设置子弹碰撞掩码为1（只检测玩家层）
	bullet.collision_mask = 1
	
	## 设置子弹飞行方向
	bullet.set_direction(direction)
	## 设置子弹生成位置（敌人前方30像素偏移，避免立即碰撞）
	bullet.global_position = global_position + direction * 30.0
	
	## 将子弹添加到父节点（GameWorld）的场景树中
	get_parent().add_child(bullet)
	
	## 添加到场景树后再启用碰撞检测
	bullet.monitoring = true
	
	## 设置子弹外观（如果有Sprite2D节点）
	var bullet_sprite: Sprite2D = bullet.get_node_or_null("Sprite2D")
	if bullet_sprite:
		## 获取子弹最终形态配置
		var form: BulletFormClass = bullet_data.get_final_form()
		if form != null:
			## 应用形态配置到子弹外观
			form.apply_visual(bullet_sprite)
		else:
			## 无形态配置时按敌人"逻辑色"染色子弹：
			## 让近战敌人（史莱姆/蝙蝠/骷髅等）的攻击弹与其体色一致，视觉上一眼可辨攻击来源
			## （逻辑色跟随主题皮肤主色，换肤后子弹颜色自动同步）
			bullet_sprite.modulate = _body_color
	
	## 发出攻击信号（用于播放攻击动画等）
	attacked.emit(direction)

## ========== 怪物技能系统 ==========

## 释放技能（根据MonsterSkill.skill_type分发到对应实现）
## 技能独立于普通攻击，有独立冷却计时器，在_physics_process中触发
func _perform_skill() -> void:
	if enemy_data == null or enemy_data.monster_skill == null:
		return
	if _player == null:
		return

	var skill: Resource = enemy_data.monster_skill
	var dmg: int = skill_damage
	var skill_color: Color = skill.effect_color

	## 技能释放音效（每种技能专属音效，玩家可凭声音辨识威胁类型）
	## 音效名与MonsterSkill.SkillType一一对应
	var sfx_name: String = "enemy_shoot"
	match skill.skill_type:
		MonsterSkill.SkillType.SPREAD_SHOT:     sfx_name = "skill_spread"
		MonsterSkill.SkillType.NOVA_BURST:      sfx_name = "skill_nova"
		MonsterSkill.SkillType.CHARGE_RUSH:     sfx_name = "skill_charge"
		MonsterSkill.SkillType.AOE_SLAM:        sfx_name = "skill_slam"
		MonsterSkill.SkillType.HOMING_SHOT:     sfx_name = "skill_homing"
		MonsterSkill.SkillType.BARRAGE:         sfx_name = "skill_barrage"
		MonsterSkill.SkillType.TELEPORT_STRIKE: sfx_name = "skill_teleport"
		MonsterSkill.SkillType.PIERCING_SHOT:   sfx_name = "skill_piercing"
		MonsterSkill.SkillType.SUICIDE_BOMB:    sfx_name = "skill_bomb_fuse"
	if AudioManager:
		AudioManager.play_2d(sfx_name, global_position, 0.8)

	## 按技能类型分发
	match skill.skill_type:
		MonsterSkill.SkillType.SPREAD_SHOT:
			_skill_spread_shot(skill, dmg, skill_color)
		MonsterSkill.SkillType.NOVA_BURST:
			_skill_nova_burst(skill, dmg, skill_color)
		MonsterSkill.SkillType.CHARGE_RUSH:
			_skill_charge_rush(skill, dmg)
		MonsterSkill.SkillType.AOE_SLAM:
			_skill_aoe_slam(skill, dmg, skill_color)
		MonsterSkill.SkillType.HOMING_SHOT:
			_skill_homing_shot(skill, dmg, skill_color)
		MonsterSkill.SkillType.BARRAGE:
			_skill_barrage(skill, dmg, skill_color)
		MonsterSkill.SkillType.TELEPORT_STRIKE:
			_skill_teleport_strike(skill, dmg, skill_color)
		MonsterSkill.SkillType.PIERCING_SHOT:
			_skill_piercing_shot(skill, dmg, skill_color)
		MonsterSkill.SkillType.SUICIDE_BOMB:
			_skill_suicide_bomb(skill, dmg, skill_color)

	## 动画反馈
	if animator != null:
		animator.play_attack()

## ---------- 技能1：扇形散射 ----------
## 发射多发子弹呈扇形分布（弓手/骷髅兵）
func _skill_spread_shot(skill: Resource, dmg: int, color: Color) -> void:
	var base_dir: Vector2 = (_player.global_position - global_position).normalized()
	## 视觉特效：扇形枪口闪光（朝玩家方向的小型扩散光圈）
	_create_cast_flash(base_dir, 30.0, color)
	var count: int = skill.projectile_count
	var spread: float = deg_to_rad(skill.spread_angle)
	for i in range(count):
		var angle_offset: float = 0.0
		if count > 1:
			angle_offset = spread * (float(i) / float(count - 1) - 0.5)
		var dir: Vector2 = base_dir.rotated(angle_offset)
		_spawn_skill_bullet(dir, dmg, skill.projectile_speed, color)

## ---------- 技能2：环形弹幕 ----------
## 360度均匀放射子弹（火法师）
func _skill_nova_burst(skill: Resource, dmg: int, color: Color) -> void:
	## 视觉特效：扩散光环（从敌人中心向外快速扩大的圆环，预警弹幕来临）
	_create_nova_flash(40.0, color)
	var count: int = skill.projectile_count
	for i in range(count):
		var angle: float = TAU * float(i) / float(count)
		var dir: Vector2 = Vector2.RIGHT.rotated(angle)
		_spawn_skill_bullet(dir, dmg, skill.projectile_speed, color)

## ---------- 技能3：冲锋突进 ----------
## 向玩家方向高速冲刺，冲刺期间碰撞伤害翻倍（骑士/食尸鬼）
func _skill_charge_rush(skill: Resource, dmg: int) -> void:
	if _player == null:
		return
	var dir: Vector2 = (_player.global_position - global_position).normalized()
	_skill_active = true
	## 冲锋期间碰撞伤害临时提升
	var original_damage: int = damage
	damage = dmg
	## 视觉提示：缩放脉冲+冲锋残影
	if sprite != null:
		var tw: Tween = create_tween()
		tw.tween_property(sprite, "scale", Vector2(1.3, 0.7), 0.1)
		## 冲锋残影：沿途留下半透明分身
		var trail_tween: Tween = create_tween()
		for trail_i in range(3):
			trail_tween.tween_callback(_spawn_charge_ghost.bind(dir, skill.charge_speed, trail_i))
			trail_tween.tween_interval(skill.charge_duration / 4.0)
	## 冲锋移动
	var tween: Tween = create_tween()
	tween.tween_property(self, "global_position", \
		global_position + dir * skill.charge_speed * skill.charge_duration, \
		skill.charge_duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	## 冲锋结束恢复
	tween.tween_callback(_end_charge_rush.bind(original_damage))

## 冲锋结束恢复回调（由_tween_callback调用）
func _end_charge_rush(original_damage: int) -> void:
	damage = original_damage
	_skill_active = false
	if sprite != null:
		sprite.scale = Vector2.ONE

## ---------- 技能4：周身震击 ----------
## 原地AOE伤害，范围内玩家受伤（坦克）
func _skill_aoe_slam(skill: Resource, dmg: int, color: Color) -> void:
	_skill_active = true
	## 视觉特效：施法前摇预警（原地快速闪白+缩放放大，提示玩家即将震击）
	if sprite != null:
		var warn: Tween = create_tween()
		warn.tween_property(sprite, "modulate", Color(1.5, 1.5, 1.5), 0.08)
	## 视觉：震击波纹（快速放大+淡出的圆环）
	var slam_visual: Node2D = _create_aoe_visual(skill.aoe_radius, color)
	## 震屏效果（小型）
	_do_screen_shake(4.0, 0.15)
	## 延迟0.1秒后造成伤害（给玩家闪避窗口）
	await get_tree().create_timer(0.1, false).timeout
	## 敌人可能在此await期间死亡被queue_free，协程恢复时引用已无效——守卫退出
	if not is_instance_valid(self) or _is_dying:
		return
	## 检查玩家是否在范围内
	if _player != null and is_instance_valid(_player):
		var dist: float = global_position.distance_to(_player.global_position)
		if dist <= skill.aoe_radius:
			if _player.has_method("set_last_attacker"):
				_player.set_last_attacker(self, {"is_bullet": false})
			if _player.has_method("take_damage"):
				_player.take_damage(dmg)
	_skill_active = false

## ---------- 技能5：追踪弹 ----------
## 发射一颗追踪玩家的子弹（猎人）
func _skill_homing_shot(skill: Resource, dmg: int, color: Color) -> void:
	var dir: Vector2 = (_player.global_position - global_position).normalized()
	## 视觉特效：施法闪光（预警追踪弹来临）
	_create_cast_flash(dir, 25.0, color)
	var bullet: Area2D = _spawn_skill_bullet(dir, dmg, skill.projectile_speed, color)
	## 追踪逻辑：子弹存在期间持续转向玩家
	if bullet != null:
		var homing_time: float = skill.homing_duration
		var turn_rate: float = 3.0  ## 追踪转向速率（弧度/秒）
		bullet.set_meta("homing_target", _player)
		bullet.set_meta("homing_turn_rate", turn_rate)
		bullet.set_meta("homing_time", homing_time)
		bullet.set_meta("homing_elapsed", 0.0)
		## 追踪弹视觉标记：Bullet.gd读取此meta绘制发光光环
		bullet.set_meta("is_homing_shot", true)
		bullet.set_meta("homing_color", color)
		## 追踪逻辑由Bullet.gd的_update_homing()读取meta驱动，无需额外连接信号

## ---------- 技能6：连续弹幕 ----------
## 间隔发射多颗子弹（火箭兵）
func _skill_barrage(skill: Resource, dmg: int, color: Color) -> void:
	var count: int = skill.projectile_count
	var interval: float = skill.barrage_interval
	for i in range(count):
		await get_tree().create_timer(interval * i, false).timeout
		## 敌人可能在此await期间死亡，守卫退出
		if not is_instance_valid(self) or _is_dying:
			return
		if _player == null or not is_instance_valid(_player):
			return
		var dir: Vector2 = (_player.global_position - global_position).normalized()
		## 视觉特效：每发枪口闪光
		_create_cast_flash(dir, 20.0, color)
		_spawn_skill_bullet(dir, dmg, skill.projectile_speed, color)

## ---------- 技能7：传送突袭 ----------
## 传送到玩家身后发射散弹（夜魇）
func _skill_teleport_strike(skill: Resource, dmg: int, color: Color) -> void:
	if _player == null:
		return
	_skill_active = true
	## 传送前视觉提示（原位闪烁淡出+粒子爆裂）
	if sprite != null:
		sprite.modulate.a = 0.3
	_create_cast_flash(Vector2.ZERO, 35.0, color)
	await get_tree().create_timer(0.15, false).timeout
	## 敌人可能在此await期间死亡，守卫退出
	if not is_instance_valid(self) or _is_dying:
		return
	## 传送到玩家身后
	var behind_dir: Vector2 = (_player.global_position - global_position).normalized()
	global_position = _player.global_position + behind_dir * skill.teleport_distance
	if sprite != null:
		sprite.modulate.a = 1.0
	## 传送后粒子爆裂（新位置）
	_create_cast_flash(Vector2.ZERO, 35.0, color)
	## 发射散弹
	var base_dir: Vector2 = -behind_dir  ## 从玩家身前向玩家方向射
	var count: int = skill.projectile_count
	var spread: float = deg_to_rad(skill.spread_angle)
	for i in range(count):
		var angle_offset: float = 0.0
		if count > 1:
			angle_offset = spread * (float(i) / float(count - 1) - 0.5)
		var dir: Vector2 = base_dir.rotated(angle_offset)
		_spawn_skill_bullet(dir, dmg, skill.projectile_speed, color)
	_skill_active = false

## ---------- 技能8：穿透弹 ----------
## 高速穿透子弹，不被销毁（狙击手）
func _skill_piercing_shot(skill: Resource, dmg: int, color: Color) -> void:
	var dir: Vector2 = (_player.global_position - global_position).normalized()
	## 视觉特效：锐利枪口闪光（长条形，暗示穿透方向）
	_create_cast_flash(dir, 35.0, color)
	var bullet: Area2D = _spawn_skill_bullet(dir, dmg, skill.piercing_speed, color)
	## 穿透弹设置keep_alive（命中后不销毁）
	if bullet != null and "_keep_alive" in bullet:
		bullet._keep_alive = true
	## 穿透弹视觉标记：Bullet.gd读取此meta绘制拖尾
	if bullet != null:
		bullet.set_meta("is_piercing_shot", true)
		bullet.set_meta("piercing_color", color)
	## 3秒后自动销毁
	if bullet != null:
		get_tree().create_timer(3.0, false).timeout.connect(bullet.queue_free)

## ---------- 技能9：自爆 ----------
## 倒计时后原地爆炸（自爆怪）
func _skill_suicide_bomb(skill: Resource, dmg: int, color: Color) -> void:
	_skill_active = true
	## 视觉提示：闪烁+放大（倒计时期间）
	if sprite != null:
		var tw: Tween = create_tween()
		tw.set_loops(int(skill.bomb_fuse / 0.15))
		tw.tween_property(sprite, "modulate", Color(1, 0.3, 0.3, 1), 0.075)
		tw.tween_property(sprite, "modulate", Color.WHITE, 0.075)
	## 倒计时
	await get_tree().create_timer(skill.bomb_fuse, false).timeout
	## 敌人可能在此await期间被玩家击杀，守卫退出避免协程引用已销毁节点
	if not is_instance_valid(self) or _is_dying:
		return
	## 爆炸：AOE伤害
	if _player != null and is_instance_valid(_player):
		var dist: float = global_position.distance_to(_player.global_position)
		if dist <= skill.aoe_radius:
			if _player.has_method("set_last_attacker"):
				_player.set_last_attacker(self, {"is_bullet": false})
			if _player.has_method("take_damage"):
				_player.take_damage(dmg)
	## 爆炸视觉
	_create_aoe_visual(skill.aoe_radius, color)
	## 爆炸震屏（大型）
	_do_screen_shake(10.0, 0.3)
	## 爆炸音效（复用bomber_explode，区别于引信音）
	if AudioManager:
		AudioManager.play_2d("bomber_explode", global_position, 1.0)
	## 自爆怪死亡
	_skill_active = false
	take_damage(max_health)  ## 直接秒杀自己

## ---------- 技能通用：创建技能子弹 ----------
## 复用现有BULLET_SCENE创建子弹，设置技能伤害/速度/颜色
func _spawn_skill_bullet(direction: Vector2, dmg: int, speed: float, color: Color) -> Area2D:
	if BULLET_SCENE == null:
		return null
	var bullet_data: BulletDataClass = BulletDataClass.new()
	bullet_data.damage = dmg
	bullet_data.speed = speed
	var bullet: Area2D = BULLET_SCENE.instantiate()
	bullet.set_bullet_data(bullet_data)
	bullet.set_owner_group("enemy")
	bullet.monitoring = false
	bullet.collision_layer = 8
	bullet.collision_mask = 1
	bullet.set_direction(direction)
	bullet.global_position = global_position + direction * 30.0
	get_parent().add_child(bullet)
	bullet.monitoring = true
	## 技能子弹染色
	var bullet_sprite: Sprite2D = bullet.get_node_or_null("Sprite2D")
	if bullet_sprite:
		bullet_sprite.modulate = color
	return bullet

## ---------- 技能通用：AOE视觉 ----------
## 创建一个快速放大+淡出的圆环Node2D作为AOE视觉反馈
func _create_aoe_visual(radius: float, color: Color) -> Node2D:
	var visual: Node2D = Node2D.new()
	visual.z_index = 10
	visual.global_position = global_position
	visual.modulate = color
	get_parent().add_child(visual)
	## 绘制AOE圆环（通过绑定方法，避免多行lambda语法问题）
	visual.draw.connect(_draw_aoe_ring.bind(visual, radius, color))
	## 动画：放大+淡出后销毁
	## 关键修复：Tween必须挂在visual节点自身而非Enemy(create_tween=挂self)，
	## 否则Enemy死亡queue_free后Tween被连带销毁，queue_free回调永不执行→红圈残留
	var tw: Tween = visual.create_tween()
	tw.set_parallel(true)
	tw.tween_property(visual, "scale", Vector2(1.3, 1.3), 0.3)
	tw.tween_property(visual, "modulate:a", 0.0, 0.3)
	tw.chain().tween_callback(visual.queue_free)
	visual.queue_redraw()
	return visual

## AOE圆环绘制回调（由draw信号触发）
func _draw_aoe_ring(visual: Node2D, radius: float, color: Color) -> void:
	visual.draw_circle(Vector2.ZERO, radius, Color(color.r, color.g, color.b, 0.15))
	visual.draw_arc(Vector2.ZERO, radius, 0, TAU, 48, color, 2.0)

## ---------- 技能通用：施法枪口闪光 ----------
## 朝指定方向创建一个快速放大+淡出的小圆，模拟施法/射击枪口闪光
## 参数：direction - 闪光方向（Vector2.ZERO=原地全方位），offset - 距离敌人中心的偏移，color - 闪光颜色
func _create_cast_flash(direction: Vector2, offset: float, color: Color) -> void:
	var flash: Node2D = Node2D.new()
	flash.z_index = 10
	## 计算闪光位置（方向偏移或原地）
	if direction == Vector2.ZERO:
		flash.global_position = global_position
	else:
		flash.global_position = global_position + direction * offset
	get_parent().add_child(flash)
	## 绘制实心圆+外环
	flash.draw.connect(_draw_cast_flash.bind(flash, color))
	## 动画：快速放大+淡出
	## 关键修复：Tween挂在flash节点自身，Enemy销毁后不影响动画完成和节点回收
	var tw: Tween = flash.create_tween()
	tw.set_parallel(true)
	tw.tween_property(flash, "scale", Vector2(2.0, 2.0), 0.15)
	tw.tween_property(flash, "modulate:a", 0.0, 0.15)
	tw.chain().tween_callback(flash.queue_free)
	flash.queue_redraw()

## 枪口闪光绘制回调
func _draw_cast_flash(flash: Node2D, color: Color) -> void:
	flash.draw_circle(Vector2.ZERO, 8.0, Color(color.r, color.g, color.b, 0.6))
	flash.draw_arc(Vector2.ZERO, 12.0, 0, TAU, 24, color, 1.5)

## ---------- 技能通用：环形弹幕扩散光环 ----------
## 从敌人中心向外快速扩大的圆环，预警环形弹幕来临
## 参数：start_radius - 起始半径，color - 光环颜色
func _create_nova_flash(start_radius: float, color: Color) -> void:
	var ring: Node2D = Node2D.new()
	ring.z_index = 10
	ring.global_position = global_position
	get_parent().add_child(ring)
	ring.draw.connect(_draw_nova_ring.bind(ring, start_radius, color))
	## 动画：快速扩大+淡出
	## 关键修复：Tween挂在ring节点自身，Enemy销毁后不影响动画完成和节点回收
	var tw: Tween = ring.create_tween()
	tw.set_parallel(true)
	tw.tween_property(ring, "scale", Vector2(3.0, 3.0), 0.2)
	tw.tween_property(ring, "modulate:a", 0.0, 0.2)
	tw.chain().tween_callback(ring.queue_free)
	ring.queue_redraw()

## 环形弹幕光环绘制回调
func _draw_nova_ring(ring: Node2D, start_radius: float, color: Color) -> void:
	ring.draw_arc(Vector2.ZERO, start_radius, 0, TAU, 36, color, 3.0)
	ring.draw_arc(Vector2.ZERO, start_radius * 0.7, 0, TAU, 36, Color(color.r, color.g, color.b, 0.4), 1.5)

## ---------- 技能通用：冲锋残影 ----------
## 在冲锋沿途留下半透明的敌人分身，模拟运动模糊
## 参数：dir - 冲锋方向，charge_speed - 冲锋速度，index - 残影序号
func _spawn_charge_ghost(dir: Vector2, charge_speed: float, index: int) -> void:
	if sprite == null:
		return
	var ghost: Sprite2D = Sprite2D.new()
	ghost.texture = sprite.texture
	ghost.region_enabled = sprite.region_enabled
	if sprite.region_enabled:
		ghost.region_rect = sprite.region_rect
	ghost.global_position = global_position - dir * charge_speed * 0.05 * float(index + 1)
	ghost.scale = sprite.scale
	ghost.modulate = Color(1.0, 1.0, 1.0, 0.35)
	ghost.z_index = sprite.z_index - 1
	get_parent().add_child(ghost)
	## 残影快速淡出
	## 关键修复：Tween挂在ghost节点自身，Enemy销毁后不影响动画完成和节点回收
	var tw: Tween = ghost.create_tween()
	tw.tween_property(ghost, "modulate:a", 0.0, 0.3)
	tw.chain().tween_callback(ghost.queue_free)

## ---------- 技能通用：震屏效果 ----------
## 对玩家相机施加短暂偏移抖动，强化打击感
## 参数：intensity - 抖动幅度（像素），duration - 持续时间（秒）
func _do_screen_shake(intensity: float, duration: float) -> void:
	var cam: Camera2D = get_viewport().get_camera_2d()
	if cam == null:
		return
	var original_offset: Vector2 = cam.offset
	var shake_tween: Tween = create_tween()
	## 3次随机偏移抖动+回归
	for i in range(3):
		var shake_offset: Vector2 = Vector2(
			RandomManager.randf_range(-intensity, intensity),
			RandomManager.randf_range(-intensity, intensity)
		)
		shake_tween.tween_property(cam, "offset", original_offset + shake_offset, duration / 3.0)
	## 回归原始偏移
	shake_tween.tween_property(cam, "offset", original_offset, duration / 3.0)

## ========== 伤害与死亡系统 ==========

## 敌人受到伤害时调用（对外接口）
## 参数：amount - 受到的伤害数值
func take_damage(amount: int) -> void:
	## 已进入死亡流程的敌人不再受击（防重入：_die()后到queue_free执行间的一帧间隙内子弹仍可命中）
	if _is_dying:
		return
	## 如果伤害小于等于0，不执行任何操作
	if amount <= 0:
		return

	## 扣除血量
	health -= amount
	## 确保血量不小于0
	health = max(health, 0)
	## 发出受伤信号（用于播放受伤动画等）
	damaged.emit(amount)
	
	## 播放受伤音效（轻微随机音高避免重复感）
	if AudioManager:
		AudioManager.play_2d("enemy_hurt", global_position, 0.7, randf_range(0.9, 1.1))

	## 播放受伤闪烁效果
	_flash_hit()

	## 弹出浮动伤害数字（直播增强：让观众看清打了多少伤害）
	## 暴击判定：伤害量 > 敌人最大血量 25% 就算大伤害（红字+放大动画）
	var is_big_hit: bool = amount > max(1, max_health) * 0.25
	DamageNumberClass.pop(global_position + Vector2(0, -20), amount, is_big_hit)

	## 如果血量归零，执行死亡逻辑
	if health <= 0:
		_die()

## 受伤闪烁效果（白色闪烁0.1秒后恢复）
## 颜色逻辑在本方法内管理（恢复"白闪前状态色"）；运动抖动委托动画器
func _flash_hit() -> void:
	## 如果精灵节点为空，直接返回
	if sprite == null:
		return

	## 运动抖动委托动画器（随机高频位移，打击感；无动画器时跳过——无主题回退路径）
	if animator != null:
		animator.play_hit_shake()

	## ---------- 闪烁窗口复用（性能优化 + 竞态修复） ----------
	## 白闪进行中时直接返回：精灵本就处于WHITE状态，无需重复起计时器；
	## 高射速下旧实现每次命中都分配一个0.1秒SceneTreeTimer（自动回收但
	## 高频小对象分配仍有churn），且多个回调按各自到期时间恢复颜色，
	## 后到的命中闪白会被先到的恢复提前掐灭（视觉抖动）
	if _flash_active:
		return

	## 记录白闪前的颜色再变白：可能是燃烧/中毒的染色（状态色）而非本色，
	## 到点恢复"白闪前"的颜色，避免白闪恢复吞掉状态染色
	var pre_color: Color = sprite.modulate
	sprite.modulate = Color.WHITE

	## 标记窗口开启（此后0.1秒内的命中全部复用本次闪烁）
	_flash_active = true

	## 等待0.1秒后恢复颜色
	## 第二参数process_always=false：闪烁计时走"游戏时间"——游戏暂停（三选一/暂停菜单）时
	## 计时冻结，避免暂停期间恢复回调与恢复后的新受击闪烁交错错乱
	await get_tree().create_timer(0.1, false).timeout

	## 敌人可能在此await期间死亡，守卫退出避免协程引用已销毁节点
	if not is_instance_valid(self) or _is_dying:
		return
	## 窗口关闭（即使精灵已销毁也无需担心：标记随实例一起回收）
	_flash_active = false
	if is_instance_valid(sprite):
		sprite.modulate = pre_color

## 应用减速效果（用于冰冻等控制技能）
## 参数：duration - 减速持续时间（秒）
##       speed_multiplier - 速度系数（0.3表示速度变为30%）
##       effect_color - 效果颜色（用于改变敌人外观）
func apply_slowdown(duration: float, speed_multiplier: float, effect_color: Color) -> void:
	## 保存原始速度
	var original_speed: float = speed
	var original_wander_speed: float = wander_speed
	
	## 应用减速
	speed *= speed_multiplier
	wander_speed *= speed_multiplier
	
	## 改变敌人颜色显示效果
	if sprite != null:
		sprite.modulate = effect_color
	
	## 等待持续时间结束
	## 第二参数process_always=false：减速时长走"游戏时间"——暂停时计时冻结，
	## 否则三选一面板停留期间减速照样倒计时，恢复游戏时效果已凭空过期
	await get_tree().create_timer(duration, false).timeout
	
	## 敌人可能在此await期间死亡，守卫退出避免协程引用已销毁节点
	if not is_instance_valid(self) or _is_dying:
		return
	## 恢复原始速度
	speed = original_speed
	wander_speed = original_wander_speed
	
	## 恢复原始颜色
	if sprite != null:
		sprite.modulate = _original_color

## 敌人死亡逻辑
func _die() -> void:
	## 防重入：已进入死亡流程则跳过（敌人血量归零到queue_free真正执行间有一帧间隙，
	## 期间子弹仍可命中触发重复_die()，导致重复掉落/重复特效/异常中断）
	if _is_dying:
		return
	_is_dying = true
	## 立即调度销毁——放在最前面确保无论后续逻辑是否异常，节点一定会被回收
	## （call_deferred仅调度一次，重复调用安全但上面_is_dying已挡住）
	call_deferred("queue_free")
	## ---------- 死亡音效 ----------
	if AudioManager:
		var is_elite: bool = (enemy_data != null and enemy_data.is_elite) or max_health >= 15
		AudioManager.play_2d("enemy_die", global_position, 0.9, randf_range(0.85, 1.1))
		## 自爆怪：爆炸音效
		if enemy_data != null and enemy_data.enemy_id == "bomber":
			AudioManager.play_2d("bomber_explode", global_position, 1.0)
			## 自爆怪视觉爆炸
			var world: Node2D = get_parent()
			if world != null:
				_spawn_death_explosion_vfx(world, global_position, Color(1, 0.6, 0.2, 1))
	
	## ---------- 死亡视觉：缩放消散 + 碎片 ----------
	_spawn_death_vfx()
	
	## 获取敌人掉落道具列表（根据概率计算）
	var drop_items: Array = []
	if enemy_data != null:
		drop_items = enemy_data.get_drops_to_spawn()
	
	## 如果数据中没有配置掉落物，自动生成默认掉落（让普通敌人也会掉碎片）
	if drop_items.is_empty():
		drop_items = _generate_default_drops()
	
	## 如果有掉落道具，发出信号通知GameWorld生成拾取物
	if drop_items.size() > 0:
		drops_generated.emit(global_position, drop_items)

	## ---------- 神庙掉落判定 ----------
	## 高级怪物（非小怪）死亡时按概率生成神庙
	## 概率在DifficultyManager中统一管理（固定1%）
	_try_spawn_temple()

	## 发出死亡信号（用于统计、清理等）
	killed.emit()

## 神庙掉落判定：掷骰命中则通知GameWorld在死亡位置生成神庙
func _try_spawn_temple() -> void:
	if enemy_data == null:
		return
	## 计算神庙出现概率（小怪返回0，高级怪按品级/难度/精英缩放）
	var chance: float = DifficultyManager.get_temple_spawn_chance(enemy_data)
	if chance <= 0.0:
		return
	## 掷骰
	if RandomManager.randf() >= chance:
		return
	## 命中：通知GameWorld生成神庙（call_deferred避免物理回调中改场景树）
	var world: Node2D = get_parent()
	if world != null and world.has_method("spawn_temple"):
		world.call_deferred("spawn_temple", global_position)

## 死亡视觉：缩放消失 + 彩色粒子碎片
## 性能设计：碎片改用TrailGhost对象池（复用节点+自驱动漂移动画），
##           替代旧的"ColorRect+3个Tween属性"方案，大量敌人同时死亡时不再卡顿
func _spawn_death_vfx() -> void:
	var world: Node2D = get_parent()
	if world == null:
		return
	var pos: Vector2 = global_position
	## 敌人颜色（用于粒子色）——用"逻辑色"：跟随主题皮肤主色，换肤后碎片颜色自动同步
	var col: Color = _body_color

	## 碎片：4个小方块飞散（从池中获取，带漂移速度+渐隐）
	for i in range(4):
		## 随机飞散方向（扇形均匀+扰动）
		var angle: float = (i / 4.0) * TAU + randf_range(-0.3, 0.3)
		## 漂移速度：方向×随机速度（24~48像素/秒，与旧版飞散距离一致）
		var drift: Vector2 = Vector2(cos(angle), sin(angle)) * randf_range(24.0, 48.0) * 2.5
		## 从对象池生成碎片（0.4秒寿命后自动回池，与旧版动画时长一致）
		TrailGhostClass.spawn(world, pos, Color(col.r, col.g, col.b, 0.9), 6.0, 0.4, 1.0, drift)

## 通用爆炸VFX（供自爆怪等使用）
## 参数：world - VFX挂载节点(通常为GameWorld)，pos - 爆炸中心(全局坐标)，col - 爆炸主色
## 实现：3层ColorRect方环并行Tween放大+渐隐(0.35秒)，chain回调自动queue_free清理节点
func _spawn_death_explosion_vfx(world: Node2D, pos: Vector2, col: Color) -> void:
	for i in range(3):
		var ring := ColorRect.new()
		var sz: float = 120.0 * (1.0 + i * 0.15)
		ring.size = Vector2(sz, sz)
		ring.position = -ring.size / 2.0
		ring.color = Color(col.r, col.g, col.b, 0.8 - i * 0.2)
		ring.global_position = pos
		world.add_child(ring)
		var tw: Tween = world.create_tween()
		tw.set_parallel(true)
		tw.tween_property(ring, "scale", Vector2(1.5, 1.5), 0.35)
		tw.tween_property(ring, "modulate:a", 0.0, 0.35)
		tw.chain().tween_callback(ring.queue_free)

## 根据敌人强度生成默认掉落（无配置数据时的回退机制）
## 爆率设计：前期控制掉落数量，避免满屏物品影响体验；精英怪保证有奖励但不泛滥
func _generate_default_drops() -> Array:
	var drops: Array = []
	## 根据最大血量判断强度，越高血量概率和品质越高
	var is_elite: bool = (enemy_data != null and enemy_data.is_elite) or max_health >= 15
	var is_strong: bool = max_health >= 8

	## 基础梦境碎片（小）：25%概率普通怪，80%概率精英怪
	var chance_frag_small: float = 0.25 if not is_elite else 0.8
	if randf() < chance_frag_small:
		var d: DropItemClass = DropItemClass.new()
		d.item_id = "fragment_small"
		d.item_name = "Small Fragment"
		d.item_type = DropItemClass.ItemType.DREAM_FRAGMENT
		d.value = 5 if not is_strong else 8
		d.drop_chance = 1.0
		d.is_rare = false
		d.auto_adsorb = true
		drops.append(d)

	## 中型碎片：12%概率（强怪），50%概率精英怪
	var chance_frag_mid: float = 0.12 if not is_elite else 0.5
	if randf() < chance_frag_mid and (is_strong or is_elite):
		var d: DropItemClass = DropItemClass.new()
		d.item_id = "fragment_medium"
		d.item_name = "Medium Fragment"
		d.item_type = DropItemClass.ItemType.DREAM_FRAGMENT
		d.value = 10 if not is_elite else 20
		d.drop_chance = 1.0
		d.is_rare = is_elite
		d.auto_adsorb = true
		drops.append(d)

	## 小血包：5%概率普通怪，25%概率精英怪
	var chance_health: float = 0.05 if not is_elite else 0.25
	if randf() < chance_health:
		var d: DropItemClass = DropItemClass.new()
		d.item_id = "health_small"
		d.item_name = "Small Health Pack"
		d.item_type = DropItemClass.ItemType.HEALTH
		d.value = 10 if not is_elite else 30
		d.drop_chance = 1.0
		d.is_rare = false
		d.auto_adsorb = true
		drops.append(d)

	## BUFF：10%概率精英怪（伤害加成）
	if is_elite and randf() < 0.1:
		var d: DropItemClass = DropItemClass.new()
		d.item_id = "buff_attack"
		d.item_name = "Power Boost"
		d.item_type = DropItemClass.ItemType.BUFF
		d.value = 3
		d.drop_chance = 1.0
		d.is_rare = true
		d.auto_adsorb = false
		drops.append(d)

	## ---------- 装备护盾掉落 ----------
	## 普通护盾：5%概率所有怪，精英怪 15%
	var chance_normal_shield: float = 0.05 if not is_elite else 0.15
	if randf() < chance_normal_shield:
		var sd: DropItemClass = DropItemClass.new()
		sd.item_id = "shield_basic"
		sd.item_name = "基础护盾"
		sd.item_type = DropItemClass.ItemType.EQUIPMENT
		sd.value = 0
		sd.drop_chance = 1.0
		sd.is_rare = false
		sd.auto_adsorb = false
		## 动态创建基础护盾数据（无特效）
		var ShieldDataClass = load("res://scripts/resources/equipment/ShieldEquipmentData.gd")
		var shield_data = ShieldDataClass.new()
		shield_data.shield_id = "shield_basic"
		shield_data.display_name = "基础护盾"
		shield_data.shield_color = Color(0.3, 0.6, 1.0, 0.8)
		shield_data.max_hp = 30.0
		shield_data.absorb_per_hit = 30.0
		shield_data.regen_delay = 10.0
		shield_data.regen_rate = 10.0
		shield_data.is_special = false
		shield_data.shield_effect = null
		sd.shield_equipment = shield_data
		drops.append(sd)

	## 特效护盾：2%概率所有怪，精英怪 8%（旧0.5%/3%太低，实测几乎看不到特效护盾掉落）
	var chance_special_shield: float = 0.02 if not is_elite else 0.08
	if randf() < chance_special_shield:
		## 随机选择一种特效护盾
		var special_types: Array = ["shield_poison", "shield_frost", "shield_reflect"]
		var chosen: String = special_types[randi() % special_types.size()]
		## 真实护盾名映射（旧版统一写"特效护盾"，玩家捡到也不认识是哪种）
		var display_names: Dictionary = {
			"shield_poison": "毒雾护盾",
			"shield_frost": "冰霜护盾",
			"shield_reflect": "反击护盾",
		}
		var sd2: DropItemClass = DropItemClass.new()
		sd2.item_id = chosen
		sd2.item_name = display_names[chosen]
		sd2.item_type = DropItemClass.ItemType.EQUIPMENT
		sd2.value = 0
		sd2.drop_chance = 1.0
		sd2.is_rare = true
		sd2.auto_adsorb = false
		## 从 .tres 资源加载特效护盾数据
		var path_map: Dictionary = {
			"shield_poison": "res://data/equipment/shield_poison.tres",
			"shield_frost": "res://data/equipment/shield_frost.tres",
			"shield_reflect": "res://data/equipment/shield_reflect.tres",
		}
		sd2.shield_equipment = load(path_map[chosen])
		drops.append(sd2)

	return drops

## ========== 碰撞检测 ==========

## 玩家碰撞处理（当敌人碰撞玩家时调用）
## 参数：player - 玩家节点
func on_player_collision(player: Node2D) -> void:
	## 通知玩家攻击者信息（装备护盾特效需要知道是谁在攻击）
	if player.has_method("set_last_attacker"):
		player.set_last_attacker(self, {"is_bullet": false})
	## 如果玩家有take_damage方法，调用它造成伤害
	if player.has_method("take_damage"):
		player.take_damage(damage)

## 碰撞检测回调：当有物体进入hitbox区域时调用
## 参数：body - 进入区域的物体节点
func _on_hitbox_body_entered(body: Node2D) -> void:
	## 如果进入的物体在"player"组中，处理碰撞
	if body.is_in_group("player"):
		on_player_collision(body)