## Bullet.gd - 子弹核心脚本
## 职责：管理子弹移动、碰撞检测、特效触发、边界回收等逻辑
## 继承：Area2D（Godot 4的2D区域节点，用于碰撞检测）
## 节点结构：Bullet(Area2D) → Sprite2D(外观) + CollisionShape2D(命中判定形状)
## 系统交互：
##   - 信号：hit → GameWorld 连接（预留扩展逻辑）；destroyed → GameWorld 从 _bullets 管理列表移除
##   - 数据：set_bullet_data 注入"玩家私有副本再duplicate"的独立数据，每颗子弹的特效修改互不干扰
## 碰撞层/掩码（场景默认 + 发射者按阵营覆盖，本脚本不写死）：
##   - 玩家子弹：沿用场景默认 layer=4(子弹层)/mask=2(敌人层) → 只检测敌人
##   - 敌人子弹：Enemy._perform_attack 覆盖为 layer=8(敌方子弹层)/mask=1(玩家层) → 只检测玩家
##   - 双保险：除碰撞层过滤外，_owner_group 同阵营比较兜底防误伤友军
## 设计意图：弹幕运动不用物理移动——_physics_process 中 position += velocity*delta 直接积分
##           （子弹挂在原点的GameWorld下，局部坐标=全局坐标），命中判定交给 Area2D 的 body/area_entered
extends Area2D

## ========== 预加载资源（避免运行时加载延迟） ==========

## 子弹数据资源类，用于配置子弹属性（伤害、速度、形态、特效等）
const BulletDataClass = preload("res://scripts/resources/bullet/BulletData.gd")

## 子弹形态资源类，用于配置子弹外观
const BulletFormClass = preload("res://scripts/resources/bullet/BulletForm.gd")

## 子弹特效资源类，用于配置子弹特效（生成、飞行、命中、销毁）
const BulletEffectClass = preload("res://scripts/resources/bullet/BulletEffect.gd")

## 残影节点类（对象池管理的高频视觉元素，拖尾专用）
const TrailGhostClass = preload("res://scripts/entities/TrailGhost.gd")

## ========== 导出变量（编辑器可配置） ==========

## 屏幕边界检测余量（像素），子弹超出此范围后自动销毁
@export var screen_margin: float = 100.0

## 子弹生成偏移量（像素），避免子弹刚生成就与发射者碰撞
@export var spawn_offset: float = 30.0

## ========== 节点引用（使用 @onready 延迟初始化） ==========

## 子弹精灵节点，用于显示子弹外观
@onready var sprite: Sprite2D = $Sprite2D

## ========== 成员变量（运行时数据） ==========

## 子弹数据配置，包含伤害、速度、形态、特效等信息
var _bullet_data: BulletDataClass = null

## 子弹飞行方向向量
var _direction: Vector2 = Vector2.RIGHT

## 子弹所属阵营（"player"或"enemy"），用于防止误伤友军
var _owner_group: String = ""

## 是否命中过目标（防重复伤害标记）
var _has_hit: bool = false

## 命中保活标记（本次命中后是否继续存活）
## 数据流：ON_HIT特效（如穿透）在apply中置true → 碰撞回调据此跳过销毁
## 每次命中前由碰撞回调重置为false，避免状态残留
var _keep_alive: bool = false

## 出场边界豁免时间（秒）：大于0时不做屏幕边界销毁判定
## 数据流：Enemy._spawn_tracking_missile 为屏幕外生成的追踪导弹赋值 → _physics_process 递减 →
##           豁免期内子弹可安全从屏幕外飞入，豁免结束后恢复常规边界回收
## 设计意图：终极BOSS追踪导弹要求在屏幕外出生并飞向玩家，若沿用常规边界判定会被立即销毁
var _boundary_grace: float = 0.0

## ========== 拖尾系统（运行时数据） ==========

## 是否启用拖尾（由追踪/加速等特效在首次触发时调用 enable_trail 开启）
var _trail_enabled: bool = false

