# MIT License
# Copyright (c) 2025 AliveGh0st
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

extends Node2D
class_name OvermapRenderer

## 连续地图overmap渲染器
## 负责动态生成和渲染无限大地图，包括地形生成、TileMap渲染和玩家标记管理

# ============================================================================
# 核心地图设置
# ============================================================================
var map_size_x: int  ## 动态计算的渲染区域宽度（游戏世界格子数）
var map_size_y: int  ## 动态计算的渲染区域高度（游戏世界格子数）
var canvas_size_x: int  ## 动态计算的画布宽度（像素）
var canvas_size_y: int  ## 动态计算的画布高度（像素）

# ============================================================================
# TileMapLayer渲染系统
# ============================================================================
var tile_map_layer: TileMapLayer  ## 地形渲染图层
var player_tile_map_layer: TileMapLayer  ## 玩家标记渲染图层（独立于地形图层）
var tile_set_resource: TileSet  ## 地形瓦片集资源




# ============================================================================
# 核心状态管理
# ============================================================================
var player_ref: CharacterBody2D  ## 玩家角色引用
var terrain_data: Dictionary = {}  ## 地形数据存储，键为世界坐标Vector2i，值为地形类型
var generated_chunks: Dictionary = {}  ## 已生成区块记录，键为区块坐标Vector2i

# ============================================================================
# 城市系统数据结构
# ============================================================================
## 城市数据类
class City:
	var pos: Vector2i          ## 城市中心位置（世界坐标）
	var pos_om: Vector2i       ## 城市所在区块坐标
	var size: int              ## 城市大小

	func _init(position: Vector2i = Vector2i.ZERO, overmap_pos: Vector2i = Vector2i.ZERO, city_size: int = 0):
		pos = position
		pos_om = overmap_pos 
		size = city_size

## 城市生成系统状态
var cities: Array[City] = []              ## 当前区域的城市列表
var city_tiles: Dictionary = {}           ## 城市瓦片坐标集合，键为Vector2i，值为bool
var urbanity: int = 0                     ## 城市化程度参数
var forestosity: float = 0.0              ## 森林密度值（用于城市大小调整计算）

## 特殊建筑跟踪系统
var globally_unique_buildings: Dictionary = {}  ## 全局独特建筑记录，键为建筑ID字符串
var placed_unique_buildings: Dictionary = {}    ## 已放置独特建筑记录（当前城市范围）
var overmap_special_placements: Dictionary = {} ## 特殊建筑放置记录，键为世界坐标Vector2i

# ============================================================================
# 渲染系统状态
# ============================================================================
var ui_disabled: bool = false  ## 临时禁用UI来测试tilemap闪烁问题
var player_marker_tile_pos: Vector2i = Vector2i(-999999, -999999)  ## 玩家标记在TileMap中的位置

# 渲染优化相关
var last_render_world_pos: Vector2i = Vector2i(-999999, -999999)  ## 上次渲染时的玩家世界位置
var render_dirty: bool = true  ## 是否需要重新渲染标记
var rendered_area: Rect2i = Rect2i()  ## 当前已渲染的屏幕区域

# ============================================================================
# 噪声生成器实例
# ============================================================================
# 噪声生成器实例 - 使用噪声管理器统一管理
# ============================================================================
var noise_manager: NoiseManager  ## 噪声管理器实例

# 动态森林大小调整值（替代原来的常量）
var forest_size_adjust: float = 0.0 ## 森林大小调整值，对应C++的forest_size_adjust
# 注意：forestosity在城市系统部分已声明

# ============================================================================
# 全局系统设置
# ============================================================================
var world_seed: int = 0  ## 世界种子，确保所有噪声生成器使用相同种子

# 性能优化控制
var chunk_creation_cooldown: float = 0.0  ## 区块创建冷却计时器，防止频繁生成

# ============================================================================
# 视口管理函数
# ============================================================================

func update_viewport_size():
	"""
	根据当前视口大小动态更新地图渲染尺寸
	计算需要渲染的游戏世界格子数量和对应的像素画布大小
	"""
	var viewport_size = get_viewport().get_visible_rect().size
	# 将视口像素大小转换为游戏世界格子数（每格Config.RenderConfig.TILE_SIZE像素）
	map_size_x = int(viewport_size.x / Config.RenderConfig.TILE_SIZE)
	map_size_y = int(viewport_size.y / Config.RenderConfig.TILE_SIZE)
	# 计算对应的像素画布大小
	canvas_size_x = map_size_x * Config.RenderConfig.TILE_SIZE
	canvas_size_y = map_size_y * Config.RenderConfig.TILE_SIZE

func _on_viewport_size_changed():
	"""
	视口大小变化事件处理器
	当窗口大小改变时重新计算渲染参数并标记需要重新渲染
	"""
	var old_canvas_size_x = canvas_size_x
	var old_canvas_size_y = canvas_size_y
	
	update_viewport_size()
	
	# 只有当画布尺寸实际发生变化时才标记需要重新渲染
	if canvas_size_x != old_canvas_size_x or canvas_size_y != old_canvas_size_y:
		render_dirty = true

# ============================================================================
# 初始化系统
# ============================================================================

func _ready():
	"""
	节点初始化函数
	设置所有子系统、噪声生成器、事件监听和初始区块生成
	"""
	add_to_group("overmap_manager")
	
	# 初始化全局世界种子
	world_seed = randi()
	print("World seed: ", world_seed)
	
	# 计算初始视野大小
	update_viewport_size()
	
	# 设置各个子系统
	setup_tilemap()
	setup_noise_manager()
	
	# 监听窗口大小变化事件
	get_viewport().size_changed.connect(_on_viewport_size_changed)
	
	# 等待一帧后查找玩家引用
	await get_tree().process_frame
	player_ref = get_tree().get_first_node_in_group("player")
	if not player_ref:
		return
	
	# 生成初始区块（世界原点0,0区块）
	generate_chunk_at(Vector2i(0, 0))
	
	# 确保玩家标记也被渲染
	var world_pos = player_ref.global_position
	var current_world_pos = Vector2i(
		int(world_pos.x / Config.RenderConfig.TILE_SIZE),
		int(world_pos.y / Config.RenderConfig.TILE_SIZE)
	)
	update_player_marker(current_world_pos.x, current_world_pos.y)
	last_render_world_pos = current_world_pos

# ============================================================================
# 主循环更新
# ============================================================================

func _process(delta):
	"""
	每帧更新函数
	处理区块生成冷却、区块生成检查和画布渲染更新
	"""
	# 更新区块生成冷却计时器
	if chunk_creation_cooldown > 0:
		chunk_creation_cooldown -= delta
	
	if not player_ref:
		return
	
	# 检查玩家位置，必要时生成新区块
	check_and_generate_chunks()
	
	# 获取当前玩家世界位置（以游戏世界格子为单位）
	var world_pos = player_ref.global_position
	var current_world_pos = Vector2i(
		int(world_pos.x / Config.RenderConfig.TILE_SIZE),
		int(world_pos.y / Config.RenderConfig.TILE_SIZE)
	)
	
	# 新的简化重绘逻辑：只有在render_dirty为true时才需要重绘
	# render_dirty只会在窗口大小变化等特殊情况下为true
	if render_dirty:
		render_dirty = false
		update_canvas_rendering()
	
	# 玩家标记始终跟随，但不触发地形重绘
	# 只在玩家实际移动到新格子时更新标记
	if current_world_pos != last_render_world_pos:
		last_render_world_pos = current_world_pos
		update_player_marker(current_world_pos.x, current_world_pos.y)

func render_chunk_immediately(chunk_coord: Vector2i):
	"""
	立即渲染指定区块的所有地形瓦片
	这是区块生成后的一次性渲染，不会被清除
	"""
	var world_start_x = chunk_coord.x * Config.RenderConfig.CHUNK_SIZE
	var world_start_y = chunk_coord.y * Config.RenderConfig.CHUNK_SIZE
	
	print("立即渲染区块: ", chunk_coord, " 世界坐标范围: (%d,%d) 到 (%d,%d)" % [
		world_start_x, world_start_y, 
		world_start_x + Config.RenderConfig.CHUNK_SIZE - 1, 
		world_start_y + Config.RenderConfig.CHUNK_SIZE - 1
	])
	
	var tiles_rendered = 0
	
	# 渲染整个区块的所有瓦片
	for x_local in range(Config.RenderConfig.CHUNK_SIZE):
		for y_local in range(Config.RenderConfig.CHUNK_SIZE):
			var world_x = world_start_x + x_local
			var world_y = world_start_y + y_local
			var world_coord = Vector2i(world_x, world_y)
			var terrain_type = terrain_data.get(world_coord, Config.TerrainConfig.TYPE_EMPTY)
			
			if terrain_type != Config.TerrainConfig.TYPE_EMPTY:
				set_tile_at_world_pos(world_coord, terrain_type)
				tiles_rendered += 1
	
	print("区块 %s 渲染完成，共渲染 %d 个瓦片" % [chunk_coord, tiles_rendered])

# ============================================================================
# TileMap渲染系统设置
# ============================================================================

func setup_tilemap():
	"""
	初始化TileMapLayer渲染系统
	创建地形图层和玩家图层，设置对应的TileSet资源
	地形图层使用外部 .tres 文件，玩家图层使用程序生成的 TileSet
	"""
	# 创建地形渲染图层
	tile_map_layer = TileMapLayer.new()
	tile_map_layer.name = "TerrainLayer"
	add_child(tile_map_layer)
	
	# 创建玩家标记图层（渲染在地形图层之上）
	player_tile_map_layer = TileMapLayer.new()
	player_tile_map_layer.name = "PlayerLayer"
	add_child(player_tile_map_layer)
	
	# 为地形图层设置外部 TileSet
	tile_set_resource = load_external_terrain_tileset()
	tile_map_layer.tile_set = tile_set_resource
	
	# 为玩家图层也使用相同的外部 TileSet
	player_tile_map_layer.tile_set = tile_set_resource
	
	# 设置初始纹理过滤模式
	update_texture_filtering_for_zoom()
	
	print("TileMapLayers created with tile_size: ", tile_set_resource.tile_size)
	print("Using external terrain tileset from: ", Config.RenderConfig.TERRAIN_TILESET_PATH)
	print("Using external tileset for player layer as well")
	print("Terrain layer position: ", tile_map_layer.position)
	print("Player layer position: ", player_tile_map_layer.position)
	
	render_dirty = true  # 标记需要重新渲染

func load_external_terrain_tileset() -> TileSet:
	"""
	加载外部地形 TileSet 资源文件
	这是唯一的地形 TileSet 加载方式，必须成功加载
	"""
	var tileset_path = Config.RenderConfig.TERRAIN_TILESET_PATH
	
	if ResourceLoader.exists(tileset_path):
		var loaded_tileset = load(tileset_path) as TileSet
		if loaded_tileset != null:
			print("外部地形 TileSet 加载成功: ", tileset_path)
			return loaded_tileset
		else:
			push_error("无法将资源作为 TileSet 加载: " + tileset_path)
	else:
		push_error("外部地形 TileSet 文件不存在: " + tileset_path)
	
	# 如果外部 TileSet 加载失败，创建一个空的 TileSet 避免崩溃
	push_error("地形 TileSet 加载失败，请检查文件路径和格式")
	var emergency_tileset = TileSet.new()
	emergency_tileset.tile_size = Vector2i(Config.RenderConfig.TILE_SIZE, Config.RenderConfig.TILE_SIZE)
	return emergency_tileset

# ============================================================================
# 动态纹理过滤系统
# ============================================================================

func update_texture_filtering_for_zoom():
	"""
	根据当前摄像机缩放级别动态调整纹理过滤模式
	在小缩放时使用线性过滤以获得更平滑的效果
	"""
	if not tile_map_layer or not player_tile_map_layer:
		return
	
	var camera_zoom = Config.get_actual_camera_zoom()
	
	# 根据缩放级别选择合适的过滤模式
	var filter_mode: CanvasItem.TextureFilter
	
	# 智能纹理过滤策略：
	# - 大缩放(>1.0)：NEAREST 保持像素风格
	# - 中等缩放(0.5-1.0)：NEAREST_WITH_MIPMAPS 减少闪烁
	# - 小缩放(<0.5)：NEAREST_WITH_MIPMAPS_ANISOTROPIC 最佳质量
	if camera_zoom >= 1.0:
		filter_mode = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	elif camera_zoom >= 0.7:
		filter_mode = CanvasItem.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	else:
		filter_mode = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	
	# 应用过滤模式到TileMapLayer
	tile_map_layer.texture_filter = filter_mode
	player_tile_map_layer.texture_filter = filter_mode
	
	var filter_name = ""
	match filter_mode:
		CanvasItem.TEXTURE_FILTER_NEAREST:
			filter_name = "NEAREST"
		CanvasItem.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS:
			filter_name = "NEAREST_WITH_MIPMAPS"
		CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS:
			filter_name = "LINEAR_WITH_MIPMAPS"
		CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC:
			filter_name = "LINEAR_WITH_MIPMAPS_ANISOTROPIC"
		_:
			filter_name = "UNKNOWN"
	
	print("纹理过滤模式更新为: %s (缩放: %.2f)" % [filter_name, camera_zoom])

# ============================================================================
# 噪声生成器初始化
# ============================================================================

func setup_noise_manager():
	"""
	初始化噪声管理器
	创建并配置所有需要的噪声生成器
	"""
	noise_manager = NoiseManager.new()
	add_child(noise_manager)
	noise_manager.initialize(world_seed)
	print("Noise manager setup completed")

# ============================================================================
# 区块生成管理系统
# ============================================================================

