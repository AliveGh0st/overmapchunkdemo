extends Node

## 统一配置管理器 - 使用AutoLoad模式
## 管理项目中所有的配置常量，提供类型安全的访问方式
## 使用Godot最佳实践：单例模式 + 资源系统 + 信号通知

# ============================================================================
# 核心渲染配置
# ============================================================================
class RenderConfig:
	## 地图渲染核心配置
	const TILE_SIZE: int = 16  ## 每个瓦片的像素大小
	const CHUNK_SIZE: int = 180  ## 地图区块大小（每个区块的格子数量）
	const BORDER_THRESHOLD: int = 11  ## 触发新区块生成的边界阈值
	
	## TileSet 资源配置
	const USE_EXTERNAL_TILESET: bool = false  ## 是否使用外部 TileSet 资源
	const TERRAIN_TILESET_PATH: String = "res://assets/tilesets/terrain_tileset.tres"  ## 地形 TileSet 路径
	const PLAYER_TILESET_PATH: String = "res://assets/tilesets/player_tileset.tres"  ## 玩家标记 TileSet 路径

# ============================================================================
# 地形系统配置
# ============================================================================
class TerrainConfig:
	## 地形类型定义
	const TYPE_EMPTY: int = 0
	const TYPE_LAND: int = 1
	const TYPE_RIVER: int = 2
	const TYPE_LAKE_SURFACE: int = 3
	const TYPE_LAKE_SHORE: int = 4
	const TYPE_FOREST: int = 5
	const TYPE_FOREST_THICK: int = 6
	const TYPE_SWAMP: int = 7
	const TYPE_ROAD: int = 8           ## 道路地形
	const TYPE_CITY_TILE: int = 9      ## 城市瓦片地形
	
	## 地形类型到TileSet瓦片ID的映射
	const TERRAIN_TO_TILE_ID: Dictionary = {
		TYPE_EMPTY: -1,
		TYPE_LAND: 0,
		TYPE_RIVER: 1,
		TYPE_LAKE_SURFACE: 2,
		TYPE_LAKE_SHORE: 3,
		TYPE_FOREST: 4,
		TYPE_FOREST_THICK: 5,
		TYPE_SWAMP: 6,
		TYPE_ROAD: 7,
		TYPE_CITY_TILE: 8
	}

# ============================================================================
# 颜色方案配置
# ============================================================================
class ColorConfig:
	## 基于CDDA终端风格的颜色配置
	const TERRAIN_COLOR: Color = Color.YELLOW
	const PLAYER_COLOR: Color = Color.RED
	const RIVER_COLOR: Color = Color.BLUE
	const LAKE_SURFACE_COLOR: Color = Color.BLUE
	const LAKE_SHORE_COLOR: Color = Color.DARK_GRAY
	const FOREST_COLOR: Color = Color.DARK_GREEN
	const FOREST_THICK_COLOR: Color = Color.FOREST_GREEN
	const SWAMP_COLOR: Color = Color(0.4, 0.6, 0.3, 1.0)
	const ROAD_COLOR: Color = Color.GRAY       ## 道路颜色
	const CITY_COLOR: Color = Color.WHITE      ## 城市建筑颜色

# ============================================================================
# 玩家配置
# ============================================================================
class PlayerConfig:
	## 玩家控制和显示配置
	const MOVEMENT_SPEED: float = 320.0  ## 移动速度（像素/秒）
	const GRID_ALIGNED: bool = true  ## 是否启用格子对齐
	
	## 玩家标记闪烁效果
	const BLINK_ENABLED: bool = true
	const BLINK_INTERVAL: float = 0.1  ## 闪烁间隔时间（秒）

# ============================================================================
# 河流生成配置
# ============================================================================
class RiverConfig:
	## 河流生成系统参数
	const DENSITY_PARAM: int = 1  ## 河流密度参数，对应C++版本的river_scale

