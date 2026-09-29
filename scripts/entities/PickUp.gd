## PickUp.gd - 拾取物核心脚本
## 职责：管理道具拾取逻辑，区分自动吸附和手动拾取两种模式
## 继承：Area2D（Godot 4的2D区域节点，用于碰撞检测）
## 节点结构：PickUp(Area2D) → Sprite2D(外观) + CollisionShape2D(贴身拾取判定) + MagnetArea(子Area2D, 大范围磁吸/提示检测)
## 系统交互：
##   - 组判定：所有回调用 is_in_group("player") 过滤（零数组分配）
##   - 信号：body_entered(自动吸附型触碰即拾取)、MagnetArea.body_entered/exited(手动型显示/隐藏拾取提示)
##   - 生成：由 GameWorld._spawn_pickup 实例化并 set_drop_item 注入数据；
##           手动拾取由 GameWorld._handle_manual_pickup 轮询交互键(E)后调用 pickup()
## 碰撞层：主区域 layer=8(物品层)/mask=1(检测玩家层)；MagnetArea layer=0/mask=1（纯检测，自身不参与碰撞）
## 双层区域设计意图：主碰撞体小(需贴近才触发)、MagnetArea大(提前感知玩家)——
##   自动吸附道具在大区域内被"磁吸"飞向玩家，手动道具在大区域内高亮提示可拾取
extends Area2D

## ========== 预加载资源（避免运行时加载延迟） ==========

## 掉落道具数据资源类，用于配置道具属性和效果
const DropItemClass = preload("res://scripts/resources/enemy/DropItem.gd")

## 图标加载库（掉落物统一按 item_id 经 DROP_ICON_MAP 加载图标贴图，含护盾掉落）
const IconLibraryLib = preload("res://scripts/ui/IconLibrary.gd")

## ========== 静态纹理缓存（性能优化） ==========
## 设计意图：每次掉落都创建Image+ImageTexture有分配和上传开销，
##           掉落物颜色/尺寸组合有限，用static缓存按"颜色|尺寸"复用纹理
static var _texture_cache: Dictionary = {}

## 图标缩小纹理缓存：命名空间:id|尺寸 → 按道具尺寸预缩小的 ImageTexture
## 命名空间区分来源（shield:护盾装备 / drop:消耗品），同类掉落物共享同一份缩小纹理
## 设计意图：图标原图可能远大于掉落物显示尺寸，加载后立即缩小一次并按键缓存，
##           多个同类掉落物共享；且不动 sprite.scale（脉冲动画按scale=1基线做绝对值tween）
static var _icon_texture_cache: Dictionary = {}

## ========== 成员变量（运行时数据） ==========

## 当前拾取物的道具数据
var drop_item: DropItemClass = null

## ========== 导出变量（编辑器可配置） ==========

## 自动吸附速度（像素/秒），道具飞向玩家的速度
@export var adsorb_speed: float = 200.0

## 吸附范围（像素），玩家进入此范围后道具开始吸附或显示拾取提示
@export var adsorb_radius: float = 100.0

## 存活寿命（秒），超过后自动消失
## 性能修复核心（渐进卡顿根因）：旧实现掉落物永不回收——每次击杀都掉落道具，
## 长时间游玩后数百个拾取物常驻场景，每个含2个Area2D物理碰撞器（主碰撞体+100px磁吸区）
## +1个无限循环Tween动画+每帧_physics_process，物理broadphase与逐帧动画负担
## 随击杀数线性膨胀 → 帧率逐步下滑 → 物理步进跟不上60Hz时引擎牺牲游戏速度换对齐
## （"游戏像被放慢"的直接来源），CPU饱和同时拖累音频线程造成声音卡顿；
## 加入寿命回收后同屏拾取物数量有稳态上限（约掉落速率×寿命），不再无限增长
@export var lifetime: float = 25.0

## 消失前闪烁警告时长（秒）：最后这段时间闪烁提示玩家"再不捡就没了"
## （roguelike掉落物的标准做法——有限寿命+临期视觉警告，兼顾性能与拾取体验）
const BLINK_WINDOW: float = 3.0

## 图标在游戏世界中的统一显示尺寸（像素，正方形边长）
## 设计意图：美术图标源图仅24px且主体只占画布约35%~65%（四周透明边距），
##           若按类型色块尺寸16/20/22渲染，视觉主体只有8~14px，远小于原实心色块；
##           统一32px显示（主体等效约12~21px），既补偿透明边距又不超过玩家角色(40px)，
##           所有掉落物视觉大小一致、清晰可辨；脉冲动画仍以scale=1为基线，不受影响
const ICON_WORLD_SIZE: int = 32

