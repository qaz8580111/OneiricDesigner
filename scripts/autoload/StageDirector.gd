## StageDirector.gd - 阶段导演（游戏总进度把控切面）
## 职责：以 AOP（面向切面）方式无痕插入"阶段进度系统"，把控整局游戏的总节奏
## 继承：Node（作为全局单例 autoload 运行）
## 设计意图（AOP 切面模型，业务代码零修改）：
##   1. 本类是一个独立的"切面"模块——不修改 GameWorld/DifficultyManager/Enemy 的任何一行，
##      仅通过观察（信号监听）与注入（外部调用公开接口/装饰节点）介入业务流程
##   2. 切点（Pointcut）一览：
##      - GameManager.game_started    → 前置通知：每局重置进度时间轴
##      - GameManager.is_playing()    → 环绕通知：自计时推进阶段事件（暂停自动冻结，与难度曲线同拍）
##      - GameWorld._spawn_enemy()    → 引入通知：怪潮期间临时抬升 DifficultyManager.level +1，
##                                      复用业务刷怪链路实现"等级+1 的怪物"，刷完立即还原
##                                      （全程同步无 await，无渲染间隙，HUD/信号零感知）
##      - Enemy.killed/damaged        → 后置通知：监听 Boss 死亡推进阶段、受击驱动外挂血条
##   3. 装饰模式：Boss 复用 Enemy.tscn 实例 + 数据深拷贝副本（绝不污染共享 .tres），
##      头顶血条/屏幕血条/阶段字幕均为切面外挂节点，随 Boss 销毁自动清理
## 进度模型（总进度把控到阶段 10，之后进入终极关卡）：
##   阶段 N 整点（N*105 秒）    → 怪潮事件：一波"等级+1"的怪物
##   阶段 N.5（N*105+52.5 秒） → 阶段 N 守门 Boss（阶段 10.5 为关底 Boss"梦境之主"）
##   事件严格串行：上一个事件完结（怪潮全灭或超时兜底 / Boss 被击杀）后，才触发下一个已到点的事件
##   击杀「梦境之主」→ 终极关卡：清空全场敌人 + 停止常规刷怪 + 生成终极 BOSS「梦境根源」
##   击杀终极 BOSS → 本局通关（emit run_completed）
## 节奏目标：阶段 10.5「梦境之主」在 1102.5 秒（≈18.4 分钟）降临，
##          整局（不含终极 BOSS 战）落在 15~20 分钟区间，与 DifficultyManager 每级 110 秒同档
## 数据流：本类自计时 → 时间轴事件表逐个触发 → 怪潮走业务刷怪链路 / Boss 由切面自建
##         → Boss 死亡信号回调 → 推进事件索引 → …… → 终极关卡 → 终局通关
extends Node

## ========== 预加载资源（避免运行时加载延迟） ==========

## 敌人场景：Boss 复用普通敌人场景（装饰模式，不改 Enemy.gd 源码）
const ENEMY_SCENE: PackedScene = preload("res://scenes/gameplay/Enemy.tscn")

## 敌人数据资源类：Boss 数据副本的类型（duplicate 后注入 Enemy）
const EnemyDataClass = preload("res://scripts/resources/enemy/EnemyData.gd")

## 掉落物数据资源类：配置 Boss 丰厚掉落
const DropItemClass = preload("res://scripts/resources/enemy/DropItem.gd")

## 子弹数据资源类：终极 BOSS 普攻强化配置（伤害/速度提升）
const BulletDataClass = preload("res://scripts/resources/bullet/BulletData.gd")

## 怪物技能资源类：终极 BOSS 三技能配置（天女散花/飞机轰炸/追踪导弹）
const MonsterSkillClass = preload("res://scripts/resources/enemy/MonsterSkill.gd")

## 残影/粒子节点类（对象池管理）：Boss 出场特效复用，遵守性能约定
const TrailGhostClass = preload("res://scripts/entities/TrailGhost.gd")

## 竞技场常量：Boss出生点必须钳制在物理墙内（防止刷在场外被墙隔开）
const ArenaConfigClass = preload("res://scripts/world/ArenaConfig.gd")

## ========== 调参常量（阶段曲线的核心配置，集中管理便于平衡调整） ==========

## 每个阶段的时长（秒）：阶段 N 事件在 N*105 秒，阶段 N.5 在 N*105+52.5 秒
## 数值依据：DifficultyManager 每级 110 秒，本切面每阶段 105 秒，两者同档推进（等级≈阶段）
## 节奏结果：阶段 10 怪潮 1050 秒 → 关底 Boss「梦境之主」1102.5 秒（≈18.4 分钟），
##          整局（不含终极 BOSS 战）落在 15~20 分钟区间
const STAGE_INTERVAL: float = 105.0

## 总进度上限：把控到阶段 10（阶段 10.5 为关底 Boss）
const MAX_STAGE: int = 10

## 怪潮完结超时（秒）：玩家长时间不清怪时自动放行下一事件，防止进度被"苟"卡死
const WAVE_TIMEOUT: float = 45.0

## Boss 生成距离（与玩家的距离，像素）：屏幕外附近，Boss 直奔玩家而来
const BOSS_SPAWN_DISTANCE: float = 700.0

## 波次怪存活检查节流（秒）：每 0.5 秒查一次快照存活数，避免每帧遍历
const WAVE_CHECK_INTERVAL: float = 0.5

## 终极 BOSS 碰撞判定半径（像素）：视觉半径为皮肤 150x150 的一半（75），
## 判定略小于视觉，避免"擦边"就被判中，手感更公平
const ULTIMATE_BOSS_COLLISION_RADIUS: float = 68.0

## 终极 BOSS 受击盒（Hitbox）半径：比物理体再小 2px，接触伤害判定稍收紧
const ULTIMATE_BOSS_HITBOX_RADIUS: float = 66.0

## ========== 阶段事件类型枚举 ==========

enum StageEventType {
	MOB_WAVE,    ## 怪潮事件：一波"等级+1"的怪物
	BOSS,        ## 守门 Boss 事件：阶段 N.5 出现的阶段 Boss
	FINAL_BOSS   ## 关底 Boss 事件：阶段 10.5 出现的"梦境之主"
}

## ========== 信号定义（供未来扩展使用，当前切面内部消费） ==========

## 阶段事件触发信号：参数为事件类型与所属阶段
signal stage_event_fired(event_type: int, stage: int)

## 终极关卡开启信号：关底 Boss「梦境之主」被击杀、全场清空并停止常规刷怪后发出
signal ultimate_stage_started

## 通关信号：终极 BOSS「梦境根源」被击杀时发出（本局通关）
signal run_completed

## ========== 运行时状态（每局由 game_started 重置） ==========

## 本局已进行的游戏时间（秒），仅游戏进行中累计（与 DifficultyManager 同拍冻结）
var _elapsed: float = 0.0

## 本局事件时间轴（_build_timeline 生成的事件字典数组，按时间升序）
var _timeline: Array = []

## 下一个待触发的事件索引（时间轴游标：触发成功才前进）
var _event_index: int = 0

## 是否已进入终局（终极关卡标志：true 后时间轴退役，不再触发任何阶段事件）
var _run_completed: bool = false

## 当前活动事件的类型（-1 = 无活动事件，即上一个事件已完结、可触发下一个）
var _active_type: int = -1

