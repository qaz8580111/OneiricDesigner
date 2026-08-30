## ThemeManager.gd - 主题管理单例（一键换肤系统的中枢）
## 职责：扫描/加载主题包 → 按角色分发皮肤 → 支持运行时热切换并广播
## 继承：Node（autoload 单例）
## 数据流（启动）：扫描 res://data/themes/*.tres → 读 user://settings.cfg 的 current_theme
##                → 静默应用（此刻无角色在场，不广播）→ 同步引擎清屏色
## 数据流（切换）：Settings界面/代码调用 set_theme(id) → 应用新主题 → 持久化到 cfg
##                → 广播 theme_changed → 场景中所有 Player/Enemy/GameWorld 各自换肤
## 换主题的成本：改 settings.cfg 一个字段，或设置界面点一下下拉框——这就是"一键换肤"
## 设计意图：角色外观逻辑全部收敛到皮肤资源（CharacterSkin），
##           Player/Enemy 只在 _ready 时向本单例"要"皮肤，自己不关心主题细节
extends Node

## ========== 预加载资源（避免运行时加载延迟） ==========

## 主题包资源类（类型校验用）
const GameThemeClass = preload("res://scripts/resources/skin/GameTheme.gd")

## ========== 信号定义（用于与其他节点通信） ==========

## 主题切换信号：运行时切换主题后广播，Player/Enemy/GameWorld 监听并即时换肤
## 参数：theme - 新的主题包资源
signal theme_changed(theme: Resource)

## ========== 常量 ==========

## 主题包存放目录（新主题 .tres 丢进这个目录即被自动发现，零代码注册）
const THEMES_DIR: String = "res://data/themes"

## 默认主题id（settings.cfg 无记录/记录失效时的回退目标）
const DEFAULT_THEME_ID: String = "default"

## ========== 成员变量（运行时数据） ==========

## 已扫描到的全部主题包（启动时扫描一次；按 theme_id 排序保证下拉框顺序稳定）
var available_themes: Array = []

## 当前生效的主题包（null 表示尚未成功加载任何主题——所有角色走占位回退）
var current_theme: GameThemeClass = null

## ========== 生命周期方法 ==========

## _ready() - autoload 启动时调用
func _ready() -> void:
	## 扫描主题目录，收集所有主题包
	_scan_themes()
	## 读取上次保存的主题id并静默应用（启动阶段无角色在场，无需广播）
	_apply_theme_by_id(_load_saved_theme_id())
	print("[ThemeManager] 已加载 %d 个主题，当前主题: %s" % [
		available_themes.size(),
		current_theme.theme_name if current_theme != null else "无(占位回退)"
	])

## ========== 主题扫描与加载 ==========

## 扫描主题目录下所有 .tres 文件，加载为主题包列表
## 设计意图：新增主题 = 往 data/themes/ 扔一个 .tres 文件，自动被发现
func _scan_themes() -> void:
	available_themes.clear()
	## 打开主题目录（目录不存在时 DirAccess.open 返回 null，静默跳过）
	var dir: DirAccess = DirAccess.open(THEMES_DIR)
	if dir == null:
		print("[ThemeManager] 主题目录不存在: %s（所有角色将使用占位外观）" % THEMES_DIR)
		return
	## 遍历目录内所有文件
	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while file_name != "":
		## 只处理文件（跳过子目录）且扩展名为 .tres 的资源
		if not dir.current_is_dir() and file_name.ends_with(".tres"):
			var loaded: Resource = load(THEMES_DIR + "/" + file_name)
			## 类型校验：目录里可能混有其他资源，只认 GameTheme
			if loaded is GameThemeClass:
				available_themes.append(loaded)
		file_name = dir.get_next()
	dir.list_dir_end()
	## 按 theme_id 排序：保证每次启动下拉框顺序一致（稳定体验）
	available_themes.sort_custom(func(a, b): return a.theme_id < b.theme_id)

## 按id应用主题（内部方法，不广播）
## 参数：theme_id - 目标主题id
## 返回：true=应用成功 / false=找不到该主题（保持现状）
func _apply_theme_by_id(theme_id: String) -> bool:
	## 在已扫描列表中查找目标主题
	for theme in available_themes:
		if theme.theme_id == theme_id:
			## 幂等保护：已是当前主题则不重复应用（避免重复广播/写盘）
			if current_theme == theme:
				return true
			current_theme = theme
			## 同步引擎清屏色：与主题背景色一致，防止窗口超出背景层时露出默认灰
			RenderingServer.set_default_clear_color(theme.bg_color)
			## 持久化选择（下次启动自动恢复）
			_save_theme_id(theme_id)
			return true
	## 找不到目标主题：打印警告保持现状（不崩溃）
	print("[ThemeManager] 未找到主题 '%s'，保持当前主题不变" % theme_id)
	return false

## ========== 对外接口（Player/Enemy/GameWorld/Settings 调用） ==========

## 切换主题（唯一对外的切换入口）
## 参数：theme_id - 目标主题id（对应 GameTheme.theme_id）
func set_theme(theme_id: String) -> void:
	## 应用成功才广播（失败保持现状，不惊动场景内角色）
	if _apply_theme_by_id(theme_id):
		## 广播主题切换：场景中所有 Player/Enemy/GameWorld 即时换肤
		theme_changed.emit(current_theme)

## 获取玩家皮肤
## 返回：CharacterSkin 或 null（无主题/未配置 → 调用方回退占位纹理）
func get_player_skin() -> Resource:
	return current_theme.player_skin if current_theme != null else null

## 获取敌人皮肤（enemy_id 精确匹配 → 主题兜底皮肤 → null）
## 参数：enemy_id - 敌人唯一标识（EnemyData.enemy_id）
func get_enemy_skin(enemy_id: String) -> Resource:
	return current_theme.get_enemy_skin(enemy_id) if current_theme != null else null

## ========== 持久化（user://settings.cfg） ==========

## 从配置文件读取保存的主题id（无记录时返回默认主题id）
func _load_saved_theme_id() -> String:
	var config: ConfigFile = ConfigFile.new()
	if config.load("user://settings.cfg") == OK:
		return str(config.get_value("Settings", "current_theme", DEFAULT_THEME_ID))
	return DEFAULT_THEME_ID

## 把主题id写入配置文件
## 注意：先 load 再改再 save（保留 cfg 中难度/音量等其他设置项，只改 current_theme 一个键）
func _save_theme_id(theme_id: String) -> void:
	var config: ConfigFile = ConfigFile.new()
	## 读取现有配置（首次运行文件不存在也无妨，save 时会创建）
	config.load("user://settings.cfg")
	config.set_value("Settings", "current_theme", theme_id)
	var err: int = config.save("user://settings.cfg")
	if err != OK:
		push_error("[ThemeManager] 保存主题选择失败，错误码: %s" % err)
