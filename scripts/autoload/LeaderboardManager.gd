## LeaderboardManager.gd - 排行榜单例
## 职责：持久化并维护两种模式的排行榜——通关榜（终极BOSS战用时升序）、登塔榜（层数降序）
## 继承：Node（作为全局单例运行）
## 设计意图：
##   1. 双榜独立：两个模式各有自己的榜与排序规则，互不影响（同一份存档文件分节存储）
##   2. 只留前 N 名：榜单长度恒定，避免存档无限膨胀；写入即排序，读取即成品
##   3. 数据与展示分离：本类只存数值与日期，格式化/分页/切换交给 LeaderboardPanel
## 数据流：终极BOSS被击败 → StageDirector 上报 BOSS 战用时 → record_classic_time()
##         玩家死亡 → Main 上报登塔层数 → record_tower_floor()
##         两者均写盘（user://leaderboard.cfg）→ LeaderboardPanel 读取展示
extends Node

## ========== 信号定义 ==========

## 榜单更新信号：任一榜单写入新记录后发出（排行榜界面若正打开可即时刷新）
signal leaderboard_updated

## ========== 调参常量 ==========

## 每个榜单保留的记录条数（用户定制：各10条）
const MAX_ENTRIES: int = 10

## 存档路径（与 settings.cfg 分文件存放，避免相互覆盖）
const SAVE_PATH: String = "user://leaderboard.cfg"

## 存档内的分节与键名（集中定义，避免拼写漂移）
const SECTION: String = "Leaderboard"
const KEY_CLASSIC: String = "classic_times"
const KEY_TOWER: String = "tower_floors"

## ========== 运行时数据（启动时从磁盘载入） ==========

## 通关榜记录：数组元素为 {time: float, date: String}，按 time 升序（用时越少越靠前）
var classic_times: Array = []

## 登塔榜记录：数组元素为 {floor: int, date: String}，按 floor 降序（层数越多越靠前）
var tower_floors: Array = []

## ========== 生命周期方法 ==========

## _ready() - 进入场景树时从磁盘载入两份榜单
func _ready() -> void:
	_load_from_disk()

## ========== 写入接口（供业务上报） ==========

## 上报一次通关成绩（终极BOSS战用时）
## 参数：seconds - 从终极BOSS登场到被击杀的用时（秒）
## 返回：本次成绩的排名（1~MAX_ENTRIES）；未进榜返回 0
func record_classic_time(seconds: float) -> int:
	var entry: Dictionary = {
		"time": maxf(seconds, 0.0),
		"date": _now_text(),
	}
	classic_times.append(entry)
	## 升序：用时少的排前面（通关榜的排序规则）
	classic_times.sort_custom(_sort_time_ascending)
	## 超出保留条数直接截断（截掉的是最慢的）
	if classic_times.size() > MAX_ENTRIES:
		classic_times.resize(MAX_ENTRIES)
	_save_to_disk()
	leaderboard_updated.emit()
	## 排名 = 在榜内位置 +1；已被截断则说明未进榜
	var rank: int = classic_times.find(entry) + 1
	print("[LeaderboardManager] 通关榜写入用时 %.1fs，排名 %d" % [seconds, rank])
	return rank

## 上报一次登塔成绩（玩家死亡时的最终层数）
## 参数：floor - 最终登塔层数（<1 视为未登塔，不记录）
## 返回：本次成绩的排名（1~MAX_ENTRIES）；未进榜返回 0
func record_tower_floor(floor: int) -> int:
	## 未登塔的局不计入登塔榜（通关模式死亡、难度10前死亡都走这里）
	if floor < 1:
		return 0
	var entry: Dictionary = {
		"floor": floor,
		"date": _now_text(),
	}
	tower_floors.append(entry)
	## 降序：层数多的排前面（登塔榜的排序规则）
	tower_floors.sort_custom(_sort_floor_descending)
	if tower_floors.size() > MAX_ENTRIES:
		tower_floors.resize(MAX_ENTRIES)
	_save_to_disk()
	leaderboard_updated.emit()
	var rank: int = tower_floors.find(entry) + 1
	print("[LeaderboardManager] 登塔榜写入第 %d 层，排名 %d" % [floor, rank])
	return rank