## 当前怪潮的敌人快照（刷怪前后的差集，用于追踪"这波怪是否全灭"）
var _wave_enemies: Array = []

## 当前怪潮的完结截止时间（超时自动放行）
var _wave_deadline: float = 0.0

## 怪潮存活检查节流累计器
var _wave_check_accum: float = 0.0

## 当前存活的 Boss 引用（killed 信号驱动阶段推进；is_instance_valid 防悬挂）
var _current_boss: Node = null

## ---------- 濒死狂暴状态（直播增强：Boss HP<20% 攻速提升+屏幕红边） ----------
## 当前 Boss 是否已进入濒死狂暴（一局只触发一次，避免反复切换）
var _boss_enraged: bool = false
## 狂暴触发的 HP 阈值（20%）
const BOSS_ENRAGE_THRESHOLD: float = 0.2

## ---------- Boss登场时停帧计数状态（process_frame 回调需要持久化） ----------
var _time_stop_remaining: int = 0
var _time_stop_callback: Callable = Callable()
const BOSS_ENTRY_TIME_STOP_FRAMES: int = 12  ## 60fps × 0.2s = 12帧

## GameWorld 缓存引用（懒查找，场景切换后自动失效重查）
var _world_cache: Node2D = null

## ========== UI 组件引用（切面自建 CanvasLayer，不改 GameHUD） ==========

## 切面专属 UI 层（阶段字幕 / Boss 血条 / 进度标签都挂这里）
var _hud_layer: CanvasLayer = null

## 左上角进度标签（"阶段 3/10"、"阶段 3.5/10"、"无尽模式"）
var _stage_label: Label = null

## 居中大字幕（阶段开始 / Boss 来袭 / 通关横幅）
var _banner_label: Label = null

## 字幕动画引用（新字幕触发前 kill 旧动画，防止闪烁冲突）
var _banner_tween: Tween = null

## Boss 血条容器（顶部居中：名称 + 背景/前景条，Boss 存活期间显示）
var _boss_box: Control = null
var _boss_name_label: Label = null
var _boss_bar_bg: ColorRect = null
var _boss_bar_fg: ColorRect = null

## ========== 生命周期方法 ==========

## _ready() - 切面初始化：搭建 UI 层 + 连接游戏生命周期信号
func _ready() -> void:
	## 搭建切面专属 UI 层（一次性构建，之后只做显示/隐藏与内容更新）
	_build_hud_layer()
	## 前置通知：每局开始时重置进度状态
	GameManager.game_started.connect(_on_game_started)

## _process() - 切面主循环：推进计时、管理活动事件、触发已到点事件
## 数据流：is_playing 门禁 → 累计时间 → 活动事件完结检查 → 下一事件触发
func _process(delta: float) -> void:
	## 门禁 1：只在游戏进行中推进（暂停/菜单/结算时时间轴冻结，与难度曲线同拍）
	if not GameManager.is_playing():
		return
	## 门禁 2：已进入终极关卡 → 时间轴退役，本局进度由终极 BOSS 战独立接管
	if _run_completed:
		return

	## 累计游戏时间
	_elapsed += delta

	## 活动事件完结检查（怪潮全灭/超时；Boss 由 killed 信号驱动，此处兜底防悬挂引用）
	_update_active_event(delta)

	## 尝试触发下一个已到点的事件（串行推进：有活动事件时挂起等待）
	_try_fire_next_event()

## ========== 事件时间轴构建 ==========

## 构建本局事件时间轴（每局 game_started 时重建）
## 时间轴模型：阶段 N 怪潮在 N*105 秒 → 阶段 N 守门 Boss 在 N*105+52.5 秒 → ……
##             阶段 10 怪潮后，10.5 位置为关底 Boss"梦境之主"
## 返回：按时间升序排列的事件字典数组 [{time, type, stage}, ...]
func _build_timeline() -> Array:
	var timeline: Array = []
	for stage in range(1, MAX_STAGE + 1):
		## 阶段 N 整点：怪潮事件
		var base_time: float = stage * STAGE_INTERVAL
		timeline.append({
			"time": base_time,
			"type": StageEventType.MOB_WAVE,
			"stage": stage,
		})
		## 阶段 N.5：阶段 10 之前是守门 Boss，阶段 10 之后是关底 Boss
		var boss_time: float = base_time + STAGE_INTERVAL * 0.5
		var boss_type: int = StageEventType.FINAL_BOSS if stage == MAX_STAGE else StageEventType.BOSS
		timeline.append({
			"time": boss_time,
			"type": boss_type,
			"stage": stage,
		})
	return timeline

## ========== 事件触发与串行推进 ==========

## 尝试触发下一个事件：时间已到 且 无活动事件（上一个已完结）才触发
## 串行语义：保证"怪潮消灭后再到阶段 N.5 出 Boss"的用户预期节奏
func _try_fire_next_event() -> void:
	## 游标越界：时间轴已全部走完（理论上 _run_completed 已置位，双保险）
	if _event_index >= _timeline.size():
		return
	## 串行门禁：上一个事件还没完结 → 挂起等待（时间已到的事件在完结后立即补触发）
	if _active_type != -1:
		return

	var ev: Dictionary = _timeline[_event_index]
	## 时间门禁：还没到点 → 等待
	if _elapsed < float(ev.time):
		return

	## 按类型分发触发（world 缺失时直接 return，游标不前进，下帧自动重试）
	match ev.type:
		StageEventType.MOB_WAVE:
			if _fire_mob_wave(ev):
				_active_type = StageEventType.MOB_WAVE
				_event_index += 1
		StageEventType.BOSS, StageEventType.FINAL_BOSS:
			if _fire_boss(ev):
				_active_type = ev.type
				_event_index += 1

## 更新活动事件状态：怪潮完结检测 + Boss 引用兜底清理
func _update_active_event(delta: float) -> void:
	## Boss 引用兜底：Boss 节点已被销毁（如场景切换）但信号未触发 → 清理引用放行
	if _current_boss != null and not is_instance_valid(_current_boss):
		_current_boss = null
		_active_type = -1
		_hide_boss_hud()

	## 怪潮完结检测：节流遍历快照，全灭或超时则放行
	if _active_type == StageEventType.MOB_WAVE:
		_wave_check_accum += delta
		if _wave_check_accum >= WAVE_CHECK_INTERVAL:
			_wave_check_accum = 0.0
			if _count_wave_alive() == 0 or _elapsed >= _wave_deadline:
				## 怪潮完结（全灭=玩家清场成功；超时=防止苟怪卡进度）
				_wave_enemies.clear()
				_active_type = -1

## 统计怪潮快照中仍存活的敌人数
## 存活判定：节点有效 且 未在销毁队列（敌人死亡走 call_deferred("queue_free")，需排除排队中的）
func _count_wave_alive() -> int:
	var alive: int = 0
	for e in _wave_enemies:
		if is_instance_valid(e) and not e.is_queued_for_deletion():
			alive += 1
	return alive

## ========== 怪潮事件（AOP 环绕通知：临时抬难度 +1，复用业务刷怪链路） ==========

