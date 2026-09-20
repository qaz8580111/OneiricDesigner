## Shop.gd - 主场景中央商店世界物体
## 职责：商店的视觉呈现、商品随机刷新、玩家交互、购买面板管理
## 继承：Area2D（与 Temple/PickUp 同类的世界交互物体）
## 出现方式：GameWorld 在游戏进行满 5 分钟后于竞技场中心 Vector2.ZERO 生成，之后永久存在不消失
## 交互方式：玩家靠近后按 E（GameWorld 统一处理 E 键，优先级神庙 > 商店 > 拾取物）→ 调用 interact(player)
## 进入规则：进入商店后游戏暂停（GameManager.pause_game），关闭面板后恢复
## 商品规则：每 60 秒随机刷新一次 3 件商品，商品全部落在现有技能/装备体系内
##          （属性词条 / 特效词条 / 装备护盾 / 血包），价格体系见 docs 商品清单
## 视觉方案：_draw() 程序化绘制（柜台 + 顶棚 + 发光宝石，脉冲呼吸），与主题皮肤无关
## 扩展性：商品生成集中在 _roll_products/_generate_product，新增商品种类只需加一个填充分支
extends Area2D

## ========== 预加载资源 ==========

## 商店商品资源类（运行时生成商品数据）
const ShopProductClass = preload("res://scripts/resources/shop/ShopProduct.gd")
## 商店面板脚本（纯代码 UI）
const SHOP_PANEL_SCRIPT = preload("res://scripts/ui/ShopPanel.gd")
## 装备护盾数据类（护盾类商品扫描 data/equipment/ 时做类型校验）
const ShieldEquipmentDataClass = preload("res://scripts/resources/equipment/ShieldEquipmentData.gd")
## 升级词条数据类（属性/技能类商品从 UpgradeManager 获取后做类型收窄）
const UpgradeDataClass = preload("res://scripts/resources/upgrade/UpgradeData.gd")

## ========== 常量 ==========

## 交互半径（玩家与商店距离小于此值时可交互）
const INTERACT_RANGE: float = 64.0

## 商品刷新间隔（秒）：每 60 秒随机一次商品
const REFRESH_INTERVAL: float = 60.0

## 每次刷新的商品数量（横向 3 件，与升级三选一数量一致，面板可完整排开）
const PRODUCT_COUNT: int = 3

## ---------- 价格体系（梦境碎片，与 docs 商品清单保持一致） ----------
## 属性类词条：按稀有度分档
const PRICE_ATTR_COMMON: int = 30
const PRICE_ATTR_RARE: int = 60
const PRICE_ATTR_EPIC: int = 100
## 技能类（子弹特效）词条：略高于属性类，特效更稀有
const PRICE_SKILL_COMMON: int = 40
const PRICE_SKILL_RARE: int = 80
const PRICE_SKILL_EPIC: int = 130
## 护盾类：基础护盾 / 特效护盾
const PRICE_SHIELD_BASIC: int = 40
const PRICE_SHIELD_SPECIAL: int = 100
## 血包：固定恢复量 + 固定价格
const PRICE_HEALTH: int = 20
const HEALTH_AMOUNT: int = 30

## ========== 成员变量 ==========

## 当前货架商品（ShopProduct 数组，购买后不消失，直到下次刷新）
var _products: Array = []

## 面板实例（交互期间存在）
var _panel: Control = null

## 面板专用 CanvasLayer（隔离相机 transform）
var _overlay_layer: CanvasLayer = null

## 面板是否打开（打开中禁止重复交互；关闭后商店保留，可再次进入）
var _open: bool = false

## 本商店是否主动暂停了游戏（关闭面板时据此恢复，避免误恢复暂停菜单等其他暂停源）
var _paused_by_shop: bool = false

## 商品刷新计时器（累计到 REFRESH_INTERVAL 触发刷新）
var _refresh_timer: float = 0.0

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