## 拖尾生成间隔（秒），越小拖尾越密集
var _trail_interval: float = 0.035

## 拖尾生成计时器（累计到间隔后生成一个拖尾节点）
var _trail_timer: float = 0.0

## 拖尾颜色（由 enable_trail 的调用方指定，体现特效特色）
var _trail_color: Color = Color(1, 1, 1, 0.6)

## ========== 性能优化：视口/相机缓存 ==========

## 缓存的相机引用（每0.5秒刷新一次，避免每帧get_camera_2d开销）
## 设计意图：边界检测每物理帧需要相机位置，get_camera_2d内部有查找开销；
##           几百颗子弹×每帧查询=热点，缓存后几乎零成本
var _cached_camera: Camera2D = null

## 相机刷新计时器（累计到0.5秒时重新查找相机）
var _camera_refresh_timer: float = 0.0

## 缓存的屏幕尺寸（与相机同步刷新，窗口模式下不变）
var _cached_screen_size: Vector2 = Vector2.ZERO

## ========== 信号定义（用于与其他节点通信） ==========

## 子弹命中目标时发出此信号
## 参数：bullet - 命中的子弹实例，target - 被命中的目标节点
signal hit(bullet: Area2D, target: Node2D)

## 子弹被销毁时发出此信号
signal destroyed()

## ========== 生命周期方法 ==========

## _ready() - 节点进入场景树时调用一次，用于初始化
func _ready() -> void:
	## 连接碰撞检测信号：当有物理体进入子弹区域时触发回调
	body_entered.connect(_on_body_entered)
	## 连接碰撞检测信号：当有区域体进入子弹区域时触发回调（用于检测玩家Hitbox）
	area_entered.connect(_on_area_entered)
	
	## 如果子弹数据为空，创建默认子弹数据
	if _bullet_data == null:
		_bullet_data = BulletDataClass.new()
	
	## 应用子弹数据配置到子弹外观
	_apply_bullet_data()
	
	## 触发子弹生成时的特效（ON_SPAWN类型）
	_bullet_data.trigger_effects(BulletEffectClass.TriggerType.ON_SPAWN, self)

## ========== 子弹数据管理方法 ==========

## 设置子弹数据（对外接口，由发射者调用）
## 参数：data - 子弹数据配置
func set_bullet_data(data: BulletDataClass) -> void:
	_bullet_data = data

## 获取子弹数据（对外接口，供其他节点读取子弹属性）
## 返回：子弹数据配置
func get_bullet_data() -> BulletDataClass:
	return _bullet_data

## 设置子弹所属阵营（对外接口，由发射者调用）
## 参数：group_name - 阵营名称（"player"或"enemy"）
func set_owner_group(group_name: String) -> void:
	_owner_group = group_name

## ========== 可击落子弹（终极BOSS追踪导弹专用） ==========

## 受到伤害（对外接口，供玩家子弹命中时调用）
## 数据流：玩家子弹area_entered命中导弹 → 导弹.take_damage() → 扣减meta计数
##        → 计数归零则播放击落特效 + 音效 + 销毁
## 参数：_amount - 伤害数值（可击落子弹按"命中次数"计数，不区分单发伤害大小）
func take_damage(_amount: float) -> void:
	## 非可击落子弹直接忽略：普通子弹没有生命值概念，不响应任何伤害
	if not has_meta("shootdown_health"):
		return
	var remain: int = int(get_meta("shootdown_health")) - 1
	set_meta("shootdown_health", remain)
	## 命中反馈：被击落时火花更多更大，未击落时是小范围受击火花
	_spawn_shootdown_sparks(remain <= 0)
	if remain > 0:
		return
	if AudioManager:
		AudioManager.play_2d("hit_explosion", global_position, 0.5)
	_destroy()