func check_and_generate_chunks():
	"""
	检查玩家位置并在需要时生成新区块
	当玩家接近区块边缘时，自动生成相邻区块以保证连续的地图体验
	支持基于摄像机缩放的动态区块生成范围调整
	"""
	if chunk_creation_cooldown > 0:
		return
	
	var world_pos = player_ref.global_position
	var world_grid_x = int(world_pos.x / Config.RenderConfig.TILE_SIZE)
	var world_grid_y = int(world_pos.y / Config.RenderConfig.TILE_SIZE)
	
	# 计算玩家当前所在的区块坐标
	var current_chunk = Vector2i(
		int(floor(float(world_grid_x) / Config.RenderConfig.CHUNK_SIZE)),
		int(floor(float(world_grid_y) / Config.RenderConfig.CHUNK_SIZE))
	)
	
	# 计算玩家在当前区块内的相对位置
	var local_x = world_grid_x - current_chunk.x * Config.RenderConfig.CHUNK_SIZE
	var local_y = world_grid_y - current_chunk.y * Config.RenderConfig.CHUNK_SIZE
	
	# 区块生成应该基于玩家实际位置，而不是摄像机缩放
	# 使用固定的边界阈值，确保只在真正接近区块边缘时才生成新区块
	var border_threshold = Config.RenderConfig.BORDER_THRESHOLD  # 固定使用11格
	
	# 检查是否接近区块边缘（使用固定阈值）
	var need_generation = false
	
	# 检查4个主要方向的边缘状态
	var near_left = local_x < border_threshold
	var near_right = local_x >= Config.RenderConfig.CHUNK_SIZE - border_threshold
	var near_top = local_y < border_threshold
	var near_bottom = local_y >= Config.RenderConfig.CHUNK_SIZE - border_threshold
	
	# 只生成相邻的区块（不再基于缩放级别扩展范围）
	
	# 检查并生成相邻区块
	var chunks_to_generate = []
	
	# 检查8个方向的相邻区块是否需要生成
	if near_left:
		chunks_to_generate.append(current_chunk + Vector2i(-1, 0))  # 西
		if near_top:
			chunks_to_generate.append(current_chunk + Vector2i(-1, -1))  # 西北
		if near_bottom:
			chunks_to_generate.append(current_chunk + Vector2i(-1, 1))  # 西南
	
	if near_right:
		chunks_to_generate.append(current_chunk + Vector2i(1, 0))  # 东
		if near_top:
			chunks_to_generate.append(current_chunk + Vector2i(1, -1))  # 东北
		if near_bottom:
			chunks_to_generate.append(current_chunk + Vector2i(1, 1))  # 东南
	
	if near_top:
		chunks_to_generate.append(current_chunk + Vector2i(0, -1))  # 北
	
	if near_bottom:
		chunks_to_generate.append(current_chunk + Vector2i(0, 1))  # 南
	
	# 生成所有需要的区块
	for chunk_coord in chunks_to_generate:
		generate_chunk_at(chunk_coord)
		need_generation = true
	
	# 确保当前区块已生成（安全检查）
	generate_chunk_at(current_chunk)
	
	# 设置冷却时间防止频繁生成
	if need_generation:
		chunk_creation_cooldown = Config.PerformanceConfig.CHUNK_CREATION_COOLDOWN_TIME

func generate_chunk_at(chunk_coord: Vector2i):
	"""
	生成指定坐标的地图区块
	包括基础地形生成以及河流、湖泊、森林等地物的生成
	"""
	# 检查区块是否已生成
	if generated_chunks.has(chunk_coord):
		return
	
	# 标记区块为已生成
	generated_chunks[chunk_coord] = true
	
	# 计算区块在世界坐标系中的起始位置
	var world_start_x = chunk_coord.x * Config.RenderConfig.CHUNK_SIZE
	var world_start_y = chunk_coord.y * Config.RenderConfig.CHUNK_SIZE
	
	print("Generating chunk at: ", chunk_coord, " world start: ", Vector2i(world_start_x, world_start_y))
	
	# 生成基础地形（默认为田野）
	for x_local in range(Config.RenderConfig.CHUNK_SIZE):
		for y_local in range(Config.RenderConfig.CHUNK_SIZE):
			var world_x = world_start_x + x_local
			var world_y = world_start_y + y_local
			
			terrain_data[Vector2i(world_x, world_y)] = Config.TerrainConfig.TYPE_LAND
	
	# 按顺序生成各种地物

	# 1. 计算当前区块的森林密度（在生成森林之前）
	calculate_forestosity(chunk_coord)

	# 1.5. 计算当前区块的城市化程度（在生成城市之前）
	calculate_urbanity(chunk_coord)

	# 2. 生成河流
	place_rivers(chunk_coord)
	
	# 2. 生成湖泊（可能会覆盖部分河流）
	place_lakes(chunk_coord)

	# 3. 生成森林（在所有水体生成后，森林密度计算后）
	place_forests(chunk_coord)

	# 4. 生成洪范平原沼泽（在森林生成后，基于河流生成洪泛平原）
	place_swamps(chunk_coord)

	# 5. 生成城市（在所有自然地形生成完成后）
	place_cities(chunk_coord)
	
	# 6. 所有地形生成完成后，立即渲染整个区块
	render_chunk_immediately(chunk_coord)
	print("区块 %s 生成并渲染完成" % chunk_coord)

# ============================================================================
# 河流生成系统（完全匹配C++逻辑）
# ============================================================================

func place_rivers(p_chunk_coord: Vector2i):
	"""
	河流生成主函数，完全复制C++版本的place_rivers逻辑
	处理与相邻区块的河流连接，确保河流网络的连续性
	避免在湖泊位置生成河流，减少地形冲突
	"""
	# 河流生成参数计算
	var river_placement_chance_divider = int(max(1.0, 1.0 / Config.RiverConfig.DENSITY_PARAM))
	var river_brush_size_factor = int(max(1.0, Config.RiverConfig.DENSITY_PARAM))

	var river_starts_local: Array[Vector2i] = [] # 河流起点（区块内坐标）
	var river_ends_local: Array[Vector2i] = []   # 河流终点（区块内坐标）

	# 检查河流地形的辅助函数
	var is_world_coord_river = func(world_coord: Vector2i):
		var terrain_type = terrain_data.get(world_coord, Config.TerrainConfig.TYPE_EMPTY)
		return terrain_type == Config.TerrainConfig.TYPE_RIVER

	# === 处理与相邻区块的河流连接 ===
	
	# 1. 处理北邻区块的河流连接
	var starts_from_north_added = 0
	var north_chunk_coord = p_chunk_coord + Vector2i(0, -1)
	if generated_chunks.has(north_chunk_coord):
		for i in range(2, Config.RenderConfig.CHUNK_SIZE - 2):
			var p_neighbour_world = _local_to_world(Vector2i(i, Config.RenderConfig.CHUNK_SIZE - 1), north_chunk_coord)
			var p_mine_local = Vector2i(i, 0)
			var p_mine_world = _local_to_world(p_mine_local, p_chunk_coord)

			# 如果邻居有河流，延续到当前区块
			if is_world_coord_river.call(p_neighbour_world):
				terrain_data[p_mine_world] = Config.TerrainConfig.TYPE_RIVER
			
			# 检查是否需要创建新的河流起点
			if is_world_coord_river.call(p_neighbour_world) and \
			   is_world_coord_river.call(p_neighbour_world + Vector2i(1, 0)) and \
			   is_world_coord_river.call(p_neighbour_world + Vector2i(-1, 0)):
				if starts_from_north_added < 3 and \
				   _one_in(river_placement_chance_divider) and (river_starts_local.is_empty() or \
				   river_starts_local.back().x < (i - 8) * river_brush_size_factor ):
					river_starts_local.append(p_mine_local)
					starts_from_north_added += 1

	var rivers_from_north_count = river_starts_local.size()
	
	# 2. 处理西邻区块的河流连接
	var starts_from_west_added = 0
	var west_chunk_coord = p_chunk_coord + Vector2i(-1, 0)
	if generated_chunks.has(west_chunk_coord):
		for i in range(2, Config.RenderConfig.CHUNK_SIZE - 2):
			var p_neighbour_world = _local_to_world(Vector2i(Config.RenderConfig.CHUNK_SIZE - 1, i), west_chunk_coord)
			var p_mine_local = Vector2i(0, i)
			var p_mine_world = _local_to_world(p_mine_local, p_chunk_coord)

			if is_world_coord_river.call(p_neighbour_world):
				terrain_data[p_mine_world] = Config.TerrainConfig.TYPE_RIVER

			if is_world_coord_river.call(p_neighbour_world) and \
			   is_world_coord_river.call(p_neighbour_world + Vector2i(0, 1)) and \
			   is_world_coord_river.call(p_neighbour_world + Vector2i(0, -1)):
				if starts_from_west_added < 3 and \
				   _one_in(river_placement_chance_divider) and (river_starts_local.size() == rivers_from_north_count or \
				   river_starts_local.back().y < (8) * river_brush_size_factor):
					river_starts_local.append(p_mine_local)
					starts_from_west_added += 1
	
	# 3. 处理南邻区块的河流连接
	var ends_from_south_added = 0
	var south_chunk_coord = p_chunk_coord + Vector2i(0, 1)
	if generated_chunks.has(south_chunk_coord):
		for i in range(2, Config.RenderConfig.CHUNK_SIZE - 2):
			var p_neighbour_world = _local_to_world(Vector2i(i, 0), south_chunk_coord)
			var p_mine_local = Vector2i(i, Config.RenderConfig.CHUNK_SIZE - 1)
			var p_mine_world = _local_to_world(p_mine_local, p_chunk_coord)

			if is_world_coord_river.call(p_neighbour_world):
				terrain_data[p_mine_world] = Config.TerrainConfig.TYPE_RIVER

			if is_world_coord_river.call(p_neighbour_world) and \
			   is_world_coord_river.call(p_neighbour_world + Vector2i(1, 0)) and \
			   is_world_coord_river.call(p_neighbour_world + Vector2i(-1, 0)):
				if ends_from_south_added < 3 and \
				   (river_ends_local.is_empty() or \
				   river_ends_local.back().x < (i - 8) ):
					river_ends_local.append(p_mine_local)
					ends_from_south_added += 1
	
	var rivers_to_south_count = river_ends_local.size()
	
	# 4. 处理东邻区块的河流连接
	var ends_from_east_added = 0
	var east_chunk_coord = p_chunk_coord + Vector2i(1, 0)
	if generated_chunks.has(east_chunk_coord):
		for i in range(2, Config.RenderConfig.CHUNK_SIZE - 2):
			var p_neighbour_world = _local_to_world(Vector2i(0, i), east_chunk_coord)
			var p_mine_local = Vector2i(Config.RenderConfig.CHUNK_SIZE - 1, i)
			var p_mine_world = _local_to_world(p_mine_local, p_chunk_coord)

			if is_world_coord_river.call(p_neighbour_world):
				terrain_data[p_mine_world] = Config.TerrainConfig.TYPE_RIVER
			
			if is_world_coord_river.call(p_neighbour_world) and \
			   is_world_coord_river.call(p_neighbour_world + Vector2i(0, 1)) and \
			   is_world_coord_river.call(p_neighbour_world + Vector2i(0, -1)):
				if ends_from_east_added < 3 and \
				   (river_ends_local.size() == rivers_to_south_count or \
				   river_ends_local.back().y < (i - 8)):
					river_ends_local.append(p_mine_local)
					ends_from_east_added += 1

	# === 平衡河流起点和终点数量 ===
	var new_rivers_buffer: Array[Vector2i] = []
	var has_north_neighbor = generated_chunks.has(north_chunk_coord)
	var has_west_neighbor = generated_chunks.has(west_chunk_coord)
	var has_south_neighbor = generated_chunks.has(south_chunk_coord)
	var has_east_neighbor = generated_chunks.has(east_chunk_coord)

	# 如果缺少北/西邻居，补充河流起点
	if not has_north_neighbor or not has_west_neighbor:
		while river_starts_local.is_empty() or river_starts_local.size() + 1 < river_ends_local.size():
			new_rivers_buffer.clear()
			if not has_north_neighbor and _one_in(river_placement_chance_divider):
				new_rivers_buffer.append(Vector2i(randi_range(10, Config.RenderConfig.CHUNK_SIZE - 11), 0))
			if not has_west_neighbor and _one_in(river_placement_chance_divider):
				new_rivers_buffer.append(Vector2i(0, randi_range(10, Config.RenderConfig.CHUNK_SIZE - 11)))
			if not new_rivers_buffer.is_empty():
				river_starts_local.append(_random_entry(new_rivers_buffer))
			else:
				break # 避免无限循环

	# 如果缺少南/东邻居，补充河流终点
	if not has_south_neighbor or not has_east_neighbor:
		while river_ends_local.is_empty() or river_ends_local.size() + 1 < river_starts_local.size():
			new_rivers_buffer.clear()
			if not has_south_neighbor and _one_in(river_placement_chance_divider):
				new_rivers_buffer.append(Vector2i(randi_range(10, Config.RenderConfig.CHUNK_SIZE - 11), Config.RenderConfig.CHUNK_SIZE - 1))
			if not has_east_neighbor and _one_in(river_placement_chance_divider):
				new_rivers_buffer.append(Vector2i(Config.RenderConfig.CHUNK_SIZE - 1, randi_range(10, Config.RenderConfig.CHUNK_SIZE - 11)))
			if not new_rivers_buffer.is_empty():
				river_ends_local.append(_random_entry(new_rivers_buffer))
			else:
				break # 避免无限循环

	# === 实际绘制河流路径 ===
	if river_starts_local.size() > river_ends_local.size() and not river_ends_local.is_empty():
		var river_ends_copy = river_ends_local.duplicate()
		while not river_starts_local.is_empty():
			var start_pos = _random_entry_removed(river_starts_local)
			if not river_ends_local.is_empty():
				var end_pos = river_ends_local.pop_front()
				_draw_single_river_path(p_chunk_coord, start_pos, end_pos)
			elif not river_ends_copy.is_empty():
				var end_pos = _random_entry(river_ends_copy)
				_draw_single_river_path(p_chunk_coord, start_pos, end_pos)
	elif river_ends_local.size() > river_starts_local.size() and not river_starts_local.is_empty():
		var river_starts_copy = river_starts_local.duplicate()
		while not river_ends_local.is_empty():
			var end_pos = _random_entry_removed(river_ends_local)
			if not river_starts_local.is_empty():
				var start_pos = river_starts_local.pop_front()
				_draw_single_river_path(p_chunk_coord, start_pos, end_pos)
			elif not river_starts_copy.is_empty():
				var start_pos = _random_entry(river_starts_copy)
				_draw_single_river_path(p_chunk_coord, start_pos, end_pos)
	elif not river_ends_local.is_empty():
		# 起点和终点数量相等，随机配对
		river_ends_local.shuffle()
		for i in range(min(river_starts_local.size(), river_ends_local.size())):
			var start_pos = river_starts_local[i]
			var end_pos = river_ends_local[i]
			_draw_single_river_path(p_chunk_coord, start_pos, end_pos)