## 触发怪潮事件：一波"等级+1"的怪物
## AOP 环绕通知实现：
##   before → DifficultyManager.level += 1（环绕抬升）
##   around → GameWorld._spawn_enemy() 业务刷怪（内部 apply_to_enemy_data 读取到的
##            就是 +1 后的等级，缩放逻辑完全复用业务代码，零重复实现）
##   after  → DifficultyManager.level -= 1（还原，对 HUD/信号零影响）
## 全程同步执行（无 await），不存在渲染帧看到中间态的可能
## 参数：ev - 事件字典 {time, type, stage}
## 返回：true=触发成功（游标可前进）；false=世界未就绪（下帧重试）
func _fire_mob_wave(ev: Dictionary) -> bool:
	var world: Node2D = _get_world()
	if world == null:
		return false
	var stage: int = int(ev.stage)

	## ---- before：临时抬升难度等级 ----
	## 封顶守卫：难度已达上限时不再抬升（否则会在满级瞬间越界到 11 级，破坏 10 级封顶约定）
	var level_boosted: bool = false
	if DifficultyManager.level < DifficultyManager.MAX_LEVEL:
		DifficultyManager.level += 1
		level_boosted = true

	## ---- around：复用业务刷怪链路 ----
	## 快照刷怪前 enemy 组（用于差集提取"这波怪"）
	var before: Dictionary = {}
	for e in get_tree().get_nodes_in_group("enemy"):
		before[e] = true
	## 波次规模：基础 6 只 + 每阶段 +2 只（阶段越高潮越猛）
	var spawn_count: int = 6 + stage * 2
	## 同屏上限保护（与业务波次 _on_wave_started 同款检查，防瞬时数量爆炸）
	var dynamic_max: int = DifficultyManager.get_max_enemies(world.max_enemies)
	for i in range(spawn_count):
		if world._enemy_count >= dynamic_max:
			break
		world._spawn_enemy()

	## ---- after：还原难度等级（仅还原本次真正抬升过的那一级） ----
	if level_boosted:
		DifficultyManager.level -= 1

	## ---- 后置：差集提取波次怪快照，启动完结追踪 ----
	_wave_enemies.clear()
	for e in get_tree().get_nodes_in_group("enemy"):
		if not before.has(e):
			_wave_enemies.append(e)
	_wave_deadline = _elapsed + WAVE_TIMEOUT
	_wave_check_accum = 0.0

	## ---- 切面展示层：字幕 + 进度标签 + 音效（业务零感知） ----
	_show_banner("—— 阶段 %d · 梦境怪潮 ——" % stage, Color(1.0, 0.9, 0.5), 2.2)
	_update_stage_label("阶段 %d/%d" % [stage, MAX_STAGE])
	if AudioManager:
		AudioManager.play("wave_start", 0.8)
	stage_event_fired.emit(StageEventType.MOB_WAVE, stage)
	print("[StageDirector] 阶段 %d 怪潮来袭：等级+1 × %d 只" % [stage, spawn_count])
	return true

## ========== Boss 事件（装饰模式：自建 Boss 实例 + 外挂血条） ==========

## 触发 Boss 事件：守门 Boss（阶段 N.5）或关底 Boss（阶段 10.5"梦境之主"）
## 参数：ev - 事件字典
## 返回：true=触发成功；false=世界未就绪（下帧重试）
func _fire_boss(ev: Dictionary) -> bool:
	var world: Node2D = _get_world()
	if world == null:
		return false
	var stage: int = int(ev.stage)
	var is_final: bool = (ev.type == StageEventType.FINAL_BOSS)

	## ---- 构建 Boss 数据（深拷贝副本，绝不污染共享资源——项目硬性约定） ----
	var boss_data: EnemyDataClass = _build_boss_data(world, stage, is_final)

	## ---- 实例化 Boss（复用敌人场景，装饰注入） ----
	var boss: CharacterBody2D = ENEMY_SCENE.instantiate()
	boss.enemy_data = boss_data
	## 组标记："enemy" 通用组（玩家子弹/特效阵营判定依赖）+ "boss" 切面标记
	boss.add_to_group("enemy")
	boss.add_to_group("boss")
	## 生成位置：玩家附近屏外环上随机点（Boss 直奔玩家，无需玩家寻找）
	boss.position = _pick_boss_spawn_position(world)
	## 挂载到 GameWorld（与业务敌人同容器，敌人子弹 get_parent().add_child 链路兼容）
	world.add_child(boss)
	## 物理插值开启后的传送必需：重置插值，避免 Boss 从原点滑向生成点（视觉 bug）
	if boss.has_method("reset_physics_interpolation"):
		boss.reset_physics_interpolation()

	## ---------- 直播增强：Boss登场时停+震屏 ----------
	## 时停 0.2 秒（Engine.time_scale = 0.0 → 帧数计数恢复，不受 time_scale 影响）
	_do_boss_entry_time_stop()
	## 震屏 0.4 秒（Camera2D offset 抖动，final_boss 强度加倍）
	_do_boss_entry_shake(world, is_final)

	## ---- 装饰 1：入场淡入（不缩放物理体——Godot4 不推荐缩放 CharacterBody2D） ----
	if "sprite" in boss and boss.sprite != null:
		boss.sprite.modulate.a = 0.0
		var tw: Tween = create_tween()
		tw.tween_property(boss.sprite, "modulate:a", 1.0, 0.5)

	## ---- 装饰 2：出场粒子（复用 TrailGhost 对象池，遵守性能约定） ----
	var boss_color: Color = boss_data.placeholder_color
	for i in range(8):
		var angle: float = (i / 8.0) * TAU
		var drift: Vector2 = Vector2(cos(angle), sin(angle)) * 90.0
		TrailGhostClass.spawn(world, boss.position, Color(boss_color.r, boss_color.g, boss_color.b, 0.9), 12.0, 0.6, 1.5, drift)

	## ---- 装饰 3：头顶血条（外挂子节点，随 Boss 销毁自动清理） ----
	_attach_boss_health_bar(boss)

	## ---- 装饰 4：屏幕 Boss 血条 + 名称（切面 UI 层） ----
	_show_boss_hud(boss_data.enemy_name, boss_data.max_health)
	## 受击信号驱动屏幕血条更新（事件驱动，无每帧轮询开销）
	boss.damaged.connect(_on_boss_damaged.bind(boss))

	## ---- 后置通知接线：Boss 死亡 → 阶段推进 / 掉落补路由 ----
	## Boss 不在 GameWorld._enemies 管理列表内（切面自建），因此：
	##   killed  → GameWorld 不会收到（列表管理无碍）；由切面监听推进进度
	##   drops_generated → GameWorld 也不会收到；由切面补路由到 _spawn_pickup
	_current_boss = boss
	boss.killed.connect(_on_boss_killed.bind(boss, is_final))
	boss.drops_generated.connect(_on_boss_drops.bind(world))

	## ---- 切面展示层：警告字幕 + 音效 ----
	if is_final:
		_show_banner("★ 关底 Boss · 梦境之主 降临 ★", Color(1.0, 0.75, 0.2), 3.0)
		_update_stage_label("阶段 %d.5/%d · 终局" % [stage, MAX_STAGE])
	else:
		_show_banner("★ 阶段 %d · 守门者降临 ★" % stage, Color(0.85, 0.3, 0.95), 2.5)
		_update_stage_label("阶段 %d.5/%d" % [stage, MAX_STAGE])
	if AudioManager:
		## 出场音效：difficulty_up 的下沉音（压迫感）+ wave_start 警报（双音叠加）
		AudioManager.play("difficulty_up", 0.9)
		AudioManager.play("wave_start", 0.7)
	stage_event_fired.emit(ev.type, stage)
	print("[StageDirector] %s 降临（阶段 %d）" % [boss_data.enemy_name, stage])
	return true