## 播放导弹被玩家命中的火花（复用对象池残影向四周散开，零节点分配开销）
## 参数：destroyed - 是否被打爆（打爆时火花更多、飞散更远）
func _spawn_shootdown_sparks(destroyed: bool) -> void:
	var world: Node = get_parent()
	if world == null:
		return
	var color: Color = get_meta("homing_color", Color(0.65, 0.85, 1.0, 1.0))
	var count: int = 10 if destroyed else 4
	var size: float = 10.0 if destroyed else 6.0
	var drift_len: float = 110.0 if destroyed else 70.0
	for i in range(count):
		var angle: float = TAU * float(i) / float(count)
		TrailGhostClass.spawn(world, global_position, color, size, 0.35, 0.2,
			Vector2.RIGHT.rotated(angle) * drift_len)

## ========== 拖尾系统方法 ==========

## 启用拖尾（对外接口，由追踪/加速等特效调用）
## 数据流：特效apply() → bullet.enable_trail() → _physics_process()中按间隔生成渐隐残影
## 参数：color - 拖尾颜色；interval - 生成间隔（秒），越小越密集
func enable_trail(color: Color = Color(1, 1, 1, 0.6), interval: float = 0.035) -> void:
	_trail_enabled = true
	_trail_color = color
	_trail_interval = interval

## 按间隔生成拖尾残影（在物理帧中调用）
## 性能设计：残影从TrailGhost对象池获取（复用节点），自身驱动渐隐动画，
##           无Tween分配、无节点创建——彻底消除高频拖尾的节点churn卡顿
## 设计意图：残影挂在子弹的父节点（世界）上而非子弹自身，
##           这样子弹销毁后残影仍能继续播放渐隐动画，避免被一起回收
func _update_trail(delta: float) -> void:
	## 未启用拖尾时跳过
	if not _trail_enabled:
		return
	var world: Node = get_parent()
	if world == null:
		return

	## 累计时间达到间隔后生成一个残影
	_trail_timer += delta
	if _trail_timer < _trail_interval:
		return
	_trail_timer = 0.0

	## 从对象池生成残影（池满时自动跳过，绝不卡顿）
	TrailGhostClass.spawn(world, global_position, _trail_color, 8.0, 0.25, 0.2)

## ========== 子弹外观应用 ==========

## 应用子弹数据到子弹外观
func _apply_bullet_data() -> void:
	## 如果子弹数据为空，直接返回
	if _bullet_data == null:
		return

	## 获取子弹最终形态配置
	var form: BulletFormClass = _bullet_data.get_final_form()
	## 如果有形态配置且有精灵节点，应用形态到外观
	if form != null and sprite != null:
		form.apply_visual(sprite)
		## 敌人弹配色守卫：形态基色若落入蓝色系，就地偏转为非蓝（与玩家蓝弹区分）
		## 只改写本子弹的精灵纹理，不动共享的 form 资源（避免污染玩家弹数据）
		if _owner_group == "enemy" and BulletFormClass.is_blue_family(form.placeholder_color):
			_set_sprite_solid_color(
				sprite.texture.get_size(),
				BulletFormClass.enemy_safe_color(form.placeholder_color)
			)

## 以纯色渲染子弹外观（对外接口，供敌人技能弹按技能效果色渲染）
## 参数：color - 目标颜色；敌人弹会自动施加非蓝守卫
## 设计意图：技能弹的 BulletData 不带 form，默认占位纹理为青蓝色，
##           若沿用 modulate 相乘会与技能色混出偏色/偏蓝，故直接以技能色重建纹理
func apply_solid_color(color: Color) -> void:
	if sprite == null:
		return
	var final_color: Color = color
	if _owner_group == "enemy":
		final_color = BulletFormClass.enemy_safe_color(color)
	var size: Vector2 = sprite.texture.get_size() if sprite.texture != null else Vector2(16, 16)
	_set_sprite_solid_color(size, final_color)

