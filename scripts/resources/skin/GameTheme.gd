## GameTheme.gd - 游戏主题包资源类（"一键换肤"的载体）
## 职责：把一套完整的视觉风格打包成一个 .tres 文件——玩家皮肤 + 全部敌人皮肤 + 世界背景色
## 继承：Resource（在 data/themes/ 下每个主题一个 .tres，皮肤作为 SubResource 内嵌其中）
## 使用场景：
##   - 制作新主题：复制一份现有主题 .tres → 改名字/颜色/形状 → 完成（无需改任何代码）
##   - 切换主题：设置界面下拉选择 / ThemeManager.set_theme("主题id") → 全场角色即时换肤
## 被引用方：ThemeManager（扫描/加载/分发）、GameWorld（背景色）、Player/Enemy（取皮肤）
## 查找规则（get_enemy_skin）：
##   1. enemy_skins 中按 enemy_id 精确匹配（如 "slime" → 史莱姆专属皮肤）
##   2. 未配置的敌人 → 使用 default_enemy_skin 兜底（保证任何敌人在任何主题下都有外观）
##   3. 两者都没有 → 返回 null，Player/Enemy 回退到各自的占位纹理（绝对不崩）
class_name GameTheme
extends Resource

## ========== 预加载资源（避免全局类名解析失败） ==========
## 设计意图：本项目曾出现"Could not find type CharacterSkin in the current scope"解析错误
## （autoload 启动早期全局类缓存未就绪时会连锁失败：GameTheme 编译失败 →
##   ThemeManager 编译失败 → Player/Enemy 编译失败 → 角色全部隐形）。
## 教训：脚本链内部一律用 preload 路径常量引用依赖类，class_name 只留给编辑器/.tres 使用
const CharacterSkinClass = preload("res://scripts/resources/skin/CharacterSkin.gd")

## ========== 主题标识 ==========

## 主题唯一标识（settings.cfg 持久化用；文件名建议与此一致，如 dream.tres → "dream"）
@export var theme_id: String = "default"

## 主题显示名（设置界面下拉框展示，可直接用中文）
@export var theme_name: String = "默认主题"

## ========== 角色皮肤 ==========

## 玩家皮肤（null 时玩家回退蓝色占位方块）
@export var player_skin: CharacterSkinClass = null

## 敌人兜底皮肤（所有未在 enemy_skins 中单独配置的敌人都用它）
@export var default_enemy_skin: CharacterSkinClass = null

## 敌人专属皮肤表：key = enemy_id（对应 data/enemy/*.tres 中的 enemy_id 字段，
## 如 "slime"/"archer"/"tank"/"elite_001"...），value = CharacterSkin
## 只需要给"想与兜底皮肤区分"的敌人配置，其余自动走 default_enemy_skin
@export var enemy_skins: Dictionary = {}

## ========== 世界外观 ==========

## 世界背景色（主题切换时同步到 GameWorld 的 BgLayer/Background 与引擎清屏色，
## 让整个"世界氛围"随主题一起换——不只是角色换色）
@export var bg_color: Color = Color(0.1, 0.1, 0.15, 1)

## 地面网格次线颜色（含alpha；ArenaBackground/LayerGrid 视差网格shader的64px小格线，随主题换色）
## alpha 建议 0.35~0.5：太亮抢眼、太暗失去空间参照作用；整体必须极暗（参照物不抢实体）
@export var grid_color: Color = Color(0.20, 0.19, 0.27, 0.45)

## 地面网格主线颜色（含alpha；512px(每8格)一条的尺度线，比次线亮一档形成层次）
@export var grid_major_color: Color = Color(0.27, 0.26, 0.36, 0.65)

## 可选远景背景纹理（null=纯色+三层视差；非null时在BgLayer平铺填充作为最远屏幕固定层）
## 使用方式：把无缝平铺图（seamless tile）放入 assets/art/bg/，在主题.tres中
## 拖入本字段即可，无需改代码；TextureRect 自动 TILE 平铺铺满屏幕（屏幕固定层，
## 星云/碎片/网格三层视差在其上按0.2/0.5/1.0速率跟随相机——共同构成纵深）
@export var bg_texture: Texture2D = null

## ========== 核心方法 ==========

## 获取指定敌人的皮肤（精确匹配 → 兜底皮肤 → null）
## 参数：enemy_id - 敌人唯一标识（EnemyData.enemy_id）
## 返回：CharacterSkin 或 null（null 时调用方回退占位纹理）
func get_enemy_skin(enemy_id: String) -> CharacterSkinClass:
	## 优先：按 enemy_id 精确匹配专属皮肤
	if enemy_skins.has(enemy_id):
		var skin: Variant = enemy_skins[enemy_id]
		## 类型校验：字典内容可能是编辑器误配的其他资源，只信任 CharacterSkin
		if skin is CharacterSkinClass:
			return skin
	## 兜底：默认敌人皮肤
	return default_enemy_skin
