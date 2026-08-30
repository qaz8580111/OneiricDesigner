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
## 进度模型（总进度把控到阶段 10）：
##   阶段 N 整点（N*120 秒）  → 怪潮事件：一波"等级+1"的怪物
##   阶段 N.5（N*120+60 秒） → 阶段 N 守门 Boss（阶段 10.5 为关底 Boss"梦境之主"）
##   事件严格串行：上一个事件完结（怪潮全灭或超时兜底 / Boss 被击杀）后，才触发下一个已到点的事件
##   击杀关底 Boss → 通关横幅 → 无尽模式（游戏照常继续，但不再触发任何阶段事件）
## 数据流：本类自计时 → 时间轴事件表逐个触发 → 怪潮走业务刷怪链路 / Boss 由切面自建
##         → Boss 死亡信号回调 → 推进事件索引 → …… → 终局通关
extends Node

## ========== 预加载资源（避免运行时加载延迟） ==========

## 敌人场景：Boss 复用普通敌人场景（装饰模式，不改 Enemy.gd 源码）
const ENEMY_SCENE: PackedScene = preload("res://scenes/gameplay/Enemy.tscn")

## 敌人数据资源类：Boss 数据副本的类型（duplicate 后注入 Enemy）
const EnemyDataClass = preload("res://scripts/resources/enemy/EnemyData.gd")

## 掉落物数据资源类：配置 Boss 丰厚掉落
const DropItemClass = preload("res://scripts/resources/enemy/DropItem.gd")

## 残影/粒子节点类（对象池管理）：Boss 出场特效复用，遵守性能约定
const TrailGhostClass = preload("res://scripts/entities/TrailGhost.gd")

## ========== 调参常量（阶段曲线的核心配置，集中管理便于平衡调整） ==========

## 每个阶段的时长（秒）：阶段 N 事件在 N*120 秒，阶段 N.5 在 N*120+60 秒
## 即：120s 阶段1怪潮 → 180s 阶段1Boss → 240s 阶段2怪潮 → 300s 阶段2Boss → ……
const STAGE_INTERVAL: float = 120.0

## 总进度上限：把控到阶段 10（阶段 10.5 为关底 Boss）
const MAX_STAGE: int = 10

## 怪潮完结超时（秒）：玩家长时间不清怪时自动放行下一事件，防止进度被"苟"卡死
const WAVE_TIMEOUT: float = 45.0

## Boss 生成距离（与玩家的距离，像素）：屏幕外附近，Boss 直奔玩家而来
const BOSS_SPAWN_DISTANCE: float = 700.0

## 波次怪存活检查节流（秒）：每 0.5 秒查一次快照存活数，避免每帧遍历
const WAVE_CHECK_INTERVAL: float = 0.5

## ========== 阶段事件类型枚举 ==========

enum StageEventType {
	MOB_WAVE,    ## 怪潮事件：一波"等级+1"的怪物
	BOSS,        ## 守门 Boss 事件：阶段 N.5 出现的阶段 Boss
	FINAL_BOSS   ## 关底 Boss 事件：阶段 10.5 出现的"梦境之主"
}

## ========== 信号定义（供未来扩展使用，当前切面内部消费） ==========

## 阶段事件触发信号：参数为事件类型与所属阶段
signal stage_event_fired(event_type: int, stage: int)

## 通关信号：关底 Boss 被击杀时发出（进入无尽模式）
signal run_completed

## ========== 运行时状态（每局由 game_started 重置） ==========

## 本局已进行的游戏时间（秒），仅游戏进行中累计（与 DifficultyManager 同拍冻结）
var _elapsed: float = 0.0

## 本局事件时间轴（_build_timeline 生成的事件字典数组，按时间升序）
var _timeline: Array = []

## 下一个待触发的事件索引（时间轴游标：触发成功才前进）
var _event_index: int = 0

## 是否已通关（无尽模式标志：true 后不再触发任何阶段事件）
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
	## 门禁 2：已通关进入无尽模式 → 时间轴退役，游戏完全交还业务系统
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
## 时间轴模型：阶段 N 怪潮在 N*120 秒 → 阶段 N 守门 Boss 在 N*120+60 秒 → ……
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
	DifficultyManager.level += 1

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

	## ---- after：还原难度等级 ----
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
		## 玩家未就绪的兜底：屏幕中心（autoload 是纯 Node，需经 get_viewport() 取视口尺寸）
		return get_viewport().get_visible_rect().size * 0.5
	var angle: float = randf() * TAU
	return player.global_position + Vector2(cos(angle), sin(angle)) * BOSS_SPAWN_DISTANCE

## ========== Boss 事件回调（后置通知） ==========

## Boss 受击回调：驱动头顶血条与屏幕血条（事件驱动，无每帧轮询）
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
		## ---- 通关：进入无尽模式 ----
		_run_completed = true
		_show_banner("★ 梦境之主已被击败 ★\n进入无尽模式 · 梦境永不完结", Color(1.0, 0.85, 0.3), 5.0)
		_update_stage_label("无尽模式")
		if AudioManager:
			AudioManager.play("buff_pickup", 0.9)
			AudioManager.play("upgrade_pick", 0.9)
		run_completed.emit()
		print("[StageDirector] 通关！进入无尽模式，阶段事件全部退役")
	else:
		_show_banner("守门者已被击败", Color(0.6, 1.0, 0.6), 1.5)
		print("[StageDirector] 守门 Boss 已被击败，下一阶段事件解锁")

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