## 用纯色填充精灵纹理（内部辅助：创建纯色纹理覆盖，调制色复位为白）
## 参数：size - 纹理尺寸；color - 填充颜色
func _set_sprite_solid_color(size: Vector2, color: Color) -> void:
	if sprite == null:
		return
	var image: Image = Image.create(maxi(int(size.x), 1), maxi(int(size.y), 1), false, Image.FORMAT_RGBA8)
	image.fill(color)
	sprite.texture = ImageTexture.create_from_image(image)
	## 复位调制色，避免与外部设置的 modulate 叠乘导致偏色
	sprite.modulate = Color(1, 1, 1, 1)

## ========== 子弹方向设置 ==========

## 设置子弹飞行方向（对外接口，由发射者调用）
## 参数：direction - 飞行方向向量
## 注意：位置偏移由发射者在 instantiate 后设置，避免重复偏移
func set_direction(direction: Vector2) -> void:
	## 归一化方向向量，确保单位长度
	_direction = direction.normalized()
	## 设置子弹旋转角度为方向向量的角度
	rotation = _direction.angle()

## ========== 物理帧更新方法 ==========

## _physics_process() - 每物理帧调用一次（默认60次/秒），用于处理子弹移动
func _physics_process(delta: float) -> void:
	## 如果子弹数据为空，直接返回
	if _bullet_data == null:
		return

	## 计算子弹当前帧的移动速度（方向 × 最终速度）
	var velocity: Vector2 = _direction * _bullet_data.get_final_speed()
	## 更新子弹位置（速度 × 时间间隔）
	position += velocity * delta

	## 触发子弹飞行时的特效（ON_TRAVEL类型）
	## 性能优化：先检查effects数组是否非空且含ON_TRAVEL类型，避免每帧空遍历
	## 后期满级技能时子弹可能带16个特效，其中ON_TRAVEL类型的可能仅1~2个；
	## 每帧×每子弹×16次遍历=百发子弹×60帧=96000次/秒无意义循环
	if _bullet_data.effects.size() > 0:
		_bullet_data.trigger_effects(BulletEffectClass.TriggerType.ON_TRAVEL, self)

	## 追踪弹逻辑：检查是否被标记为追踪弹（由Enemy._skill_homing_shot设置meta）
	_update_homing(delta)

	## 递减出场边界豁免时间（终极BOSS屏幕外追踪导弹入场用），最小钳制到0
	if _boundary_grace > 0.0:
		_boundary_grace = maxf(_boundary_grace - delta, 0.0)

	## 更新拖尾残影（若已被特效启用）
	_update_trail(delta)

	## 技能子弹视觉：追踪弹发光光环/穿透弹拖尾需要每帧重绘
	if has_meta("is_homing_shot") or has_meta("is_piercing_shot"):
		queue_redraw()

	## 检查子弹是否超出屏幕边界
	_check_screen_boundary()

## ========== 追踪弹逻辑 ==========

## 追踪弹方向更新（由Enemy._skill_homing_shot通过meta标记驱动）
## 检查子弹是否携带追踪meta，有则持续转向目标
func _update_homing(delta: float) -> void:
	if not has_meta("homing_target"):
		return
	var target: Node = get_meta("homing_target")
	if target == null or not is_instance_valid(target):
		return
	## 追踪时长耗尽则停止追踪
	var elapsed: float = get_meta("homing_elapsed") + delta
	set_meta("homing_elapsed", elapsed)
	var homing_time: float = get_meta("homing_time")
	if elapsed >= homing_time:
		return  ## 追踪期结束，子弹直线飞行
	## 计算朝向目标的方向
	var to_target: Vector2 = (target.global_position - global_position).normalized()
	var turn_rate: float = get_meta("homing_turn_rate")
	## 逐步转向目标方向（线性插值，按转向速率限制角度变化）
	_direction = _direction.lerp(to_target, turn_rate * delta).normalized()

## ========== 屏幕边界检测 ==========

