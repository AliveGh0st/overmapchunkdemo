# OvermapChunkDemo - 程序化地形生成系统
<img width="1338" height="500" alt="image" src="https://github.com/user-attachments/assets/3fa4f288-a674-42a0-bc60-f6d0958c1fa9" />
基于 Godot 4.x 的程序化地形生成项目，主要研究和实现多层地形生成算法和区块管理系统。项目参考了 Cataclysm: Dark Days Ahead 的地图生成思路。

## 系统架构

### 设计思路

采用了单例配置管理器来统一管理参数：
```gdscript
# AutoLoad 单例，便于全局访问配置
Config.terrain.TYPE_RIVER  # 地形类型配置
Config.render.CHUNK_SIZE   # 渲染参数配置
```

主要模块分工：
- `OvermapRenderer`: 地形生成和渲染
- `NoiseManager`: 噪声生成管理
- `ConfigManager`: 配置参数管理
- `OvermapPlayer`: 玩家控制
- `OvermapUI`: 调试信息显示

使用信号进行模块间通信：
```gdscript
signal chunk_generated(chunk_coord: Vector2i)
signal config_changed(category: String, key: String, value)
signal debug_mode_changed(enabled: bool)
```

### 项目结构

```
overmapchunkdemo/
├── 核心系统
│   ├── config_manager.gd      # 配置管理 (约600行)
│   ├── overmap_renderer.gd    # 地形生成引擎 (约2400行)
│   └── noise_manager.gd       # 噪声生成管理
├── 用户交互
│   ├── overmap_player.gd      # 玩家控制
│   └── overmap_ui.gd          # 调试界面
├── 场景资源
│   ├── overmap_system.tscn    # 主场景
│   └── assets/                # 瓦片集和纹理
└── 项目配置
    ├── project.godot          # Godot 项目设置
    ├── LICENSE                # MIT 许可证
    └── README.md              # 项目文档
```

## 地形生成算法实现

### 1. 河流生成 (River Generation)

使用随机游走算法，同时保证跨区块连续性：

```gdscript
# 河流路径生成的核心逻辑
func _draw_single_river_path(chunk_coord: Vector2i, start: Vector2i, end: Vector2i):
    var p2 = start
    while p2 != end:
        # 随机游走
        p2.x += randi_range(-1, 1)
        p2.y += randi_range(-1, 1)

        # 向目标点偏移
        if end.x > p2.x and probability_check():
            p2.x += 1
        # ... 其他方向的偏移逻辑

        # 应用河流笔刷，设置地形
        apply_river_brush(p2, river_scale)
```

实现要点：
- 检测相邻区块的河流边界，确保连接
- 用 `river_scale` 参数控制河流宽度
- 避免在湖泊位置生成河流

### 2. 湖泊生成 (Lake Generation)

基于噪声生成湖泊形状，然后用洪水填充算法确定连通区域：

```gdscript
# 四连通洪水填充算法
func _point_flood_fill_4_connected(start: Vector2i, visited: Dictionary, predicate: Callable) -> Array[Vector2i]:
    var filled_points: Array[Vector2i] = []
    var to_check: Array[Vector2i] = [start]

    while not to_check.is_empty():
        var current = to_check.pop_front()
        if visited.has(current) or not predicate.call(current):
            continue

        visited[current] = true
        filled_points.append(current)

        # 添加四个方向的邻居点
        for direction in [Vector2i(0,1), Vector2i(0,-1), Vector2i(1,0), Vector2i(-1,0)]:
            to_check.append(current + direction)

    return filled_points
```

实现细节：
- 用 Simplex 噪声确定湖泊的基础形状
- 过滤掉面积小于 `SIZE_MIN` 的水体
- 大型湖泊会自动连接到附近的河流
- 区分湖泊表面和湖岸两种地形

### 3. 森林生成 (Forest Generation)

采用双层噪声系统，支持方向性密度调整：

```gdscript
# 森林噪声计算
func forest_noise_at(world_pos: Vector2i) -> float:
    # 第一层：基础分布噪声
    var base = (noise_1.get_noise_2d(pos.x, pos.y) + 1.0) * 0.5
    base = pow(base, NOISE_1_POWER)

    # 第二层：密度减少噪声
    var density_reduction = (noise_2.get_noise_2d(pos.x, pos.y) + 1.0) * 0.5
    density_reduction = pow(density_reduction, NOISE_2_POWER)

    # 合成最终值
    return max(0.0, base - density_reduction * 0.5)
```

方向性密度调整：
```gdscript
# 根据世界坐标调整森林密度
func calculate_forestosity(chunk_coord: Vector2i):
    var forest_size_adjust = 0.0

    # 不同方向的增长率影响
    if chunk_coord.x < 0:  # 西方
        forest_size_adjust -= chunk_coord.x * INCREASE_WEST
    if chunk_coord.x > 0:  # 东方
        forest_size_adjust += chunk_coord.x * INCREASE_EAST
    # ... 北方和南方的处理类似

    # 限制森林覆盖率上限
    forest_size_adjust = min(forest_size_adjust, LIMIT - THRESHOLD)
```

### 4. 沼泽生成 (Swamp Generation)

模拟河流洪泛平原，在合适的位置生成沼泽：

```gdscript
# 河流洪泛平原计算
func _add_flood_buffer_fast(center: Vector2i, radius: int, floodplain: Dictionary):
    var radius_sq = radius * radius

    for x in range(center.x - radius, center.x + radius + 1):
        for y in range(center.y - radius, center.y + radius + 1):
            var distance_sq = (x - center.x) * (x - center.x) + (y - center.y) * (y - center.y)

            if distance_sq <= radius_sq:
                var point = Vector2i(x, y)
                floodplain[point] = floodplain.get(point, 0) + 1  # 记录被覆盖次数
```