func _draw_single_river_path(p_chunk_coord: Vector2i, pa_local: Vector2i, pb_local: Vector2i):
	"""
	在两点之间绘制单条河流路径
	使用随机游走算法，逐步向目标移动并应用笔刷效果
	完全匹配C++版本的place_river函数逻辑
	"""
	var river_chance = int(max(1.0, 1.0 / Config.RiverConfig.DENSITY_PARAM))
	var river_scale = int(max(1.0, Config.RiverConfig.DENSITY_PARAM))

	var p2_local = pa_local # 当前位置（区块内坐标）
	
	# 主要的河流绘制循环
	while p2_local != pb_local:
		# 第一步：随机游走
		p2_local.x += randi_range(-1, 1)
		p2_local.y += randi_range(-1, 1)
		
		# 确保坐标在区块边界内
		if p2_local.x < 0:
			p2_local.x = 0
		if p2_local.x > Config.RenderConfig.CHUNK_SIZE - 1:
			p2_local.x = Config.RenderConfig.CHUNK_SIZE - 1
		if p2_local.y < 0:
			p2_local.y = 0
		if p2_local.y > Config.RenderConfig.CHUNK_SIZE - 1:
			p2_local.y = Config.RenderConfig.CHUNK_SIZE - 1
		
		# 应用河流笔刷（第一次）
		for i in range(-1 * river_scale, 1 * river_scale + 1):
			for j in range(-1 * river_scale, 1 * river_scale + 1):
				var brush_point_local = p2_local + Vector2i(j, i)
				if brush_point_local.y >= 0 and brush_point_local.y < Config.RenderConfig.CHUNK_SIZE and brush_point_local.x >= 0 and brush_point_local.x < Config.RenderConfig.CHUNK_SIZE:
					var world_coord = _local_to_world(brush_point_local, p_chunk_coord)
					# 避免在湖泊位置放置河流，按概率放置
					if not _is_lake_at(world_coord) and _one_in(river_chance):
						terrain_data[world_coord] = Config.TerrainConfig.TYPE_RIVER
		
		# 第二步：向目标移动（C++原版的复杂移动逻辑）
		if pb_local.x > p2_local.x and (randi_range(0, int(Config.RenderConfig.CHUNK_SIZE * 1.2) - 1) < pb_local.x - p2_local.x or \
		(randi_range(0, int(Config.RenderConfig.CHUNK_SIZE * 0.2) - 1) > pb_local.x - p2_local.x and \
			randi_range(0, int(Config.RenderConfig.CHUNK_SIZE * 0.2) - 1) > abs(pb_local.y - p2_local.y))):
			p2_local.x += 1
		if pb_local.x < p2_local.x and (randi_range(0, int(Config.RenderConfig.CHUNK_SIZE * 1.2) - 1) < p2_local.x - pb_local.x or \
		(randi_range(0, int(Config.RenderConfig.CHUNK_SIZE * 0.2) - 1) > p2_local.x - pb_local.x and \
			randi_range(0, int(Config.RenderConfig.CHUNK_SIZE * 0.2) - 1) > abs(pb_local.y - p2_local.y))):
			p2_local.x -= 1
		if pb_local.y > p2_local.y and (randi_range(0, int(Config.RenderConfig.CHUNK_SIZE * 1.2) - 1) < pb_local.y - p2_local.y or \
		(randi_range(0, int(Config.RenderConfig.CHUNK_SIZE * 0.2) - 1) > pb_local.y - p2_local.y and \
			randi_range(0, int(Config.RenderConfig.CHUNK_SIZE * 0.2) - 1) > abs(p2_local.x - pb_local.x))):
			p2_local.y += 1
		if pb_local.y < p2_local.y and (randi_range(0, int(Config.RenderConfig.CHUNK_SIZE * 1.2) - 1) < p2_local.y - pb_local.y or \
		(randi_range(0, int(Config.RenderConfig.CHUNK_SIZE * 0.2) - 1) > p2_local.y - pb_local.y and \
			randi_range(0, int(Config.RenderConfig.CHUNK_SIZE * 0.2) - 1) > abs(p2_local.x - pb_local.x))):
			p2_local.y -= 1

# ============================================================================
# 河流生成辅助函数
# ============================================================================
func _is_lake_at(world_coord: Vector2i) -> bool:
	"""检查指定世界坐标是否是湖泊地形（仅检查已生成的地形类型）"""
	var terrain_type = terrain_data.get(world_coord, Config.TerrainConfig.TYPE_EMPTY)
	return terrain_type == Config.TerrainConfig.TYPE_LAKE_SURFACE or terrain_type == Config.TerrainConfig.TYPE_LAKE_SHORE

func _local_to_world(local_pos: Vector2i, p_chunk_coord: Vector2i) -> Vector2i:
	"""将区块内坐标转换为世界坐标"""
	var world_start_x = p_chunk_coord.x * Config.RenderConfig.CHUNK_SIZE
	var world_start_y = p_chunk_coord.y * Config.RenderConfig.CHUNK_SIZE
	return Vector2i(world_start_x + local_pos.x, world_start_y + local_pos.y)

func _is_inbounds_local(local_pos: Vector2i, border: int = 0) -> bool:
	"""检查区块内坐标是否在边界范围内"""
	return (local_pos.x >= border and local_pos.x < Config.RenderConfig.CHUNK_SIZE - border and \
			local_pos.y >= border and local_pos.y < Config.RenderConfig.CHUNK_SIZE - border)

func _one_in(chance: int) -> bool:
	"""
	概率检查函数，完全匹配C++版本的逻辑
	如果chance<=1则总是返回true，否则有1/chance的概率返回true
	"""
	if chance <= 1:
		return true
	return randi_range(0, chance - 1) == 0

func _random_entry(arr: Array):
	"""从数组中随机选择一个元素"""
	if arr.is_empty():
		push_warning("Attempted to get random entry from empty array.")
		return Vector2i.ZERO 
	return arr[randi() % arr.size()]

func _random_entry_removed(arr: Array):
	"""从数组中随机选择并移除一个元素"""
	if arr.is_empty():
		push_warning("Attempted to remove random entry from empty array.")
		return Vector2.ZERO 
	var idx = randi() % arr.size()
	var entry = arr[idx]
	arr.remove_at(idx)
	return entry

# ============================================================================
# 湖泊生成系统（完全匹配C++逻辑）
# ============================================================================

func place_lakes(chunk_coord: Vector2i):
	"""
	湖泊生成主函数，完全匹配C++的place_lakes函数逻辑
	使用洪水填充算法识别湖泊区域，区分湖泊表面和湖岸
	自动连接大型湖泊到最近的河流系统
	"""
	# 计算区块在世界坐标系中的起始位置
	var world_start_x = chunk_coord.x * Config.RenderConfig.CHUNK_SIZE
	var world_start_y = chunk_coord.y * Config.RenderConfig.CHUNK_SIZE
	
	# 湖泊检测函数（匹配C++的lambda表达式）
	var is_lake = func(p: Vector2i) -> bool:
		# 边界检查（允许一定的边界扩展）
		var inbounds = p.x > world_start_x - 5 and p.y > world_start_y - 5 and \
					   p.x < world_start_x + Config.RenderConfig.CHUNK_SIZE + 5 and p.y < world_start_y + Config.RenderConfig.CHUNK_SIZE + 5
		if not inbounds:
			return false
		# 噪声检查
		return _is_lake_noise_at(p)
	
	# 已访问位置记录（对应C++的unordered_set）
	var visited: Dictionary = {}
	
	# 遍历区块内所有位置寻找湖泊种子点
	for i in range(Config.RenderConfig.CHUNK_SIZE):
		for j in range(Config.RenderConfig.CHUNK_SIZE):
			var seed_point = Vector2i(world_start_x + i, world_start_y + j)
			
			# 跳过已访问的位置
			if visited.has(seed_point):
				continue
			
			# 跳过非湖泊位置
			if not is_lake.call(seed_point):
				continue
			
			# 使用洪水填充算法获取连通的湖泊区域
			var lake_points = _point_flood_fill_4_connected(seed_point, visited, is_lake)
			
			# 过滤掉过小的湖泊
			if lake_points.size() < Config.LakeConfig.SIZE_MIN:
				continue
			
			# 构建湖泊点集合（包括湖泊点和所有河流点）
			var lake_set: Dictionary = {}
			for p in lake_points:
				lake_set[p] = true
			
			# 将所有河流点添加到湖泊集合（C++逻辑）
			for x in range(Config.RenderConfig.CHUNK_SIZE):
				for y in range(Config.RenderConfig.CHUNK_SIZE):
					var p = Vector2i(world_start_x + x, world_start_y + y)
					var terrain_type = terrain_data.get(p, Config.TerrainConfig.TYPE_EMPTY)
					if terrain_type == Config.TerrainConfig.TYPE_RIVER:
						lake_set[p] = true
			
			# 处理湖泊点，区分表面和岸边
			for p in lake_points:
				# 只处理当前区块内的点
				if not _is_world_point_in_chunk(p, chunk_coord):
					continue
				
				var shore = false
				# 检查8个相邻位置，如果有非湖泊区域则为岸边
				for ni in range(-1, 2):
					if shore:
						break
					for nj in range(-1, 2):
						if shore:
							break
						var n = p + Vector2i(ni, nj)
						if not lake_set.has(n):
							shore = true
				
				# 设置地形类型
				if shore:
					terrain_data[p] = Config.TerrainConfig.TYPE_LAKE_SHORE
				else:
					terrain_data[p] = Config.TerrainConfig.TYPE_LAKE_SURFACE
			
			# 连接大型湖泊到河流系统
			_connect_lake_to_rivers_cpp_style(lake_points, chunk_coord)

func _point_flood_fill_4_connected(starting_point: Vector2i, visited: Dictionary, predicate: Callable) -> Array[Vector2i]:
	"""
	四连通洪水填充算法
	使用广度优先搜索找到所有连通的满足条件的点
	"""
	var filled_points: Array[Vector2i] = []
	var to_check: Array[Vector2i] = [starting_point]
	
	while not to_check.is_empty():
		var current_point = to_check.pop_front()
		
		# 跳过已访问的点
		if visited.has(current_point):
			continue
		
		# 标记为已访问
		visited[current_point] = true
		
		# 如果满足条件，加入结果并检查相邻点
		if predicate.call(current_point):
			filled_points.append(current_point)
			
			# 添加四个方向的相邻点到检查队列
			to_check.append(current_point + Vector2i(0, 1))   # 南
			to_check.append(current_point + Vector2i(0, -1))  # 北
			to_check.append(current_point + Vector2i(1, 0))   # 东
			to_check.append(current_point + Vector2i(-1, 0))  # 西
	
	return filled_points

func _connect_lake_to_rivers_cpp_style(lake_points: Array[Vector2i], chunk_coord: Vector2i):
	"""
	湖泊河流连接系统，完全匹配C++的连接逻辑
	找到湖泊的最北和最南点，将它们连接到最近的河流
	"""
	if lake_points.is_empty():
		return
	
	# 检查湖泊大小是否达到连接阈值
	if lake_points.size() < Config.LakeConfig.RIVER_CONNECTION_MIN_SIZE:
		return
	
	# 检查湖泊是否已经与河流重叠
	var lake_has_river = false
	for lake_point in lake_points:
		var terrain_type = terrain_data.get(lake_point, Config.TerrainConfig.TYPE_EMPTY)
		if terrain_type == Config.TerrainConfig.TYPE_RIVER:
			lake_has_river = true
			break
	
	# 如果湖泊已包含河流，跳过连接逻辑
	if lake_has_river:
		print("Lake already contains rivers, skipping connection logic")
		return
	
	# 连接湖泊点到符合条件河流的函数
	var connect_lake_to_qualified_river = func(lake_connection_point: Vector2i, is_northmost: bool):
		var closest_distance = -1
		var closest_point = Vector2i.ZERO
		
		# 搜索所有已生成区块中的河流
		for chunk_coord_key in generated_chunks.keys():
			var world_start_x = chunk_coord_key.x * Config.RenderConfig.CHUNK_SIZE
			var world_start_y = chunk_coord_key.y * Config.RenderConfig.CHUNK_SIZE
			
			for x in range(Config.RenderConfig.CHUNK_SIZE):
				for y in range(Config.RenderConfig.CHUNK_SIZE):
					var p = Vector2i(world_start_x + x, world_start_y + y)
					var terrain_type = terrain_data.get(p, Config.TerrainConfig.TYPE_EMPTY)
					
					if terrain_type != Config.TerrainConfig.TYPE_RIVER:
						continue
					
					# 检查河流位置是否符合连接条件
					var river_qualifies = false
					if is_northmost:
						# 最北点只连接到高于该点的河流（y值更小）
						river_qualifies = (p.y < lake_connection_point.y)
					else:
						# 最南点只连接到低于该点的河流（y值更大）
						river_qualifies = (p.y > lake_connection_point.y)
					
					if not river_qualifies:
						continue
					
					# 计算距离
					var distance = _square_dist(lake_connection_point, p)
					if distance < closest_distance or closest_distance < 0:
						closest_point = p
						closest_distance = distance
		
		# 如果找到符合条件的河流，建立连接
		if closest_distance > 0:
			_place_river_between_points(closest_point, lake_connection_point, chunk_coord)
	
	# 获取湖泊的最北和最南点
	var north_south_most = _get_north_south_most_points_cpp_style(lake_points)
	var northmost = north_south_most[0]
	var southmost = north_south_most[1]
	
	# 连接最北和最南点到符合条件的河流
	if _is_world_point_in_chunk(northmost, chunk_coord):
		connect_lake_to_qualified_river.call(northmost, true)  # true表示这是最北点
	
	if _is_world_point_in_chunk(southmost, chunk_coord):
		connect_lake_to_qualified_river.call(southmost, false)  # false表示这是最南点