## _draw() - 技能子弹视觉绘制（追踪弹发光光环/穿透弹拖尾）
## 仅当子弹被标记为技能子弹时绘制额外视觉，普通子弹不触发
func _draw() -> void:
	## 追踪弹发光光环：围绕子弹绘制脉动的彩色光环
	if has_meta("is_homing_shot"):
		var color: Color = get_meta("homing_color", Color(0.6, 0.3, 0.8))
		var pulse: float = 0.7 + 0.3 * sin(Time.get_ticks_msec() * 0.008)
		## 外圈光晕（半透明大圆）
		draw_circle(Vector2.ZERO, 10.0, Color(color.r, color.g, color.b, 0.2 * pulse))
		## 内圈光环（较亮）
		draw_arc(Vector2.ZERO, 7.0, 0, TAU, 24, Color(color.r, color.g, color.b, pulse), 1.5)

	## 穿透弹拖尾：沿反方向绘制渐变拖尾线段
	if has_meta("is_piercing_shot"):
		var color: Color = get_meta("piercing_color", Color(1.0, 0.9, 0.3))
		## 拖尾方向：子弹的反方向
		var trail_dir: Vector2 = -_direction
		## 绘制3段渐变拖尾（由近到远逐渐透明）
		for i in range(3):
			var alpha: float = 0.6 - 0.18 * float(i)
			var start: Vector2 = trail_dir * (4.0 + i * 6.0)
			var end: Vector2 = trail_dir * (10.0 + i * 6.0)
			draw_line(start, end, Color(color.r, color.g, color.b, alpha), 3.0 - float(i) * 0.5)

## 检查子弹是否超出屏幕边界，超出则自动销毁
## 性能设计：相机/屏幕尺寸使用缓存（每0.5秒刷新），避免每帧的查找开销
func _check_screen_boundary() -> void:
	## 出场豁免期内不做边界销毁：终极BOSS追踪导弹从屏幕外飞入需要时间，豁免结束才恢复回收
	if _boundary_grace > 0.0:
		return

	## 相机刷新计时：每0.5秒重新查找一次相机并缓存屏幕尺寸
	## 数据流：计时器归零 → get_camera_2d重新查找 → 更新缓存引用
	_camera_refresh_timer += get_physics_process_delta_time()
	if _camera_refresh_timer >= 0.5 or _cached_screen_size == Vector2.ZERO:
		_camera_refresh_timer = 0.0
		_cached_camera = get_viewport().get_camera_2d()
		_cached_screen_size = get_viewport_rect().size

	## 如果没有缓存的相机，直接返回（等下次刷新）
	if _cached_camera == null:
		return

	## 使用缓存的相机位置与屏幕尺寸计算可视区域
	var camera_pos: Vector2 = _cached_camera.global_position
	var screen_size: Vector2 = _cached_screen_size
	## 计算屏幕半尺寸
	var half_screen: Vector2 = screen_size / 2.0
	## 获取边界余量
	var margin: float = screen_margin

	## 计算可视区域矩形（包含边界余量）
	var visible_rect: Rect2 = Rect2(
		camera_pos - half_screen - Vector2(margin, margin),
		screen_size + Vector2(margin * 2.0, margin * 2.0)
	)

	## 如果子弹不在可视区域内，销毁子弹
	if not visible_rect.has_point(global_position):
		_destroy()

## ========== 碰撞检测回调 ==========