## ========== 内部状态变量 ==========

## 是否正在被拾取（防止重复拾取）
var _is_picking: bool = false

## 玩家引用，用于自动吸附时追踪玩家位置
var _player: CharacterBody2D = null

## 原始颜色（用于恢复手动拾取提示状态）
var _original_color: Color = Color.WHITE

## 已存活时间（秒），每物理帧累计，达到lifetime后触发回收
var _life_timer: float = 0.0

## ========== 节点引用（使用 @onready 延迟初始化） ==========

## 拾取物精灵节点，用于显示道具外观
@onready var sprite: Sprite2D = $Sprite2D

## 磁铁区域节点（大范围检测），用于检测玩家进入/离开吸附范围
@onready var magnet_area: Area2D = $MagnetArea

## ========== 生命周期方法 ==========

## _ready() - 节点进入场景树时调用一次，用于初始化
func _ready() -> void:
	## 连接碰撞检测信号：当玩家接触主碰撞体时触发（自动吸附类型直接拾取）
	body_entered.connect(_on_body_entered)
	## 连接磁铁区域信号：当玩家进入吸附范围时触发（手动拾取类型显示提示）
	magnet_area.body_entered.connect(_on_magnet_body_entered)
	## 连接磁铁区域信号：当玩家离开吸附范围时触发（隐藏拾取提示）
	magnet_area.body_exited.connect(_on_magnet_body_exited)
	## 查找玩家引用
	_find_player()
	
	## 添加道具脉冲动画（让道具更明显）
	_start_pulse_animation()

## ========== 玩家查找方法 ==========

## 查找玩家引用（从"player"组查找）
func _find_player() -> void:
	var players: Array[Node] = get_tree().get_nodes_in_group("player")
	if players.size() > 0:
		_player = players[0] as CharacterBody2D

## ========== 物理帧更新方法 ==========

## _physics_process() - 每物理帧调用一次（默认60次/秒），用于处理拾取交互
func _physics_process(delta: float) -> void:
	## ---------- 生命周期管理（最先执行，即使数据异常的拾取物也会正常到期回收） ----------
	_update_lifetime(delta)

	## 如果正在拾取或道具数据为空，直接返回
	if _is_picking or drop_item == null:
		return

	## 自动吸附类型（梦境碎片、回血）：飞向玩家
	## 手动类型（武器、物品、BUFF/技能）：原地停留，需玩家走到位置后按E拾取
	## 扩展：新增装备类型时，在DropItem.get_auto_adsorb()中返回false即可走手动拾取路径
	if drop_item.get_auto_adsorb() and _player != null:
		## 计算从道具位置指向玩家位置的方向向量并归一化
		var direction: Vector2 = (_player.position - position).normalized()
		## 计算道具与玩家之间的距离
		var distance: float = _player.position.distance_to(position)

		## 在吸附范围内才移动（加50像素余量）
		if distance < adsorb_radius + 50.0:
			## 距离越近速度越快（速度乘数：1.0 ~ 3.0）
			var speed_multiplier: float = 1.0 + (1.0 - distance / adsorb_radius) * 2.0
			## 更新道具位置（方向 × 速度 × 乘数 × 时间）
			position += direction * adsorb_speed * speed_multiplier * delta

	## 注意：手动拾取（BUFF技能书/护盾等）不在本节点轮询交互键——
	## 统一由 GameWorld._handle_manual_pickup() 处理（神庙交互优先级 > 拾取）。
	## 旧实现在此与GameWorld双重轮询同一个game_interact边沿（读取即消费），
	## 谁先执行不确定，可能抢在神庙前吞掉按键；且game_interact曾误绑鼠标左键，
	## 导致玩家开枪路过时"自动捡走"技能书。现单一入口，本节点只负责自动吸附位移。

## ========== 生命周期管理（性能修复核心） ==========

