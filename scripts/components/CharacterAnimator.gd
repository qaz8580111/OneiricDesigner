## CharacterAnimator.gd - 通用角色动画器组件（玩家/敌人/Boss 共用）
## 职责：驱动角色外观动画——按皮肤模式分两条实现路径：
##   PROCEDURAL 模式：程序驱动 Sprite2D（呼吸/弹跳/挤压拉伸/攻击前倾/受击白闪抖动）
##   FRAMES 模式：    切换 AnimatedSprite2D 播放列表（idle/move/attack/hit/death 槽位）
## 继承：Node（由 Player/Enemy 在应用皮肤时动态创建并 add_child，无需场景配置）
## 设计意图：
##   1. 角色逻辑只调四个语义接口 set_moving/set_facing/play_attack/flash_hit，
##      不关心动画怎么实现——以后序列帧美术进来，角色代码零改动
##   2. 动画"性格"由皮肤参数控制（CharacterSkin 的幅度/频率字段），动画器代码通用
##   3. 自驱动 _process 动画，不占用宿主的 _physics_process（AI逻辑与动画解耦）
## 数据流：宿主状态变化 → 语义接口 → 内部状态 → _process 每帧写 sprite 的
##         scale/rotation/position/flip_h/modulate（或切换 AnimatedSprite2D 动画）
class_name CharacterAnimator
extends Node2D

## ========== 预加载资源 ==========

## 皮肤资源类（类型注解用）
const CharacterSkinClass = preload("res://scripts/resources/skin/CharacterSkin.gd")

## ========== 动画节奏常量 ==========

## 攻击脉冲时长（秒）：前倾+放大回弹的总时长
const ATTACK_PULSE_DURATION: float = 0.18

## 受击白闪/抖动时长（秒）
const HIT_FLASH_DURATION: float = 0.12

## ========== 成员变量（运行时数据） ==========

## 当前驱动的皮肤（决定动画参数与渲染模式）
var _skin: CharacterSkinClass = null

## 宿主的 Sprite2D（PROCEDURAL 模式的操作对象）
var _sprite: Sprite2D = null

## 序列帧精灵（FRAMES 模式动态创建；procedural 模式为 null）
var _anim_sprite: AnimatedSprite2D = null

## 累计时间（驱动呼吸/弹跳的相位）
var _time: float = 0.0

## 是否处于移动状态（true=弹跳挤压动画 / false=待机呼吸动画）
var _moving: bool = false

## 朝向（+1=面朝右 / -1=面朝左；控制 flip_h 与攻击前倾方向）
var _facing: float = 1.0

## 攻击脉冲剩余时间（>0 时叠加攻击缩放与前倾）
var _attack_timer: float = 0.0

## 受击效果剩余时间（>0 时位置抖动；颜色白闪由宿主自身逻辑管理）
var _hit_timer: float = 0.0

## ========== 初始化 ==========

## 设置动画器驱动目标（首次创建或热切换皮肤时调用）
## 参数：skin - 角色皮肤；sprite - 宿主的 Sprite2D 节点
func setup(skin: CharacterSkinClass, sprite: Sprite2D) -> void:
	## 记录皮肤与精灵引用
	_skin = skin
	_sprite = sprite
	## FRAMES 模式：创建序列帧精灵并隐藏原 Sprite2D（序列帧取代色块）
	if skin != null and skin.has_frames():
		_build_frames_sprite()
	elif _anim_sprite != null:
		## 从 FRAMES 切回 PROCEDURAL（热切换场景）：显示原精灵、移除序列帧精灵
		_anim_sprite.queue_free()
		_anim_sprite = null
		if sprite != null:
			sprite.visible = true