## ========== 查询接口（供排行榜界面读取） ==========

## 获取通关榜记录（按用时升序）
## 返回：数组副本（元素 {time: float, date: String}），调用方修改不影响存档
func get_classic_times() -> Array:
	return classic_times.duplicate(true)

## 获取登塔榜记录（按层数降序）
## 返回：数组副本（元素 {floor: int, date: String}），调用方修改不影响存档
func get_tower_floors() -> Array:
	return tower_floors.duplicate(true)

## 获取通关榜最佳用时（用于界面显示"历史最佳"）
## 返回：最佳用时（秒）；榜单为空返回 -1.0
func get_best_classic_time() -> float:
	if classic_times.is_empty():
		return -1.0
	return float(classic_times[0].get("time", 0.0))

## 获取登塔榜最高层数
## 返回：最高层数；榜单为空返回 0
func get_best_tower_floor() -> int:
	if tower_floors.is_empty():
		return 0
	return int(tower_floors[0].get("floor", 0))

## 将秒数格式化为排行榜展示文本
## 参数：seconds - 用时（秒）
## 返回：如"1分23秒"
func format_time(seconds: float) -> String:
	var minutes: int = int(seconds) / 60
	var secs: int = int(seconds) % 60
	return "%d分%02d秒" % [minutes, secs]

## ========== 内部方法 ==========

## 升序比较器：用时少的排前面
static func _sort_time_ascending(a: Dictionary, b: Dictionary) -> bool:
	return float(a.get("time", 0.0)) < float(b.get("time", 0.0))

## 降序比较器：层数多的排前面
static func _sort_floor_descending(a: Dictionary, b: Dictionary) -> bool:
	return int(a.get("floor", 0)) > int(b.get("floor", 0))

## 生成当前系统日期文本（记录成绩产生时间，便于玩家区分同名成绩）
func _now_text() -> String:
	var dt: Dictionary = Time.get_datetime_dict_from_system()
	return "%04d-%02d-%02d %02d:%02d" % [dt.year, dt.month, dt.day, dt.hour, dt.minute]

## 从 user://leaderboard.cfg 载入两份榜单
## 容错：文件不存在/字段缺失/类型不符时一律回退为空榜（首次启动的正常路径）
func _load_from_disk() -> void:
	var config: ConfigFile = ConfigFile.new()
	var err: int = config.load(SAVE_PATH)
	if err != OK:
		classic_times = []
		tower_floors = []
		return
	classic_times = _sanitize_times(config.get_value(SECTION, KEY_CLASSIC, []))
	tower_floors = _sanitize_floors(config.get_value(SECTION, KEY_TOWER, []))

## 清洗通关榜数据：过滤非法元素并重新排序截断
## 参数：raw - 存档读出的原始值（可能不是数组或元素结构不符）
## 返回：合法的通关榜数组
func _sanitize_times(raw: Variant) -> Array:
	var result: Array = []
	if raw is Array:
		for item in raw:
			if item is Dictionary and item.has("time"):
				result.append({
					"time": float(item["time"]),
					"date": str(item.get("date", "")),
				})
	result.sort_custom(_sort_time_ascending)
	if result.size() > MAX_ENTRIES:
		result.resize(MAX_ENTRIES)
	return result

## 清洗登塔榜数据：过滤非法元素并重新排序截断
## 参数：raw - 存档读出的原始值（可能不是数组或元素结构不符）
## 返回：合法的登塔榜数组
func _sanitize_floors(raw: Variant) -> Array:
	var result: Array = []
	if raw is Array:
		for item in raw:
			if item is Dictionary and item.has("floor"):
				result.append({
					"floor": int(item["floor"]),
					"date": str(item.get("date", "")),
				})
	result.sort_custom(_sort_floor_descending)
	if result.size() > MAX_ENTRIES:
		result.resize(MAX_ENTRIES)
	return result

## 将两份榜单写入 user://leaderboard.cfg
func _save_to_disk() -> void:
	var config: ConfigFile = ConfigFile.new()
	config.set_value(SECTION, KEY_CLASSIC, classic_times)
	config.set_value(SECTION, KEY_TOWER, tower_floors)
	config.save(SAVE_PATH)
