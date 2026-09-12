## DamageNumber.gd - 浮动伤害数字组件
## 职责：在指定位置弹出伤害数字，向上飘浮+淡出，大小颜色随伤害量变化
## 继承：Label（直接用文字节点，轻量高效）
## 直播价值：每次命中都有即时视觉反馈，观众能看清"打了多少伤害"
## 生成方式：Enemy.take_damage() 中调用 DamageNumber.pop() 静态方法
## 性能设计（LV32后卡顿优化）：
##   1. 对象池复用Label，避免高频命中时反复new节点+创建Tween（后期每秒上百次分配会触发GC卡顿）
##   2. 实例自驱动(_process)上浮淡出，不再为每个数字创建Tween对象
##   3. 同时活跃数封顶MAX_ACTIVE，超出直接丢弃（视觉上数字过密也无法辨认）
extends Label

## ========== 对象池常量/状态（静态，跨实例共享） ==========

## 同时活跃的伤害数字上限（后期弹幕战每秒可能触发上百次命中，超出部分丢弃）
const MAX_ACTIVE: int = 30
## 数字存活时长（秒）
const LIFE_TIME: float = 0.6
## 上浮总距离（像素）
const FLOAT_DISTANCE: float = 30.0
## 普通/暴击字号
const FONT_SIZE_NORMAL: int = 14
const FONT_SIZE_CRIT: int = 20

## 本脚本引用（静态工厂中用它创建带脚本的Label实例）
const SELF_SCRIPT: GDScript = preload("res://scripts/components/DamageNumber.gd")

## 空闲实例池（不可见且已停用，等待复用）
static var _pool: Array = []
## 当前活跃数量（在场景中播放中的数字）
static var _active_count: int = 0
## 池所属场景：场景切换（重开局）后旧节点随旧场景释放，池整体作废重建
static var _pool_scene: Node = null

## ========== 实例状态 ==========

## 剩余存活时间
var _life_left: float = 0.0
## 起始Y坐标（上浮从start_y到start_y-FLOAT_DISTANCE）
var _start_y: float = 0.0
## 暴击放大动画进度（0→1，仅暴击数字用）
var _crit_anim: float = 0.0
## 是否暴击（驱动放大动画）
var _is_crit_instance: bool = false

## ========== 静态方法 ==========

## 弹出伤害数字（对外接口，由Enemy/Player调用）
## 参数：position - 弹出位置（世界坐标），amount - 伤害数值，is_crit - 是否暴击/大伤害
##       color - 可选自定义颜色（不传则按is_crit自动选红/白）
static func pop(position: Vector2, amount: int, is_crit: bool = false, color: Color = Color(-1, -1, -1)) -> void:
	## 获取当前场景树
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null or tree.current_scene == null:
		return

	## 场景切换后旧池作废（旧场景中的池节点已随场景释放，计数也一并重置）
	if _pool_scene != tree.current_scene:
		_pool.clear()
		_active_count = 0
		_pool_scene = tree.current_scene

	## 活跃数封顶：超出直接丢弃（屏幕上数字过密玩家本就看不清，保帧率优先）
	if _active_count >= MAX_ACTIVE:
		return

	## 从池中取一个空闲实例；池空则新建
	## 注意：本脚本无class_name，这里必须用无类型Variant接收，
	## 否则标注DamageNumber类型会解析失败；方法调用走动态分发
	var num = null
	while not _pool.is_empty():
		var candidate = _pool.pop_back()
		## 场景切换等情况下池引用可能已失效，跳过释放过的节点
		if is_instance_valid(candidate):
			num = candidate
			break
	if num == null:
		num = SELF_SCRIPT.new()

	## 颜色优先级：自定义颜色 > is_crit默认色
	var final_color: Color
	if color.r >= 0:
		final_color = color
	elif is_crit:
		final_color = Color(1.0, 0.3, 0.2)
	else:
		final_color = Color(1.0, 1.0, 0.9)

	num.activate(tree.current_scene, position, amount, is_crit, final_color)
	_active_count += 1

## ========== 实例方法 ==========

## 激活/重置一个数字实例（新弹出或从池中复用时调用）
## 参数：parent - 挂载场景；world_pos - 世界坐标；amount - 伤害值；is_crit - 暴击；font_color - 颜色
func activate(parent: Node, world_pos: Vector2, amount: int, is_crit: bool, font_color: Color) -> void:
	text = str(amount)
	position = world_pos + Vector2(randf_range(-8, 8), -10)
	_start_y = position.y
	z_index = 100
	horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_theme_font_size_override("font_size", FONT_SIZE_CRIT if is_crit else FONT_SIZE_NORMAL)
	add_theme_color_override("font_color", font_color)
	## 复位所有动画相关属性（复用实例时上一轮的残留必须清干净）
	modulate = Color.WHITE
	scale = Vector2(0.6, 0.6) if is_crit else Vector2.ONE
	_life_left = LIFE_TIME
	_crit_anim = 0.0
	_is_crit_instance = is_crit
	visible = true
	set_process(true)
	## 池实例平时挂在场景下但停用；若此前被remove_child则重新挂回
	if not is_inside_tree():
		parent.add_child(self)

## _process() - 自驱动上浮淡出（替代旧方案每实例一个Tween，零动画对象分配）
func _process(delta: float) -> void:
	_life_left -= delta
	if _life_left <= 0.0:
		_return_to_pool()
		return
	## 进度0→1（1=刚弹出，0=结束），上浮与淡出都基于它计算
	var progress: float = 1.0 - _life_left / LIFE_TIME
	position.y = _start_y - FLOAT_DISTANCE * (1.0 - (1.0 - progress) * (1.0 - progress))
	modulate.a = 1.0 - progress
	## 暴击数字：快速从0.6放大到1.15（0.15秒内，模拟旧Tween的BACK_OUT弹手感）
	if _is_crit_instance and _crit_anim < 1.0:
		_crit_anim = minf(_crit_anim + delta / 0.15, 1.0)
		var s: float = lerpf(0.6, 1.15, 1.0 - (1.0 - _crit_anim) * (1.0 - _crit_anim))
		scale = Vector2(s, s)

## 播放结束归还对象池（隐藏+停用+计数回退，节点保留供下次复用）
func _return_to_pool() -> void:
	set_process(false)
	visible = false
	_active_count = maxi(_active_count - 1, 0)
	## 先记录归属场景（remove_child后get_tree()会返回null，必须提前取值）
	var tree: SceneTree = get_tree()
	var belongs_to_pool_scene: bool = tree != null and tree.current_scene == _pool_scene
	if is_inside_tree():
		## 从播放父节点摘下但不销毁；池节点暂存于"游离"状态，下次activate时重新挂回
		remove_child(self)
	## 池所属场景已切换则不回收（节点会随旧场景释放，避免新场景持旧引用）
	if belongs_to_pool_scene:
		_pool.append(self)