## 构建 Boss 数据副本（深拷贝，绝不触碰共享 .tres——项目硬性约定）
## 参数：world - 游戏世界（取精英数据作基底）、stage - 所属阶段、is_final - 是否关底 Boss
## 返回：配置完毕的 Boss 数据副本
func _build_boss_data(world: Node2D, stage: int, is_final: bool) -> EnemyDataClass:
	## 基底：GameWorld 的精英怪数据（_ready 已初始化，兜底 new 防御）
	var base_data: EnemyDataClass = null
	if "elite_enemy_data" in world and world.elite_enemy_data != null:
		base_data = world.elite_enemy_data
	## duplicate(true) 递归深拷贝子弹/掉落等子资源，修改副本不污染共享数据
	var boss_data: EnemyDataClass = base_data.duplicate(true) if base_data != null else EnemyDataClass.new()

	## ---- 身份标识 ----
	boss_data.enemy_id = "final_boss" if is_final else "stage_boss_%d" % stage
	boss_data.enemy_name = "梦境之主" if is_final else "阶段%d·守门者" % stage
	boss_data.is_elite = true          ## 复用业务精英发光链路（Enemy._create_elite_glow_effect）
	boss_data.elite_prefix = "★"

	## ---- 外观（程序占位，无美术依赖） ----
	boss_data.shape_type = "circle"    ## 圆形 = 体积感/压迫感
	boss_data.placeholder_color = Color(1.0, 0.78, 0.25, 1) if is_final else Color(0.8, 0.25, 0.9, 1)
	boss_data.placeholder_size = Vector2(96, 96) if is_final else Vector2(64, 64)

	## ---- 数值（基础值；守门 Boss 再经难度缩放，关底 Boss 按终局形态固定设计） ----
	if is_final:
		boss_data.max_health = 900
		boss_data.damage = 25
		boss_data.speed = 80.0
		boss_data.attack_range = 500.0
		boss_data.attack_cooldown = 1.2
	else:
		boss_data.max_health = 60 + stage * 45
		boss_data.damage = 15 + stage * 3
		boss_data.speed = 90.0
		boss_data.attack_range = 420.0
		boss_data.attack_cooldown = 1.6
	boss_data.wander_speed = 60.0
	boss_data.wander_interval = 2.5
	boss_data.detection_range = 1200.0  ## 全图索敌：Boss 不会丢失玩家

	## ---- 难度缩放（守门 Boss 按业务精英强度 0.6 温和缩放，与精英怪一致；
	##      关底 Boss 不缩放——时间点固定在终局，数值已按最终形态设计） ----
	if not is_final:
		DifficultyManager.apply_to_enemy_data(boss_data, true)

	## ---- 掉落配置（丰厚奖励，鼓励击败 Boss；副本上的修改天然安全） ----
	boss_data.drop_items.clear()
	## 大额梦境碎片（必掉，自动吸附）
	var frag: DropItemClass = DropItemClass.new()
	frag.item_id = "boss_fragment"
	frag.item_name = "Boss Dream Fragment"
	frag.item_type = DropItemClass.ItemType.DREAM_FRAGMENT
	frag.value = 200 if is_final else 30 + stage * 10
	frag.drop_chance = 1.0
	frag.is_rare = true
	frag.auto_adsorb = true
	boss_data.drop_items.append(frag)
	## 大血包（高概率，Boss 战后补给）
	var heal: DropItemClass = DropItemClass.new()
	heal.item_id = "boss_health"
	heal.item_name = "Large Health Pack"
	heal.item_type = DropItemClass.ItemType.HEALTH
	heal.value = 60 if is_final else 30
	heal.drop_chance = 0.8
	heal.is_rare = false
	heal.auto_adsorb = true
	boss_data.drop_items.append(heal)
	## 增益道具（关底必掉，守门 50%）
	var buff: DropItemClass = DropItemClass.new()
	buff.item_id = "boss_buff"
	buff.item_name = "Power Boost"
	buff.item_type = DropItemClass.ItemType.BUFF
	buff.value = 8 if is_final else 5
	buff.drop_chance = 1.0 if is_final else 0.5
	buff.is_rare = true
	buff.auto_adsorb = false
	boss_data.drop_items.append(buff)

	return boss_data

## 选取 Boss 生成位置：玩家周围环形随机点（BOSS_SPAWN_DISTANCE 距离）
## 参数：world - 游戏世界（读取玩家引用）
## 返回：全局坐标
func _pick_boss_spawn_position(world: Node2D) -> Vector2:
	var player: Node2D = null
	if "player" in world and world.player != null and is_instance_valid(world.player):
		player = world.player
	if player == null:
		## 玩家未就绪的兜底：竞技场中心（autoload 是纯 Node，需经 get_viewport() 取视口尺寸）
		return Vector2.ZERO
	var angle: float = randf() * TAU
	## 玩家周围环形随机点，再钳制进竞技场（预留120px墙内边距，Boss体积大避免贴墙卡模型）
	var ring_point: Vector2 = player.global_position \
			+ Vector2(cos(angle), sin(angle)) * BOSS_SPAWN_DISTANCE
	return ArenaConfigClass.clamp_inside(ring_point, 120.0)

## ========== Boss 事件回调（后置通知） ==========

## Boss 受击回调：驱动头顶血条与屏幕血条 + 濒死狂暴检测（直播增强）
## 参数：_amount - 伤害值（未用），boss - Boss 实例
func _on_boss_damaged(_amount: int, boss: Node) -> void:
	if not is_instance_valid(boss):
		return
	## 计算血量比例（max_health<=0 防御）
	var ratio: float = 1.0
	if boss.max_health > 0:
		ratio = clampf(float(boss.health) / float(boss.max_health), 0.0, 1.0)
	## 头顶血条：前景条宽度按比例收缩（子节点由 _attach_boss_health_bar 挂载）
	var bar: Node2D = boss.get_node_or_null("BossHpBar")
	if bar != null and bar.has_meta("fg_width"):
		var full_w: float = bar.get_meta("fg_width")
		var fg: ColorRect = bar.get_node_or_null("FG")
		if fg != null:
			fg.size.x = full_w * ratio
	## 屏幕血条：同比例更新
	if _boss_bar_fg != null:
		_boss_bar_fg.size.x = _boss_bar_fg.get_parent().get_meta("full_w") * ratio

	## ---------- 濒死狂暴检测（直播增强） ----------
	## HP 低于 20% 且还没狂暴过 → 触发濒死狂暴
	if not _boss_enraged and ratio <= BOSS_ENRAGE_THRESHOLD:
		_boss_enraged = true
		_do_boss_enrage(boss)