func _get_north_south_most_points_cpp_style(lake_points: Array[Vector2i]) -> Array[Vector2i]:
	"""找到湖泊点集合中Y坐标最小（最北）和最大（最南）的点"""
	if lake_points.is_empty():
		return [Vector2i.ZERO, Vector2i.ZERO]
	
	var northmost = lake_points[0]  # 最小Y值（最北）
	var southmost = lake_points[0]  # 最大Y值（最南）
	
	for point in lake_points:
		if point.y < northmost.y:
			northmost = point
		if point.y > southmost.y:
			southmost = point
	
	return [northmost, southmost]

func _is_lake_noise_at(world_pos: Vector2i) -> bool:
	"""检查指定世界坐标是否应该生成湖泊（基于噪声计算）"""
	# 获取原始噪声值（范围-1到1）
	var noise_value = noise_manager.get_lake_value(world_pos.x, world_pos.y)
	# 规范化到0-1范围
	noise_value = (noise_value + 1.0) * 0.5
	# 应用幂运算使分布更稀疏、边缘更清晰
	noise_value = pow(noise_value, Config.LakeConfig.NOISE_POWER)
	
	return noise_value > Config.LakeConfig.NOISE_THRESHOLD

func _is_world_point_in_chunk(world_pos: Vector2i, chunk_coord: Vector2i) -> bool:
	"""检查世界坐标点是否在指定区块范围内"""
	var world_start_x = chunk_coord.x * Config.RenderConfig.CHUNK_SIZE
	var world_start_y = chunk_coord.y * Config.RenderConfig.CHUNK_SIZE
	
	return (world_pos.x >= world_start_x and world_pos.x < world_start_x + Config.RenderConfig.CHUNK_SIZE and
			world_pos.y >= world_start_y and world_pos.y < world_start_y + Config.RenderConfig.CHUNK_SIZE)

func _square_dist(p1: Vector2i, p2: Vector2i) -> int:
	"""计算两点间的平方距离（避免开方运算提高性能）"""
	var dx = p1.x - p2.x
	var dy = p1.y - p2.y
	return dx * dx + dy * dy

# ============================================================================
# 跨区块河流连接系统
# ============================================================================

func _place_river_between_points(start_point: Vector2i, end_point: Vector2i, chunk_coord: Vector2i):
	"""
	在两个世界坐标点之间绘制河流连接
	用于连接湖泊到最近的河流，但只在当前生成的区块内绘制
	"""
	var river_chance = int(max(1.0, 1.0 / Config.RiverConfig.DENSITY_PARAM))
	var river_scale = int(max(1.0, Config.RiverConfig.DENSITY_PARAM))

	var p2 = start_point

	while p2 != end_point:
		# 第一步：随机游走
		p2.x += randi_range(-1, 1)
		p2.y += randi_range(-1, 1)
		
		# 应用河流笔刷（允许河流穿过湖泊）
		for i in range(-1 * river_scale, 1 * river_scale + 1):
			for j in range(-1 * river_scale, 1 * river_scale + 1):
				var brush_point = p2 + Vector2i(j, i)
				# 确保只在当前区块内绘制
				if _is_world_point_in_chunk(brush_point, chunk_coord) and _one_in(river_chance):
					terrain_data[brush_point] = Config.TerrainConfig.TYPE_RIVER
		
		# 第二步：向目标移动（复杂的方向性移动逻辑）
		var WORLD_SIZE_FACTOR = Config.RenderConfig.CHUNK_SIZE * 10
		if end_point.x > p2.x and (randi_range(0, int(WORLD_SIZE_FACTOR * 1.2) - 1) < end_point.x - p2.x or \
			(randi_range(0, int(WORLD_SIZE_FACTOR * 0.2) - 1) > end_point.x - p2.x and \
			randi_range(0, int(WORLD_SIZE_FACTOR * 0.2) - 1) > abs(end_point.y - p2.y))):
			p2.x += 1
		if end_point.x < p2.x and (randi_range(0, int(WORLD_SIZE_FACTOR * 1.2) - 1) < p2.x - end_point.x or \
			(randi_range(0, int(WORLD_SIZE_FACTOR * 0.2) - 1) > p2.x - end_point.x and \
			randi_range(0, int(WORLD_SIZE_FACTOR * 0.2) - 1) > abs(end_point.y - p2.y))):
			p2.x -= 1
		if end_point.y > p2.y and (randi_range(0, int(WORLD_SIZE_FACTOR * 1.2) - 1) < end_point.y - p2.y or \
			(randi_range(0, int(WORLD_SIZE_FACTOR * 0.2) - 1) > end_point.y - p2.y and \
			randi_range(0, int(WORLD_SIZE_FACTOR * 0.2) - 1) > abs(p2.x - end_point.x))):
			p2.y += 1
		if end_point.y < p2.y and (randi_range(0, int(WORLD_SIZE_FACTOR * 1.2) - 1) < p2.y - end_point.y or \
			(randi_range(0, int(WORLD_SIZE_FACTOR * 0.2) - 1) > p2.y - end_point.y and \
			randi_range(0, int(WORLD_SIZE_FACTOR * 0.2) - 1) > abs(p2.x - end_point.x))):
			p2.y -= 1
		
		# 第三步：再次随机游走
		p2.x += randi_range(-1, 1)
		p2.y += randi_range(-1, 1)

		# 第四步：再次应用河流笔刷
		for i in range(-1 * river_scale, 1 * river_scale + 1):
			for j in range(-1 * river_scale, 1 * river_scale + 1):
				var brush_point = p2 + Vector2i(j, i)
				
				# 如果接近目标或符合概率就放置河流
				var is_near_target = abs(end_point.y - brush_point.y) < 4 and abs(end_point.x - brush_point.x) < 4
				# 确保只在当前区块内绘制
				if _is_world_point_in_chunk(brush_point, chunk_coord) and (is_near_target or _one_in(river_chance)):
					terrain_data[brush_point] = Config.TerrainConfig.TYPE_RIVER

# ============================================================================
# 森林生成系统（完全匹配C++逻辑）
# ============================================================================
# ============================================================================
# 森林密度计算系统（完全匹配C++逻辑）
# ============================================================================

func calculate_forestosity(chunk_coord: Vector2i):
	"""
	计算当前区块的森林密度调整值
	根据区块在世界中的位置和4个方向的森林增长率参数来动态调整森林大小
	完全匹配C++版本的overmap::calculate_forestosity()函数
	"""
	# 获取当前区块的世界绝对坐标（对应C++的point_abs_om this_om = pos()）
	var this_om_x = chunk_coord.x
	var this_om_y = chunk_coord.y
	
	# 重置森林大小调整值
	forest_size_adjust = 0.0
	
	# 西方向森林增长率影响（x < 0的区块）
	if Config.ForestConfig.INCREASE_WEST != 0.0 and this_om_x < 0:
		forest_size_adjust -= this_om_x * Config.ForestConfig.INCREASE_WEST
	
	# 北方向森林增长率影响（y < 0的区块）
	if Config.ForestConfig.INCREASE_NORTH != 0.0 and this_om_y < 0:
		forest_size_adjust -= this_om_y * Config.ForestConfig.INCREASE_NORTH
	
	# 东方向森林增长率影响（x > 0的区块）
	if Config.ForestConfig.INCREASE_EAST != 0.0 and this_om_x > 0:
		forest_size_adjust += this_om_x * Config.ForestConfig.INCREASE_EAST
	
	# 南方向森林增长率影响（y > 0的区块）
	if Config.ForestConfig.INCREASE_SOUTH != 0.0 and this_om_y > 0:
		forest_size_adjust += this_om_y * Config.ForestConfig.INCREASE_SOUTH
	
	# 计算forestosity值（对应C++的forestosity = forest_size_adjust * 25.0f）
	forestosity = forest_size_adjust * 25.0
	
	# 确保森林大小永远不会完全覆盖地图（对应C++的森林上限检查）
	# forest_size_adjust不能超过 (森林上限 - 森林噪声阈值)
	var max_forest_adjust = Config.ForestConfig.LIMIT - Config.ForestConfig.NOISE_THRESHOLD_FOREST
	forest_size_adjust = min(forest_size_adjust, max_forest_adjust)
	
	# 调试输出（对应C++的debugmsg，可以根据需要启用）
	# print("forestosity = %.2f at OM %d, %d" % [forestosity, this_om_x, this_om_y])

func calculate_urbanity(chunk_coord: Vector2i):
	"""
	计算当前区块的城市化程度调整值
	完全匹配C++版本的overmap::calculate_urbanity()函数
	根据区块在世界中的位置和4个方向的城市化增长率参数来动态调整城市大小和密度
	"""
	var op_city_size = Config.CityConfig.CITY_SIZE
	if op_city_size <= 0:
		return
	
	var northern_urban_increase = Config.CityConfig.URBAN_INCREASE_NORTH
	var eastern_urban_increase = Config.CityConfig.URBAN_INCREASE_EAST
	var western_urban_increase = Config.CityConfig.URBAN_INCREASE_WEST
	var southern_urban_increase = Config.CityConfig.URBAN_INCREASE_SOUTH
	
	# 如果所有方向的城市化增长都为0，直接返回
	if northern_urban_increase == 0 and eastern_urban_increase == 0 and \
	   western_urban_increase == 0 and southern_urban_increase == 0:
		return
	
	var urbanity_adj: float = 0.0
	
	# 获取当前区块的世界绝对坐标（对应C++的point_abs_om this_om = pos()）
	var this_om_x = chunk_coord.x
	var this_om_y = chunk_coord.y
	
	# 北方向城市化增长影响
	if northern_urban_increase != 0 and this_om_y < 0:
		urbanity_adj -= this_om_y * northern_urban_increase / 10.0
		# 添加一些衰减到边缘，保持城市较大但打破巨型城市
		# 如果我们在这些方向也期望巨型城市则不适用
		if this_om_x < 0 and western_urban_increase == 0:
			urbanity_adj /= max(this_om_x / -2.0, 1.0)
		if this_om_x > 0 and eastern_urban_increase == 0:
			urbanity_adj /= max(this_om_x / 2.0, 1.0)
	
	# 东方向城市化增长影响
	if eastern_urban_increase != 0 and this_om_x > 0:
		urbanity_adj += this_om_x * eastern_urban_increase / 10.0
		if this_om_y < 0 and northern_urban_increase == 0:
			urbanity_adj /= max(this_om_y / -2.0, 1.0)
		if this_om_y > 0 and southern_urban_increase == 0:
			urbanity_adj /= max(this_om_y / 2.0, 1.0)
	
	# 西方向城市化增长影响
	if western_urban_increase != 0 and this_om_x < 0:
		urbanity_adj -= this_om_x * western_urban_increase / 10.0
		if this_om_y < 0 and northern_urban_increase == 0:
			urbanity_adj /= max(this_om_y / -2.0, 1.0)
		if this_om_y > 0 and southern_urban_increase == 0:
			urbanity_adj /= max(this_om_y / 2.0, 1.0)
	
	# 南方向城市化增长影响
	if southern_urban_increase != 0 and this_om_y > 0:
		urbanity_adj += this_om_y * southern_urban_increase / 10.0
		if this_om_x < 0 and western_urban_increase == 0:
			urbanity_adj /= max(this_om_x / -2.0, 1.0)
		if this_om_x > 0 and eastern_urban_increase == 0:
			urbanity_adj /= max(this_om_x / 2.0, 1.0)
	
	# 设置最终的城市化程度值
	urbanity = int(urbanity_adj)
	
	# 调试输出（对应C++的debugmsg，可以根据需要启用）
	# print("urbanity = %d at OM %d, %d" % [urbanity, this_om_x, this_om_y])

# ============================================================================
# 画布渲染更新系统
# ============================================================================

func update_canvas_rendering():
	"""
	简化的渲染更新系统
	由于地形瓦片在区块生成时已永久渲染，这里只需要更新玩家标记
	"""
	# 获取玩家当前世界位置（游戏世界格子坐标）
	var world_pos = player_ref.global_position
	var center_world_x = int(world_pos.x / Config.RenderConfig.TILE_SIZE)
	var center_world_y = int(world_pos.y / Config.RenderConfig.TILE_SIZE)
	
	# 只更新玩家标记位置
	update_player_marker(center_world_x, center_world_y)
	
	print("渲染更新 - 仅更新玩家标记位置: (%d, %d)" % [center_world_x, center_world_y])

