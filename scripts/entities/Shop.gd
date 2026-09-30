## Shop.gd - 主场景中央商店世界物体
## 职责：商店的视觉呈现、固定服务构造、玩家交互、购买面板管理
## 继承：Area2D（与 Temple/PickUp 同类的世界交互物体）
## 出现方式：GameWorld 在游戏开始时于竞技场中心 Vector2.ZERO 生成，之后永久存在不消失
## 交互方式：玩家靠近后按 E（GameWorld 统一处理 E 键，优先级神庙 > 商店 > 拾取物）→ 调用 interact(player)
## 进入规则：进入商店后游戏暂停（GameManager.pause_game），关闭面板后恢复
## 商品规则：固定三大服务（恢复健康 / 随机装备 / 合成装备），不做随机刷新——
##          恢复健康 = 100 梦境碎片直接满血；随机装备 = 200 梦境碎片获得随机稀有度随机装备；
##          合成装备 = 面板子视图，消耗各槽位装备碎片合成保底稀有装备
## 视觉方案：_draw() 程序化绘制（柜台 + 顶棚 + 发光宝石，脉冲呼吸），与主题皮肤无关
## 扩展性：服务构造集中在 _build_services，新增服务只需加一个 _make_* 分支
extends Area2D

## ========== 预加载资源 ==========

## 商店商品资源类（运行时生成商品数据）
const ShopProductClass = preload("res://scripts/resources/shop/ShopProduct.gd")
## 商店面板脚本（纯代码 UI）
const SHOP_PANEL_SCRIPT = preload("res://scripts/ui/ShopPanel.gd")
## 装备回收/合成数值口径（合成消耗碎片数、保底稀有度）
const EquipmentRecyclerLib = preload("res://scripts/resources/equipment/EquipmentRecycler.gd")

## ========== 常量 ==========

## 交互半径（玩家与商店距离小于此值时可交互）
const INTERACT_RANGE: float = 64.0

## ---------- 价格体系（梦境碎片） ----------
## 恢复健康：消耗后直接把核心血补满
const PRICE_HEAL_FULL: int = 100
## 随机装备：消耗后获得一件随机稀有度的随机装备
const PRICE_RANDOM_EQUIPMENT: int = 200

## ========== 成员变量 ==========

## 当前固定服务列表（ShopProduct 数组，游戏开始即固定，不刷新）
var _products: Array = []

## 面板实例（交互期间存在）
var _panel: Control = null

## 面板专用 CanvasLayer（隔离相机 transform）
var _overlay_layer: CanvasLayer = null

## 面板是否打开（打开中禁止重复交互；关闭后商店保留，可再次进入）
var _open: bool = false

## 本商店是否主动暂停了游戏（关闭面板时据此恢复，避免误恢复暂停菜单等其他暂停源）
var _paused_by_shop: bool = false

## 玩家是否在交互范围内（_process 中节流探测缓存，_draw 只读缓存）
var _player_near: bool = false

## 交互范围探测节流计时（0.1 秒一次，组查询成本摊薄）
var _near_check_timer: float = 0.0
const NEAR_CHECK_INTERVAL: float = 0.1

## 视觉脉冲计时器（宝石发光呼吸）
var _pulse_time: float = 0.0

## 重绘节流计时（脉冲动画 30fps 足够，避免每帧全量重画）
var _redraw_timer: float = 0.0
const REDRAW_INTERVAL: float = 1.0 / 30.0

## ========== 生命周期方法 ==========

