## LevelUpPanel.gd - 升级三选一面板（纯代码构建UI，无需.tscn）
## 职责：展示随机抽取的3个词条供玩家选择，玩家选定后发出信号
## 继承：Control（全屏覆盖层，挂在根节点下，暂停状态可见可交互）
## 设计意图：
##   1. 三选一是roguelike的核心决策时刻：面板需清晰展示词条名称/稀有度/效果
##   2. 支持鼠标点击与数字键1/2/3两种选择方式，兼顾操作效率
##   3. 纯代码构建：由UpgradeManager动态创建销毁，不污染场景文件
## 数据流：UpgradeManager.open_level_up_choice()（is_choosing立即上锁防重入）→ call_deferred 延迟一帧
##        创建本面板（PROCESS_MODE_ALWAYS，游戏暂停下仍可交互）→ setup(choices) 动态建卡片
##        → 玩家选定 upgrade_chosen → UpgradeManager 应用词条、销毁面板、解锁is_choosing并恢复游戏
extends Control

## ========== 预加载资源 ==========

## 词条数据资源类（用于类型检查和读取稀有度）
const UpgradeDataClass = preload("res://scripts/resources/upgrade/UpgradeData.gd")

## ========== 信号定义 ==========

## 玩家选定词条信号：点击卡片或按数字键时发出
## 参数：upgrade - 玩家选定的词条数据
signal upgrade_chosen(upgrade: Resource)

## ========== 成员变量 ==========

## 当前展示的候选词条数组（最多3个）
var _choices: Array = []

## 已选定的词条（防止双击重复发信号）
var _locked: bool = false

## 卡片容器引用（_ready构建UI时保存，setup动态添加卡片用）
var _card_container: VBoxContainer = null

## ========== 生命周期方法 ==========

## _ready() - 构建整个面板UI（纯代码）
func _ready() -> void:
	## 全屏覆盖：set_anchors_and_offsets_preset同时设置锚点与偏移（等价编辑器Layout菜单）
	## 关键修复（与GameOverPanel同款）：不能用set_anchors_preset——它只改锚点并按
	## "保持当前矩形"重算偏移，新建Control的矩形是(0,0,0,0)，结果面板塌缩成左上角
	## 0x0的点，表现为三选一界面堆在左上角且拦截不住鼠标点击
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	## 鼠标过滤器设为STOP：拦截所有点击，防止穿透到下层游戏UI
	mouse_filter = Control.MOUSE_FILTER_STOP

	## ---------- 全屏暗色背景 ----------
	## 半透明黑色背景：弱化游戏画面，突出选择面板
	## 顺序：先add_child挂到面板下，再设全屏锚点偏移（确保相对父矩形计算生效）
	var bg: ColorRect = ColorRect.new()
	bg.color = Color(0, 0, 0, 0.75)
	## 背景必须IGNORE鼠标事件，否则会挡住卡片按钮的点击（项目教训）
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	## ---------- 居中容器 ----------
	## CenterContainer全屏铺满，子节点按最小尺寸永远居中——
	## 不依赖任何锚点/偏移语义，任意分辨率下都可靠居中（与GameOverPanel同款兜底）
	var center: CenterContainer = CenterContainer.new()
	add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	## 容器自身不拦截鼠标（卡片按钮在子级中，事件先命中按钮；未命中的落到面板STOP层）
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE

	## ---------- 垂直布局容器 ----------
	## VBox排列：标题 + 3张词条卡片
	## 居中交给CenterContainer，vbox作为普通子节点无需任何锚点配置
	var vbox: VBoxContainer = VBoxContainer.new()
	## 容器间垂直间距（小视口下用6px紧凑排列）
	vbox.add_theme_constant_override("separation", 6)
	## 容器不拦截鼠标（让子按钮接收）
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(vbox)

	## ---------- 标题 ----------
	var title: Label = Label.new()
	title.text = "✦ 升级！选择一项强化 ✦"
	## 标题居中对齐
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	## 金色标题突出仪式感
	title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	vbox.add_child(title)

	## ---------- 词条卡片 ----------
	## 卡片在setup()中动态创建（需要_choices数据）
	## 这里只记录vbox引用，卡片创建延迟到setup()
	_card_container = vbox

## _unhandled_input() - 处理数字键1/2/3快捷选择
## 注意：面板挂载在root下且游戏暂停，键盘事件仍会到达这里（PROCESS_MODE_ALWAYS）
func _unhandled_input(event: InputEvent) -> void:
	## 非按键按下事件直接忽略（先用类型检查避免访问不存在的属性）
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	## 数字键1/2/3映射到候选索引0/1/2
	var index: int = -1
	match event.physical_keycode:
		KEY_1: index = 0
		KEY_2: index = 1
		KEY_3: index = 2
	## 索引有效且未锁定时选择对应词条
	if index >= 0 and index < _choices.size():
		_choose(index)

## ========== 对外接口 ==========

## 初始化面板显示（UpgradeManager创建面板后调用）
## 参数：choices - 候选词条数组（最多3个UpgradeData）
func setup(choices: Array) -> void:
	## 保存候选数据
	_choices = choices
	## 为每个候选词条创建一张可点击卡片
	for i in range(choices.size()):
		_card_container.add_child(_create_card(choices[i], i))

## ========== 内部构建方法 ==========

## 创建单个词条卡片按钮
## 参数：upgrade - 词条数据，index - 候选索引（用于数字键提示）
## 返回：构建好的Button节点
func _create_card(upgrade: Resource, index: int) -> Button:
	## 用Button作为卡片：自带鼠标悬停/点击反馈
	var card: Button = Button.new()
	## 组装显示文本：[数字键提示] 稀有度颜色名称 + 描述
	## 稀有度前缀：普通/稀有/史诗，让玩家一眼判断价值
	var rarity_names: Array = ["普通", "稀有", "史诗"]
	var rarity_colors: Array = [
		Color(0.85, 0.85, 0.85),  ## 普通：灰白
		Color(0.35, 0.65, 1.0),   ## 稀有：蓝色
		Color(0.8, 0.4, 1.0),     ## 史诗：紫色
	]
	var rarity: int = upgrade.rarity if "rarity" in upgrade else 0
	var display_name: String = upgrade.display_name if "display_name" in upgrade else "???"
	var desc: String = upgrade.description if "description" in upgrade else ""
	## 多行文本：%d. [稀有度] 名称\n描述
	card.text = "%d. [%s] %s\n%s" % [index + 1, rarity_names[rarity], display_name, desc]
	## 卡片尺寸：宽280适配400视口留边距，高48容纳两行文本
	card.custom_minimum_size = Vector2(280, 48)
	## 文本自动换行兜底（描述过长时；属性存在才设置，规避引擎版本差异）
	if "autowrap_mode" in card:
		card.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	## 应用稀有度颜色（字体颜色）
	card.add_theme_color_override("font_color", rarity_colors[rarity])
	## 悬停时字体变为高亮黄（视觉反馈）
	card.add_theme_color_override("font_hover_color", Color(1.0, 0.95, 0.5))
	## 点击音效反馈由UpgradeManager统一播放，这里只连信号
	card.pressed.connect(_choose.bind(index))
	return card

## 选择词条（统一入口：鼠标点击与键盘快捷键都走这里）
## 参数：index - 候选索引
func _choose(index: int) -> void:
	## 防止重复选择（双击/连按会发多次信号）
	if _locked:
		return
	## 索引越界保护
	if index < 0 or index >= _choices.size():
		return
	## 上锁并发出选择信号
	_locked = true
	upgrade_chosen.emit(_choices[index])