# 删除了复杂的视口清除和区域渲染函数，因为地形瓦片现在永久保留

func set_tile_at_world_pos(world_pos: Vector2i, terrain_type: int):
	"""在世界坐标位置设置对应的地形瓦片，支持线性地形系统"""
	if terrain_type == Config.TerrainConfig.TYPE_EMPTY:
		tile_map_layer.erase_cell(world_pos)
	else:
		var atlas_coords: Vector2i
		
		# 检查是否为线性道路地形
		var linear_info = get_linear_terrain_info(world_pos)
		if not linear_info.is_empty() and terrain_type == Config.TerrainConfig.TYPE_ROAD:
			# 使用线性地形的图集坐标
			atlas_coords = linear_info.get("atlas_coords", Vector2i(0, 0))
		else:
			# 使用常规地形映射
			atlas_coords = Config.TerrainConfig.TERRAIN_TO_ATLAS_COORDS.get(terrain_type, Vector2i(0, 0))
		
		# 确保坐标有效（不是空地形的-1,-1坐标）
		if atlas_coords.x >= 0 and atlas_coords.y >= 0:
			tile_map_layer.set_cell(world_pos, 0, atlas_coords)
			# 调试：第一个瓦片设置时输出信息
			if world_pos == Vector2i(90, 90):  # 区块中心位置
				print("设置瓦片 - 位置: %s, 地形类型: %d, 图集坐标: %s" % [world_pos, terrain_type, atlas_coords])
		else:
			print("警告：无效的图集坐标 %s，地形类型: %d" % [atlas_coords, terrain_type])

func update_player_marker(world_x: int, world_y: int):
	"""
	更新玩家标记的位置（始终可见）
	只在位置实际变化时更新，避免重复绘制
	"""
	var new_player_pos = Vector2i(world_x, world_y)
	
	# 如果位置没有变化，直接返回，不重复绘制
	# 清除旧位置的玩家标记
	if player_marker_tile_pos != Vector2i(-999999, -999999):
		player_tile_map_layer.erase_cell(player_marker_tile_pos)
	
	# 设置新位置并显示标记
	player_marker_tile_pos = new_player_pos
	player_tile_map_layer.set_cell(player_marker_tile_pos, 0, Config.PlayerConfig.PLAYER_ATLAS_COORDS)

func forest_noise_at(world_pos: Vector2i) -> float:
	"""
	森林噪声计算函数，完全匹配C++的om_noise_layer_forest::noise_at函数
	使用双层噪声系统：基础分布噪声减去密度减少噪声
	"""
	# 第一层噪声 - 森林基础分布
	var r = noise_manager.get_forest_base_value(world_pos.x, world_pos.y)
	# 将噪声值从[-1,1]范围映射到[0,1]范围
	r = (r + 1.0) * 0.5
	# 应用幂运算增强对比度
	r = pow(r, Config.ForestConfig.NOISE_1_POWER)
	
	# 第二层噪声 - 森林密度减少效果
	var d = noise_manager.get_forest_density_value(world_pos.x, world_pos.y)
	# 将噪声值从[-1,1]范围映射到[0,1]范围
	d = (d + 1.0) * 0.5
	# 应用幂运算
	d = pow(d, Config.ForestConfig.NOISE_2_POWER)
	
	# 返回最终噪声值（基础分布减去密度减少效果）
	return max(0.0, r - d *  0.5)

func floodplain_noise_at(world_pos: Vector2i) -> float:
	"""
	洪泛平原噪声计算函数，完全匹配C++的om_noise_layer_floodplain::noise_at函数
	使用单层噪声生成，通过幂运算增强对比度
	"""
	# 获取基础噪声值
	var r = noise_manager.get_floodplain_value(world_pos.x, world_pos.y)
	# 将噪声值从[-1,1]范围映射到[0,1]范围
	r = (r + 1.0) * 0.5
	# 应用幂运算增强对比度，使小值更小，大值相对更大
	r = pow(r, Config.SwampConfig.FLOODPLAIN_NOISE_POWER)
	
	return r

func place_forests(chunk_coord: Vector2i):
	"""
	森林生成主函数，完全匹配C++的overmap::place_forests()函数逻辑
	只在默认地形（田野）上生成森林，根据噪声值决定森林类型
	"""
	# 计算区块在世界坐标系中的起始位置
	var world_start_x = chunk_coord.x * Config.RenderConfig.CHUNK_SIZE
	var world_start_y = chunk_coord.y * Config.RenderConfig.CHUNK_SIZE
	
	# 默认地形类型（只在此类型上生成森林）
	var default_terrain_type = Config.TerrainConfig.TYPE_LAND
	
	# 遍历区块内所有位置
	for x in range(Config.RenderConfig.CHUNK_SIZE):
		for y in range(Config.RenderConfig.CHUNK_SIZE):
			var world_pos = Vector2i(world_start_x + x, world_start_y + y)
			var current_terrain = terrain_data.get(world_pos, Config.TerrainConfig.TYPE_EMPTY)
			
			# 只考虑将默认地形转换为森林
			if current_terrain != default_terrain_type:
				continue
			
			# 获取该位置的森林噪声值
			var n = forest_noise_at(world_pos)
			
			# 根据噪声值和阈值决定森林类型
			if n + forest_size_adjust > Config.ForestConfig.NOISE_THRESHOLD_FOREST_THICK:
				# 生成密林
				terrain_data[world_pos] = Config.TerrainConfig.TYPE_FOREST_THICK
			elif n + forest_size_adjust > Config.ForestConfig.NOISE_THRESHOLD_FOREST:
				# 生成普通森林
				terrain_data[world_pos] = Config.TerrainConfig.TYPE_FOREST

func place_swamps(chunk_coord: Vector2i):
	"""
	洪范平原生成主函数，优化版本
	基于河流位置计算洪泛平原，结合噪声生成沼泽地形
	只在森林地形上生成沼泽，符合生态逻辑
	
	性能优化：
	1. 去除不必要的排序操作
	2. 智能边界检查，减少不必要的计算
	3. 早期退出优化
	"""
	# 计算区块在世界坐标系中的范围
	var world_start_x = chunk_coord.x * Config.RenderConfig.CHUNK_SIZE
	var world_start_y = chunk_coord.y * Config.RenderConfig.CHUNK_SIZE
	var world_end_x = world_start_x + Config.RenderConfig.CHUNK_SIZE
	var world_end_y = world_start_y + Config.RenderConfig.CHUNK_SIZE
	
	# 创建洪泛平原计数数组，记录每个位置被河流缓冲区覆盖的次数
	# 使用Dictionary来存储稀疏数据，只有被缓冲的位置才会有条目
	var floodplain: Dictionary = {}
	
	# 性能优化：如果没有启用优化，可以在这里添加原始实现
	# 目前直接使用优化版本
	
	# 步骤1：计算河流洪泛平原缓冲区 - 性能优化版本
	var check_range = Config.SwampConfig.RIVER_FLOODPLAIN_BUFFER_DISTANCE_MAX
	var _river_count = 0  # 统计河流数量用于性能分析
	
	# 智能范围计算：根据实际需要的缓冲距离动态调整搜索范围
	if Config.SwampConfig.RIVER_SEARCH_RADIUS_OPTIMIZATION:
		check_range = Config.SwampConfig.RIVER_FLOODPLAIN_BUFFER_DISTANCE_MAX
	
	for check_x in range(world_start_x - check_range, world_end_x + check_range):
		for check_y in range(world_start_y - check_range, world_end_y + check_range):
			var check_pos = Vector2i(check_x, check_y)
			var terrain_type = terrain_data.get(check_pos, Config.TerrainConfig.TYPE_EMPTY)
			
			# 检查是否为河流地形（匹配C++的is_ot_match("river", ot_match_type::contains)）
			if terrain_type == Config.TerrainConfig.TYPE_RIVER:
				_river_count += 1
				
				# 为该河流点生成随机缓冲区距离
				var buffer_distance = randi_range(
					Config.SwampConfig.RIVER_FLOODPLAIN_BUFFER_DISTANCE_MIN,
					Config.SwampConfig.RIVER_FLOODPLAIN_BUFFER_DISTANCE_MAX
				)
				
				# 优化：直接生成缓冲区内的点，无需排序
				_add_flood_buffer_fast(check_pos, buffer_distance, floodplain, 
									  world_start_x, world_end_x, world_start_y, world_end_y)
	
	# 步骤2：根据洪泛平原数据和噪声生成沼泽
	var swamp_generated = 0  # 统计生成的沼泽数量
	var forest_checked = 0   # 统计检查的森林格子数量
	
	for x in range(Config.RenderConfig.CHUNK_SIZE):
		for y in range(Config.RenderConfig.CHUNK_SIZE):
			var world_pos = Vector2i(world_start_x + x, world_start_y + y)
			var current_terrain = terrain_data.get(world_pos, Config.TerrainConfig.TYPE_EMPTY)
			
			# 只在森林地形上生成沼泽（匹配C++的is_ot_match("forest", ot_match_type::contains)）
			if current_terrain != Config.TerrainConfig.TYPE_FOREST and current_terrain != Config.TerrainConfig.TYPE_FOREST_THICK:
				continue
			
			forest_checked += 1
			
			# 获取当前位置的洪泛平原噪声值
			var noise_value = floodplain_noise_at(world_pos)
			
			# 检查是否应该生成河流邻近沼泽
			var floodplain_count = floodplain.get(world_pos, 0)
			var should_flood = false
			
			if floodplain_count > 0:
				# 洪泛平原概率：计数越高，生成概率越大（!one_in(floodplain_count)）
				var flood_chance = 1.0 - (1.0 / float(floodplain_count))
				var random_roll = randf()
				
				should_flood = (random_roll < flood_chance and 
							   noise_value > Config.SwampConfig.NOISE_THRESHOLD_ADJACENT_WATER)
			
			# 检查是否应该生成独立沼泽
			var should_isolated_swamp = noise_value > Config.SwampConfig.NOISE_THRESHOLD_ISOLATED
			
			# 如果满足任一条件，生成沼泽
			if should_flood or should_isolated_swamp:
				terrain_data[world_pos] = Config.TerrainConfig.TYPE_SWAMP
				swamp_generated += 1
	
	# 性能统计输出（调试时可启用）
	if Config.SwampConfig.ENABLE_PERFORMANCE_LOGGING and (_river_count > 10 or swamp_generated > 5):  # 只在有意义的情况下输出
		print("沼泽生成统计 - 区块 ", chunk_coord, ": 河流数=", _river_count, 
			  ", 森林检查=", forest_checked, ", 沼泽生成=", swamp_generated)

# ============================================================================
# 调试信息系统
# ============================================================================

func get_terrain_type(world_x: int, world_y: int) -> String:
	"""获取指定世界坐标的地形类型描述，支持线性地形系统"""
	var world_coord = Vector2i(world_x, world_y)
	var terrain_type = terrain_data.get(world_coord, Config.TerrainConfig.TYPE_EMPTY)
	
	# 检查是否为线性道路地形
	if terrain_type == Config.TerrainConfig.TYPE_ROAD:
		var linear_info = get_linear_terrain_info(world_coord)
		if not linear_info.is_empty():
			var line_value = linear_info.get("line_value", -1)
			return Config.TerrainConfig.get_linear_terrain_name(line_value)
	
	# 常规地形类型
	match terrain_type:
		Config.TerrainConfig.TYPE_EMPTY:
			return "空地"
		Config.TerrainConfig.TYPE_LAND:
			return "田野/草地"
		Config.TerrainConfig.TYPE_RIVER:
			return "河流"
		Config.TerrainConfig.TYPE_LAKE_SURFACE:
			return "湖泊表面"
		Config.TerrainConfig.TYPE_LAKE_SHORE:
			return "湖岸"
		Config.TerrainConfig.TYPE_FOREST:
			return "森林"
		Config.TerrainConfig.TYPE_FOREST_THICK:
			return "密林"
		Config.TerrainConfig.TYPE_SWAMP:
			return "沼泽"
		Config.TerrainConfig.TYPE_ROAD:
			return "道路"
		Config.TerrainConfig.TYPE_CITY_TILE:
			return "城市建筑"
		_:
			return "未知 (%d)" % terrain_type

func get_simple_info() -> String:
	"""返回简化的玩家位置信息，用于UI显示"""
	if ui_disabled:
		return ""
		
	var world_pos = player_ref.global_position if player_ref else Vector2.ZERO
	var world_grid_x = int(world_pos.x / Config.RenderConfig.TILE_SIZE)
	var world_grid_y = int(world_pos.y / Config.RenderConfig.TILE_SIZE)
	var current_chunk = Vector2i(
		int(floor(float(world_grid_x) / Config.RenderConfig.CHUNK_SIZE)),
		int(floor(float(world_grid_y) / Config.RenderConfig.CHUNK_SIZE))
	)
	
	# 计算当前区块的城市数量
	var cities_in_current_chunk = 0
	for city in cities:
		if city.pos_om == current_chunk:
			cities_in_current_chunk += 1

	# 检查当前位置的线性地形信息
	var current_world_coord = Vector2i(world_grid_x, world_grid_y)
	var linear_info = get_linear_terrain_info(current_world_coord)
	var linear_terrain_desc = ""
	if not linear_info.is_empty():
		var line_value = linear_info.get("line_value", -1)
		var atlas_coords = linear_info.get("atlas_coords", Vector2i(-1, -1))
		linear_terrain_desc = "\n线性地形: 值=%d, 图集=(%d,%d)" % [line_value, atlas_coords.x, atlas_coords.y]

	return "位置: (%d, %d)\n区块: (%d, %d)\n地形: %s%s\n森林密度: %.3f\n城市化程度: %d\n总城市数: %d\n本区块城市: %d\n线性地形总数: %d" % [
		world_grid_x, world_grid_y, current_chunk.x, current_chunk.y, 
		get_terrain_type(world_grid_x, world_grid_y), linear_terrain_desc, forest_size_adjust, urbanity, cities.size(), cities_in_current_chunk, linear_terrain_info.size()
	]