## Boss 死亡回调：阶段推进 / 通关结算
## 参数：boss - 死亡的 Boss，is_final - 是否关底 Boss
func _on_boss_killed(boss: Node, is_final: bool) -> void:
	## 补记击杀统计：Boss 不在 GameWorld._enemies 列表，业务的 add_kill 不会触发，切面补上
	RunStats.add_kill()
	## 爆炸音效强化（Enemy._die 已播 enemy_die，切面叠加爆炸声强调击杀反馈）
	if AudioManager:
		AudioManager.play("hit_explosion", 1.0)
	## 活动事件完结：放行下一阶段事件
	_current_boss = null
	_active_type = -1
	_hide_boss_hud()

	if is_final:
		## ---- 关底 Boss 已倒：无缝进入终极关卡（清场 + 停刷怪 + 生成终极 BOSS） ----
		_show_banner("★ 梦境之主已被击败 ★\n梦境深处传来更古老的回响……", Color(1.0, 0.85, 0.3), 3.0)
		if AudioManager:
			AudioManager.play("buff_pickup", 0.9)
			AudioManager.play("upgrade_pick", 0.9)
		_enter_ultimate_stage()
	else:
		_show_banner("守门者已被击败", Color(0.6, 1.0, 0.6), 1.5)
		print("[StageDirector] 守门 Boss 已被击败，下一阶段事件解锁")

## ========== 终极关卡（终局流程：清场 → 停刷怪 → 终极 BOSS） ==========

## 进入终极关卡：本局阶段流程的终点，之后只面对终极 BOSS「梦境根源」
## 触发时机：阶段 10.5「梦境之主」被击杀（难度 10 的收尾 Boss）
## 执行顺序（严格）：时间轴退役 → 清空全场敌人 → 停止常规刷怪 → 宣告 → 生成终极 BOSS
func _enter_ultimate_stage() -> void:
	var world: Node2D = _get_world()

	## ---- 1. 时间轴退役：不再触发任何阶段事件（进度交由终极 BOSS 战接管） ----
	_run_completed = true
	_active_type = -1
	_wave_enemies.clear()

	## ---- 2. 清空全场敌人（含不在业务管理列表内的实体，避免残留小怪干扰终局战） ----
	if world != null and world.has_method("clear_all"):
		world.call("clear_all")

	## ---- 3. 停止一切常规刷怪：终极关卡只面对终极 BOSS，玩家需专注躲技能 ----
	if world != null and "spawning_enabled" in world:
		world.spawning_enabled = false

	## ---- 4. 狂暴状态复位：上一个 Boss 的濒死狂暴标记不能带到终极 BOSS ----
	_boss_enraged = false

	## ---- 5. 切面展示层：终极关卡宣告 ----
	_update_stage_label("终极关卡")
	if AudioManager:
		AudioManager.play("difficulty_up", 1.0)
		AudioManager.play("wave_start", 0.8)
	ultimate_stage_started.emit()
	print("[StageDirector] 终极关卡开启：全场清空 + 常规刷怪已停止")

	## ---- 6. 生成终极 BOSS（world 缺失时静默跳过，避免空引用崩溃） ----
	if world != null:
		_spawn_ultimate_boss(world)

## 生成终极 BOSS「梦境根源」：复用敌人场景 + 装饰注入（与阶段 Boss 同一套外挂装饰）
## 说明：终极 BOSS 与阶段事件解耦——不推进事件游标、不参与难度缩放，数值为终局固定形态
## 参数：world - 游戏世界（Boss 挂载容器 / 掉落路由目标）
func _spawn_ultimate_boss(world: Node2D) -> void:
	## 构建数据副本（深拷贝，绝不污染共享 .tres——项目硬性约定）
	var boss_data: EnemyDataClass = _build_ultimate_boss_data(world)

	## ---- 实例化与挂载（与 _fire_boss 同款链路，保证物理/阵营行为一致） ----
	var boss: CharacterBody2D = ENEMY_SCENE.instantiate()
	boss.enemy_data = boss_data
	boss.add_to_group("enemy")
	boss.add_to_group("boss")
	boss.position = _pick_boss_spawn_position(world)
	world.add_child(boss)
	if boss.has_method("reset_physics_interpolation"):
		boss.reset_physics_interpolation()

	## ---- 体积配套：同步放大碰撞判定（Enemy.tscn 默认半径 16/15 是普通怪规格） ----
	## 说明：视觉体积由主题皮肤 target_size 决定（见 _build_ultimate_boss_data），
	##       碰撞判定无法随皮肤自动变化，必须在此显式覆写，否则巨型 BOSS 只有 30px 的受击范围
	_sync_ultimate_boss_body_size(boss)

	## ---- 登场演出：时停 0.2 秒 + 强震屏（终局规格，强度高于阶段 Boss） ----
	_do_boss_entry_time_stop()
	_do_boss_entry_shake(world, true)

	## ---- 装饰 1：入场淡入（时长拉长，强调压迫感） ----
	if "sprite" in boss and boss.sprite != null:
		boss.sprite.modulate.a = 0.0
		var tw: Tween = create_tween()
		tw.tween_property(boss.sprite, "modulate:a", 1.0, 0.8)

	## ---- 装饰 2：出场粒子（16 方向，数量与漂移距离均高于阶段 Boss） ----
	var boss_color: Color = boss_data.placeholder_color
	for i in range(16):
		var angle: float = (i / 16.0) * TAU
		var drift: Vector2 = Vector2(cos(angle), sin(angle)) * 160.0
		TrailGhostClass.spawn(world, boss.position, Color(boss_color.r, boss_color.g, boss_color.b, 0.9), 16.0, 0.8, 2.0, drift)

	## ---- 装饰 3/4：头顶血条 + 屏幕 Boss 血条（复用现有外挂装饰） ----
	_attach_boss_health_bar(boss)
	_show_boss_hud(boss_data.enemy_name, boss_data.max_health)
	boss.damaged.connect(_on_boss_damaged.bind(boss))

	## ---- 后置通知接线：终极 BOSS 死亡 = 本局通关 ----
	_current_boss = boss
	boss.killed.connect(_on_ultimate_boss_killed.bind(boss))
	boss.drops_generated.connect(_on_boss_drops.bind(world))

	## ---- 切面展示层 ----
	_show_banner("★ 梦境根源 · 降临 ★", Color(1.0, 0.3, 0.3), 3.5)
	print("[StageDirector] 终极 BOSS「%s」降临" % boss_data.enemy_name)