## _ready() - 加入场景树：分组、首次上货、入场动画
func _ready() -> void:
	## 加入 shop 分组（GameWorld/其他系统可按组查找）
	add_to_group("shop")

	## 首次随机上货（生成即有一批商品）
	_roll_products()

	## 入场动画：从透明 + 缩小弹出
	modulate.a = 0.0
	scale = Vector2(0.5, 0.5)
	var tween: Tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property(self, "modulate:a", 1.0, 0.3)
	tween.tween_property(self, "scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

## _process() - 商品刷新计时、交互范围探测、视觉脉冲（均节流，降低开销）
func _process(delta: float) -> void:
	## 打开面板期间游戏已暂停，本节点 PAUSABLE 不会继续 _process；
	## 因此刷新计时天然只在"非暂停的战斗时间"内推进，符合"每 1 分钟随机一次"
	_refresh_timer += delta
	if _refresh_timer >= REFRESH_INTERVAL:
		_refresh_timer = 0.0
		_roll_products()

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
	## 升级三选一面板排队中/正在选择：不允许进入（防止上下文栈与暂停状态交叉）
	if UpgradeManager and UpgradeManager.is_choosing:
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

## 随机刷新货架商品（PRODUCT_COUNT 件）
func _roll_products() -> void:
	_products.clear()
	for i in range(PRODUCT_COUNT):
		_products.append(_generate_product())

## 生成一件商品：随机品类 → 从现有体系填充载荷 + 按价格体系定价
func _generate_product() -> ShopProductClass:
	var product: ShopProductClass = ShopProductClass.new()
	## 品类随机分布：属性 30% / 技能 30% / 护盾 20% / 血包 20%
	var roll: float = RandomManager.randf()
	if roll < 0.3:
		_fill_attribute_product(product)
	elif roll < 0.6:
		_fill_skill_product(product)
	elif roll < 0.8:
		_fill_shield_product(product)
	else:
		_fill_health_product(product)
	return product

## 填充属性类商品（随机一个 bullet_effect 为空的属性词条）
func _fill_attribute_product(product: ShopProductClass) -> void:
	var upgrade: UpgradeDataClass = UpgradeManager.get_random_attribute_upgrade() as UpgradeDataClass
	if upgrade == null:
		## 属性词条池耗尽时回退为血包，保证商店永远有货
		_fill_health_product(product)
		return
	product.product_type = ShopProductClass.ProductType.ATTRIBUTE
	product.product_id = "attr_" + str(upgrade.upgrade_id)
	product.display_name = str(upgrade.display_name)
	product.description = str(upgrade.description)
	product.price = _upgrade_price(upgrade, false)
	product.product_color = _rarity_color(int(upgrade.rarity))
	product.upgrade_data = upgrade

## 填充技能类商品（随机一个 bullet_effect 非空的子弹特效词条）
func _fill_skill_product(product: ShopProductClass) -> void:
	var upgrade: UpgradeDataClass = UpgradeManager.get_random_effect_upgrade() as UpgradeDataClass
	if upgrade == null:
		## 特效词条池耗尽时回退为血包
		_fill_health_product(product)
		return
	product.product_type = ShopProductClass.ProductType.SKILL
	product.product_id = "skill_" + str(upgrade.upgrade_id)
	product.display_name = str(upgrade.display_name)
	product.description = str(upgrade.description)
	product.price = _upgrade_price(upgrade, true)
	product.product_color = _rarity_color(int(upgrade.rarity))
	product.upgrade_data = upgrade

## 填充护盾类商品（随机一件 data/equipment/ 下的装备护盾）
func _fill_shield_product(product: ShopProductClass) -> void:
	var shield: ShieldEquipmentDataClass = _random_shield()
	if shield == null:
		_fill_health_product(product)
		return
	product.product_type = ShopProductClass.ProductType.SHIELD
	product.product_id = "shield_" + str(shield.shield_id)
	product.display_name = str(shield.display_name)
	product.description = "装备护盾：同类型叠加（最多3层），不同类型替换为1层"
	product.price = PRICE_SHIELD_SPECIAL if shield.is_special else PRICE_SHIELD_BASIC
	product.product_color = shield.shield_color
	product.shield_data = shield

## 填充血包商品（固定恢复量 + 固定价格）
func _fill_health_product(product: ShopProductClass) -> void:
	product.product_type = ShopProductClass.ProductType.HEALTH
	product.product_id = "health_pack"
	product.display_name = "梦境血包"
	product.description = "立即恢复 %d 点核心血量" % HEALTH_AMOUNT
	product.price = PRICE_HEALTH
	product.product_color = Color(1.0, 0.45, 0.45, 1.0)
	product.heal_amount = HEALTH_AMOUNT

## 随机加载一件装备护盾（扫描 data/equipment/ 目录，数据驱动）
func _random_shield() -> ShieldEquipmentDataClass:
	var shields: Array[ShieldEquipmentDataClass] = []
	var dir_path: String = "res://data/equipment"
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return null

	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".tres"):
			var res: Resource = load(dir_path + "/" + file_name)
			if res is ShieldEquipmentDataClass:
				shields.append(res as ShieldEquipmentDataClass)
		file_name = dir.get_next()
	dir.list_dir_end()

	if shields.is_empty():
		return null
	return shields[RandomManager.randi_range(0, shields.size() - 1)]