func get_building_info_at_position(world_grid_pos: Vector2i) -> Dictionary:
	"""
	获取指定世界坐标位置的建筑信息
	返回包含建筑类型、特殊属性等信息的字典
	"""
	if ui_disabled:
		return {"has_building": false, "terrain_type": "UI已禁用"}
		
	var result = {
		"has_building": false,
		"building_type": "",
		"building_id": "",
		"is_special": false,
		"is_unique": false,
		"terrain_type": get_terrain_type(world_grid_pos.x, world_grid_pos.y)
	}
	
	# 检查是否是城市瓦片
	var chunk_coord = Vector2i(
		int(floor(float(world_grid_pos.x) / Config.RenderConfig.CHUNK_SIZE)),
		int(floor(float(world_grid_pos.y) / Config.RenderConfig.CHUNK_SIZE))
	)
	var local_pos = Vector2i(
		world_grid_pos.x - chunk_coord.x * Config.RenderConfig.CHUNK_SIZE,
		world_grid_pos.y - chunk_coord.y * Config.RenderConfig.CHUNK_SIZE
	)
	
	# 检查是否在城市瓦片中
	if city_tiles.has(local_pos):
		result.has_building = true
		
		# 检查是否是特殊建筑
		if overmap_special_placements.has(world_grid_pos):
			result.is_special = true
			result.building_id = overmap_special_placements[world_grid_pos]
			result.building_type = _get_building_display_name(result.building_id)
			
			# 检查是否是独特建筑
			if globally_unique_buildings.has(result.building_id):
				result.is_unique = true
		else:
			# 根据距离最近城市中心的距离推断建筑类型
			var nearest_city = _find_nearest_city(world_grid_pos)
			if nearest_city:
				var dist_to_city = _square_dist(world_grid_pos, nearest_city.pos)
				var town_dist = dist_to_city * 100 / max(nearest_city.size, 1)
				
				# 使用和建筑生成相同的逻辑来推断建筑类型
				var shop_radius = Config.CityConfig.SHOP_RADIUS
				var park_radius = Config.CityConfig.PARK_RADIUS
				var shop_sigma = Config.CityConfig.SHOP_SIGMA
				var park_sigma = Config.CityConfig.PARK_SIGMA
				
				var shop_normal = shop_radius
				if shop_sigma > 0:
					shop_normal = max(shop_normal, int(_normal_roll(shop_radius, shop_sigma)))
				
				var park_normal = park_radius
				if park_sigma > 0:
					park_normal = max(park_normal, int(_normal_roll(park_radius, park_sigma)))
				
				if shop_normal > town_dist:
					result.building_type = "商店区"
				elif park_normal > town_dist:
					result.building_type = "公园区"
				else:
					result.building_type = "住宅区"
			else:
				result.building_type = "一般建筑"
	
	return result

func get_building_info_at_mouse(_mouse_pos: Vector2 = Vector2.ZERO) -> Dictionary:
	"""
	获取鼠标位置的建筑信息
	"""
	if ui_disabled:
		return {"has_building": false, "terrain_type": "UI已禁用"}
		
	# 将屏幕坐标转换为世界网格坐标
	var camera = get_viewport().get_camera_2d()
	if not camera:
		return {"has_building": false, "terrain_type": "未知"}
	
	var world_pos = camera.get_global_mouse_position()
	var world_grid_pos = Vector2i(
		int(world_pos.x / Config.RenderConfig.TILE_SIZE),
		int(world_pos.y / Config.RenderConfig.TILE_SIZE)
	)
	
	return get_building_info_at_position(world_grid_pos)

func _get_building_display_name(building_id: String) -> String:
	"""
	将建筑ID转换为显示名称
	"""
	var name_map = {
		"house_small": "小型住宅",
		"house_medium": "中型住宅", 
		"house_large": "大型住宅",
		"shop_general": "综合商店",
		"shop_supermarket": "超市",
		"shop_mall": "购物中心",
		"park_small": "小公园",
		"park_medium": "中型公园",
		"park_large": "大型公园",
		"test_mall": "测试购物中心",
		# 特殊道路特征
		"road_manhole_feature": "下水道井盖"
	}
	
	return name_map.get(building_id, building_id.capitalize())

func _find_nearest_city(world_pos: Vector2i) -> City:
	"""
	查找距离指定位置最近的城市
	"""
	var nearest_city: City = null
	var min_distance = INF
	
	for city in cities:
		var distance = _square_dist(world_pos, city.pos)
		if distance < min_distance:
			min_distance = distance
			nearest_city = city
	
	return nearest_city

func _add_flood_buffer_fast(center: Vector2i, radius: int, floodplain: Dictionary, 
						   world_start_x: int, world_end_x: int, world_start_y: int, world_end_y: int):
	"""
	优化版本的洪泛缓冲区计算，去除不必要的排序操作
	直接在圆形范围内增加洪泛计数，只处理目标区块内的点
	性能提升：O(r²) 而不是 O(r² log r²)
	"""
	var radius_sq = radius * radius
	
	# 计算需要检查的边界框，限制在目标区块范围内
	var min_x = max(center.x - radius, world_start_x)
	var max_x = min(center.x + radius, world_end_x - 1)
	var min_y = max(center.y - radius, world_start_y)
	var max_y = min(center.y + radius, world_end_y - 1)
	
	# 早期退出：如果边界框无效，直接返回
	if min_x > max_x or min_y > max_y:
		return
	
	# 只遍历边界框内的点
	for x in range(min_x, max_x + 1):
		for y in range(min_y, max_y + 1):
			var dx = x - center.x
			var dy = y - center.y
			var distance_sq = dx * dx + dy * dy
			
			# 检查是否在圆形范围内
			if distance_sq <= radius_sq:
				var point = Vector2i(x, y)
				floodplain[point] = floodplain.get(point, 0) + 1

# ============================================================================
# 城市生成系统（完全匹配C++逻辑）
# ============================================================================

func place_cities(chunk_coord: Vector2i):
	"""
	城市生成主函数，完全仿照C++版本的overmap::place_cities()函数
	处理城市间距、大小调整和城市街道网络生成
	"""
	var op_city_spacing = Config.CityConfig.CITY_SPACING
	var op_city_size = Config.CityConfig.CITY_SIZE  
	var max_urbanity = Config.CityConfig.OVERMAP_MAXIMUM_URBANITY
	
	if op_city_size <= 0:
		return
	
	# 确保城市大小调整永远不会使op_city_size降到2以下
	var city_size_adjust = min(urbanity - int(forestosity / 2.0), -1 * op_city_size + 2)
	var city_space_adjust = urbanity / 2.0
	var max_city_size = min(op_city_size + city_size_adjust, op_city_size * max_urbanity)
	
	if max_city_size < op_city_size:
		# 如果max_city_size小于op_city_size会产生奇怪的结果
		max_city_size = op_city_size
	
	if op_city_spacing > 0:
		city_space_adjust = min(city_space_adjust, op_city_spacing - 2)
		op_city_spacing = op_city_spacing - city_space_adjust + int(forestosity)
	
	# 确保间距不会过于极端
	op_city_spacing = min(op_city_spacing, 10)
	
	# 计算城市覆盖参数
	var omts_per_overmap = Config.RenderConfig.CHUNK_SIZE * Config.RenderConfig.CHUNK_SIZE
	var city_map_coverage_ratio = 1.0 / pow(2.0, op_city_spacing)
	var omts_per_city = (op_city_size * 2 + 1) * (max_city_size * 2 + 1) * 3 / 4.0
	
	# 计算当前区块应该有多少城市
	var num_cities_on_this_overmap = 0
	var cities_to_place: Array[City] = []
	
	# 检查是否已有预定义城市（模拟C++的city::get_all()）
	for c in cities:
		if c.pos_om == chunk_coord:
			num_cities_on_this_overmap += 1
			cities_to_place.append(c)
	
	# 对于每个区块，如果没有预定义城市就使用随机生成
	var use_random_cities = cities_to_place.is_empty()
	
	# 如果没有预定义城市，随机生成城市数量
	if use_random_cities:
		num_cities_on_this_overmap = _roll_remainder(omts_per_overmap * city_map_coverage_ratio / omts_per_city)
	
	var MAX_PLACEMENT_ATTEMPTS = Config.CityConfig.MAX_PLACEMENT_ATTEMPTS
	var placement_attempts = 0
	var cities_placed_in_this_chunk = 0  # 追踪当前区块已放置的城市数量
	
	# 为num_cities_on_this_overmap个城市放置种子点
	while cities_placed_in_this_chunk < num_cities_on_this_overmap and placement_attempts < MAX_PLACEMENT_ATTEMPTS:
		placement_attempts += 1
		
		var p_local: Vector2i
		var tmp = City.new()
		tmp.pos_om = chunk_coord
		
		if use_random_cities:
			# 随机创建城市大小
			var size = randi_range(op_city_size - 1, max_city_size)
			if _one_in(Config.CityConfig.TINY_CITY_CHANCE):  # 33% 微小城市
				size = int(size * Config.CityConfig.TINY_SIZE_MULTIPLIER)
			elif _one_in(Config.CityConfig.SMALL_CITY_CHANCE):  # 33% 小城市
				size = int(size * Config.CityConfig.SMALL_SIZE_MULTIPLIER)
			elif _one_in(Config.CityConfig.LARGE_CITY_CHANCE):  # 17% 大城市
				size = int(size * Config.CityConfig.LARGE_SIZE_MULTIPLIER)
			else:  # 17% 超大城市
				size = int(size * Config.CityConfig.HUGE_SIZE_MULTIPLIER)
			
			# 确保城市至少为大小2
			size = max(size, Config.CityConfig.MIN_CITY_SIZE)
			size = min(size, Config.CityConfig.MAX_CITY_SIZE)
			
			# 不要在地图边缘绘制城市，它们会被裁剪
			var c_local = Vector2i(
				randi_range(size - 1, Config.RenderConfig.CHUNK_SIZE - size), 
				randi_range(size - 1, Config.RenderConfig.CHUNK_SIZE - size)
			)
			p_local = c_local
			var p_world = _local_to_world(p_local, chunk_coord)
			
			if terrain_data.get(p_world, Config.TerrainConfig.TYPE_EMPTY) == Config.TerrainConfig.TYPE_LAND:
				placement_attempts = 0
				terrain_data[p_world] = Config.TerrainConfig.TYPE_ROAD  # 每个城市都从十字路口开始
				city_tiles[c_local] = true
				tmp.pos = p_local
				tmp.size = size
		else:
			placement_attempts = 0
			tmp = _random_entry(cities_to_place)
			p_local = tmp.pos
			var p_world = _local_to_world(p_local, chunk_coord)
			terrain_data[p_world] = Config.TerrainConfig.TYPE_ROAD
			city_tiles[tmp.pos] = true
		
		if placement_attempts == 0:
			cities.append(tmp)
			cities_placed_in_this_chunk += 1  # 增加当前区块的城市计数
			var start_dir = _random_direction()
			var cur_dir = start_dir
			
			# 追踪已放置的城市独特建筑
			var local_placed_unique_buildings: Dictionary = {}
			
			# 在4个方向上建造城市街道
			while true:
				_build_city_street(tmp.pos, tmp.size, cur_dir, tmp, local_placed_unique_buildings, chunk_coord)
				cur_dir = _turn_right(cur_dir)
				if cur_dir == start_dir:
					break
	
	# 执行城市瓦片洪水填充
	_flood_fill_city_tiles(chunk_coord)

func _build_city_street(street_start: Vector2i, cs: int, direction: int, city: City, 
						local_placed_unique_buildings: Dictionary, chunk_coord: Vector2i, block_width: int = 2):
	"""
	完全仿照C++版本的build_city_street函数
	递归生成复杂的城市街道网络，包括分支街道和建筑放置
	
	参数对应关系：
	- street_start: 对应C++ const point_om_omt &p
	- cs: 对应C++ int cs (城市大小)
	- direction: 对应C++ om_direction::type dir
	- city: 对应C++ const city &town
	- local_placed_unique_buildings: 对应C++ std::unordered_set<overmap_special_id> &placed_unique_buildings
	- chunk_coord: GDScript特有的区块坐标
	- block_width: 对应C++ int block_width (默认值2)
	"""
	var c = cs
	var croad = cs
	
	# 完全匹配C++版本的错误检查：if( dir == om_direction::type::invalid )
	if direction < 0 or direction > 3:
		print("Invalid road direction: ", direction)  # 对应C++ debugmsg
		return
	
	# 规划街道路径（对应C++的lay_out_street）
	var street_path = _lay_out_street(street_start, direction, cs + 1, chunk_coord)
	
	if street_path.size() <= 1:
		return  # 路径太短，不值得建造
	
	# 建造实际的街道（对应C++的build_connection）
	_build_connection(street_path, chunk_coord)
	
	# 沿着既定方向增长，产生子道路并放置建筑  
	# 跳过第一个节点（起始点）- 完全匹配C++的std::next()逻辑
	var new_width = randi_range(3, 5) if block_width == 2 else 2  # 完全匹配C++的随机范围逻辑
	
	for i in range(1, street_path.size()):
		c -= 1
		var current_pos = street_path[i]
		
		# 生成分支街道
		if c >= 2 and c < croad - block_width:
			croad = c
			var left = cs - randi_range(1, 3)
			var right = cs - randi_range(1, 3)
			
			# 移除长度为1的道路残端
			if left == 1:
				left += 1
			if right == 1:
				right += 1
			
			# 递归建造左右分支街道
			_build_city_street(current_pos, left, _turn_left(direction), city, 
							  local_placed_unique_buildings, chunk_coord, new_width)
			_build_city_street(current_pos, right, _turn_right(direction), city, 
							  local_placed_unique_buildings, chunk_coord, new_width)
			
			# 匹配C++版本的特殊道路检测和井盖放置逻辑
			# 在十字交叉路口有50%概率放置井盖（对应C++ one_in(2)）
			if _one_in(2):
				var world_pos = _local_to_world(current_pos, chunk_coord)
				var terrain_type = terrain_data.get(world_pos, Config.TerrainConfig.TYPE_EMPTY)
				# 检查是否为道路类型（对应C++ oter->type_is(oter_type_id("road"))）
				if terrain_type == Config.TerrainConfig.TYPE_ROAD:
					# 可以在这里添加特殊路面标记，如井盖
					# 对应C++ ter_set(rp, oter_road_nesw_manhole.id())
					_add_special_road_feature(current_pos, "manhole", chunk_coord)
		
		# 在街道两侧放置建筑
		if not _one_in(Config.CityConfig.BUILDING_CHANCE):
			_place_building(current_pos, _turn_left(direction), city, local_placed_unique_buildings, chunk_coord)
		if not _one_in(Config.CityConfig.BUILDING_CHANCE):
			_place_building(current_pos, _turn_right(direction), city, local_placed_unique_buildings, chunk_coord)
	
	# 如果我们还有空间，在城镇边缘做一个转弯
	# 似乎能形成小社区
	cs -= randi_range(1, 3)
	
	if cs >= 2 and c == 0 and street_path.size() > 0:
		var last_pos = street_path.back()
		var rnd_dir = _turn_random(direction)
		_build_city_street(last_pos, cs, rnd_dir, city, local_placed_unique_buildings, chunk_coord)
		if _one_in(5):
			_build_city_street(last_pos, cs, _opposite_direction(rnd_dir), city, 
							  local_placed_unique_buildings, chunk_coord, new_width)