## 更新存活时间：到期自动回收，最后BLINK_WINDOW秒闪烁警告
## 数据流：每物理帧累计_life_timer → 剩余寿命进入闪烁窗口时方波闪烁 → 归零queue_free
## 回收路径说明：queue_free触发tree_exiting信号 → GameWorld._on_pickup_tree_exiting
## 同步清理_pickups管理列表（生成时已连接），无需额外通知逻辑
func _update_lifetime(delta: float) -> void:
	## 已进入拾取流程（含专家模式二次确认等待期）：冻结寿命累计，
	## 保证玩家在确认面板上做决定时道具不会在脚下悄悄过期消失
	if _is_picking:
		return
	## 累计已存活时间
	_life_timer += delta
	## 计算剩余寿命
	var remain: float = lifetime - _life_timer

	## 寿命耗尽：自动消失（queue_free本就是延迟到帧末的安全销毁；
	## 若同帧已被拾取标记_is_picking，重复queue_free幂等无害）
	if remain <= 0.0:
		queue_free()
		return

	## 临近消失：闪烁警告（0.4秒一周期：0.2秒原色 / 0.2秒25%透明度）
	## 方波闪烁用fmod取余判断相位，零额外计时器分配；
	## 仅在未进入拾取流程时执行，避免覆盖拾取瞬间的表现
	if remain < BLINK_WINDOW and sprite != null and not _is_picking:
		var blink_on: bool = fmod(remain, 0.4) < 0.2
		## 保留原色相只改透明度：闪烁期间颜色语义不丢失（碎片仍金黄/血包仍绿色）
		sprite.modulate = _original_color if blink_on else Color(
			_original_color.r, _original_color.g, _original_color.b, 0.25)

## ========== 道具数据设置 ==========

## 设置道具数据并应用外观（对外接口，由GameWorld调用）
## 参数：item - 掉落道具数据
func set_drop_item(item: DropItemClass) -> void:
	drop_item = item
	
	## 如果精灵节点或道具数据为空，直接返回
	if sprite == null or item == null:
		return
	
	## 根据道具类型设置显示尺寸与"兜底色"（有真实图标时颜色不生效，
	## 仅在图标资源缺失时作为占位方块色，颜色语义保留用于兜底辨认）
	var color: Color = Color.WHITE
	var size: Vector2 = Vector2(20, 20)

	## 根据道具类型设置不同颜色和大小
	match item.item_type:
		DropItemClass.ItemType.DREAM_FRAGMENT:
			## 梦境碎片：兜底色金色，16x16（正常使用 icon_fragments_* 真实图标）
			color = Color(1, 0.8, 0, 1)
			size = Vector2(16, 16)
		DropItemClass.ItemType.HEALTH:
			## 回血道具：兜底色绿色，20x20（正常使用 icon_blood_* 真实图标）
			color = Color(0, 1, 0, 1)
			size = Vector2(20, 20)
		DropItemClass.ItemType.WEAPON:
			## 武器：灰色，24x24（预留类型，暂无图标→显示灰色方块）
			color = Color(0.5, 0.5, 0.5, 1)
			size = Vector2(24, 24)
		DropItemClass.ItemType.ITEM:
			## 普通物品：浅灰色，20x20（预留类型，暂无图标→显示浅灰方块）
			color = Color(0.8, 0.8, 0.8, 1)
			size = Vector2(20, 20)
		DropItemClass.ItemType.BUFF:
			## 增益效果：兜底色紫色，22x22（正常使用 icon_skill 真实图标）
			color = Color(1, 0, 1, 1)
			size = Vector2(22, 22)
		DropItemClass.ItemType.EQUIPMENT:
			## 装备：兜底色青蓝色，24x24（正常使用对应护盾真实图标）
			color = Color(0.3, 0.6, 1.0, 1)
			size = Vector2(24, 24)

	## 稀有道具兜底方块半透明（有图标时下方白色基色会覆盖此效果）
	if item.is_rare:
		color.a = 0.8

	## ========== 外观解析：优先真实图标，缺失才用占位色块 ==========
	## 统一走掉落物图标路径（敌人掉落目录，item_id 经 DROP_ICON_MAP 映射），
	## 不再按类型拆分支：护盾装备也在 DROP_ICON_MAP 登记为 icon_shield_basic，
	## 地面掉落阶段只告知"这是护盾"，具体护盾种类留给拾取后的三选一决定
	var icon_src: Texture2D = IconLibraryLib.get_drop_icon(item.item_id)
	var icon_cache_key: String = "drop:%s" % item.item_id

	## 按世界统一显示尺寸生成图标纹理（不用类型色块尺寸——那会把24px源图再下采样到16~22）。
	## 放大像素小图用NEAREST、缩小大图用LANCZOS，插值方式在缩放方法内部按方向自动选择
	var final_tex: Texture2D = null
	if icon_src != null:
		final_tex = _get_scaled_icon_texture(icon_src, icon_cache_key, ICON_WORLD_SIZE)

	if final_tex != null:
		## 图标路径：白色modulate保留美术原色（类型tint色会给彩色图标串色）；
		## 闪烁/拾取淡出逻辑只改alpha，白色基色下表现不受影响
		sprite.texture = final_tex
		_original_color = Color.WHITE
		sprite.modulate = Color.WHITE
	else:
		## 兜底路径：无图标资源（如预留的WEAPON/ITEM类型）时用颜色占位方块
		_original_color = color
		sprite.modulate = color
		_create_placeholder_texture(sprite, color, int(size.x), int(size.y))