## 创建序列帧精灵（FRAMES 模式专用）
func _build_frames_sprite() -> void:
	## 首次：动态创建 AnimatedSprite2D 挂到本组件下（跟随宿主移动）
	if _anim_sprite == null:
		_anim_sprite = AnimatedSprite2D.new()
		add_child(_anim_sprite)
		## 非循环动画（attack/hit）播完自动回到循环态（idle/move）
		_anim_sprite.animation_finished.connect(_on_frames_animation_finished)
	## 换肤：替换帧资源并显示
	_anim_sprite.sprite_frames = _skin.frames
	if _sprite != null:
		_sprite.visible = false
	## 序列帧尺寸对齐：按皮肤目标尺寸缩放（美术帧尺寸可能与占位尺寸不同）
	## 只在 idle 槽位存在时对齐（避免查询不存在的动画报错）
	if _skin.frames != null and _skin.frames.has_animation("idle") \
			and _skin.frames.get_frame_count("idle") > 0:
		var tex: Texture2D = _skin.frames.get_frame_texture("idle", 0)
		if tex != null and tex.get_width() > 0:
			var fit_scale: float = _skin.target_size.x / float(tex.get_width())
			_anim_sprite.scale = Vector2(fit_scale, fit_scale)
	## 关键：创建后立即播放 idle，否则 AnimatedSprite2D 默认 animation 为 "default"（不存在），
	## 启动时 set_moving(false) 因状态未变直接 return，不会触发 idle 播放 → 角色不可见
	_play_frames("idle")

## ========== 语义接口（宿主唯一需要调用的四个动画入口 + 辅助） ==========

## 设置移动状态（宿主每帧或状态切换时调用）
## 参数：moving - true=移动(弹跳/摇摆) / false=待机(呼吸)
func set_moving(moving: bool) -> void:
	## 状态无变化直接返回（避免重复切换 AnimatedSprite2D 播放头）
	if _moving == moving:
		return
	_moving = moving
	## FRAMES 模式：切换移动/待机动画槽位
	if _anim_sprite != null:
		_play_frames("move" if moving else "idle")

## 设置朝向（+1=右 / -1=左；宿主根据移动方向或瞄准方向调用）
func set_facing(dir_x: float) -> void:
	## 只取符号（0 保持原朝向）
	if absf(dir_x) > 0.01:
		_facing = signf(dir_x)
	## FRAMES 模式：直接翻转序列帧精灵（PROCEDURAL 模式在 _process 中处理 sprite.flip_h）
	if _anim_sprite != null and _skin != null:
		_anim_sprite.flip_h = _skin.flip_with_direction and _facing < 0.0

## 播放攻击动画（宿主执行攻击动作时调用一次）
func play_attack() -> void:
	## PROCEDURAL：启动脉冲计时器（_process 中消费）
	_attack_timer = ATTACK_PULSE_DURATION
	## FRAMES：切换到 attack 槽位（播完由 animation_finished 回到循环态）
	if _anim_sprite != null:
		_play_frames("attack")

## 播放受击抖动（纯运动效果：随机高频位移；FRAMES 模式播 hit 槽位）
## 设计说明：不操作 modulate——颜色状态（燃烧染色/冰冻染色/白闪恢复）由宿主
##           自行管理（Enemy 已有"恢复白闪前颜色"的精细逻辑），动画器只管运动
func play_hit_shake() -> void:
	## 重复受击时重置计时即可（抖动连贯不叠加）
	_hit_timer = HIT_FLASH_DURATION
	## FRAMES：播放 hit 槽位
	if _anim_sprite != null:
		_play_frames("hit")

## 播放死亡动画（FRAMES 模式切到 death 槽位；PROCEDURAL 模式无动作，由宿主处理外观）
func play_death() -> void:
	if _anim_sprite != null:
		_play_frames("death")

## ========== 每帧动画驱动 ==========

