## AccelerateEffect.gd - 加速特效
## 职责：子弹飞行过程中速度逐渐增加（ON_TRAVEL触发）
## 继承：BulletEffect
## 被引用方：挂载于子弹配置的effects数组（data/bullet/effect/accelerate.tres），
##           也可作为UpgradeData.bullet_effect特效词条被玩家获得
## 设计意图：策略模式特效——由Bullet的ON_TRAVEL钩子每物理帧触发，实现"越飞越快"的弹道手感；
##           全部运行时状态存于bullet.meta，特效资源本身无状态（可被所有子弹安全共享）
## 继承改为按路径引用基类：全局类缓存缺失BulletEffect注册时，
## extends BulletEffect会报"Could not find base class"并连锁破坏所有引用特效的资源加载
extends "res://scripts/resources/bullet/BulletEffect.gd"

## ========== 加速属性 ==========

## 每秒加速度
@export var acceleration: float = 50.0

## 最大速度限制（倍数，默认最多达原速度的3倍）
@export var max_speed_mult: float = 3.0

## ========== 实现方法 ==========

## 每级叠层成长：加速度+20/s、速度上限倍数+0.4
## 设计意图：满级10层时50→230每秒加速、上限3→6.6倍原速，"越飞越快"的爽感随等级翻倍
func _on_stack_grown() -> void:
	acceleration += 20.0
	max_speed_mult += 0.4

## 应用加速特效（重写基类方法）
## 触发时机：ON_TRAVEL（飞行中每物理帧触发一次，性能热点路径）
## 参数：bullet - 飞行中的子弹实例；target/context 对本特效无意义（始终为null/空）
## 返回值：无
## 设计意图：每帧为子弹提速并启用专属拖尾/音效；基准速度与启用状态均挂在bullet上保证子弹间互不干扰
func apply(bullet: Node2D, target: Node2D = null, context: Dictionary = {}) -> void:
	if bullet == null:
		return
	var bd = bullet.get_bullet_data() if bullet.has_method("get_bullet_data") else null
	if bd == null:
		return

	## 基准速度存储在子弹实例的meta中（特效.tres被所有子弹共享，
	## 用特效成员变量会导致所有子弹共用第一颗子弹的速度基准）
	if not bullet.has_meta("accel_base_speed"):
		bullet.set_meta("accel_base_speed", bd.speed)
	var base_speed: float = bullet.get_meta("accel_base_speed")

	## ---------- 首次触发（按子弹实例判断）：引擎轰鸣音效 + 启用橙色加速拖尾 ----------
	## 注意：特效资源(.tres)被所有子弹共享，不能用特效自身变量记录状态，
	## 而是检查子弹实例的_trail_enabled（每颗子弹独立，销毁后新子弹重新启用）
	if bullet.has_method("enable_trail") and not bullet._trail_enabled:
		## 音效：低频滑升的引擎加速声，提示子弹开始蓄能加速
		if AudioManager:
			AudioManager.play_2d("fx_accelerate", bullet.global_position, 0.7)
		## 视觉：橙红色高温拖尾，体现速度感
		## （拖尾残影由Bullet内部经TrailGhost对象池生成，特效只负责开启并指定颜色/间隔）
		bullet.enable_trail(Color(1.0, 0.6, 0.15, 0.6), 0.025)

	var max_speed: float = base_speed * max_speed_mult
	## 每帧加速
	## 关键修复：Resource没有get_process_delta_time()方法（每帧报错刷屏导致卡顿），
	## 改为从子弹节点获取物理帧间隔（ON_TRAVEL在物理帧中触发）
	bd.speed = min(bd.speed + acceleration * bullet.get_physics_process_delta_time(), max_speed)