func _lay_out_street(source: Vector2i, direction: int, length: int, chunk_coord: Vector2i) -> Array[Vector2i]:
	"""
	规划街道路径，对应C++的lay_out_street函数
	检查地形冲突和边界，返回实际可建造的路径
	"""
	var path: Array[Vector2i] = []
	var dir_vec = _direction_to_vector(direction)
	var actual_len = 0
	
	# 检查是否需要延长一步
	var end_pos = source + dir_vec * (length + 1)
	if _is_inbounds_local(end_pos, 1):
		var world_end = _local_to_world(end_pos, chunk_coord)
		if terrain_data.get(world_end, Config.TerrainConfig.TYPE_EMPTY) == Config.TerrainConfig.TYPE_ROAD:
			length += 1
	
	while actual_len < length:
		var pos = source + dir_vec * actual_len
		
		# 不要接近区块边界
		if not _is_inbounds_local(pos, 1):
			break
		
		var world_pos = _local_to_world(pos, chunk_coord)
		var terrain_type = terrain_data.get(world_pos, Config.TerrainConfig.TYPE_EMPTY)
		
		# 完全匹配C++版本的地形检查逻辑
		# C++: ter_id->is_river() || ter_id->is_ravine() || ter_id->is_ravine_edge() || !connection.pick_subtype_for( ter_id )
		# 只能在空地或已有道路上建造道路，不能在其他地形上建造
		if terrain_type != Config.TerrainConfig.TYPE_EMPTY and \
		   terrain_type != Config.TerrainConfig.TYPE_LAND and \
		   terrain_type != Config.TerrainConfig.TYPE_ROAD:
			break
		
		# 检查道路冲突（防止道路过于密集）
		var collided = false
		var collisions = 0
		var forward_pos = pos + dir_vec
		var backward_pos = pos - dir_vec
		
		for i in range(-1, 2):
			if collided:
				break
			for j in range(-1, 2):
				var check_pos = pos + Vector2i(i, j)
				
				# 跳过前后方向和当前位置
				if check_pos == forward_pos or check_pos == backward_pos or check_pos == pos:
					continue
				
				var check_world = _local_to_world(check_pos, chunk_coord)
				if terrain_data.get(check_world, Config.TerrainConfig.TYPE_EMPTY) == Config.TerrainConfig.TYPE_ROAD:
					collisions += 1
		
		# 停止道路紧邻运行
		if collisions >= 3:
			collided = true
			break
		
		if collided:
			break
		
		city_tiles[pos] = true
		path.append(pos)
		actual_len += 1
		
		# 如果超过1步且遇到现有道路，在此停止
		if actual_len > 1 and terrain_type == Config.TerrainConfig.TYPE_ROAD:
			break
	
	return path

# ============================================================================
# 线性地形系统变量
# ============================================================================
var linear_terrain_info: Dictionary = {}  ## 存储线性地形信息，键为世界坐标Vector2i，值为线性地形数据

# ============================================================================
# 线性地形系统函数
# ============================================================================

func _store_linear_terrain_info(world_pos: Vector2i, line_value: int, atlas_coords: Vector2i):
	"""
	存储线性地形信息，用于后续渲染和查询
	"""
	linear_terrain_info[world_pos] = {
		"line_value": line_value,
		"atlas_coords": atlas_coords,
		"terrain_type": "road_linear"
	}

func get_linear_terrain_info(world_pos: Vector2i) -> Dictionary:
	"""
	获取指定位置的线性地形信息
	"""
	return linear_terrain_info.get(world_pos, {})

func _build_connection(path: Array[Vector2i], chunk_coord: Vector2i):
	"""
	建造实际的道路连接，完全匹配C++的build_connection函数逻辑
	使用线性地形系统来设置正确的街道类型（直线、弯道、T型路口、十字路口等）
	"""
	if path.is_empty():
		return
	
	# 线性地形系统常量，完全匹配C++的om_lines命名空间
	var _LINES_SIZE = 16  # 对应om_lines::size
	var LINES_INVALID = 0  # 对应om_lines::invalid
	
	# 方向常量，匹配C++的om_direction
	var DIR_NORTH = 0
	var DIR_EAST = 1  
	var DIR_SOUTH = 2
	var DIR_WEST = 3
	var DIR_INVALID = -1
	
	# 线性地形操作函数
	var set_segment = func(line: int, dir: int) -> int:
		if dir == DIR_INVALID:
			return line
		return line | (1 << dir)
	
	var has_segment = func(line: int, dir: int) -> bool:
		if dir == DIR_INVALID:
			return false
		return bool(line & (1 << dir))
	
	var is_straight = func(line: int) -> bool:
		return line in [1, 2, 4, 5, 8, 10]  # 匹配C++的is_straight逻辑
	
	# 检查地形是否为道路的函数
	var is_road_terrain = func(world_pos: Vector2i) -> bool:
		var terrain_type = terrain_data.get(world_pos, Config.TerrainConfig.TYPE_EMPTY)
		return terrain_type == Config.TerrainConfig.TYPE_ROAD
	
	# 获取道路地形的线性值
	var get_road_line = func(world_pos: Vector2i) -> int:
		# 从线性地形信息中获取当前的线性值
		var terrain_info = linear_terrain_info.get(world_pos, {})
		return terrain_info.get("line_value", 0)
	
	# 设置线性地形的函数
	var set_linear_terrain = func(world_pos: Vector2i, line_value: int):
		# 设置基础道路地形
		terrain_data[world_pos] = Config.TerrainConfig.TYPE_ROAD
		
		# 设置对应的tileset坐标
		if line_value >= 0 and line_value < Config.TerrainConfig.LINEAR_TERRAIN_DEFINITIONS.size():
			# 使用配置管理器中的地形类型映射到tileset坐标
			var atlas_coords = Config.TerrainConfig.get_linear_terrain_atlas_coords(line_value)
			if atlas_coords != Vector2i(-1, -1):
				# 存储线性地形信息用于渲染
				_store_linear_terrain_info(world_pos, line_value, atlas_coords)
	
	# 主要的连接建造循环，完全匹配C++逻辑
	var prev_dir = DIR_INVALID
	
	for i in range(path.size()):
		var pos = path[i] 
		var world_pos = _local_to_world(pos, chunk_coord)
		
		# 计算当前节点的方向
		var new_dir = DIR_INVALID
		if i < path.size() - 1:
			var next_pos = path[i + 1]
			var diff = next_pos - pos
			if diff == Vector2i(0, -1):
				new_dir = DIR_NORTH
			elif diff == Vector2i(1, 0):
				new_dir = DIR_EAST
			elif diff == Vector2i(0, 1):
				new_dir = DIR_SOUTH
			elif diff == Vector2i(-1, 0):
				new_dir = DIR_WEST
		
		# 初始化线段值（如果已经是道路则获取现有值，否则为0）
		var new_line = get_road_line.call(world_pos)
		
		# 设置当前方向的线段
		if new_dir != DIR_INVALID:
			new_line = set_segment.call(new_line, new_dir)
		
		# 设置前一个方向的相反线段
		if prev_dir != DIR_INVALID:
			new_line = set_segment.call(new_line, _opposite_direction(prev_dir))
		
		# 检查所有相邻位置并建立连接
		for dir in [DIR_NORTH, DIR_EAST, DIR_SOUTH, DIR_WEST]:
			var neighbor_pos = world_pos + _direction_to_vector(dir)
			
			# 检查邻居是否在有效范围内
			var neighbor_chunk = Vector2i(
				int(floor(float(neighbor_pos.x) / Config.RenderConfig.CHUNK_SIZE)),
				int(floor(float(neighbor_pos.y) / Config.RenderConfig.CHUNK_SIZE))
			)
			
			# 只处理已生成区块内的邻居
			if generated_chunks.has(neighbor_chunk):
				if is_road_terrain.call(neighbor_pos):
					var near_line = get_road_line.call(neighbor_pos)
					
					# 检查是否可以连接
					if is_straight.call(near_line) or has_segment.call(near_line, new_dir):
						# 建立双向连接
						var new_near_line = set_segment.call(near_line, _opposite_direction(dir))
						set_linear_terrain.call(neighbor_pos, new_near_line)
						new_line = set_segment.call(new_line, dir)
			else:
				# 对于路径的起点和终点，自动连接到边界外
				if i == 0 or i == path.size() - 1:
					new_line = set_segment.call(new_line, dir)
		
		# 验证线段值的有效性
		if new_line == LINES_INVALID:
			print("Invalid line configuration for connection at: ", world_pos)
			# 设置为基础道路
			terrain_data[world_pos] = Config.TerrainConfig.TYPE_ROAD
		else:
			# 设置最终的线性地形
			set_linear_terrain.call(world_pos, new_line)
		
		# 标记为城市瓦片
		city_tiles[pos] = true
		
		# 更新前一个方向
		prev_dir = new_dir

func _place_building(road_pos: Vector2i, direction: int, city: City, 
					local_placed_unique_buildings: Dictionary, chunk_coord: Vector2i):
	"""
	在指定位置和方向放置建筑，完全仿照C++版本的place_building函数
	"""
	var building_pos = road_pos + _direction_to_vector(direction)
	var building_dir = _opposite_direction(direction)  # 建筑朝向与道路方向相反
	
	# 检查建筑位置是否在边界内
	if not _is_inbounds_local(building_pos, 1):
		return
	
	var building_world_pos = _local_to_world(building_pos, chunk_coord)
	
	# 首先检查建筑位置的地形是否合适
	var building_terrain = terrain_data.get(building_world_pos, Config.TerrainConfig.TYPE_EMPTY)
	if building_terrain != Config.TerrainConfig.TYPE_EMPTY and building_terrain != Config.TerrainConfig.TYPE_LAND:
		# 建筑位置地形不合适（可能是森林、河流等），跳过建筑放置
		return
	
	# 计算到城市中心的距离（使用三角距离，对应C++的trig_dist）
	var actual_distance = sqrt(_square_dist(building_world_pos, city.pos))
	var town_dist = int((actual_distance * 100) / max(city.size, 1))
	
	# 重试机制：最多尝试10次放置建筑
	for retries in range(10, 0, -1):
		var building_type = _pick_random_building_to_place(town_dist, city.size, local_placed_unique_buildings)
		
		# 检查是否可以放置这个建筑
		if _can_place_building_special(building_type, building_pos, building_dir, chunk_coord):
			# 放置建筑
			var used_positions = _place_building_special(building_type, building_pos, building_dir, city, chunk_coord)
			
			# 将使用的位置标记为城市瓦片
			for pos in used_positions:
				city_tiles[pos] = true
			
			# 标记城市独特建筑已放置
			if building_type.has("city_unique") and building_type.city_unique:
				local_placed_unique_buildings[building_type.id] = true
			
			break  # 成功放置，退出重试循环

func _add_special_road_feature(pos: Vector2i, feature_type: String, chunk_coord: Vector2i):
	"""
	在道路上添加特殊地物，对应C++版本的ter_set特殊道路变种
	简化实现：直接标记为特殊道路，不与建筑放置系统冲突
	"""
	var world_pos = _local_to_world(pos, chunk_coord)
	# 根据特征类型设置特殊道路标记
	match feature_type:
		"manhole":
			# 简单地标记这个位置有井盖，使用特殊前缀避免与建筑ID冲突
			overmap_special_placements[world_pos] = "road_manhole_feature"
		_:
			pass  # 其他特殊道路特征

