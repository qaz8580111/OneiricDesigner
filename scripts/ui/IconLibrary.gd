## IconLibrary.gd - 图标资源统一加载库（静态工具类，无需实例化）
## 职责：按"文件名契约"自动加载技能/装备/敌人掉落物图标，UI 层只管要图标、不关心路径组织
## 命名契约（新增图标零代码的核心）：
##   路径 = assets/art/ui/icons/<目录名>/icon_<资源id>.png
##   目录名由类型/稀有度映射：普通=白色普通、稀有=蓝色稀有、史诗=紫色史诗、
##   护盾装备=灰色护盾、敌人掉落物=敌人掉落（掉落物 item_id 经 DROP_ICON_MAP 映射到文件名）
## 使用场景：LevelUpPanel（三选一卡片）、GameHUD（buff图标/护盾显示）、PickUp（掉落物贴图）
## 数据流：调用方传入 upgrade_id/shield_id/item_id → 本类拼路径 → load() → 缓存后返回
## 设计意图：
##   1. 约定优于配置：只要 png 按 icon_<id>.png 命名放进对应目录，UI 自动显示，无需改任何 .tres/代码
##   2. 容错兜底：图标缺失时返回 null，调用方回退到原有文字/色块显示（游戏永不因缺图报错）
##   3. 双缓存：正缓存存已加载纹理；负缓存记录"确认不存在"的路径，
##      避免每次刷新都重复 file_exists 磁盘查询（buff栏升级时会高频刷新）
class_name IconLibrary
extends RefCounted

## ========== 路径契约常量 ==========

## 图标根目录
const BASE_PATH: String = "res://assets/art/ui/icons"

## 稀有度枚举值 → 图标子目录名（目录改名需同步此处）
## 键与 UpgradeData.Rarity 枚举对齐：0=普通 1=稀有 2=史诗
const RARITY_FOLDERS: Dictionary = {
	0: "白色普通",
	1: "蓝色稀有",
	2: "紫色史诗",
}

## 护盾装备图标子目录名（装备无稀有度维度，独立目录）
const SHIELD_FOLDER: String = "灰色护盾"

## 敌人掉落物图标子目录名（碎片/血包/技能书等消耗品）
const DROP_FOLDER: String = "敌人掉落"

## 掉落物 item_id → 图标文件名（不含扩展名）映射表
## 设计意图：item_id 与美术文件名按英文语义对应但不完全同名（如 fragment_small → icon_fragments_small，
##           精英怪变体 elite_* 共用同一张大图），故用映射表做"按英文自动适配"的唯一登记点；
##           新增掉落物种类时：美术放 icon_xxx.png 到"敌人掉落"目录 + 本表加一行，零代码改动
## 取值来源：Enemy._generate_default_drops() 动态生成的 item_id，以及 data/items/*.tres 的预留 id
const DROP_ICON_MAP: Dictionary = {
	## 梦境碎片：小碎片用小图；中碎片/精英碎片共用大图（大小掉落从图标尺寸上也能区分）
	"fragment_small": "icon_fragments_small",
	"fragment_medium": "icon_fragments_big",
	"elite_fragment": "icon_fragments_big",
	## 血包：普通小血包/精英大血包（回复量不同，图标大小区分）
	"health_small": "icon_blood_small",
	"elite_health": "icon_blood_big",
	## 随机技能书：普通怪与精英怪的即时技能奖励共用技能图标
	"buff_attack": "icon_skill",
	"elite_buff_attack": "icon_skill",
}

## ========== 静态缓存 ==========

## 正缓存：路径 → 已加载的 Texture2D（load()本身有引擎级缓存，此处主要省路径拼接与查询）
static var _cache: Dictionary = {}

## 负缓存：确认不存在的路径集合（值为 true），命中直接返回 null 不再查盘
static var _miss_cache: Dictionary = {}

## ========== 对外接口 ==========

## 获取升级词条图标（三选一卡片 / HUD buff 图标共用）
## 参数：upgrade_id - 词条唯一标识（如 "upg_damage"）；rarity - 稀有度枚举值（决定子目录）
## 返回：图标纹理；图标缺失或 id 为空时返回 null（调用方自行回退文字显示）
static func get_upgrade_icon(upgrade_id: String, rarity: int) -> Texture2D:
	## 空id直接失败（新词条未配id时不炸）
	if upgrade_id.is_empty():
		return null
	## 按稀有度映射子目录（未知稀有度回退普通目录，保证总有合法路径）
	var folder: String = RARITY_FOLDERS.get(rarity, "白色普通")
	return _load_icon("%s/%s/icon_%s.png" % [BASE_PATH, folder, upgrade_id])

## 获取护盾装备图标（掉落物贴图用）
## 参数：shield_id - 护盾唯一标识（如 "shield_basic"）
## 返回：图标纹理；缺失或 id 为空时返回 null（调用方回退占位色块）
static func get_shield_icon(shield_id: String) -> Texture2D:
	if shield_id.is_empty():
		return null
	return _load_icon("%s/%s/icon_%s.png" % [BASE_PATH, SHIELD_FOLDER, shield_id])

## 获取敌人掉落物图标（碎片/血包/技能书贴图用）
## 参数：item_id - 掉落物唯一标识（DropItem.item_id，如 "fragment_small"）
## 返回：图标纹理；id 未登记映射或图标文件缺失时返回 null（调用方回退占位色块）
static func get_drop_icon(item_id: String) -> Texture2D:
	if item_id.is_empty():
		return null
	## 经映射表把 item_id 翻译成美术图标文件名（未登记的 id 视为无图标，如预留的 WEAPON/ITEM 类）
	var icon_name: String = DROP_ICON_MAP.get(item_id, "")
	if icon_name.is_empty():
		return null
	return _load_icon("%s/%s/%s.png" % [BASE_PATH, DROP_FOLDER, icon_name])

## ========== 内部方法 ==========

## 统一加载入口：正/负缓存 + 文件存在性检查 + load
## 参数：path - 完整 res:// 图标路径
## 返回：纹理或 null
static func _load_icon(path: String) -> Texture2D:
	## 正缓存命中：直接返回（零查询开销）
	if _cache.has(path):
		return _cache[path]
	## 负缓存命中：已知不存在，直接返回 null（避免高频刷新重复查盘）
	if _miss_cache.has(path):
		return null
	## 文件不存在：记入负缓存（某词条没做图是常态，只查一次盘）
	if not FileAccess.file_exists(path):
		_miss_cache[path] = true
		return null
	## 正式加载并写入正缓存（load 失败返回 null 时也记负缓存，防反复报错刷屏）
	var tex: Texture2D = load(path) as Texture2D
	if tex == null:
		_miss_cache[path] = true
	else:
		_cache[path] = tex
	return tex
