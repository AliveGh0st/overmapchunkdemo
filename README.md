# Overmap Canvas渲染系统

这是一个使用Canvas渲染的连续地图系统，实现了180x180格子的渲染视窗，每个格子4px，使用绿色渲染。

## 功能特点

- **渲染视窗**: 180x180 格子（720x720 像素）
- **连续地图**: 无限扩展的世界地图，玩家可以无缝移动
- **智能区块生成**: 当玩家距离已生成区域边缘11格时自动生成新区块
  - 支持8个方向的区块生成（上下左右 + 四个对角线方向）
  - 确保对角线移动时不会出现未生成的区块
- **地形连续性**: 使用全局噪声生成器确保相邻区块间地形完全连续
- **Canvas渲染**: 每个格子4px，实时渲染
- **颜色方案**: 绿色地形，深绿色背景，红色玩家指示器
- **玩家闪烁**: 可配置的玩家标记闪烁效果，通过 `PLAYER_BLINK_ENABLED` 常量控制
- **闪烁问题修复**: 内置了 Godot 4.x TileMapLayer 闪烁问题的完整解决方案

## TileMap 闪烁问题解决方案

本项目解决了 Godot 4.x 中的 TileMapLayer 闪烁问题：

- ✅ **自动像素吸附配置** - 启用 "Snap 2D Transforms to Pixel" 项目设置
- ✅ **禁用纹理填充** - 防止纹理渗透和视觉故障
- ✅ **双图层架构** - 分离地形和玩家图层减少渲染冲突
- ✅ **优化纹理图案** - 使用更稳定的十字形图案替代细线
- ✅ **可控闪烁效果** - 通过常量控制玩家标记闪烁

详细信息请参考：[TILEMAP_FLICKERING_FIX.md](TILEMAP_FLICKERING_FIX.md)

## 核心文件

- `overmap_system.tscn` - 主场景文件
- `overmap_renderer.gd` - 连续地图渲染管理器，处理区块生成和Canvas绘制
- `overmap_player.gd` - 玩家控制器，支持WASD和方向键移动
- `overmap_ui.gd` - 调试UI，显示实时地图状态

## 使用方法

1. 在Godot中打开项目
2. 运行主场景 `overmap_system.tscn`
3. 使用WASD或方向键移动红色玩家方块
4. 地图会跟随玩家移动，当接近边缘时自动生成新区块

## 控制说明

- **WASD** 或 **方向键** - 移动玩家
- 玩家始终显示在画布中心，地图跟随玩家移动
- 左下角显示实时调试信息（玩家世界坐标、当前区块、已生成区块数）

## 配置选项

### 玩家闪烁控制
在 `overmap_renderer.gd` 文件中，你可以通过修改以下常量来控制玩家标记的闪烁效果：

```gdscript
const PLAYER_BLINK_ENABLED: bool = true  # 设为 false 可关闭玩家闪烁
const PLAYER_BLINK_INTERVAL: float = 0.1  # 闪烁间隔（秒）
```

- 设置 `PLAYER_BLINK_ENABLED = false` 可以关闭玩家闪烁，让玩家标记始终显示
- 设置 `PLAYER_BLINK_ENABLED = true` 启用闪烁效果，玩家标记会按设定间隔闪烁
- `PLAYER_BLINK_INTERVAL` 控制闪烁的速度，数值越小闪烁越快

### 森林方向性生成控制
在 `overmap_renderer.gd` 文件中新增了基于区块位置的森林密度调整功能，完全匹配Cataclysm DDA的森林生成系统：

```gdscript
# 森林方向增长率参数（对应CDDA的配置选项）
const OVERMAP_FOREST_INCREASE_NORTH: float = 0.01  # 北方向森林增长率
const OVERMAP_FOREST_INCREASE_EAST: float = 0.015  # 东方向森林增长率  
const OVERMAP_FOREST_INCREASE_WEST: float = 0.0   # 西方向森林增长率
const OVERMAP_FOREST_INCREASE_SOUTH: float = 0.0  # 南方向森林增长率
const OVERMAP_FOREST_LIMIT: float = 0.8           # 森林大小上限
```

#### 森林密度计算原理
- **方向性增长**: 不同方向的区块会根据增长率参数调整森林密度
- **距离影响**: 距离原点越远的区块，方向性效果越明显
- **北方/西方**: 负坐标区块，增长率乘以坐标的绝对值
- **南方/东方**: 正坐标区块，增长率直接乘以坐标值
- **上限保护**: 森林密度不会超过设定上限，防止地图被森林完全覆盖

#### 调试信息
游戏界面左下角的调试信息现在会显示当前区块的森林密度值，方便观察不同位置的森林生成效果。

## 技术实现

1. **连续世界**: 使用世界坐标系统，支持无限扩展
2. **动态区块生成**: 基于玩家位置自动生成180x180的区块
3. **Canvas渲染**: 渲染玩家周围180x180格子的区域
4. **地形生成**: 使用FastNoiseLite生成程序化地形，每个区块有独立的种子

## 系统特性

- **无缝移动**: 玩家在连续的世界中移动，没有传送或跳跃
- **智能区块管理**: 只在需要时生成新区块，避免性能浪费
- **内存保留**: 所有生成的区块保存在内存中，支持重复访问
- **实时渲染**: 地图跟随玩家实时更新，始终显示玩家周围的区域