## 碰撞检测回调：当有物理体进入子弹区域时调用
## 参数：body - 进入区域的物理体节点（如CharacterBody2D）
func _on_body_entered(body: Node2D) -> void:
	## 如果已经命中过目标，忽略后续碰撞（防止同一子弹造成多次伤害）
	if _has_hit:
		return
	
	## 如果子弹有所属阵营，且碰撞的物体与子弹同阵营，忽略碰撞（防止误伤友军）
	if _owner_group != "" and body.is_in_group(_owner_group):
		return
	
	## 重置保活标记（由ON_HIT特效决定本次命中后是否继续存活，如穿透）
	_keep_alive = false
	
	## 如果有子弹数据，触发命中时的特效（ON_HIT类型）
	if _bullet_data != null:
		_bullet_data.trigger_effects(
			BulletEffectClass.TriggerType.ON_HIT,
			self,
			body,
			{"direction": _direction}
		)
	
	## 穿透等保活特效会保持_has_hit为false，让子弹继续飞行命中下一个目标
	if not _keep_alive:
		_has_hit = true
	
	## 调用目标的take_damage方法（使用get_final_damage获取最终伤害，支持扩展）
	var damage_amount: float = _bullet_data.get_final_damage() if _bullet_data else 10.0
	## 通知目标攻击者信息（装备护盾特效需要知道子弹和方向）
	if body.has_method("set_last_attacker"):
		body.set_last_attacker(self, {"is_bullet": true, "direction": _direction, "bullet_data": _bullet_data})
	if body.has_method("take_damage"):
		body.call("take_damage", damage_amount)
		hit.emit(self, body)

	## 销毁子弹（保活特效生效时跳过）
	if not _keep_alive:
		_destroy()

## 碰撞检测回调：当有区域体进入子弹区域时调用（用于检测玩家Hitbox）
## 参数：area - 进入区域的Area2D节点（如玩家Hitbox）
func _on_area_entered(area: Area2D) -> void:
	## 如果已经命中过目标，忽略后续碰撞（防止同一子弹造成多次伤害）
	if _has_hit:
		return
	
	## 检查区域的父节点是否属于同一阵营
	if _owner_group != "":
		var parent_node: Node = area.get_parent()
		if parent_node != null and parent_node.is_in_group(_owner_group):
			return
	
	## 重置保活标记（由ON_HIT特效决定本次命中后是否继续存活，如穿透）
	_keep_alive = false
	
	## 如果有子弹数据，触发命中时的特效（ON_HIT类型）
	if _bullet_data != null:
		_bullet_data.trigger_effects(
			BulletEffectClass.TriggerType.ON_HIT,
			self,
			area,
			{"direction": _direction}
		)
	
	## 找到命中目标（通常是区域父节点，如玩家Hitbox → Player角色本体）
	## 特例：区域自身就是"可击落子弹"（终极BOSS追踪导弹直接挂在世界节点下，
	##       此时 get_parent() 会取到世界节点=错误目标），必须以区域自身为命中目标
	var target: Node2D = area
	if not area.has_meta("shootdown_health"):
		target = area.get_parent()
	if target == null:
		target = area
	
	## 穿透等保活特效会保持_has_hit为false，让子弹继续飞行命中下一个目标
	if not _keep_alive:
		_has_hit = true
	
	## 调用目标的take_damage方法（使用get_final_damage获取最终伤害，支持扩展）
	var damage_amount: float = _bullet_data.get_final_damage() if _bullet_data else 10.0
	## 通知目标攻击者信息（装备护盾特效需要知道子弹和方向）
	if target.has_method("set_last_attacker"):
		target.set_last_attacker(self, {"is_bullet": true, "direction": _direction, "bullet_data": _bullet_data})
	if target.has_method("take_damage"):
		target.call("take_damage", damage_amount)
		hit.emit(self, target)
	
	## 销毁子弹（保活特效生效时跳过）
	if not _keep_alive:
		_destroy()

## ========== 子弹销毁 ==========

## 销毁子弹（清理资源、触发特效、发出信号）
func _destroy() -> void:
	## 如果有子弹数据，触发销毁时的特效（ON_DESTROY类型）
	if _bullet_data != null:
		_bullet_data.trigger_effects(BulletEffectClass.TriggerType.ON_DESTROY, self)
	
	## 发出子弹销毁信号（用于GameWorld从管理列表中移除子弹）
	destroyed.emit()
	
	## 从场景树中移除并销毁子弹节点
	queue_free()