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
	## 梦境碎片：小碎片用小图；中碎片/精英碎片/Boss碎片共用大图（大小掉落从图标尺寸上也能区分）
	"fragment_small": "icon_fragments_small",
	"fragment_medium": "icon_fragments_big",
	"elite_fragment": "icon_fragments_big",
	"boss_fragment": "icon_fragments_big",
	## 血包：普通小血包/精英大血包/Boss大血包（回复量不同，图标大小区分）
	"health_small": "icon_blood_small",
	"elite_health": "icon_blood_big",
	"boss_health": "icon_blood_big",
	## 特效技能书：普通怪与精英怪/Boss 的即时技能奖励共用技能图标
	## 设计意图：技能书已拆分为"特效技能"与"属性技能"两类掉落，
	##           本组 id 统一映射 icon_skill，拾取后只展示特效技能三选一
	"buff_attack": "icon_skill",
	"elite_buff_attack": "icon_skill",
	"boss_buff": "icon_skill",
	## 属性技能书：拾取后只展示属性技能三选一（与特效技能掉落完全分离）
	"buff_attribute": "icon_AS",
	## 弹道构型书：拾取后只展示弹道构型三选一（构型不叠层，选定即替换当前弹道）
	"shot_pattern": "icon_BC",
	## 护盾掉落：基础/特效护盾在地面掉落物阶段统一显示同一张"基础护盾"图标
	## 设计意图：掉落物只需告知玩家"这是一个护盾"，具体护盾种类由拾取后的三选一决定，
	##           故 4 种护盾 id 全部映射到 icon_shield_basic（不再显示各特效护盾专属图标）
	"shield_basic": "icon_shield_basic",
	"shield_poison": "icon_shield_basic",
	"shield_frost": "icon_shield_basic",
	"shield_reflect": "icon_shield_basic",
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

## 获取护盾装备图标（HUD护盾栏 / 暂停菜单装备展示用，不再用于地面掉落物）
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

## 统一加载入口：正/负缓存 + 文件存在性检查 + load + Image兜底
## 参数：path - 完整 res:// 图标路径
## 返回：纹理或 null
## 加载策略（两层兜底）：
##   1. 先走 Godot 的 load()（依赖 .ctex 导入产物，引擎级缓存、GPU 友好）
##   2. load 失败时用 Image.load() 直接读 PNG 像素数据 → ImageTexture.create_from_image()
##      （绕开导入链路，适合 .import/.ctex 失步的紧急修复；性能略低但能跑）
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
		print("[IconLibrary] MISS (file_not_found): ", path)
		return null
	## 第一层：Godot 标准 load() 依赖 .ctex 导入产物
	var tex: Texture2D = load(path) as Texture2D
	if tex != null:
		_cache[path] = tex
		return tex
	## 第二层兜底：直接从 PNG 像素数据构造纹理（绕过导入链路）
	## 适用场景：.import/.ctex 失步或完全缺失时，确保掉落物能显示图标而不是色块
	var img: Image = Image.new()
	var err: Error = img.load(path)
	if err == OK and img.get_data() != null:
		## 确保格式为 RGBA8（ImageTexture 要求有 alpha 通道才能正常透明渲染）
		if img.get_format() != Image.FORMAT_RGBA8:
			img.convert(Image.FORMAT_RGBA8)
		tex = ImageTexture.create_from_image(img)
		if tex != null:
			_cache[path] = tex
			print("[IconLibrary] FALLBACK Image.load() OK: ", path, " size=", img.get_width(), "x", img.get_height())
			return tex
	## 彻底失败：记入负缓存，打印诊断日志便于排查 PNG 格式问题
	_miss_cache[path] = true
	print("[IconLibrary] FAIL (load + Image.load both null): ", path, " Image.load err=", err)
	return tex