## 构建终极 BOSS 数据副本（深拷贝，绝不触碰共享 .tres）
## 参数：world - 游戏世界（取精英数据作基底）
## 返回：配置完毕的终极 BOSS 数据副本
func _build_ultimate_boss_data(world: Node2D) -> EnemyDataClass:
	## 基底：GameWorld 的精英怪数据（复用已配置的碰撞/技能等基础字段）
	var base_data: EnemyDataClass = null
	if "elite_enemy_data" in world and world.elite_enemy_data != null:
		base_data = world.elite_enemy_data
	var boss_data: EnemyDataClass = base_data.duplicate(true) if base_data != null else EnemyDataClass.new()

	## ---- 身份标识 ----
	boss_data.enemy_id = "ultimate_boss"
	boss_data.enemy_name = "梦境根源"
	boss_data.is_elite = true
	boss_data.elite_prefix = "★"

	## ---- 外观：体积为普通 Boss 的 5 倍 ----
	## 关键：视觉体积由主题皮肤 target_size 决定（enemy_id="ultimate_boss" → 主题里的巨型皮肤），
	##       placeholder_size 仅作血条定位等切面用途，必须与皮肤尺寸保持一致，否则血条悬空
	boss_data.shape_type = "circle"
	boss_data.placeholder_color = Color(1.0, 0.25, 0.3, 1)
	boss_data.placeholder_size = Vector2(150, 150)

	## ---- 数值：血量/伤害大幅高于阶段 Boss（远高于关底 Boss 的 900 血/25 伤） ----
	boss_data.max_health = 5000
	boss_data.damage = 45
	boss_data.speed = 55.0            ## 移速低于玩家（180），保证可被走位拉扯
	boss_data.wander_speed = 40.0
	boss_data.wander_interval = 2.0
	boss_data.attack_range = 700.0    ## 远程普攻覆盖大半屏
	boss_data.attack_cooldown = 0.9   ## 普攻间隔短于阶段 Boss（1.6），压迫感更强
	boss_data.detection_range = 3000.0  ## 全图索敌，不会丢失玩家

	## ---- 普攻强化：比关底 Boss（25 伤 / 300 速）小幅提升 ----
	## 说明：Enemy._perform_attack 走 enemy_data.get_bullet_data()；不配置时会兜底用 damage 作伤害，
	##       在此显式配置以获得更高的伤害与弹速（飞行速度 300 → 400）
	## 形态留空：子弹走 _body_color 染色，颜色自动跟随主题皮肤主色
	var boss_bullet: BulletDataClass = BulletDataClass.new()
	boss_bullet.damage = 35
	boss_bullet.speed = 400.0
	boss_data.bullet_data = boss_bullet

	## ---- 技能：三技能并发（天女散花 / 飞机轰炸 / 追踪导弹） ----
	## 装配方式：填 monster_skills（多技能并发数组），monster_skill 留 null
	##           → Enemy._init_skill_slots() 为每个技能建立独立触发槽，触发即释放、互不排队
	## 注意：monster_skills 不会被 EnemyData.apply_to_enemy() 同步覆盖，此处副本赋值即最终生效值
	boss_data.skill_damage = 18    ## 散花单颗子弹伤害（散花技能取 enemy.skill_damage）
	boss_data.skill_cooldown = 8.0 ## 单技能路径未启用（monster_skill 为空），保留合理默认值
	boss_data.monster_skills = _build_ultimate_skills()

	return boss_data

## 构建终极 BOSS 的三技能配置（三技能并发的手感来源）
## 返回：三个技能资源组成的数组（填入 EnemyData.monster_skills）
## 设计意图：
##   1. 需求要求"三个技能不是依次释放，而是各有内置触发点、触发即释放" →
##      三个技能的 trigger_interval 各不相同（8/15/25 秒），Enemy._get_slot_interval
##      会在此基础上再叠加 ±30% 随机抖动 → 三条节奏逐渐错开、偶发重合，
##      形成"小概率同时存在 2 个、极小概率同时存在 3 个"的效果
##   2. 技能节奏参数（环数/波数/导弹数量等）取 MonsterSkill 资源的默认值，
##      仅在需要单独平衡时在此显式覆盖
func _build_ultimate_skills() -> Array[Resource]:
	var skills: Array[Resource] = []

	## ---- 技能1：天女散花（以 BOSS 为圆心的多环不规则弹幕，只能靠走位穿缝） ----
	var bloom: MonsterSkillClass = MonsterSkillClass.new()
	bloom.skill_id = "ultimate_sky_bloom"
	bloom.display_name = "天女散花"
	bloom.skill_type = MonsterSkillClass.SkillType.SKY_BLOOM
	bloom.effect_color = Color(1.0, 0.35, 0.75, 1.0)
	bloom.trigger_interval = 8.0      ## 三技能中最频繁：持续压缩走位空间
	bloom.projectile_speed = 240.0    ## 略低于普通技能弹（250），弹幕密集时更易穿缝
	skills.append(bloom)

	## ---- 技能2：飞机轰炸（全屏随机伤害圈，预警 5 秒后爆炸，共 5 波 × 12 落点） ----
	var bomb: MonsterSkillClass = MonsterSkillClass.new()
	bomb.skill_id = "ultimate_air_bombardment"
	bomb.display_name = "飞机轰炸"
	bomb.skill_type = MonsterSkillClass.SkillType.AIR_BOMBARDMENT
	bomb.effect_color = Color(1.0, 0.55, 0.2, 1.0)
	bomb.trigger_interval = 25.0      ## 单次持续约 17 秒，触发最稀疏（避免全屏长期被覆盖）
	skills.append(bomb)

	## ---- 技能3：追踪导弹（屏幕外飞入、持续锁定、需打爆才解除） ----
	var missile: MonsterSkillClass = MonsterSkillClass.new()
	missile.skill_id = "ultimate_tracking_missile"
	missile.display_name = "追踪导弹"
	missile.skill_type = MonsterSkillClass.SkillType.TRACKING_MISSILE
	missile.effect_color = Color(0.65, 0.85, 1.0, 1.0)
	missile.trigger_interval = 15.0   ## 触发频率居中
	missile.missile_speed = 120.0     ## 硬约束：必须小于玩家移速(180)，玩家可靠走位甩开而非被必杀
	skills.append(missile)

	return skills

## 同步终极 BOSS 的碰撞判定尺寸（放大到与巨型体型匹配）
## 参数：boss - 终极 BOSS 实例
## 说明：Enemy.tscn 的 CollisionShape2D / Hitbox 默认半径 16/15 是普通怪规格，
##       不改则巨型 BOSS 只有 30px 见方的受击范围（玩家子弹穿体而过却不掉血）
func _sync_ultimate_boss_body_size(boss: CharacterBody2D) -> void:
	_override_circle_radius(boss, "CollisionShape2D", ULTIMATE_BOSS_COLLISION_RADIUS)
	_override_circle_radius(boss, "Hitbox/CollisionShape2D", ULTIMATE_BOSS_HITBOX_RADIUS)

## 覆写指定碰撞节点的圆形半径（副本化形状，避免污染共享 SubResource）
## 参数：host - 宿主节点、path - 碰撞节点相对路径、radius - 新的圆形半径
## 说明：Enemy.tscn 内所有敌人实例共享同一个 CircleShape2D 资源，
##       直接改 shape.radius 会让全场敌人（含后续生成的）一起变大，必须 duplicate 后替换
func _override_circle_radius(host: Node, path: String, radius: float) -> void:
	var shape_node: CollisionShape2D = host.get_node_or_null(path) as CollisionShape2D
	if shape_node == null:
		return
	var circle: CircleShape2D = shape_node.shape as CircleShape2D
	if circle == null:
		return
	var own_shape: CircleShape2D = circle.duplicate() as CircleShape2D
	own_shape.radius = radius
	shape_node.shape = own_shape

## 终极 BOSS 死亡回调：本局通关（时间轴已退役，此处只做终局收尾）
## 参数：boss - 死亡的终极 BOSS（未直接使用，保留实例便于扩展）
func _on_ultimate_boss_killed(_boss: Node) -> void:
	RunStats.add_kill()
	if AudioManager:
		AudioManager.play("hit_explosion", 1.0)
	_current_boss = null
	_active_type = -1
	_hide_boss_hud()
	_show_banner("★ 梦境根源已被击碎 ★\n梦境终结 · 恭喜通关", Color(1.0, 0.9, 0.4), 6.0)
	_update_stage_label("通关")
	if AudioManager:
		AudioManager.play("buff_pickup", 1.0)
		AudioManager.play("upgrade_pick", 1.0)
	run_completed.emit()
	print("[StageDirector] 终极 BOSS 已被击败：本局通关")

