## ArenaConfig.gd - 梦境竞技场（固定大小战场）全局配置
## 职责：集中定义竞技场尺寸、物理墙碰撞层位、边缘预警参数，供场景与各系统共用
## 设计意图：墙体坐标（GameWorld.tscn）、相机限制（Player.tscn Camera2D）、
##           刷怪/Boss出生点钳制（GameWorld/StageDirector）、边缘红光（GameWorld）
##           全部引用同一常量，调整战场大小时只改此文件，避免多处魔法数字漂移
## 用法：const ArenaConfigClass = preload("res://scripts/world/ArenaConfig.gd")
##       常量直接 ArenaConfigClass.HALF_WIDTH 访问；静态函数 ArenaConfigClass.clamp_inside(...)
extends RefCounted

## ========== 竞技场尺寸（1920×1280视口的3×3屏，固定矩形战场，禁止无限地图） ==========

## 竞技场总宽度（像素）= 3个屏幕宽
const ARENA_WIDTH: float = 5760.0

## 竞技场总高度（像素）= 3个屏幕高
const ARENA_HEIGHT: float = 3840.0

## 半宽：中心原点到左右墙的距离（x∈[-2880,2880]）
const HALF_WIDTH: float = ARENA_WIDTH * 0.5

## 半高：中心原点到上下墙的距离（y∈[-1920,1920]）
const HALF_HEIGHT: float = ARENA_HEIGHT * 0.5

## 物理墙厚度（像素，墙中心线与竞技场边界重合，各向内/外突出一半）
const WALL_THICKNESS: float = 40.0

## ========== 碰撞层位约定（与 project 物理层规划一致） ==========

## 世界墙所在层：bit5=16（1=玩家 / 2=敌人 / 4=玩家子弹 / 8=敌人子弹&拾取物 / 16=世界墙）
const LAYER_WORLD: int = 16

## 角色移动碰撞掩码：玩家层1 + 敌人层2 + 世界墙层16 = 19
## 玩家(CharacterBody2D)与敌人(CharacterBody2D)均使用此掩码——被墙挡住且保持敌人间互挤；
## 子弹/拾取物/伤害Area的掩码(1/2/8)不含16，对墙完全无感知（不会撞墙销毁/误触发）
const MASK_ENTITY_BLOCKING: int = 1 | 2 | LAYER_WORLD

## 远距休眠敌人的碰撞掩码：仅保留世界墙16
## 休眠目的是消除O(n²)敌人间窄相解算（互挤+玩家碰撞），4堵静态墙是O(1)常量成本可保留；
## 否则被击退弹飞到墙外的敌人唤醒后会被物理墙永久隔在场外，无法回到场内追击玩家
const MASK_DORMANT: int = LAYER_WORLD

## ========== 边缘红光预警（玩家接近物理墙时屏幕四边泛红） ==========

## 触发预警的距离：玩家距最近一面墙小于此值（像素）时开始泛红
const WARN_DISTANCE: float = 200.0

## 预警最大透明度（贴墙时 alpha 上限 0.5，既能警示又不遮挡战斗可读性）
const WARN_MAX_ALPHA: float = 0.5

## ========== 工具函数 ==========

## 将任意世界坐标钳制在竞技场矩形内（并预留 margin 的安全边距）
## 用途：敌人/Boss出生点必须落在墙内，防止生成在墙外被墙永久隔开
## 参数：point - 期望坐标；margin - 距墙的最小内缩像素
## 返回：钳制后的合法坐标
static func clamp_inside(point: Vector2, margin: float = 0.0) -> Vector2:
	return Vector2(
		clampf(point.x, -HALF_WIDTH + margin, HALF_WIDTH - margin),
		clampf(point.y, -HALF_HEIGHT + margin, HALF_HEIGHT - margin)
	)