# ============================================================================
# 湖泊生成配置
# ============================================================================
class LakeConfig:
	## 湖泊生成系统参数
	const NOISE_THRESHOLD: float = 0.25  ## 湖泊生成的噪声阈值
	const SIZE_MIN: int = 20  ## 湖泊最小尺寸
	const RIVER_CONNECTION_MIN_SIZE: int = 65  ## 湖泊连接河流的最小尺寸阈值
	const DEPTH: int = -5  ## 湖泊深度（Z轴层级）
	
	## 湖泊噪声生成参数
	const NOISE_OCTAVES: int = 8
	const NOISE_PERSISTENCE: float = 0.5
	const NOISE_SCALE: float = 0.002
	const NOISE_POWER: float = 4.0

# ============================================================================
# 森林生成配置
# ============================================================================
class ForestConfig:
	## 森林生成阈值
	const NOISE_THRESHOLD_FOREST: float = 0.25
	const NOISE_THRESHOLD_FOREST_THICK: float = 0.3
	
	## 森林方向增长率参数
	const INCREASE_NORTH: float = 0.04
	const INCREASE_EAST: float = 0.0
	const INCREASE_WEST: float = 0.02
	const INCREASE_SOUTH: float = 0.0
	const LIMIT: float = 0.395  ## 森林大小上限
	
	## 第一层噪声参数（基础分布）
	const NOISE_1_OCTAVES: int = 4
	const NOISE_1_PERSISTENCE: float = 0.5
	const NOISE_1_SCALE: float = 0.03
	const NOISE_1_POWER: float = 2.0
	
	## 第二层噪声参数（密度减少效果）
	const NOISE_2_OCTAVES: int = 6
	const NOISE_2_PERSISTENCE: float = 0.5
	const NOISE_2_SCALE: float = 0.07
	const NOISE_2_POWER: float = 3.0

# ============================================================================
# 沼泽生成配置
# ============================================================================
class SwampConfig:
	## 河流洪泛平原缓冲区距离范围（以格子为单位）
	const RIVER_FLOODPLAIN_BUFFER_DISTANCE_MIN: int = 3
	const RIVER_FLOODPLAIN_BUFFER_DISTANCE_MAX: int = 15
	
	## 沼泽生成噪声阈值
	const NOISE_THRESHOLD_ADJACENT_WATER: float = 0.3  # 河流邻近沼泽阈值
	const NOISE_THRESHOLD_ISOLATED: float = 0.6        # 独立沼泽阈值
	
	## 性能优化参数
	const ENABLE_PERFORMANCE_OPTIMIZATIONS: bool = true  # 启用性能优化
	const RIVER_SEARCH_RADIUS_OPTIMIZATION: bool = true  # 优化河流搜索半径
	const ENABLE_PERFORMANCE_LOGGING: bool = false       # 启用性能统计日志
	
	## 洪泛平原噪声参数（对应C++的om_noise_layer_floodplain）
	const FLOODPLAIN_NOISE_OCTAVES: int = 4      ## 噪声倍频数
	const FLOODPLAIN_NOISE_PERSISTENCE: float = 0.5 ## 噪声持续性
	const FLOODPLAIN_NOISE_SCALE: float = 0.05     ## 噪声缩放比例
	const FLOODPLAIN_NOISE_POWER: float = 2.0      ## 幂运算系数