## _process() - 每渲染帧调用（视觉动画跟渲染帧率走更平滑）
func _process(delta: float) -> void:
	## 皮肤/精灵未就绪时跳过
	if _skin == null or _sprite == null:
		return
	## FRAMES 模式：播放交由 AnimatedSprite2D 自身，无需程序驱动
	if _anim_sprite != null:
		return
	## 累计动画时间（呼吸/弹跳相位源）
	_time += delta

	## ---------- 1) 计算基础缩放（移动弹跳 / 待机呼吸） ----------
	var target_scale: Vector2 = Vector2.ONE
	if _moving:
		## 弹跳：|sin| 让每次触地都是"压扁→拉长"，经典挤压拉伸手感
		var bounce: float = absf(sin(_time * _skin.move_bounce_speed)) * _skin.move_bounce_scale
		## 纵向拉长 + 横向压扁（体积感守恒的近似）
		target_scale = Vector2(1.0 - bounce * 0.45, 1.0 + bounce)
		## 按形状差异化：圆形加果冻波动、菱形加轻摆（不同体型不同动法）
		match _skin.shape:
			"circle":
				## 果冻感：横向叠加一个慢速波动
				target_scale.x += sin(_time * 7.0) * _skin.move_bounce_scale * 0.4
			"diamond":
				## 敏捷感：移动时身体轻微左右倾摆
				_sprite.rotation = sin(_time * 6.0) * 0.12
			_:
				pass
	else:
		## 待机呼吸：纵向轻微起伏 + 横向反向微缩（呼吸体积感）
		var breath: float = sin(_time * 2.6) * _skin.idle_breath_scale
		target_scale = Vector2(1.0 - breath * 0.5, 1.0 + breath)

	## ---------- 2) 叠加攻击脉冲（放大回弹 + 朝向侧前倾） ----------
	var pos_x: float = 0.0
	var pos_y: float = 0.0
	if _attack_timer > 0.0:
		## 脉冲进度 1→0；sin(p*PI) 中间凸起（0→1→0 的平滑包络）
		var pulse: float = _attack_timer / ATTACK_PULSE_DURATION
		target_scale *= 1.0 + sin(pulse * PI) * 0.16
		## 前倾：向面朝方向探出 2.5px，模拟"发力顶出去"的位移感
		pos_x += sin(pulse * PI) * _facing * 2.5
		## 脉冲计时衰减
		_attack_timer -= delta

	## ---------- 3) 受击抖动（随机高频位移，打击感核心） ----------
	if _hit_timer > 0.0:
		## 每帧随机抖动 ±2px（高频抖动比固定位移更有打击感）
		pos_x += randf_range(-2.0, 2.0)
		pos_y += randf_range(-2.0, 2.0)
		## 抖动结束：位置归零（颜色恢复由宿主自身逻辑管理，此处不碰）
		_hit_timer -= delta
		if _hit_timer <= 0.0:
			pos_x = 0.0
			pos_y = 0.0

	## ---------- 4) 写入精灵属性 ----------
	## 菱形待机时回正倾摆（只有 diamond 移动分支写了 rotation，其余情况保持 0）
	if _skin.shape != "diamond" or not _moving:
		_sprite.rotation = 0.0
	## 应用缩放与位移
	_sprite.scale = target_scale
	_sprite.position = Vector2(pos_x, pos_y)
	## 朝向翻转（皮肤可关闭：对称形状如圆球翻转无意义）
	_sprite.flip_h = _skin.flip_with_direction and _facing < 0.0

## ========== FRAMES 模式辅助 ==========

## 播放指定槽位动画（槽位不存在时静默跳过——序列帧美术可只配部分动画）
func _play_frames(anim_name: String) -> void:
	if _anim_sprite == null or _anim_sprite.sprite_frames == null:
		return
	## 槽位存在才播放（缺失槽位自动跳过，容错美术资源不全的情况）
	if _anim_sprite.sprite_frames.has_animation(anim_name):
		_anim_sprite.play(anim_name)

## 非循环动画（attack/hit）播完回调：回到当前状态的循环动画
func _on_frames_animation_finished() -> void:
	## 回到与移动状态匹配的循环动画
	_play_frames("move" if _moving else "idle")