## 按词条稀有度与品类计算价格（属性/技能分档，见常量区）
## 参数：upgrade - 词条数据；is_skill - true=技能(特效)类，false=属性类
func _upgrade_price(upgrade: UpgradeDataClass, is_skill: bool) -> int:
	var rarity: int = int(upgrade.rarity)
	if is_skill:
		match rarity:
			2: return PRICE_SKILL_EPIC
			1: return PRICE_SKILL_RARE
			_: return PRICE_SKILL_COMMON
	else:
		match rarity:
			2: return PRICE_ATTR_EPIC
			1: return PRICE_ATTR_RARE
			_: return PRICE_ATTR_COMMON

## 按稀有度返回展示颜色（0=普通白 / 1=稀有蓝 / 2=史诗紫）
func _rarity_color(rarity: int) -> Color:
	match rarity:
		2: return Color(0.8, 0.4, 1.0)
		1: return Color(0.4, 0.7, 1.0)
		_: return Color(0.9, 0.9, 0.9)

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

	## 传入玩家引用与当前货架商品（面板需显示碎片余额、处理购买点击）
	var player: Node = _get_player()
	_panel.setup(_products, player)

	## 玩家选定购买 → 扣款并应用；请求关闭 → 恢复游戏
	_panel.product_selected.connect(_on_product_selected)
	_panel.close_requested.connect(_close_panel)

	## 暂停战斗（状态机守卫保证只在 PLAYING 时生效）
	if GameManager and GameManager.is_playing():
		GameManager.pause_game()
		_paused_by_shop = true

	## 注册商店上下文：暂停后移动/射击自然停止，放行 LT/RT 左右、确认、取消
	## push 自带 0.2s 屏蔽期，防止按 E 交互的同一次按键立刻触发购买/关闭
	InputManager.push_context("SHOP_CHOICE")

## 玩家选定购买商品（响应 ShopPanel.product_selected）
## 参数：product - 被选中的商品
func _on_product_selected(product: Resource) -> void:
	var player: Node = _get_player()
	if player == null:
		return

	## 余额不足：只提示，不扣款不发货
	if not player.has_method("spend_dream_fragment") or player.dream_fragment < int(product.price):
		if AudioManager:
			AudioManager.play("ui_click", 0.6)
		if _panel != null and _panel.has_method("notify_insufficient"):
			_panel.notify_insufficient()
		return

	## 先扣款再发货（apply 失败也视为已扣，当前所有商品 apply 均必成功）
	if not player.spend_dream_fragment(int(product.price)):
		return
	product.apply(player)

	## 购买成功音效
	if AudioManager:
		AudioManager.play("upgrade_pick", 0.9)
	## 刷新面板上的碎片余额显示
	if _panel != null and _panel.has_method("refresh_after_purchase"):
		_panel.refresh_after_purchase()

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
