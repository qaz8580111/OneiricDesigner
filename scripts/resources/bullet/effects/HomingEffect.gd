## HomingEffect.gd - 追踪（制导）特效
## 职责：子弹在飞行过程中自动追踪最近的敌人
## 继承：BulletEffect（注意：此特效触发时机应为 ON_TRAVEL）
## 性能设计（每物理帧调用的热点优化）：
##   旧实现：每帧 get_nodes_in_group + O(n)距离扫描 → 多颗制导弹×大量敌人时CPU热点
##   新实现：目标重锁定按0.12秒节流（meta计时器），锁定后每帧只做廉价向量插值
## 被引用方：挂载于子弹配置的effects数组（trigger_type须配ON_TRAVEL），
##           也可作为UpgradeData.bullet_effect特效词条被玩家获得
## 设计意图：策略模式特效——Bullet飞行钩子逐帧触发；锁定目标与节流计时随子弹meta存取，
##           子弹销毁时一并回收（无泄漏），特效资源自身保持无状态可共享
## 继承改为按路径引用基类：全局类缓存缺失BulletEffect注册时，
## extends BulletEffect会报"Could not find base class"并连锁破坏所有引用特效的资源加载
extends "res://scripts/resources/bullet/BulletEffect.gd"

## ========== 追踪属性 ==========

## 追踪范围（检测范围内目标）
@export var homing_range: float = 300.0

## 转向速度（0-1，越大转向越快）
@export var turn_speed: float = 0.05

## 追踪强度阈值（距离目标小于此值时不追踪，避免绕圈）
@export var min_distance: float = 20.0

## 目标重锁定间隔（秒）：每隔此时间重新扫描最近目标
## 设计意图：0.12秒的锁定延迟肉眼无感，但将组查询频率从每帧降到约1/7帧
@export var retarget_interval: float = 0.12

## ========== 实现方法 ==========

## 每级叠层成长：转向速度+0.02（弹道更粘人）、追踪范围+40px
## 设计意图：满级5层时0.05→0.13转向、范围300→460px，子弹如制导导弹般指哪打哪
func _on_stack_grown() -> void:
	turn_speed = minf(turn_speed + 0.02, 0.4)
	homing_range += 40.0

## 应用追踪特效（重写基类方法）
## 触发时机：ON_TRAVEL（飞行中每物理帧触发，性能敏感路径）
## 参数：bullet - 飞行中的子弹实例；target/context 对本特效无意义（始终为null/空）
## 返回值：无
## 设计意图：重锁定（组查询+距离扫描）按retarget_interval节流并把目标/计时器存入bullet.meta；
##           其余每帧仅做向量lerp插值转向，控制制导弹道平滑度
func apply(bullet: Node2D, target: Node2D = null, context: Dictionary = {}) -> void:
	if bullet == null:
		return

	## ---------- 首次触发（按子弹实例判断）：锁定音效 + 启用青色追踪拖尾 ----------
	## 注意：特效资源(.tres)被所有子弹共享，不能用特效自身变量记录状态，
	## 而是检查子弹实例的_trail_enabled（每颗子弹独立，销毁后新子弹重新启用）
	if bullet.has_method("enable_trail") and not bullet._trail_enabled:
		## 音效：上升的"锁定"哔声，提示子弹进入制导状态
		if AudioManager:
			AudioManager.play_2d("fx_homing", bullet.global_position, 0.6)
		## 视觉：青绿色魔法拖尾，体现制导轨迹
		## （拖尾残影由Bullet内部经TrailGhost对象池生成，特效只负责开启并指定颜色/间隔）
		bullet.enable_trail(Color(0.4, 1.0, 0.85, 0.55), 0.03)

	## ---------- 目标重锁定（节流） ----------
	## 重锁定计时器存在子弹meta中（每颗子弹独立计时）
	var timer: float = bullet.get_meta("homing_retarget_t", 0.0)
	timer -= bullet.get_physics_process_delta_time()

	## 计时器归零或尚无锁定目标时：重新扫描最近敌人
	var locked_target: Node2D = null
	if bullet.has_meta("homing_target"):
		locked_target = bullet.get_meta("homing_target")
	## 目标失效（死亡/销毁）时强制重锁
	if locked_target != null and not is_instance_valid(locked_target):
		locked_target = null

	if timer <= 0.0 or locked_target == null:
		## 重置节流计时器
		timer = retarget_interval
		## 扫描并锁定新目标（唯一保留的组查询点，已按0.12秒节流）
		var new_target: Node2D = _find_nearest_enemy(bullet)
		if new_target != null:
			## 目标引用存入子弹meta（子弹销毁时meta一并回收，无泄漏）
			bullet.set_meta("homing_target", new_target)
			locked_target = new_target
		elif locked_target == null:
			## 无目标可用：直接返回保持直线飞行
			bullet.set_meta("homing_retarget_t", timer)
			return
	## 回写节流计时器
	bullet.set_meta("homing_retarget_t", timer)

	## ---------- 每帧廉价转向（向量插值，无任何查找） ----------
	## 锁定目标可能在本帧内死亡：再次校验有效性
	if locked_target == null or not is_instance_valid(locked_target):
		return

	## 获取当前子弹方向（Bullet成员变量名为_direction，属性检查需带下划线）
	var current_dir: Vector2 = bullet._direction if "_direction" in bullet else Vector2.RIGHT
	if current_dir == Vector2.ZERO:
		return

	## 距离过近时不转向（避免绕圈打转）
	var dist: float = locked_target.global_position.distance_to(bullet.global_position)
	if dist <= min_distance:
		return

	## 计算追踪方向并平滑转向（插值）
	var desired_dir: Vector2 = (locked_target.global_position - bullet.global_position).normalized()
	var new_dir: Vector2 = current_dir.lerp(desired_dir, turn_speed).normalized()

	## 回写方向到子弹
	if bullet.has_method("set_direction"):
		bullet.set_direction(new_dir)
	elif "_direction" in bullet:
		bullet._direction = new_dir

## 查找追踪范围内最近的敌人（仅在重锁定时调用）
## 参数：bullet - 发起查找的子弹
## 返回：最近的敌人节点，无目标时返回null
func _find_nearest_enemy(bullet: Node2D) -> Node2D:
	## 获取阵营（玩家弹追踪敌人，敌人弹追踪玩家）
	var owner_group: String = bullet._owner_group if "_owner_group" in bullet else "player"
	var enemy_group: String = "enemy" if owner_group == "player" else "player"

	## 组查询+距离扫描（每0.12秒一次，成本可控）
	## 注意：特效是Resource节点，没有get_tree()方法，通过bullet获取场景树
	var enemies: Array = bullet.get_tree().get_nodes_in_group(enemy_group)
	var nearest: Node2D = null
	var nearest_dist: float = homing_range

	for e in enemies:
		if e == null or not is_instance_valid(e):
			continue
		var dist: float = e.global_position.distance_to(bullet.global_position)
		if dist < nearest_dist and dist > min_distance:
			nearest = e
			nearest_dist = dist
	return nearest