# ============================================================================
# 城市生成配置
# ============================================================================
class CityConfig:
	## 城市间距和大小参数（对应C++中的配置选项）
	const CITY_SPACING: int = 3               ## 城市间距配置值（降低以增加城市数量）
	const CITY_SIZE: int = 12                 ## 基础城市大小
	const OVERMAP_MAXIMUM_URBANITY: int = 8  ## 最大城市化程度乘数
	
	## 城市化程度增长参数（对应C++的城市化方向增长）
	const URBAN_INCREASE_NORTH: int = 0      ## 北方向城市化增长值
	const URBAN_INCREASE_EAST: int = 10       ## 东方向城市化增长值
	const URBAN_INCREASE_WEST: int = 0       ## 西方向城市化增长值
	const URBAN_INCREASE_SOUTH: int = 5      ## 南方向城市化增长值
	
	## 城市生成约束
	const MAX_PLACEMENT_ATTEMPTS: int = 50   ## 最大放置尝试次数
	const MIN_CITY_SIZE: int = 2             ## 最小城市大小
	const MAX_CITY_SIZE: int = 55            ## 最大城市大小
	const BUILDING_CHANCE: int = 4           ## 建筑生成概率 (1/4 = 25%)
	
	## 城市生成概率参数
	const TINY_CITY_CHANCE: int = 3          ## 生成微小城市的概率 (1/3)
	const SMALL_CITY_CHANCE: int = 2         ## 生成小城市的概率 (1/2)
	const LARGE_CITY_CHANCE: int = 2         ## 生成大城市的概率 (1/2)
	# 其余为大型城市 (17%)
	
	## 城市大小调整系数
	const TINY_SIZE_MULTIPLIER: float = 1.0 / 3.0     ## 微小城市大小倍数
	const SMALL_SIZE_MULTIPLIER: float = 2.0 / 3.0    ## 小城市大小倍数
	const LARGE_SIZE_MULTIPLIER: float = 3.0 / 2.0    ## 大城市大小倍数
	const HUGE_SIZE_MULTIPLIER: float = 2.0           ## 超大城市大小倍数
	
	## 商店和公园分布参数（对应C++的city_settings）
	const SHOP_RADIUS: int = 30               ## 商店分布半径（增大以覆盖更多区域）
	const PARK_RADIUS: int = 20               ## 公园分布半径（增大以覆盖更多区域）
	const SHOP_SIGMA: int = 50                ## 商店分布标准差（合理的变化范围）
	const PARK_SIGMA: int = 80                ## 公园分布标准差（合理的变化范围）
	
	## 建筑类型定义
	static func get_building_types() -> Dictionary:
		return {
			"houses": [
				{"id": "house_small", "size": Vector2i(1, 1), "city_unique": false, "globally_unique": false},
				{"id": "house_medium", "size": Vector2i(2, 2), "city_unique": false, "globally_unique": false},
				{"id": "house_large", "size": Vector2i(3, 3), "city_unique": false, "globally_unique": false}
			],
			"shops": [
				{"id": "shop_general", "size": Vector2i(2, 2), "city_unique": false, "globally_unique": false},
				{"id": "shop_supermarket", "size": Vector2i(3, 3), "city_unique": true, "globally_unique": false},
				{"id": "shop_mall", "size": Vector2i(5, 5), "city_unique": true, "globally_unique": true}
			],
			"parks": [
				{"id": "park_small", "size": Vector2i(2, 2), "city_unique": false, "globally_unique": false},
				{"id": "park_medium", "size": Vector2i(3, 3), "city_unique": false, "globally_unique": false},
				{"id": "park_large", "size": Vector2i(4, 4), "city_unique": true, "globally_unique": false}
			]
		}

# ============================================================================
# 性能优化配置
# ============================================================================
class PerformanceConfig:
	## 区块创建优化
	const CHUNK_CREATION_COOLDOWN_TIME: float = 0.1  ## 区块创建冷却时间（秒）

# ============================================================================
# 配置管理器实例
# ============================================================================

## 配置分类实例
var render: RenderConfig = RenderConfig.new()
var terrain: TerrainConfig = TerrainConfig.new()
var colors: ColorConfig = ColorConfig.new()
var player: PlayerConfig = PlayerConfig.new()
var river: RiverConfig = RiverConfig.new()
var lake: LakeConfig = LakeConfig.new()
var forest: ForestConfig = ForestConfig.new()
var swamp: SwampConfig = SwampConfig.new()
var city: CityConfig = CityConfig.new()
var performance: PerformanceConfig = PerformanceConfig.new()

# ============================================================================
# 动态配置支持
# ============================================================================

## 可在运行时修改的配置
var runtime_config: Dictionary = {
	"debug_mode": false,
	"forest_size_adjust": 0.0,
	"forestosity": 0.0,
	"custom_seed": 0
}

# ============================================================================
# 信号定义
# ============================================================================

## 配置更改时发出的信号
signal config_changed(category: String, key: String, value)
signal debug_mode_changed(enabled: bool)

# ============================================================================
# 初始化和配置加载
# ============================================================================

func _ready():
	print("ConfigManager initialized as AutoLoad singleton")
	load_runtime_config()