## ========== 辅助方法 ==========

## 获取按世界显示尺寸缩放的图标纹理（通用：护盾装备/消耗品掉落共用，带静态缓存）
## 数据流：调用方已从IconLibrary取得原图 → get_image缩放到目标尺寸 → 按缓存键复用
## 参数：src - IconLibrary加载的原始图标纹理；cache_key - 缓存键（命名空间:id，尺寸由内部拼接）
##       target_size - 目标显示尺寸（像素，正方形边长）
## 返回：缩放后的纹理；原图无图像数据时返回 null（调用方回退占位色块）
## 插值选择（关键画质点）：
##   源图>目标（如护盾128→32，下采样）→ LANCZOS 高质量缩小，边缘干净
##   源图<目标（如掉落24→32，上采样）→ NEAREST 最近邻，像素风小图放大保持锐利不发糊
##   源图=目标 → 不resize，直接建纹理
func _get_scaled_icon_texture(src: Texture2D, cache_key: String, target_size: int) -> Texture2D:
	## 缓存键补尺寸后缀（同一id在不同显示尺寸下分别缓存）
	var full_key := "%s|%d" % [cache_key, target_size]
	if _icon_texture_cache.has(full_key):
		return _icon_texture_cache[full_key]
	## 取出图像数据
	var img: Image = src.get_image()
	if img == null:
		return null
	## 尺寸不一致才resize，按缩放方向选择插值算法
	if img.get_width() != target_size:
		var interp: int = Image.INTERPOLATE_LANCZOS if img.get_width() > target_size else Image.INTERPOLATE_NEAREST
		img.resize(target_size, target_size, interp)
	var scaled_tex: ImageTexture = ImageTexture.create_from_image(img)
	_icon_texture_cache[full_key] = scaled_tex
	return scaled_tex

## 创建占位纹理（无美术资源时使用）
## 性能设计：纹理按"颜色|尺寸"键入静态缓存，同配置掉落物共享纹理，
##           大量掉落时零Image生成/纹理上传开销
## 参数：sprite_node - 要设置纹理的Sprite2D节点
##       color - 纹理颜色
##       width - 纹理宽度（像素）
##       height - 纹理高度（像素）
func _create_placeholder_texture(sprite_node: Sprite2D, color: Color, width: int, height: int) -> void:
	## 缓存键：颜色|宽|高
	var cache_key: String = "%s|%d|%d" % [color.to_html(), width, height]
	## 缓存命中：直接复用（零开销路径）
	if _texture_cache.has(cache_key):
		sprite_node.texture = _texture_cache[cache_key]
		return
	## 缓存未命中：首次生成
	## 创建指定尺寸的RGBA8格式图像
	var image: Image = Image.create(width, height, false, Image.FORMAT_RGBA8)
	## 用指定颜色填充整个图像
	image.fill(color)
	## 将图像转换为纹理并存入缓存
	var texture: ImageTexture = ImageTexture.create_from_image(image)
	_texture_cache[cache_key] = texture
	## 将纹理设置到Sprite2D节点上
	sprite_node.texture = texture

## 启动道具脉冲动画（让道具更明显，方便玩家发现）
func _start_pulse_animation() -> void:
	if sprite == null:
		return
	
	## 创建循环脉冲动画（缩放+透明度变化）
	var tween: Tween = create_tween()
	tween.set_loops()
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(sprite, "scale", Vector2(1.2, 1.2), 1.0)
	tween.tween_property(sprite, "scale", Vector2(1.0, 1.0), 1.0)

## ========== 碰撞检测回调 ==========

## 接触拾取回调（当玩家接触主碰撞体时触发）
## 参数：body - 进入碰撞区域的物体节点
func _on_body_entered(body: Node2D) -> void:
	## 如果正在拾取或接触的不是玩家，直接返回
	## 性能说明：用is_in_group代替"body in get_nodes_in_group()"（后者每次分配数组）
	if _is_picking or not body.is_in_group("player"):
		return
	
	## 手动拾取类型（武器、物品、BUFF）：不触发接触拾取，必须通过交互键
	if drop_item != null and not drop_item.get_auto_adsorb():
		return
	
	## 自动吸附类型：执行拾取
	pickup(body)