func _can_place_building_special(building_type: Dictionary, pos: Vector2i, _direction: int, chunk_coord: Vector2i) -> bool:
	var world_pos = _local_to_world(pos, chunk_coord)
	var terrain_type = terrain_data.get(world_pos, Config.TerrainConfig.TYPE_EMPTY)
	
	# 基本检查：只能在空地上建造
	if terrain_type != Config.TerrainConfig.TYPE_LAND:
		return false
	
	# 检查全局独特性约束
	if building_type.has("globally_unique") and building_type.globally_unique:
		if globally_unique_buildings.has(building_type.id):
			return false
	
	# 检查建筑大小要求（简化处理）
	var building_size = building_type.get("size", Vector2i(1, 1))
	for x in range(building_size.x):
		for y in range(building_size.y):
			var check_pos = pos + Vector2i(x, y)
			var check_world_pos = _local_to_world(check_pos, chunk_coord)
			
			# 检查边界
			if not _is_inbounds_local(check_pos, 1):
				return false
			
			# 检查地形
			var check_terrain = terrain_data.get(check_world_pos, Config.TerrainConfig.TYPE_EMPTY)
			if check_terrain != Config.TerrainConfig.TYPE_LAND:
				return false
	
	return true

func _place_building_special(building_type: Dictionary, pos: Vector2i, _direction: int, _city: City, chunk_coord: Vector2i) -> Array[Vector2i]:
	"""
	放置特殊建筑，简化版的place_special
	"""
	var used_positions: Array[Vector2i] = []
	var building_size = building_type.get("size", Vector2i(1, 1))
	
	# 标记全局独特建筑
	if building_type.has("globally_unique") and building_type.globally_unique:
		globally_unique_buildings[building_type.id] = true
	
	# 放置建筑的所有瓦片
	for x in range(building_size.x):
		for y in range(building_size.y):
			var building_pos = pos + Vector2i(x, y)
			var world_pos = _local_to_world(building_pos, chunk_coord)
			
			# 设置地形为城市瓦片
			terrain_data[world_pos] = Config.TerrainConfig.TYPE_CITY_TILE
			
			# 记录特殊建筑放置
			overmap_special_placements[world_pos] = building_type.id
			
			used_positions.append(building_pos)
	
	return used_positions

func _pick_random_building_to_place(town_dist: int, town_size: int, placed_unique: Dictionary) -> Dictionary:
	"""
	选择要放置的随机建筑类型，完全仿照C++版本的pick_random_building_to_place
	"""
	# 获取商店和公园分布参数
	var shop_radius = Config.CityConfig.SHOP_RADIUS
	var park_radius = Config.CityConfig.PARK_RADIUS
	var shop_sigma = Config.CityConfig.SHOP_SIGMA
	var park_sigma = Config.CityConfig.PARK_SIGMA
	
	# 正态分布调整商店和公园分布区域
	# 限制在半径的一半以防止房屋在城市中心生成
	# 公园几乎可以保证在城市任何地方都有生成概率
	var shop_normal = shop_radius
	if shop_sigma > 0:
		shop_normal = max(shop_normal, int(_normal_roll(shop_radius, shop_sigma)))
	
	var park_normal = park_radius
	if park_sigma > 0:
		park_normal = max(park_normal, int(_normal_roll(park_radius, park_sigma)))
	
	# 根据距离选择建筑类型
	var building_category: String
	if shop_normal > town_dist:
		building_category = "shops"
	elif park_normal > town_dist:
		building_category = "parks"
	else:
		building_category = "houses"
	
	# 获取建筑类型列表
	var building_types = Config.CityConfig.get_building_types()
	var available_buildings = building_types[building_category]
	
	# 循环选择，直到找到有效的建筑
	var attempts = 0
	while attempts < 100:  # 防止无限循环
		var ret = _random_entry(available_buildings)
		
		# 检查独特性约束
		var existing_unique = false
		if ret.has("city_unique") and ret.city_unique:
			existing_unique = placed_unique.has(ret.id)
		elif ret.has("globally_unique") and ret.globally_unique:
			existing_unique = globally_unique_buildings.has(ret.id)
		
		# 检查城市大小约束（简化版）
		var size_valid = true
		if ret.has("min_city_size"):
			size_valid = town_size >= ret.min_city_size
		if ret.has("max_city_size"):
			size_valid = size_valid and town_size <= ret.max_city_size
		
		if not existing_unique and size_valid:
			return ret
		
		attempts += 1
	
	# 如果找不到合适的建筑，返回默认房屋
	return {"id": "house_small", "size": Vector2i(1, 1), "city_unique": false, "globally_unique": false}

func _normal_roll(mean: float, sigma: float) -> float:
	"""
	正态分布随机数生成（简化版Box-Muller变换）
	"""
	if sigma <= 0:
		return mean
	
	# 简化的正态分布近似
	var u1 = randf()
	var u2 = randf()
	var z = sqrt(-2.0 * log(u1)) * cos(2.0 * PI * u2)
	return mean + sigma * z

func _can_place_building(pos: Vector2i, _building_type: Dictionary, chunk_coord: Vector2i) -> bool:
	"""
	检查是否可以在指定位置放置建筑
	"""
	var building_world_pos = _local_to_world(pos, chunk_coord)
	var terrain_type = terrain_data.get(building_world_pos, Config.TerrainConfig.TYPE_EMPTY)
	
	# 只能在空地上建造
	return terrain_type == Config.TerrainConfig.TYPE_LAND

func _can_place_special(special: Dictionary, pos: Vector2i, direction: int, 
						chunk_coord: Vector2i, must_be_unexplored: bool = false) -> bool:
	"""
	检查特殊建筑是否可以放置，仿照C++版本的can_place_special
	"""
	if direction < 0 or direction > 3:
		return false
	
	if not special.has("id") or special.id.is_empty():
		return false
	
	# 检查全局独特性约束
	if special.has("globally_unique") and special.globally_unique:
		if globally_unique_buildings.has(special.id):
			return false
	
	# 如果有怪物生成区域，检查是否与安全区域冲突
	if special.has("monster_spawns") and special.monster_spawns.has("group"):
		var spawns = special.monster_spawns
		var radius = spawns.get("radius_max", 5)
		
		# 检查生成半径内是否有安全区域
		for x in range(pos.x - radius, pos.x + radius + 1):
			for y in range(pos.y - radius, pos.y + radius + 1):
				var check_pos = Vector2i(x, y)
				var world_pos = _local_to_world(check_pos, chunk_coord)
				if overmap_special_placements.has(world_pos):
					var existing_special_id = overmap_special_placements[world_pos]
					# 这里可以检查是否有"SAFE_AT_WORLDGEN"标志
					# 简化处理：假设某些建筑类型是安全的
					if existing_special_id.begins_with("shelter") or existing_special_id.begins_with("bunker"):
						return false
	
	# 检查所需的地形类型
	var required_locations = special.get("required_locations", [])
	for location in required_locations:
		var check_pos = pos + _rotate_point(location.get("offset", Vector2i.ZERO), direction)
		var world_pos = _local_to_world(check_pos, chunk_coord)
		
		# 检查边界
		if not _in_bounds(check_pos, chunk_coord):
			return false
		
		# 如果必须未探索，检查是否已生成子地图
		if must_be_unexplored:
			# 简化处理：检查是否已有地形数据
			if terrain_data.has(world_pos):
				return false
		
		# 检查地形类型是否符合要求
		var terrain_type = terrain_data.get(world_pos, Config.TerrainConfig.TYPE_LAND)
		var allowed_terrains = location.get("allowed_terrains", [Config.TerrainConfig.TYPE_LAND])
		if not allowed_terrains.has(terrain_type):
			return false
	
	return true

func _place_special(special: Dictionary, pos: Vector2i, direction: int, _city: City, 
					chunk_coord: Vector2i, must_be_unexplored: bool = false, force: bool = false) -> Array[Vector2i]:
	"""
	放置特殊建筑，仿照C++版本的place_special
	"""
	if direction < 0 or direction > 3:
		return []
	
	if not force:
		if not _can_place_special(special, pos, direction, chunk_coord, must_be_unexplored):
			return []
	
	var placed_positions: Array[Vector2i] = []
	
	# 标记全局独特建筑
	if special.has("globally_unique") and special.globally_unique:
		globally_unique_buildings[special.id] = true
	elif special.has("city_unique") and special.city_unique:
		placed_unique_buildings[special.id] = true
	
	# 标记建筑为安全区域（如果适用）
	var is_safe_zone = special.get("safe_at_worldgen", false)
	
	# 放置建筑的所有组件
	var building_locations = special.get("locations", [{"offset": Vector2i.ZERO}])
	for location in building_locations:
		var building_pos = pos + _rotate_point(location.get("offset", Vector2i.ZERO), direction)
		var world_pos = _local_to_world(building_pos, chunk_coord)
		
		# 设置地形
		var building_terrain = location.get("terrain_type", Config.TerrainConfig.TYPE_CITY_TILE)
		terrain_data[world_pos] = building_terrain
		city_tiles[building_pos] = true
		
		# 记录特殊建筑放置
		overmap_special_placements[world_pos] = special.id
		placed_positions.append(building_pos)
	
	# 放置怪物生成点（如果有）
	if special.has("monster_spawns") and special.monster_spawns.has("group"):
		var spawns = special.monster_spawns
		var pop = randi_range(spawns.get("population_min", 1), spawns.get("population_max", 5))
		var rad = randi_range(spawns.get("radius_min", 1), spawns.get("radius_max", 3))
		
		# 这里可以添加怪物群组生成逻辑
		print("Would spawn ", pop, " monsters of type ", spawns.group, " with radius ", rad, " at ", pos)
	
	# 如果是安全区域，移除现有生成点
	if is_safe_zone:
		# 这里可以移除指定区域内的怪物生成点
		pass
	
	return placed_positions

func _rotate_point(point: Vector2i, direction: int) -> Vector2i:
	"""
	根据方向旋转点，对应C++中的om_direction::rotate
	"""
	match direction:
		0:  # 北
			return point
		1:  # 东
			return Vector2i(-point.y, point.x)
		2:  # 南
			return Vector2i(-point.x, -point.y)
		3:  # 西
			return Vector2i(point.y, -point.x)
		_:
			return point

func _straight_path(source: Vector2i, direction: int, length: int) -> Array[Vector2i]:
	"""
	生成直线路径，对应C++版本的straight_path
	"""
	var path: Array[Vector2i] = []
	if length == 0:
		return path
	
	var current_pos = source
	var dir_vector = _direction_to_vector(direction)
	
	path.resize(length)
	for i in range(length):
		path.append(current_pos)
		if i < length - 1:  # 不在最后一个位置移动
			current_pos += dir_vector
	
	return path

func _in_bounds(pos: Vector2i, _chunk_coord: Vector2i) -> bool:
	"""
	检查位置是否在区块边界内
	"""
	return pos.x >= 0 and pos.x < Config.RenderConfig.CHUNK_SIZE and \
		   pos.y >= 0 and pos.y < Config.RenderConfig.CHUNK_SIZE

func _flood_fill_city_tiles(_chunk_coord: Vector2i):
	"""
	城市瓦片洪水填充，完全仿照C++版本的flood_fill_city_tiles()函数
	寻找被城市瓦片包围的区域并将其标记为城市的一部分
	"""
	var visited: Dictionary = {}
	
	# 计算区块边界
	var chunk_bounds = Rect2i(Vector2i(0, 0), Vector2i(Config.RenderConfig.CHUNK_SIZE, Config.RenderConfig.CHUNK_SIZE))
	
	# 遍历区块内的每个点
	for y in range(Config.RenderConfig.CHUNK_SIZE):
		for x in range(Config.RenderConfig.CHUNK_SIZE):
			var checked = Vector2i(x, y)
			
			# 如果已经在之前的洪水填充中查看过，忽略它
			if visited.has(checked):
				continue
			
			# 检查连接到此点的区域是否被city_tiles包围
			var enclosed = [true]  # 使用数组来解决闭包捕获问题
			
			# 洪水填充的谓词，同时检测是否有点洪水填充到了区块边缘
			var is_unchecked = func(pt: Vector2i) -> bool:
				if city_tiles.has(pt):
					return false
				
				# 我们碰到了区块边缘！我们自由了！
				if not chunk_bounds.has_point(pt):
					enclosed[0] = false
					return false
				
				return true
			
			# 连接到此点且不属于城市的所有点
			var area = _point_flood_fill_4_connected(checked, visited, is_unchecked)
			if not enclosed[0]:
				continue
			
			# 它们被包围了，所以应该被视为城市的一部分
			for pt in area:
				city_tiles[pt] = true

# ============================================================================
# 城市生成辅助函数
# ============================================================================

func _roll_remainder(value: float) -> int:
	"""
	对浮点数进行概率性向上取整
	模拟C++版本的roll_remainder函数
	"""
	var base = int(value)
	var remainder = value - base
	if randf() < remainder:
		return base + 1
	return base

func _random_direction() -> int:
	"""返回随机方向（0-3）"""
	return randi() % 4

func _turn_right(direction: int) -> int:
	"""向右转90度"""
	return (direction + 1) % 4

func _turn_left(direction: int) -> int:
	"""向左转90度"""
	return (direction + 3) % 4

func _opposite_direction(direction: int) -> int:
	"""返回相反方向"""
	return (direction + 2) % 4

func _turn_random(direction: int) -> int:
	"""随机转向（左或右）"""
	return _turn_left(direction) if _one_in(2) else _turn_right(direction)

func _direction_to_vector(direction: int) -> Vector2i:
	"""将方向转换为向量"""
	match direction:
		0: return Vector2i(0, -1)  # 北
		1: return Vector2i(1, 0)   # 东
		2: return Vector2i(0, 1)   # 南
		3: return Vector2i(-1, 0)  # 西
		_: return Vector2i.ZERO

func _get_perpendicular_directions(direction: int) -> Array[int]:
	"""获取垂直方向"""
	match direction:
		0, 2: return [1, 3]  # 北/南 -> 东/西
		1, 3: return [0, 2]  # 东/西 -> 北/南
		_: return [0, 1, 2, 3]