## Boss 掉落补路由：Boss 不在业务管理列表，drops_generated 信号由切面转接
## 参数：position - 掉落位置，drops - 掉落物数组，world - 游戏世界
func _on_boss_drops(position: Vector2, drops: Array, world: Node2D) -> void:
	if not is_instance_valid(world):
		return
	## 复用业务的拾取物生成入口；deferred 调用避免物理回调链中修改场景树（项目教训）
	for drop_item in drops:
		if drop_item == null:
			continue
		world.call_deferred("_spawn_pickup", position, drop_item)

## ========== Boss 头顶血条（装饰子节点） ==========

## 给 Boss 挂载头顶血条（外挂装饰，不改 Enemy.gd；随 Boss 销毁自动清理）
## 结构：BossHpBar(Node2D, z_index=50) → BG(ColorRect 深色底) / FG(ColorRect 红色血量)
func _attach_boss_health_bar(boss: CharacterBody2D) -> void:
	## 血条尺寸随 Boss 体型自适应
	var bar_w: float = boss.enemy_data.placeholder_size.x + 10.0
	var bar_h: float = 8.0
	var bar_y: float = -boss.enemy_data.placeholder_size.y * 0.5 - 16.0

	var bar_root: Node2D = Node2D.new()
	bar_root.name = "BossHpBar"
	bar_root.z_index = 50  ## 保证绘制在 Boss 精灵之上
	bar_root.position = Vector2(-bar_w * 0.5, bar_y)
	## 存储满宽供受击回调计算比例
	bar_root.set_meta("fg_width", bar_w)

	## 背景条（深灰底，mouse_filter=IGNORE 遵守 UI 约定）
	var bg: ColorRect = ColorRect.new()
	bg.name = "BG"
	bg.size = Vector2(bar_w, bar_h)
	bg.color = Color(0.1, 0.1, 0.1, 0.75)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.z_index = 0
	bar_root.add_child(bg)

	## 前景条（红色血量，从满血开始）
	var fg: ColorRect = ColorRect.new()
	fg.name = "FG"
	fg.size = Vector2(bar_w, bar_h)
	fg.color = Color(0.9, 0.2, 0.25, 1.0)
	fg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fg.z_index = 1
	bar_root.add_child(fg)

	boss.add_child(bar_root)

## ========== 切面 UI 层（阶段字幕 / Boss 血条 / 进度标签） ==========

## 搭建切面专属 CanvasLayer（一次性构建；不改 GameHUD —— 无痕插入的关键）
func _build_hud_layer() -> void:
	_hud_layer = CanvasLayer.new()
	_hud_layer.name = "StageDirectorHud"
	_hud_layer.layer = 10  ## 高于游戏世界与业务 HUD，保证切面提示最显眼
	add_child(_hud_layer)

	## ---- 左上角进度标签 ----
	_stage_label = Label.new()
	_stage_label.name = "StageLabel"
	_stage_label.position = Vector2(24, 18)
	_stage_label.add_theme_font_size_override("font_size", 26)
	_stage_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
	_stage_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_stage_label.add_theme_constant_override("outline_size", 6)
	_stage_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage_label.text = ""
	_hud_layer.add_child(_stage_label)

	## ---- 居中大字幕（阶段开始/Boss 来袭/通关横幅） ----
	_banner_label = Label.new()
	_banner_label.name = "Banner"
	## 全宽水平居中，垂直位于屏幕上 1/3 处（anchor 布局，自适应分辨率）
	_banner_label.anchor_left = 0.0
	_banner_label.anchor_right = 1.0
	_banner_label.anchor_top = 0.16
	_banner_label.anchor_bottom = 0.32
	_banner_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_banner_label.add_theme_font_size_override("font_size", 44)
	_banner_label.add_theme_color_override("font_color", Color.WHITE)
	_banner_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_banner_label.add_theme_constant_override("outline_size", 10)
	_banner_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner_label.modulate.a = 0.0  ## 初始透明，字幕触发时淡入
	_hud_layer.add_child(_banner_label)

	## ---- 顶部居中 Boss 血条组（名称 + 背景条 + 前景条） ----
	_boss_box = Control.new()
	_boss_box.name = "BossBox"
	_boss_box.anchor_left = 0.5
	_boss_box.anchor_right = 0.5
	_boss_box.offset_left = -300.0
	_boss_box.offset_right = 300.0
	_boss_box.offset_top = 20.0
	_boss_box.offset_bottom = 72.0
	_boss_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	## 存储血条满宽供受击回调计算
	_boss_box.set_meta("full_w", 560.0)
	_hud_layer.add_child(_boss_box)

	## Boss 名称
	_boss_name_label = Label.new()
	_boss_name_label.name = "BossName"
	_boss_name_label.anchor_right = 1.0
	_boss_name_label.offset_bottom = 28.0
	_boss_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_boss_name_label.add_theme_font_size_override("font_size", 24)
	_boss_name_label.add_theme_color_override("font_color", Color(1, 0.5, 0.5))
	_boss_name_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_boss_name_label.add_theme_constant_override("outline_size", 6)
	_boss_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_boss_box.add_child(_boss_name_label)

	## 血条背景（全宽 560 x 14，名称下方）
	_boss_bar_bg = ColorRect.new()
	_boss_bar_bg.name = "BarBG"
	_boss_bar_bg.anchor_left = 0.0
	_boss_bar_bg.anchor_right = 1.0
	_boss_bar_bg.offset_top = 36.0
	_boss_bar_bg.offset_bottom = 50.0
	_boss_bar_bg.color = Color(0.1, 0.1, 0.1, 0.8)
	_boss_bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_boss_box.add_child(_boss_bar_bg)

	## 血条前景（红色血量，满血开始）
	_boss_bar_fg = ColorRect.new()
	_boss_bar_fg.name = "BarFG"
	_boss_bar_fg.position = Vector2(0, 36.0)
	_boss_bar_fg.size = Vector2(560.0, 14.0)
	_boss_bar_fg.color = Color(0.85, 0.15, 0.2, 1.0)
	_boss_bar_fg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_boss_box.add_child(_boss_bar_fg)

	## 初始全部隐藏（游戏未开始/无事件时切面 UI 不可见）
	_boss_box.visible = false

## 显示居中大字幕：淡入 → 停留 → 淡出（旧动画 kill 防冲突）
## 参数：text - 字幕文本，color - 字色，duration - 停留时长（秒）
func _show_banner(text: String, color: Color, duration: float) -> void:
	## 终止上一次字幕动画，避免两次字幕的 tween 互相打架
	if _banner_tween != null and _banner_tween.is_valid():
		_banner_tween.kill()
	_banner_label.text = text
	_banner_label.add_theme_color_override("font_color", color)
	_banner_tween = create_tween()
	_banner_tween.tween_property(_banner_label, "modulate:a", 1.0, 0.3)
	_banner_tween.tween_interval(duration)
	_banner_tween.tween_property(_banner_label, "modulate:a", 0.0, 0.6)

## 更新左上角进度标签文本
func _update_stage_label(text: String) -> void:
	_stage_label.text = text

## 显示屏幕 Boss 血条组
## 参数：boss_name - Boss 名称，max_health - 满血值（用于重置前景条）
func _show_boss_hud(boss_name: String, max_health: int) -> void:
	_boss_name_label.text = boss_name
	_boss_bar_fg.size.x = float(_boss_box.get_meta("full_w")) if max_health > 0 else 0.0
	_boss_box.visible = true

## 隐藏屏幕 Boss 血条组
func _hide_boss_hud() -> void:
	_boss_box.visible = false