生成逻辑：
- 每个河流点周围生成随机半径的洪泛缓冲区
- 根据洪泛次数和噪声值判断是否生成沼泽
- 只在森林地形上生成沼泽，符合生态逻辑

### 5. 城市生成 (City Generation)

参考L-System思路，用递归算法生成街道网络：

```gdscript
# 递归街道生成
func _build_city_street(start: Vector2i, length: int, direction: int, city: City):
    # 1. 规划街道路径
    var path = _lay_out_street(start, direction, length)

    # 2. 建造主干道
    _build_connection(path)

    # 3. 生成分支街道
    for i in range(1, path.size()):
        if should_branch(i, length):
            var left_length = length - randi_range(1, 3)
            var right_length = length - randi_range(1, 3)

            # 递归生成左右分支
            _build_city_street(path[i], left_length, turn_left(direction), city)
            _build_city_street(path[i], right_length, turn_right(direction), city)
```

建筑放置策略：
```gdscript
# 根据距离城市中心的远近选择建筑类型
func _pick_random_building_to_place(town_dist: int, town_size: int) -> Dictionary:
    var shop_normal = max(shop_radius, normal_distribution(shop_radius, shop_sigma))
    var park_normal = max(park_radius, normal_distribution(park_radius, park_sigma))

    if shop_normal > town_dist:
        return select_from_category("shops")
    elif park_normal > town_dist:
        return select_from_category("parks")
    else:
        return select_from_category("houses")
```

## 噪声系统

### 噪声管理器设计

使用统一的管理器来处理不同类型的噪声：

```gdscript
# 噪声管理器结构
class NoiseManager:
    var _noise_instances: Dictionary = {
        NoiseType.LAKE: FastNoiseLite,           # 湖泊形状
        NoiseType.FOREST_BASE: FastNoiseLite,    # 森林基础分布
        NoiseType.FOREST_DENSITY: FastNoiseLite, # 森林密度变化
        NoiseType.FLOODPLAIN: FastNoiseLite      # 洪泛平原
    }
```

### 噪声参数配置

不同噪声类型的参数设置：

| 类型 | 频率 | 倍频数 | 持续性 | 用途 |
|------|------|--------|--------|------|
| Lake | 0.002 | 8 | 0.5 | 湖泊边界 |
| Forest Base | 0.03 | 4 | 0.5 | 森林分布 |
| Forest Density | 0.07 | 6 | 0.5 | 森林密度 |
| Floodplain | 0.05 | 4 | 0.5 | 沼泽生成 |

## 性能优化

### 1. 渲染优化

只渲染可见区域，减少不必要的计算：

```gdscript
# 增量渲染实现
func update_canvas_rendering():
    var new_render_area = calculate_visible_area()

    if rendered_area != new_render_area:
        clear_tiles_outside_area(new_render_area)  # 清理视口外区域
        render_terrain_in_area(new_render_area)    # 只渲染新可见区域
        rendered_area = new_render_area
```

### 2. 区块生成控制

用冷却机制避免频繁生成：

```gdscript
# 冷却控制
var chunk_creation_cooldown: float = 0.0

func check_and_generate_chunks():
    if chunk_creation_cooldown > 0:
        return  # 冷却期内不生成

    # 执行生成逻辑...
    chunk_creation_cooldown = COOLDOWN_TIME
```

### 3. 数据缓存

- 地形数据：用 Dictionary 缓存已生成的地形
- TileMap：只在可见区域创建瓦片
- 噪声值：按需计算，不预存储

## 扩展性考虑

### 地形生成器接口

为了便于添加新地形类型，设计了基础接口：

```gdscript
# 地形生成器基类
class_name BaseTerrainGenerator

func generate(chunk_coord: Vector2i, terrain_data: Dictionary) -> void:
    # 子类实现具体生成逻辑
    pass

func get_priority() -> int:
    # 返回生成优先级
    return 0
```

### 运行时配置修改

支持在运行时调整参数：

```gdscript
# 动态配置修改
func set_runtime_config(key: String, value):
    runtime_config[key] = value
    config_changed.emit("runtime", key, value)

    # 处理特定配置的变更
    if key == "forest_size_adjust":
        recalculate_forest_regions()
```

## 使用说明

### 运行环境

- Godot 4.4 或更高版本
- 导入 `project.godot` 文件
- 运行 `overmap_system.tscn` 场景

## 实现特点

### 1. 跨区块连续性
用全局坐标系统和边界检测，确保地形特征（如河流）在区块边界处能够连接。

### 2. 分层地形生成
按以下顺序生成地形：
1. 基础地形（陆地）
2. 水系（河流、湖泊）
3. 植被（森林）
4. 湿地（沼泽）
5. 人工建筑（城市、道路）

### 3. 建筑分布
根据距离城市中心的远近来决定建筑类型，模拟现实城市的分区。

### 4. 方向性增长
森林和城市的密度会根据世界坐标进行方向性调整，形成自然的地理分布模式。

## 系统性能

经测试，在以下配置下运行良好：
- 最低：Godot 4.4, 2GB RAM
- 推荐：Godot 4.4+, 4GB RAM, 独立显卡
- 分辨率：1600x800 或更高
- 帧率：60fps 下可管理 9-25 个活跃区块

## 许可证

本项目使用 MIT 许可证，详情见 [LICENSE](LICENSE) 文件。

## 参考资料

- 灵感来源：[Cataclysm: Dark Days Ahead](https://github.com/CleverRaven/Cataclysm-DDA) 的 Overmap 系统
- 技术支持：Godot Engine