## _ready() - 加入场景树：分组、构造固定服务、入场动画
func _ready() -> void:
	## 加入 shop 分组（GameWorld/其他系统可按组查找）
	add_to_group("shop")

	## 构造固定服务（游戏开始即固定，不再随机刷新）
	_build_services()

	## 入场动画：从透明 + 缩小弹出
	modulate.a = 0.0
	scale = Vector2(0.5, 0.5)
	var tween: Tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property(self, "modulate:a", 1.0, 0.3)
	tween.tween_property(self, "scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

## _process() - 交互范围探测、视觉脉冲（均节流，降低开销）
func _process(delta: float) -> void:
	## 交互范围探测（节流 0.1 秒）
	if not _open:
		_near_check_timer -= delta
		if _near_check_timer <= 0.0:
			_near_check_timer = NEAR_CHECK_INTERVAL
			_player_near = _is_player_near()

	## 脉冲计时与 30fps 重绘（_draw 是纯 CPU 绘制，节流避免每帧全量重画）
	_pulse_time += delta
	_redraw_timer -= delta
	if _redraw_timer <= 0.0:
		_redraw_timer = REDRAW_INTERVAL
		queue_redraw()

## _exit_tree() - 节点被释放时兜底清理：面板挂在 root 的 CanvasLayer 上，不随 Shop 自动销毁
func _exit_tree() -> void:
	_close_panel()

## _draw() - 程序化绘制商店外观（柜台 + 顶棚 + 发光宝石）
func _draw() -> void:
	var counter: Color = Color(0.35, 0.3, 0.22, 1.0)   ## 木质柜台主色
	var counter_dark: Color = Color(0.24, 0.2, 0.15, 1.0)  ## 木质暗色
	var awning: Color = Color(0.85, 0.65, 0.25, 1.0)  ## 金色顶棚
	var gem_glow: float = 0.6 + 0.4 * sin(_pulse_time * 2.5)  ## 宝石脉冲系数
	var gem: Color = Color(0.4, 0.9, 0.95, gem_glow)  ## 青蓝色发光宝石

	## 底部柜台（梯形底座）
	draw_rect(Rect2(-26, 10, 52, 9), counter_dark)
	draw_rect(Rect2(-20, 4, 40, 9), counter)

	## 顶棚（金色遮阳篷）
	draw_rect(Rect2(-28, -30, 56, 7), awning)
	draw_rect(Rect2(-24, -24, 48, 4), Color(0.7, 0.5, 0.15, 1.0))

	## 左右立柱
	draw_rect(Rect2(-18, -24, 6, 30), counter)
	draw_rect(Rect2(12, -24, 6, 30), counter)

	## 中央发光宝石（脉冲呼吸）
	draw_circle(Vector2(0, -14), 6.0, gem)
	## 宝石外圈光晕（半透明大圆）
	var glow_color: Color = gem
	glow_color.a = 0.25 * gem_glow
	draw_circle(Vector2(0, -14), 10.0, glow_color)

	## 玩家在交互范围内且未打开：绘制交互提示（_player_near 为节流探测缓存）
	if not _open and _player_near:
		var hint_color: Color = Color(0.9, 0.95, 1.0, 0.9)
		draw_string(ThemeDB.fallback_font, Vector2(-40, 44), "按 [E] 进入商店", \
			HORIZONTAL_ALIGNMENT_CENTER, 80, 10, hint_color)

## ========== 对外接口 ==========

## 玩家是否在交互范围内（GameWorld._handle_manual_pickup 调用）
func is_player_in_range() -> bool:
	return not _open and _player_near

## 玩家交互（GameWorld._handle_manual_pickup 在玩家按 E 时调用）
## 参数：player - 玩家节点
func interact(_player: Node) -> void:
	## 已打开 / 游戏中断：不响应
	if _open:
		return
	if not GameManager.is_playing():
		return

	_open = true
	_open_panel()

## ========== 内部方法 ==========

## 玩家是否在交互范围内（内部距离检测，节流缓存使用）
func _is_player_near() -> bool:
	var players: Array = get_tree().get_nodes_in_group("player")
	if players.is_empty():
		return false
	var player: Node2D = players[0]
	if not is_instance_valid(player):
		return false
	return global_position.distance_to(player.global_position) <= INTERACT_RANGE

## 构造商店的固定服务列表（游戏开始即固定，不做随机刷新）
## 说明：合成装备不是 ShopProduct，由 ShopPanel 的合成子视图承载（走 craft_requested）
func _build_services() -> void:
	_products.clear()
	_products.append(_make_heal_service())
	_products.append(_make_random_equipment_service())

## 构造「恢复健康」服务：消耗梦境碎片，直接把核心血补满
func _make_heal_service() -> ShopProductClass:
	var product: ShopProductClass = ShopProductClass.new()
	product.product_id = "heal_full"
	product.display_name = "恢复健康"
	product.description = "消耗 %d 梦境碎片，立即将核心血回满" % PRICE_HEAL_FULL
	product.product_color = Color(1.0, 0.45, 0.45, 1.0)
	product.product_type = ShopProductClass.ProductType.HEAL_FULL
	product.price = PRICE_HEAL_FULL
	return product

## 构造「随机装备」服务：消耗梦境碎片，获得一件随机稀有度的随机装备（附概率分布说明）
func _make_random_equipment_service() -> ShopProductClass:
	var product: ShopProductClass = ShopProductClass.new()
	product.product_id = "random_equipment"
	product.display_name = "随机装备"
	product.description = "消耗 %d 梦境碎片，随机获得一件随机稀有度装备\n%s" \
		% [PRICE_RANDOM_EQUIPMENT, _rarity_distribution_text()]
	product.product_color = Color(0.7, 0.55, 1.0, 1.0)
	product.product_type = ShopProductClass.ProductType.RANDOM_EQUIPMENT
	product.price = PRICE_RANDOM_EQUIPMENT
	return product

## 拼接装备稀有度概率分布文案
## 数据源：UpgradeManager.EQUIPMENT_RARITY_WEIGHTS（权重归一化为百分比，避免两处硬编码不同步）
## 返回：如 "稀有度概率：普通 76% / 稀有 20% / 史诗 4%"；权重缺失时返回空串
func _rarity_distribution_text() -> String:
	var weights: Array = UpgradeManager.EQUIPMENT_RARITY_WEIGHTS
	var total: float = 0.0
	for w in weights:
		total += float(w)
	if total <= 0.0:
		return ""
	## 稀有度中文名（下标 = EquipmentData.Rarity：0普通 / 1稀有 / 2史诗）
	var names: PackedStringArray = ["普通", "稀有", "史诗"]
	var parts: PackedStringArray = []
	for i in range(weights.size()):
		var label: String = names[i] if i < names.size() else str(i)
		parts.append("%s %d%%" % [label, int(round(float(weights[i]) / total * 100.0))])
	return "稀有度概率：" + " / ".join(parts)

## 打开购买面板（专用 CanvasLayer 隔离相机，与神庙/升级面板同方案）
func _open_panel() -> void:
	_overlay_layer = CanvasLayer.new()
	_overlay_layer.name = "ShopOverlay"
	## layer 越大越在上层显示，与升级/神庙面板同级=50
	_overlay_layer.layer = 50
	## 进入商店即暂停：覆盖层必须绕过暂停，否则面板自身无法交互
	_overlay_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().root.add_child(_overlay_layer)

	_panel = SHOP_PANEL_SCRIPT.new()
	_panel.process_mode = Node.PROCESS_MODE_ALWAYS
	_overlay_layer.add_child(_panel)

	## 传入玩家引用与固定服务列表（面板需显示碎片余额、处理购买点击）
	var player: Node = _get_player()
	_panel.setup(_products, player)

	## 玩家选定购买 → 扣款并应用；请求合成 → 消耗装备碎片生成装备；请求关闭 → 恢复游戏
	_panel.product_selected.connect(_on_product_selected)
	_panel.craft_requested.connect(_on_craft_requested)
	_panel.close_requested.connect(_close_panel)

	## 暂停战斗（状态机守卫保证只在 PLAYING 时生效）
	if GameManager and GameManager.is_playing():
		GameManager.pause_game()
		_paused_by_shop = true

	## 注册商店上下文：暂停后移动/射击自然停止，放行 LT/RT 左右、确认、取消
	## push 自带 0.2s 屏蔽期，防止按 E 交互的同一次按键立刻触发购买/关闭
	InputManager.push_context("SHOP_CHOICE")

## 玩家选定购买（响应 ShopPanel.product_selected）
## 参数：product - 被选中的商品
func _on_product_selected(product: Resource) -> void:
	var player: Node = _get_player()
	if player == null:
		return

	## 余额不足：只提示，不扣款不发货
	if not player.has_method("spend_dream_fragment") or player.dream_fragment < int(product.price):
		_notify_failure()
		return

	## 恢复健康且已满血：无需购买，直接拒绝（避免白扣碎片）
	if int(product.product_type) == ShopProductClass.ProductType.HEAL_FULL and _is_fully_healed(player):
		_notify_failure()
		return

	## 随机装备且背包已满：直接拒绝（避免扣款后装备无处安放而丢失）
	if int(product.product_type) == ShopProductClass.ProductType.RANDOM_EQUIPMENT and _is_backpack_full(player):
		_notify_failure()
		return

	## 先扣款再发货
	if not player.spend_dream_fragment(int(product.price)):
		return
	## 发货失败（如背包竞态满）→ 退款兜底，保证玩家不白花钱
	if not product.apply(player):
		if player.has_method("add_dream_fragment"):
			player.add_dream_fragment(int(product.price))
		_notify_failure()
		return

	## 购买成功音效
	if AudioManager:
		AudioManager.play("upgrade_pick", 0.9)
	## 刷新面板上的碎片余额显示
	if _panel != null and _panel.has_method("refresh_after_purchase"):
		_panel.refresh_after_purchase()

## 玩家请求合成装备（响应 ShopPanel.craft_requested）
## 流程：校验装备碎片/梦境碎片 → 校验背包容量 → 生成保底稀有装备 → 扣两种货币 → 入背包（失败全额回退）→ 结果反馈
## 参数：slot - 目标槽位（EquipmentData.Slot）
func _on_craft_requested(slot: int) -> void:
	var player: Node = _get_player()
	if player == null:
		return

	var frag_cost: int = int(EquipmentRecyclerLib.CRAFT_FRAGMENT_COST)
	var dream_cost: int = int(EquipmentRecyclerLib.CRAFT_DREAM_COST)
	## 装备碎片不足：只提示，不生成不扣费
	if not player.has_method("get_equipment_fragment") or int(player.get_equipment_fragment(slot)) < frag_cost:
		_notify_failure()
		return
	## 梦境碎片不足：同上，不生成不扣费
	if int(player.dream_fragment) < dream_cost:
		_notify_failure()
		return
	## 背包已满：直接拒绝（避免扣费后装备无处安放而丢失）
	if _is_backpack_full(player):
		_notify_failure()
		return

	## 先生成装备（生成失败不扣任何货币）
	var eq: Resource = UpgradeManager.generate_equipment_with_floor(slot, int(EquipmentRecyclerLib.CRAFT_RARITY_FLOOR))
	if eq == null:
		_notify_failure()
		return
	## 扣装备碎片
	if not player.spend_equipment_fragment(slot, frag_cost):
		_notify_failure()
		return
	## 扣梦境碎片：失败则退还已扣的装备碎片
	if not player.spend_dream_fragment(dream_cost):
		if player.has_method("add_equipment_fragment"):
			player.add_equipment_fragment(slot, frag_cost)
		_notify_failure()
		return
	## 入背包失败（如竞态满）→ 退还两种货币兜底，保证玩家不白损失
	if not player.add_equipment_to_backpack(eq):
		if player.has_method("add_equipment_fragment"):
			player.add_equipment_fragment(slot, frag_cost)
		if player.has_method("add_dream_fragment"):
			player.add_dream_fragment(dream_cost)
		_notify_failure()
		return

	## 合成成功音效（沿用强化/购买的反馈音）
	if AudioManager:
		AudioManager.play("upgrade_pick", 0.9)
	## 刷新面板上的碎片余额与合成按钮可用态
	if _panel != null and _panel.has_method("refresh_after_craft"):
		_panel.refresh_after_craft()
	## 展示合成结果反馈（与神庙融合同款结果视图，让玩家看清合成了什么）
	if _panel != null and _panel.has_method("show_craft_result"):
		_panel.show_craft_result("合成成功！\n" + UpgradeManager.build_obtain_message(eq))

## 购买/合成失败提示（余额不足 / 已满血 / 背包已满 / 发货失败）：播放提示音并让面板标题闪红
func _notify_failure() -> void:
	if AudioManager:
		AudioManager.play("ui_click", 0.6)
	if _panel != null and _panel.has_method("notify_failure"):
		_panel.notify_failure()

## 玩家是否已满血（无生存状态接口时视为未满，交由 apply 兜底判定）
func _is_fully_healed(player: Node) -> bool:
	if player == null or not player.has_method("get_survival_state"):
		return false
	var state: Dictionary = player.get_survival_state()
	return float(state.get("core", 0.0)) >= float(state.get("max_core", 0.0))

## 玩家背包是否已满（无背包组件时视为未满）
func _is_backpack_full(player: Node) -> bool:
	if player == null or not player.has_method("get_backpack"):
		return false
	var backpack: Node = player.get_backpack()
	if backpack == null or not backpack.has_method("is_full"):
		return false
	return bool(backpack.is_full())

## 获取玩家节点（通过 player 组查找）
func _get_player() -> Node:
	var players: Array = get_tree().get_nodes_in_group("player")
	if players.is_empty():
		return null
	return players[0] as Node

## 关闭面板（连同 CanvasLayer 一起清理），恢复战斗
func _close_panel() -> void:
	## 条件注销上下文：仅当栈顶确实是商店上下文时才 pop
	if InputManager and InputManager.get_current_context() == "SHOP_CHOICE":
		InputManager.pop_context()
	## 恢复战斗：仅当暂停由本商店发起时才恢复
	if _paused_by_shop and GameManager:
		_paused_by_shop = false
		GameManager.resume_game()
	_open = false
	if _panel != null and is_instance_valid(_panel):
		_panel.queue_free()
		_panel = null
	if _overlay_layer != null and is_instance_valid(_overlay_layer):
		_overlay_layer.queue_free()
		_overlay_layer = null