## ========== 每局重置（前置通知） ==========

## 响应 GameManager.game_started：清空切面状态，重建时间轴
## 覆盖所有重开路径（R 键重开/菜单重开/死亡重开）——业务如何重开与本切面无关
func _on_game_started() -> void:
	_elapsed = 0.0
	_timeline = _build_timeline()
	_event_index = 0
	_run_completed = false
	_active_type = -1
	_wave_enemies.clear()
	_wave_deadline = 0.0
	_wave_check_accum = 0.0
	_current_boss = null
	_boss_enraged = false  ## 重置濒死狂暴状态（新局从满血开始）
	_world_cache = null  ## 场景可能已重建，强制重查 GameWorld
	## 切面 UI 复位
	_hide_boss_hud()
	_stage_label.text = ""
	## 字幕立即隐藏（kill 动画 + 透明）
	if _banner_tween != null and _banner_tween.is_valid():
		_banner_tween.kill()
	_banner_label.modulate.a = 0.0
	print("[StageDirector] 进度时间轴已重置：%d 个阶段事件待触发" % _timeline.size())

## ========== 工具方法 ==========

## 懒查找并缓存 GameWorld 引用（切面与业务解耦：不依赖场景结构的具体路径）
## 查找策略：current_scene 下名为 "GameWorld" 的节点 + has_method 特征校验（切点匹配）
func _get_world() -> Node2D:
	if _world_cache != null and is_instance_valid(_world_cache):
		return _world_cache
	_world_cache = null
	var scene: Node = get_tree().current_scene
	if scene == null:
		return null
	var gw: Node = scene.get_node_or_null("GameWorld")
	if gw != null and gw.has_method("_spawn_enemy"):
		_world_cache = gw
	return _world_cache

## ========== 直播增强：Boss登场特效 ==========

## Boss登场时停效果：Engine.time_scale = 0.0 持续约 12 帧（≈0.2秒@60fps）
## 用帧计数恢复（time_scale=0 会让 Timer 失效，但帧循环本身不受影响）
func _do_boss_entry_time_stop() -> void:
	_time_stop_remaining = BOSS_ENTRY_TIME_STOP_FRAMES
	_time_stop_callback = _on_boss_entry_time_stop_tick
	Engine.time_scale = 0.0
	get_tree().process_frame.connect(_time_stop_callback)

## Boss登场时停帧回调（每帧减1，到0时恢复 time_scale=1.0）
func _on_boss_entry_time_stop_tick() -> void:
	_time_stop_remaining -= 1
	if _time_stop_remaining <= 0:
		Engine.time_scale = 1.0
		get_tree().process_frame.disconnect(_time_stop_callback)

## Boss登场震屏效果：Camera2D offset 抖动（关底Boss强度加倍）
## 参数：world - 游戏世界（用于取 Camera2D），is_final - 是否关底Boss
func _do_boss_entry_shake(world: Node2D, is_final: bool) -> void:
	var cam: Camera2D = world.get_viewport().get_camera_2d()
	if cam == null:
		return

	var original_offset: Vector2 = cam.offset
	var duration: float = 0.4
	## 关底Boss震屏强度加倍
	var intensity: float = 6.0 if is_final else 3.0

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

## Boss濒死狂暴：HP<20%时攻速+50% + 屏幕红边闪烁 + 专属音效
## 设计意图：让Boss在即将死亡时给玩家最后一击的紧张感，观众也跟着屏息
## 参数：boss - 濒死的Boss实例
func _do_boss_enrage(boss: Node) -> void:
	## 1. 攻速提升50%（减小攻击冷却 + 提升移动速度）
	if boss.has_method("set_attack_cooldown"):
		boss.set_attack_cooldown(boss.attack_cooldown * 0.66)
	else:
		## 没有setter时直接修改属性
		if "attack_cooldown" in boss:
			boss.attack_cooldown *= 0.66
		if "speed" in boss:
			boss.speed *= 1.2

	## 2. 屏幕红边闪烁（用 CanvasLayer + ColorRect 构建四条边）
	var border_thickness: float = 16.0
	var cam: Camera2D = null
	if get_tree().current_scene != null:
		cam = get_tree().current_scene.get_viewport().get_camera_2d()
	if cam != null:
		var layer: CanvasLayer = CanvasLayer.new()
		layer.name = "BossEnrageBorder"
		layer.layer = 100  ## 顶层显示
		get_tree().current_scene.add_child(layer)

		## 四条边：anchor配置(左/右/上/下) + offset配置(左/右/上/下)
		## 上：anchor(0,1,1,1) offset(0,0,0,-border) → 位于顶部，高度=border
		## 下：anchor(0,1,1,1) offset(0,0,-border,0) → 位于底部，高度=border
		## 左：anchor(0,0,0,1) offset(0,border,0,-border) → 左侧，宽=border
		## 右：anchor(1,0,1,1) offset(-border,border,0,-border) → 右侧，宽=border
		var rect_configs: Array[Dictionary] = [
			{"anchor_l": 0.0, "anchor_r": 1.0, "anchor_t": 0.0, "anchor_b": 0.0,
			 "offset_l": 0.0, "offset_r": 0.0, "offset_t": 0.0, "offset_b": border_thickness},       ## 上
			{"anchor_l": 0.0, "anchor_r": 1.0, "anchor_t": 1.0, "anchor_b": 1.0,
			 "offset_l": 0.0, "offset_r": 0.0, "offset_t": -border_thickness, "offset_b": 0.0},     ## 下
			{"anchor_l": 0.0, "anchor_r": 0.0, "anchor_t": 0.0, "anchor_b": 1.0,
			 "offset_l": 0.0, "offset_r": border_thickness, "offset_t": 0.0, "offset_b": 0.0},      ## 左
			{"anchor_l": 1.0, "anchor_r": 1.0, "anchor_t": 0.0, "anchor_b": 1.0,
			 "offset_l": -border_thickness, "offset_r": 0.0, "offset_t": 0.0, "offset_b": 0.0},     ## 右
		]

		for cfg in rect_configs:
			var rect: ColorRect = ColorRect.new()
			rect.color = Color(1.0, 0.15, 0.15, 0.0)
			rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
			rect.anchor_left = cfg["anchor_l"]
			rect.anchor_right = cfg["anchor_r"]
			rect.anchor_top = cfg["anchor_t"]
			rect.anchor_bottom = cfg["anchor_b"]
			rect.offset_left = cfg["offset_l"]
			rect.offset_right = cfg["offset_r"]
			rect.offset_top = cfg["offset_t"]
			rect.offset_bottom = cfg["offset_b"]
			layer.add_child(rect)

		## 红边闪烁动画：连续闪烁3次后淡出销毁
		var tw: Tween = layer.create_tween()
		tw.set_trans(Tween.TRANS_SINE)
		for i in range(3):
			tw.tween_property(layer, "modulate:a", 0.8, 0.1)
			tw.tween_property(layer, "modulate:a", 0.0, 0.15)
		tw.tween_interval(0.3)
		tw.tween_callback(layer.queue_free)

	## 3. 狂暴音效 + 屏幕字幕
	if AudioManager:
		AudioManager.play("difficulty_up", 1.1)
	var boss_name: String = boss.enemy_data.enemy_name if "enemy_data" in boss else "Boss"
	_show_banner("⚠ %s 狂暴了！" % boss_name, Color(1.0, 0.3, 0.3), 1.5)
