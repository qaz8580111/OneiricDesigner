## TrailGhost.gd - 通用视觉残影/碎片节点（对象池管理）
## 职责：为子弹拖尾、死亡碎片等高频视觉元素提供可复用的渐隐节点
## 继承：ColorRect（轻量绘制节点，无纹理开销）
## 性能设计（解决卡顿核心问题）：
##   旧实现：每0.03秒 new ColorRect + create_tween → 每秒创建销毁30~40个节点+Tween
##           （多颗拖尾子弹时每秒100+节点churn，引发GC压力和渲染卡顿）
##   新实现：节点回收进静态对象池，重复使用，动画由自身_process驱动（零Tween分配）
## 使用方式：只通过静态方法 spawn() 获取节点，不要手动 new
class_name TrailGhost
extends ColorRect

## class_name 说明：脚本内部使用了自身类型（Array[TrailGhost]、TrailGhost.new()），
## 必须声明 class_name 才能在自身作用域中引用本类，否则编译报错
## "Could not find type TrailGhost in the current scope"，
## 该错误会连锁导致 Bullet.gd 编译失败→玩家子弹完全无法生成

## ========== 对象池（静态，全局共享） ==========

## 空闲节点池（已动画结束、可复用的节点）
static var _pool: Array[TrailGhost] = []

## 当前活跃节点追踪表（spawn时加入、_recycle时移除，size即活跃数）
## 设计意图：用数组追踪替代纯计数器——重开局时世界节点销毁会连带释放活跃残影，
## 节点被外部释放而计数器无法感知，跨局累积后虚高直至永久封死上限（拖尾/碎片全失效）；
## 数组在达到上限时先清理失效引用再判断，天然自愈
static var _active: Array[TrailGhost] = []

## 活跃节点上限（拖尾+碎片共享的硬上限，超出时跳过生成——视觉略降级但绝不卡顿）
## 96的依据：拖尾0.035秒/个×0.25秒寿命≈每颗子弹同时8个，2颗拖尾子弹约16个；
##           其余余量留给死亡碎片（每敌4个）与敌潮同屏场景，稳态下绘制成本可忽略
const MAX_ACTIVE: int = 96

## ========== 动画参数（spawn时设置） ==========

## 剩余寿命（秒），归零后回池
var _life: float = 0.0

## 总寿命（秒），用于按比例计算渐隐/缩放进度
var _life_max: float = 0.25

## 结束时缩放（拖尾缩小到0.2倍，碎片保持1倍）
var _end_scale: float = 0.2

## 漂移速度（像素/秒，碎片飞散用，拖尾为ZERO）
var _drift: Vector2 = Vector2.ZERO

## ========== 静态工厂方法 ==========

## 生成一个残影/碎片（对外唯一入口）
## 数据流：Bullet._update_trail / Enemy._spawn_death_vfx → 此方法 → 从池中取节点复用
## 参数：world - 挂载父节点（通常为GameWorld，残影不随子弹销毁）
##       global_pos - 出生位置；color - 颜色；size_px - 方块边长
##       lifetime - 存活时长（秒）；end_scale - 结束缩放；drift - 漂移速度
## 返回：true=生成成功，false=池满被跳过（上限保护）
static func spawn(world: Node, global_pos: Vector2, color: Color, size_px: float = 8.0,
		lifetime: float = 0.25, end_scale_val: float = 0.2, drift: Vector2 = Vector2.ZERO) -> bool:
	## 父节点无效时放弃（防御）
	if world == null:
		return false
	## 活跃数达上限时：先清理数组中已被外部释放的失效引用（如上一局世界节点
	## 销毁时连带释放的残影——自愈机制防止跨局泄漏永久封死视觉上限），再判断
	if _active.size() >= MAX_ACTIVE:
		_active = _active.filter(func(g: TrailGhost) -> bool: return is_instance_valid(g))
		if _active.size() >= MAX_ACTIVE:
			return false

	## 从池中取节点：优先复用空闲节点，池空时才创建新节点
	## 注意：池中可能残留已被释放的节点（如上一局的世界节点销毁时连带释放），
	##       必须循环清理失效引用，否则add_child已释放节点会崩溃
	var ghost: TrailGhost = null
	while _pool.size() > 0:
		var candidate: TrailGhost = _pool.pop_back()
		if is_instance_valid(candidate):
			ghost = candidate
			break
	## 池空或全部失效：创建新节点（仅前期预热阶段发生，稳态后零分配）
	if ghost == null:
		ghost = TrailGhost.new()

	## 配置节点状态
	ghost._life = lifetime
	ghost._life_max = lifetime
	ghost._end_scale = end_scale_val
	ghost._drift = drift
	ghost.size = Vector2(size_px, size_px)
	## 居中技巧：ColorRect的position是左上角锚点，取负半尺寸让方块几何中心对准global_position
	ghost.position = -ghost.size / 2.0
	ghost.color = Color(color.r, color.g, color.b, color.a)
	ghost.rotation = 0.0
	ghost.scale = Vector2.ONE
	ghost.z_index = -1  ## 绘制在弹体/敌人下方，保持原拖尾视觉层次
	ghost.global_position = global_pos
	## 活跃数+1（登记进活跃追踪表）并挂到世界节点
	_active.append(ghost)
	world.add_child(ghost)
	return true

## ========== 实例方法 ==========

## _process() - 自驱动动画：渐隐+缩放+漂移，结束后回池
## 设计意图：用自身_process代替Tween，避免每帧动画的Tween对象分配
func _process(delta: float) -> void:
	## 递减寿命
	_life -= delta
	## 寿命耗尽：回收回池
	if _life <= 0.0:
		_recycle()
		return

	## 计算动画进度（1→0线性）
	var progress: float = _life / _life_max
	## 渐隐：透明度随进度线性下降
	modulate.a = progress
	## 缩放：从1倍插值到结束缩放
	var s: float = lerpf(_end_scale, 1.0, progress)
	scale = Vector2(s, s)
	## 漂移：碎片按初速度移动（拖尾drift=ZERO无移动）
	if _drift != Vector2.ZERO:
		global_position += _drift * delta

## 回收回池（复用核心）
func _recycle() -> void:
	## 从场景树移除（但节点对象保留，不销毁）
	## 父节点判空防御：节点被外部从树上摘除时get_parent()为null，直接跳过移除步骤
	var parent_node: Node = get_parent()
	if parent_node != null:
		parent_node.remove_child(self)
	## 活跃数-1（从活跃追踪表注销），节点进入空闲池
	_active.erase(self)
	_pool.append(self)