## 从文件加载运行时配置（如果存在）
func load_runtime_config():
	var config_file_path = "user://runtime_config.cfg"
	if FileAccess.file_exists(config_file_path):
		var config_file = ConfigFile.new()
		var err = config_file.load(config_file_path)
		if err == OK:
			for key in runtime_config.keys():
				runtime_config[key] = config_file.get_value("runtime", key, runtime_config[key])
			print("Runtime config loaded from: ", config_file_path)
		else:
			print("Failed to load runtime config: ", err)

## 保存运行时配置到文件
func save_runtime_config():
	var config_file = ConfigFile.new()
	for key in runtime_config.keys():
		config_file.set_value("runtime", key, runtime_config[key])
	
	var err = config_file.save("user://runtime_config.cfg")
	if err == OK:
		print("Runtime config saved successfully")
	else:
		print("Failed to save runtime config: ", err)

# ============================================================================
# 配置访问方法
# ============================================================================

## 获取运行时配置值
func get_runtime_config(key: String, default_value = null):
	return runtime_config.get(key, default_value)

## 设置运行时配置值
func set_runtime_config(key: String, value) -> void:
	if runtime_config.has(key):
		var old_value = runtime_config[key]
		runtime_config[key] = value
		config_changed.emit("runtime", key, value)
		
		# 特殊处理调试模式
		if key == "debug_mode":
			debug_mode_changed.emit(value)
		
		print("Config changed: runtime.", key, " = ", value, " (was: ", old_value, ")")
	else:
		print("Warning: Unknown runtime config key: ", key)

## 重置运行时配置到默认值
func reset_runtime_config() -> void:
	runtime_config = {
		"debug_mode": false,
		"forest_size_adjust": 0.0,
		"forestosity": 0.0,
		"custom_seed": 0
	}
	config_changed.emit("runtime", "all", "reset")
	print("Runtime config reset to defaults")

# ============================================================================
# 便利访问方法
# ============================================================================

## 快速访问常用配置
func get_tile_size() -> int:
	return RenderConfig.TILE_SIZE

func get_chunk_size() -> int:
	return RenderConfig.CHUNK_SIZE

func get_player_color() -> Color:
	return ColorConfig.PLAYER_COLOR

func get_terrain_color(terrain_type: int) -> Color:
	match terrain_type:
		TerrainConfig.TYPE_LAND: return ColorConfig.TERRAIN_COLOR
		TerrainConfig.TYPE_RIVER: return ColorConfig.RIVER_COLOR
		TerrainConfig.TYPE_LAKE_SURFACE: return ColorConfig.LAKE_SURFACE_COLOR
		TerrainConfig.TYPE_LAKE_SHORE: return ColorConfig.LAKE_SHORE_COLOR
		TerrainConfig.TYPE_FOREST: return ColorConfig.FOREST_COLOR
		TerrainConfig.TYPE_FOREST_THICK: return ColorConfig.FOREST_THICK_COLOR
		TerrainConfig.TYPE_SWAMP: return ColorConfig.SWAMP_COLOR
		TerrainConfig.TYPE_ROAD: return ColorConfig.ROAD_COLOR
		TerrainConfig.TYPE_CITY_TILE: return ColorConfig.CITY_COLOR
		_: return Color.WHITE

## 获取地形类型对应的瓦片ID
func get_tile_id_for_terrain(terrain_type: int) -> int:
	return TerrainConfig.TERRAIN_TO_TILE_ID.get(terrain_type, -1)

# ============================================================================
# 调试和诊断
# ============================================================================

## 获取配置摘要信息
func get_config_summary() -> String:
	var summary = []
	summary.append("=== ConfigManager Summary ===")
	summary.append("Tile Size: %d" % RenderConfig.TILE_SIZE)
	summary.append("Chunk Size: %d" % RenderConfig.CHUNK_SIZE)
	summary.append("Debug Mode: %s" % str(runtime_config.debug_mode))
	summary.append("Forest Adjust: %.3f" % runtime_config.forest_size_adjust)
	summary.append("==============================")
	return "\n".join(summary)

## 打印所有配置信息（调试用）
func print_all_config():
	print(get_config_summary())
	print("Runtime Config: ", runtime_config)