## 玩家进入吸附范围回调（磁铁区域触发）
## 参数：body - 进入磁铁区域的物体节点
func _on_magnet_body_entered(body: Node2D) -> void:
	## 如果进入的不是玩家，直接返回（is_in_group零分配）
	if not body.is_in_group("player"):
		return
	
	## 手动拾取类型：显示拾取提示（改变透明度）
	if drop_item != null and not drop_item.get_auto_adsorb():
		_show_pickup_hint()

## 玩家离开吸附范围回调（磁铁区域触发）
## 参数：body - 离开磁铁区域的物体节点
func _on_magnet_body_exited(body: Node2D) -> void:
	## 如果离开的不是玩家，直接返回（is_in_group零分配）
	if not body.is_in_group("player"):
		return
	
	## 隐藏拾取提示（恢复原始颜色）
	_hide_pickup_hint()

## ========== 拾取提示方法 ==========

## 显示拾取提示（手动拾取类型，玩家进入范围时调用）
func _show_pickup_hint() -> void:
	if sprite != null:
		## 设置为半透明白色，提示玩家可以拾取
		sprite.modulate = Color(1, 1, 1, 0.8)

## 隐藏拾取提示（玩家离开范围时调用）
func _hide_pickup_hint() -> void:
	if sprite != null:
		## 恢复原始颜色
		sprite.modulate = _original_color

## ========== 核心拾取方法 ==========

## 执行拾取（核心方法，对外接口）
## 参数：target - 拾取目标（通常是玩家）
func pickup(target: Node2D) -> void:
	## 如果正在拾取或道具数据为空，直接返回
	if _is_picking or drop_item == null:
		return

	## 专家模式：类别型道具（BUFF/属性技能/护盾/弹道构型）不再立即生效，
	## 改走"二次确认"——是→按类别随机升级并消耗；否→保留道具在原地。
	## 具体升级发放与销毁由 UpgradeManager 负责，本节点只负责发起与状态切换。
	if _is_expert_choice_item():
		## 未受理（已有三选一/确认进行中）：保持原样，玩家稍后可重试
		if UpgradeManager == null or not UpgradeManager.request_expert_pickup(self, drop_item.item_type):
			return
		## 锁定拾取：防止确认期间被重复触发；同时冻结寿命与脉冲闪烁
		_is_picking = true
		return

	## 标记正在拾取（防止重复拾取）
	_is_picking = true
	
	## 拾取音效：稀有BUFF用特殊音效
	if AudioManager:
		var sfx: String = "buff_pickup" if drop_item.is_rare else "pickup_item"
		AudioManager.play_2d(sfx, global_position, 0.8)
	
	## 应用道具效果到目标（添加碎片、恢复血量等）
	drop_item.apply(target)
	
	## 从场景树中移除并销毁拾取物节点
	queue_free()

## 判定当前道具是否为专家模式需要二次确认的"类别型"拾取物
## （BUFF特效技能 / 属性技能 / 护盾装备 / 弹道构型；碎片、回血无类别，仍走自动吸附立即拾取）
## 返回：true=专家模式下应走二次确认流程
func _is_expert_choice_item() -> bool:
	if drop_item == null:
		return false
	## 非专家模式：不启用二次确认
	if DifficultyManager == null or not DifficultyManager.is_expert_mode():
		return false
	## 四类"书 / 宝石"共用手动拾取 + 类别随机升级；用数组包含代替多分支 match，便于日后扩展
	return drop_item.item_type in [
		DropItemClass.ItemType.BUFF,
		DropItemClass.ItemType.ATTRIBUTE_SKILL,
		DropItemClass.ItemType.EQUIPMENT,
		DropItemClass.ItemType.SHOT_PATTERN,
	]

## 完成专家确认拾取（玩家选择"是"，由 UpgradeManager 调用）
## 语义：播放拾取音效并销毁道具本体
func finish_expert_pickup() -> void:
	if AudioManager:
		var sfx: String = "buff_pickup" if (drop_item != null and drop_item.is_rare) else "pickup_item"
		AudioManager.play_2d(sfx, global_position, 0.8)
	queue_free()

## 取消专家确认拾取（玩家选择"否"，由 UpgradeManager 调用）
## 语义：解除拾取锁定，道具保留在原地并恢复可拾取显示，玩家可稍后重试
func cancel_expert_pickup() -> void:
	_is_picking = false
	if sprite != null:
		sprite.modulate = _original_color

## ========== 范围检测方法 ==========

## 检测玩家是否在手动拾取范围内（对外接口，由GameWorld调用）
## 返回：true表示玩家在拾取范围内，false表示不在范围内
func is_player_in_range() -> bool:
	if _player == null:
		return false
	## 计算玩家与拾取物之间的距离是否小于吸附半径
	return _player.position.distance_to(position) < adsorb_radius