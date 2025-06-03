extends Control
class_name OvermapRenderer

# 连续地图overmap渲染器

# 地图设置
const MAP_SIZE = 180  # 当前渲染区域：180x180 格子
const CELL_SIZE = 4   # 每个格子4像素
const BORDER_THRESHOLD = 11  # 距离边缘11格时创建新区块
const CANVAS_SIZE = MAP_SIZE * CELL_SIZE  # 720x720 像素
const CHUNK_SIZE = 180  # 区块大小

# 颜色设置
const TERRAIN_COLOR = Color.GREEN
const EMPTY_COLOR = Color.DARK_GREEN
const PLAYER_COLOR = Color.RED
const RIVER_COLOR = Color.BLUE # 新增河流颜色
const DEBUG_RIVER_START_END_COLOR = Color.YELLOW # 新增调试颜色

# 地形类型
const TERRAIN_TYPE_EMPTY = 0
const TERRAIN_TYPE_LAND = 1
const TERRAIN_TYPE_RIVER = 2
const TERRAIN_TYPE_DEBUG_RIVER_START_END = 3 # 新增调试地形类型
# 新增河流生成参数
const RIVER_DENSITY_PARAM = 1 # 对应 C++ settings->river_scale, 0.0 表示无河流. 值越小河越多但可能越细, 值越大河越少但可能越宽.
								# 例如 0.5 -> chance_divider=2, brush_size=1. 2.0 -> chance_divider=1, brush_size=2.

# 玩家和地图状态
var player_ref: CharacterBody2D
var terrain_data: Dictionary = {}  # 存储所有地形数据，key为世界坐标Vector2i
var generated_chunks: Dictionary = {}  # 已生成的区块，key为区块坐标Vector2i

# 渲染变量
var canvas_texture: ImageTexture
var canvas_image: Image

# 防止无限循环的变量
var chunk_creation_cooldown: float = 0.0
var COOLDOWN_TIME: float = 0.5  # 半秒冷却时间

func _ready():
	add_to_group("overmap_manager")
	setup_canvas()
	
	# 查找玩家
	await get_tree().process_frame
	player_ref = get_tree().get_first_node_in_group("player")
	if not player_ref:
		print("警告：未找到玩家节点")
		return
	
	# 生成初始区块（0,0区块）
	generate_chunk_at(Vector2i(0, 0))

func _process(delta):
	if chunk_creation_cooldown > 0:
		chunk_creation_cooldown -= delta
	
	if not player_ref:
		return
	
	# 检查玩家位置，必要时生成新区块
	check_and_generate_chunks()
	
	# 更新画布
	update_canvas_rendering()

func setup_canvas():
	"""初始化画布"""
	canvas_image = Image.create(CANVAS_SIZE, CANVAS_SIZE, false, Image.FORMAT_RGB8)
	canvas_texture = ImageTexture.new()
	canvas_texture.set_image(canvas_image)

func check_and_generate_chunks():
	"""检查玩家位置并在需要时生成新区块"""
	if chunk_creation_cooldown > 0:
		return
	
	var world_pos = player_ref.global_position
	var world_grid_x = int(world_pos.x / 32.0)
	var world_grid_y = int(world_pos.y / 32.0)
	
	# 计算玩家当前所在的区块
	var current_chunk = Vector2i(
		int(floor(float(world_grid_x) / CHUNK_SIZE)),
		int(floor(float(world_grid_y) / CHUNK_SIZE))
	)
	
	# 计算玩家在当前区块内的位置
	var local_x = world_grid_x - current_chunk.x * CHUNK_SIZE
	var local_y = world_grid_y - current_chunk.y * CHUNK_SIZE
	
	# 检查是否接近边缘，如果是则生成相邻区块
	var need_generation = false
	
	if local_x < BORDER_THRESHOLD:
		generate_chunk_at(current_chunk + Vector2i(-1, 0))
		need_generation = true
	if local_x >= CHUNK_SIZE - BORDER_THRESHOLD:
		generate_chunk_at(current_chunk + Vector2i(1, 0))
		need_generation = true
	if local_y < BORDER_THRESHOLD:
		generate_chunk_at(current_chunk + Vector2i(0, -1))
		need_generation = true
	if local_y >= CHUNK_SIZE - BORDER_THRESHOLD:
		generate_chunk_at(current_chunk + Vector2i(0, 1))
		need_generation = true
	
	if need_generation:
		chunk_creation_cooldown = COOLDOWN_TIME

func generate_chunk_at(chunk_coord: Vector2i):
	"""生成指定坐标的区块"""
	if generated_chunks.has(chunk_coord):
		return
	
	generated_chunks[chunk_coord] = true
	
	# 计算区块在世界坐标中的起始位置
	var world_start_x = chunk_coord.x * CHUNK_SIZE
	var world_start_y = chunk_coord.y * CHUNK_SIZE
	
	# 生成区块内的地形（默认为土地）
	for x_local in range(CHUNK_SIZE): # Renamed to x_local for clarity
		for y_local in range(CHUNK_SIZE): # Renamed to y_local for clarity
			var world_x = world_start_x + x_local
			var world_y = world_start_y + y_local
			
			terrain_data[Vector2i(world_x, world_y)] = TERRAIN_TYPE_LAND # 修正：设置为土地类型
	
	# 在基础地形生成后，尝试生成河流
	if RIVER_DENSITY_PARAM > 0.0:
		_place_rivers_for_chunk(chunk_coord)

func _place_rivers_for_chunk(p_chunk_coord: Vector2i):
	# GDScript translation of C++ place_rivers function
	# OMAPX and OMAPY are CHUNK_SIZE in this context
	var river_placement_chance_divider = int(max(1.0, 1.0 / RIVER_DENSITY_PARAM))
	var river_brush_size_factor = int(max(1.0, RIVER_DENSITY_PARAM))

	var river_starts_local: Array[Vector2i] = [] # Local coords within the chunk
	var river_ends_local: Array[Vector2i] = []   # Local coords within the chunk

	# --- Determine points where rivers & roads should connect w/ adjacent maps ---
	# Helper to check for river in world coordinates
	var is_world_coord_river = func(world_coord: Vector2i):
		var terrain_type = terrain_data.get(world_coord, TERRAIN_TYPE_EMPTY)
		return terrain_type == TERRAIN_TYPE_RIVER or terrain_type == TERRAIN_TYPE_DEBUG_RIVER_START_END # MODIFIED

	var starts_from_north_added = 0
	# North neighbor
	var north_chunk_coord = p_chunk_coord + Vector2i(0, -1)
	if generated_chunks.has(north_chunk_coord): # Equivalent to C++ (north != nullptr)
		for i in range(2, CHUNK_SIZE - 2):
			var p_neighbour_world = _local_to_world(Vector2i(i, CHUNK_SIZE - 1), north_chunk_coord)
			var p_mine_local = Vector2i(i, 0)
			var p_mine_world = _local_to_world(p_mine_local, p_chunk_coord)

			if is_world_coord_river.call(p_neighbour_world):
				terrain_data[p_mine_world] = TERRAIN_TYPE_RIVER
			
			if is_world_coord_river.call(p_neighbour_world) and \
			   is_world_coord_river.call(p_neighbour_world + Vector2i(1, 0)) and \
			   is_world_coord_river.call(p_neighbour_world + Vector2i(-1, 0)):
				if starts_from_north_added < 3 and \
				   _one_in(river_placement_chance_divider) and (river_starts_local.is_empty() or \
				   river_starts_local.back().x < (i - 6) * river_brush_size_factor ): # river_scale in C++ is river_brush_size_factor here for spacing
					river_starts_local.append(p_mine_local)
					starts_from_north_added += 1

	var rivers_from_north_count = river_starts_local.size()
	var starts_from_west_added = 0
	# West neighbor
	var west_chunk_coord = p_chunk_coord + Vector2i(-1, 0)
	if generated_chunks.has(west_chunk_coord): # Equivalent to C++ (west != nullptr)
		for i in range(2, CHUNK_SIZE - 2):
			var p_neighbour_world = _local_to_world(Vector2i(CHUNK_SIZE - 1, i), west_chunk_coord)
			var p_mine_local = Vector2i(0, i)
			var p_mine_world = _local_to_world(p_mine_local, p_chunk_coord)

			if is_world_coord_river.call(p_neighbour_world):
				terrain_data[p_mine_world] = TERRAIN_TYPE_RIVER

			if is_world_coord_river.call(p_neighbour_world) and \
			   is_world_coord_river.call(p_neighbour_world + Vector2i(0, 1)) and \
			   is_world_coord_river.call(p_neighbour_world + Vector2i(0, -1)):
				if starts_from_west_added < 3 and \
				   _one_in(river_placement_chance_divider) and (river_starts_local.size() == rivers_from_north_count or \
				   river_starts_local.back().y < (i - 6) * river_brush_size_factor):
					river_starts_local.append(p_mine_local)
					starts_from_west_added += 1
	
	var ends_from_south_added = 0
	# South neighbor
	var south_chunk_coord = p_chunk_coord + Vector2i(0, 1)
	if generated_chunks.has(south_chunk_coord): # Equivalent to C++ (south != nullptr)
		for i in range(2, CHUNK_SIZE - 2):
			var p_neighbour_world = _local_to_world(Vector2i(i, 0), south_chunk_coord)
			var p_mine_local = Vector2i(i, CHUNK_SIZE - 1)
			var p_mine_world = _local_to_world(p_mine_local, p_chunk_coord)

			if is_world_coord_river.call(p_neighbour_world):
				terrain_data[p_mine_world] = TERRAIN_TYPE_RIVER

			if is_world_coord_river.call(p_neighbour_world) and \
			   is_world_coord_river.call(p_neighbour_world + Vector2i(1, 0)) and \
			   is_world_coord_river.call(p_neighbour_world + Vector2i(-1, 0)):
				if ends_from_south_added < 3 and \
				   (river_ends_local.is_empty() or \
				   river_ends_local.back().x < (i - 6) ): # Spacing, original C++ seems to not use river_scale here
					river_ends_local.append(p_mine_local)
					ends_from_south_added += 1
	
	var rivers_to_south_count = river_ends_local.size()
	var ends_from_east_added = 0
	# East neighbor
	var east_chunk_coord = p_chunk_coord + Vector2i(1, 0)
	if generated_chunks.has(east_chunk_coord): # Equivalent to C++ (east != nullptr)
		for i in range(2, CHUNK_SIZE - 2):
			var p_neighbour_world = _local_to_world(Vector2i(0, i), east_chunk_coord)
			var p_mine_local = Vector2i(CHUNK_SIZE - 1, i)
			var p_mine_world = _local_to_world(p_mine_local, p_chunk_coord)

			if is_world_coord_river.call(p_neighbour_world):
				terrain_data[p_mine_world] = TERRAIN_TYPE_RIVER
			
			if is_world_coord_river.call(p_neighbour_world) and \
			   is_world_coord_river.call(p_neighbour_world + Vector2i(0, 1)) and \
			   is_world_coord_river.call(p_neighbour_world + Vector2i(0, -1)):
				if ends_from_east_added < 3 and \
				   (river_ends_local.size() == rivers_to_south_count or \
				   river_ends_local.back().y < (i - 6)): # Spacing
					river_ends_local.append(p_mine_local)
					ends_from_east_added += 1

	# --- Even up the start and end points of rivers ---
	var new_rivers_buffer: Array[Vector2i] = []
	var has_north_neighbor = generated_chunks.has(north_chunk_coord)
	var has_west_neighbor = generated_chunks.has(west_chunk_coord)
	var has_south_neighbor = generated_chunks.has(south_chunk_coord)
	var has_east_neighbor = generated_chunks.has(east_chunk_coord)

	if not has_north_neighbor or not has_west_neighbor:
		while river_starts_local.is_empty() or river_starts_local.size() + 1 < river_ends_local.size():
			new_rivers_buffer.clear()
			if not has_north_neighbor and _one_in(river_placement_chance_divider):
				new_rivers_buffer.append(Vector2i(randi_range(10, CHUNK_SIZE - 11), 0))
			if not has_west_neighbor and _one_in(river_placement_chance_divider):
				new_rivers_buffer.append(Vector2i(0, randi_range(10, CHUNK_SIZE - 11)))
			if not new_rivers_buffer.is_empty():
				river_starts_local.append(_random_entry(new_rivers_buffer))
			else: # Avoid infinite loop if no new rivers can be added
				break 

	if not has_south_neighbor or not has_east_neighbor:
		while river_ends_local.is_empty() or river_ends_local.size() + 1 < river_starts_local.size():
			new_rivers_buffer.clear()
			if not has_south_neighbor and _one_in(river_placement_chance_divider):
				new_rivers_buffer.append(Vector2i(randi_range(10, CHUNK_SIZE - 11), CHUNK_SIZE - 1))
			if not has_east_neighbor and _one_in(river_placement_chance_divider):
				new_rivers_buffer.append(Vector2i(CHUNK_SIZE - 1, randi_range(10, CHUNK_SIZE - 11)))
			if not new_rivers_buffer.is_empty():
				river_ends_local.append(_random_entry(new_rivers_buffer))
			else: # Avoid infinite loop
				break

	# --- Now actually place those rivers ---
	if river_starts_local.size() > river_ends_local.size() and not river_ends_local.is_empty():
		var river_ends_copy = river_ends_local.duplicate()
		while not river_starts_local.is_empty():
			var start_pos = _random_entry_removed(river_starts_local)
			if not river_ends_local.is_empty():
				var end_pos = river_ends_local.pop_front() # Erase begin
				_draw_single_river_path(p_chunk_coord, start_pos, end_pos)
				# Mark start and end points for debugging AFTER drawing the river
				terrain_data[_local_to_world(start_pos, p_chunk_coord)] = TERRAIN_TYPE_DEBUG_RIVER_START_END
				terrain_data[_local_to_world(end_pos, p_chunk_coord)] = TERRAIN_TYPE_DEBUG_RIVER_START_END
			elif not river_ends_copy.is_empty(): # C++ random_entry(river_end_copy)
				var end_pos = _random_entry(river_ends_copy)
				_draw_single_river_path(p_chunk_coord, start_pos, end_pos)
				# Mark start and end points for debugging AFTER drawing the river
				terrain_data[_local_to_world(start_pos, p_chunk_coord)] = TERRAIN_TYPE_DEBUG_RIVER_START_END
				terrain_data[_local_to_world(end_pos, p_chunk_coord)] = TERRAIN_TYPE_DEBUG_RIVER_START_END
	elif river_ends_local.size() > river_starts_local.size() and not river_starts_local.is_empty():
		var river_starts_copy = river_starts_local.duplicate()
		while not river_ends_local.is_empty():
			var end_pos = _random_entry_removed(river_ends_local)
			if not river_starts_local.is_empty():
				var start_pos = river_starts_local.pop_front() # Erase begin
				_draw_single_river_path(p_chunk_coord, start_pos, end_pos)
				# Mark start and end points for debugging AFTER drawing the river
				terrain_data[_local_to_world(start_pos, p_chunk_coord)] = TERRAIN_TYPE_DEBUG_RIVER_START_END
				terrain_data[_local_to_world(end_pos, p_chunk_coord)] = TERRAIN_TYPE_DEBUG_RIVER_START_END
			elif not river_starts_copy.is_empty():
				var start_pos = _random_entry(river_starts_copy)
				_draw_single_river_path(p_chunk_coord, start_pos, end_pos)
				# Mark start and end points for debugging AFTER drawing the river
				terrain_data[_local_to_world(start_pos, p_chunk_coord)] = TERRAIN_TYPE_DEBUG_RIVER_START_END
				terrain_data[_local_to_world(end_pos, p_chunk_coord)] = TERRAIN_TYPE_DEBUG_RIVER_START_END
	elif not river_ends_local.is_empty(): # Sizes are equal or start was empty and end was not (covered by first if)
		if river_starts_local.size() != river_ends_local.size(): # Should be equal or handled above, C++ had a fallback
			# This case in C++ adds a random start point if sizes don't match but both are non-empty.
			# For simplicity, if they are non-empty and not equal here, it implies an issue with prior logic or direct C++ port.
			# The C++ code `river_start.emplace_back( rng( OMAPX / 4, ( OMAPX * 3 ) / 4 ), rng( OMAPY / 4, ( OMAPY * 3 ) / 4 ) );`
			# suggests adding a random internal river if counts mismatch unexpectedly.
			# Let's ensure they are paired if both have elements.
			pass # Assuming prior logic balanced them or one is empty.
		
		# Shuffle one of them to get varied pairings if sizes are equal
		river_ends_local.shuffle()
		for i in range(min(river_starts_local.size(), river_ends_local.size())):
			var start_pos = river_starts_local[i]
			var end_pos = river_ends_local[i]
			_draw_single_river_path(p_chunk_coord, start_pos, end_pos)
			# Mark start and end points for debugging AFTER drawing the river
			terrain_data[_local_to_world(start_pos, p_chunk_coord)] = TERRAIN_TYPE_DEBUG_RIVER_START_END
			terrain_data[_local_to_world(end_pos, p_chunk_coord)] = TERRAIN_TYPE_DEBUG_RIVER_START_END


func _draw_single_river_path(p_chunk_coord: Vector2i, pa_local: Vector2i, pb_local: Vector2i):
	# GDScript translation of C++ place_river function
	var river_placement_chance_divider = int(max(1.0, 1.0 / RIVER_DENSITY_PARAM))
	var river_brush_size_factor = int(max(1.0, RIVER_DENSITY_PARAM))

	var p2_local = pa_local # Current point, local to chunk
	
	var iterations = 0 # Safety break for the loop
	var max_iterations = CHUNK_SIZE * CHUNK_SIZE * 2 # Heuristic limit

	while p2_local != pb_local and iterations < max_iterations:
		iterations += 1
		var prev_p2_local = p2_local

		# --- First block of river drawing from C++ ---
		# Random walk component
		p2_local.x += randi_range(-1, 1)
		p2_local.y += randi_range(-1, 1)
		p2_local.x = clamp(p2_local.x, 0, CHUNK_SIZE - 1)
		p2_local.y = clamp(p2_local.y, 0, CHUNK_SIZE - 1)

		_apply_river_brush(p_chunk_coord, p2_local, river_brush_size_factor, river_placement_chance_divider)

		# --- Move towards pb_local (target point) ---
		# Simplified C++ logic for moving p2 towards pb
		var OMAPX_times_1_2 = int(CHUNK_SIZE * 1.2)
		var OMAPY_times_1_2 = int(CHUNK_SIZE * 1.2)
		var OMAPX_times_0_2 = int(CHUNK_SIZE * 0.2)
		var OMAPY_times_0_2 = int(CHUNK_SIZE * 0.2)

		if pb_local.x > p2_local.x and (randi_range(0, OMAPX_times_1_2 -1) < pb_local.x - p2_local.x or \
		   (randi_range(0, OMAPX_times_0_2-1) > pb_local.x - p2_local.x and randi_range(0, OMAPY_times_0_2-1) > abs(pb_local.y - p2_local.y))):
			p2_local.x += 1
		if pb_local.x < p2_local.x and (randi_range(0, OMAPX_times_1_2 -1) < p2_local.x - pb_local.x or \
		   (randi_range(0, OMAPX_times_0_2-1) > p2_local.x - pb_local.x and randi_range(0, OMAPY_times_0_2-1) > abs(pb_local.y - p2_local.y))):
			p2_local.x -= 1
		if pb_local.y > p2_local.y and (randi_range(0, OMAPY_times_1_2 -1) < pb_local.y - p2_local.y or \
		   (randi_range(0, OMAPY_times_0_2-1) > pb_local.y - p2_local.y and randi_range(0, OMAPX_times_0_2-1) > abs(p2_local.x - pb_local.x))):
			p2_local.y += 1
		if pb_local.y < p2_local.y and (randi_range(0, OMAPY_times_1_2 -1) < p2_local.y - pb_local.y or \
		   (randi_range(0, OMAPY_times_0_2-1) > p2_local.y - pb_local.y and randi_range(0, OMAPX_times_0_2-1) > abs(p2_local.x - pb_local.x))):
			p2_local.y -= 1
		
		# Clamp after movement
		p2_local.x = clamp(p2_local.x, 0, CHUNK_SIZE - 1)
		p2_local.y = clamp(p2_local.y, 0, CHUNK_SIZE - 1)

		# --- Second block of river drawing from C++ (slightly different conditions) ---
		# Another random step
		p2_local.x += randi_range(-1, 1)
		p2_local.y += randi_range(-1, 1)
		p2_local.x = clamp(p2_local.x, 0, CHUNK_SIZE - 1) # C++ used OMAPX-2 for x max here, but OMAPX-1 for y. Sticking to CHUNK_SIZE-1 for consistency.
		p2_local.y = clamp(p2_local.y, 0, CHUNK_SIZE - 1)

		# Apply brush, considering C++ `inbounds` logic
		for i in range(-river_brush_size_factor, river_brush_size_factor + 1):
			for j in range(-river_brush_size_factor, river_brush_size_factor + 1):
				var brush_point_local = p2_local + Vector2i(j, i)
				
				# C++: if( inbounds( p, 1 ) || ( std::abs( pb.y() - p.y() ) < 4 && std::abs( pb.x() - p.x() ) < 4 ) )
				var is_near_target = abs(pb_local.y - brush_point_local.y) < 4 and abs(pb_local.x - brush_point_local.x) < 4
				if _is_inbounds_local(brush_point_local, 1) or is_near_target:
					if not _is_inbounds_local(brush_point_local, 0): # C++: if( !inbounds( p ) ) continue;
						continue
					
					var world_coord = _local_to_world(brush_point_local, p_chunk_coord)
					# Assuming no lakes: C++: if( !ter( p )->is_lake() && one_in( river_chance ) )
					if _one_in(river_placement_chance_divider):
						terrain_data[world_coord] = TERRAIN_TYPE_RIVER
		
		# If p2 didn't move, and it's not the target, force a small step to avoid getting stuck.
		if p2_local == prev_p2_local and p2_local != pb_local:
			if p2_local.x < pb_local.x: p2_local.x += 1
			elif p2_local.x > pb_local.x: p2_local.x -=1
			if p2_local.y < pb_local.y: p2_local.y += 1
			elif p2_local.y > pb_local.y: p2_local.y -=1
			p2_local.x = clamp(p2_local.x, 0, CHUNK_SIZE - 1)
			p2_local.y = clamp(p2_local.y, 0, CHUNK_SIZE - 1)


	# Ensure the very last point (pb_local) is river if the loop terminated early or exactly.
	_apply_river_brush(p_chunk_coord, pb_local, river_brush_size_factor, river_placement_chance_divider, true) # Force placement at end point


func _apply_river_brush(p_chunk_coord: Vector2i, center_local: Vector2i, brush_factor: int, chance_divider: int, force_place: bool = false):
	"""Applies the river brush around a center point."""
	for i in range(-brush_factor, brush_factor + 1):
		for j in range(-brush_factor, brush_factor + 1):
			var brush_p_local = center_local + Vector2i(j, i)
			if _is_inbounds_local(brush_p_local):
				var world_coord = _local_to_world(brush_p_local, p_chunk_coord)
				# C++: if( !ter( p )->is_lake() && one_in( river_chance ) )
				# Assuming no lakes for now.
				if force_place or _one_in(chance_divider):
					terrain_data[world_coord] = TERRAIN_TYPE_RIVER

# --- Helper Functions for River Generation ---
func _local_to_world(local_pos: Vector2i, p_chunk_coord: Vector2i) -> Vector2i:
	var world_start_x = p_chunk_coord.x * CHUNK_SIZE
	var world_start_y = p_chunk_coord.y * CHUNK_SIZE
	return Vector2i(world_start_x + local_pos.x, world_start_y + local_pos.y)

func _is_inbounds_local(local_pos: Vector2i, border: int = 0) -> bool:
	return (local_pos.x >= border and local_pos.x < CHUNK_SIZE - border and \
			local_pos.y >= border and local_pos.y < CHUNK_SIZE - border)

func _one_in(chance: int) -> bool:
	if chance <= 0: return true # Or false, depending on desired behavior for invalid chance
	if chance == 1: return true
	return randi() % chance == 0

func _random_entry(arr: Array):
	if arr.is_empty():
		# Fallback or error. For now, returning a default if array is empty.
		# This should ideally not happen if logic before ensures non-empty.
		push_warning("Attempted to get random entry from empty array.")
		return Vector2i.ZERO 
	return arr[randi() % arr.size()]

func _random_entry_removed(arr: Array):
	if arr.is_empty():
		push_warning("Attempted to remove random entry from empty array.")
		return Vector2i.ZERO 
	var idx = randi() % arr.size()
	var entry = arr[idx]
	arr.remove_at(idx)
	return entry
# --- End Helper Functions ---

func update_canvas_rendering():
	canvas_image.fill(EMPTY_COLOR)
	
	# 获取玩家当前位置，计算渲染范围
	var world_pos = player_ref.global_position
	var center_world_x = int(world_pos.x / 32.0) # Assuming 32.0 is tile size for player pos
	var center_world_y = int(world_pos.y / 32.0) # Assuming 32.0 is tile size for player pos
	
	# 计算渲染区域的世界坐标范围
	var render_start_x = center_world_x - int(MAP_SIZE / 2.0)
	var render_start_y = center_world_y - int(MAP_SIZE / 2.0)
	
	# 绘制地形
	for x_canvas in range(MAP_SIZE): # Renamed to x_canvas for clarity
		for y_canvas in range(MAP_SIZE): # Renamed to y_canvas for clarity
			var world_x = render_start_x + x_canvas
			var world_y = render_start_y + y_canvas
			var world_coord = Vector2i(world_x, world_y)
			
			var terrain_type = terrain_data.get(world_coord, TERRAIN_TYPE_EMPTY)
			
			var color_to_draw = EMPTY_COLOR
			match terrain_type:
				TERRAIN_TYPE_LAND:
					color_to_draw = TERRAIN_COLOR
				TERRAIN_TYPE_RIVER:
					color_to_draw = RIVER_COLOR
				TERRAIN_TYPE_DEBUG_RIVER_START_END: # 新增
					color_to_draw = DEBUG_RIVER_START_END_COLOR
			
			# Only draw if not empty, or handle EMPTY_COLOR explicitly if needed
			# The fill operation already set it to EMPTY_COLOR
			if terrain_type != TERRAIN_TYPE_EMPTY:
				draw_cell_at_canvas_pos(Vector2i(x_canvas, y_canvas), color_to_draw)
	
	# 绘制玩家（始终在画布中心）
	var player_canvas_pos = Vector2i(int(MAP_SIZE / 2.0), int(MAP_SIZE / 2.0))
	draw_cell_at_canvas_pos(player_canvas_pos, PLAYER_COLOR)
	
	canvas_texture.set_image(canvas_image)
	queue_redraw()

func draw_cell_at_canvas_pos(canvas_pos: Vector2i, color: Color):
	"""在画布指定位置绘制一个格子"""
	if canvas_pos.x < 0 or canvas_pos.x >= MAP_SIZE or canvas_pos.y < 0 or canvas_pos.y >= MAP_SIZE:
		return
	
	var pixel_x = canvas_pos.x * CELL_SIZE
	var pixel_y = canvas_pos.y * CELL_SIZE
	
	for dx in range(CELL_SIZE):
		for dy in range(CELL_SIZE):
			var px = pixel_x + dx
			var py = pixel_y + dy
			if px < CANVAS_SIZE and py < CANVAS_SIZE:
				canvas_image.set_pixel(px, py, color)

func _draw():
	"""绘制画布"""
	if canvas_texture:
		draw_texture(canvas_texture, Vector2.ZERO)

func get_debug_info() -> String:
	var world_pos = player_ref.global_position if player_ref else Vector2.ZERO
	var world_grid_x = int(world_pos.x / 32.0)
	var world_grid_y = int(world_pos.y / 32.0)
	var current_chunk = Vector2i(
		int(floor(float(world_grid_x) / CHUNK_SIZE)),
		int(floor(float(world_grid_y) / CHUNK_SIZE))
	)
	var local_x = world_grid_x - current_chunk.x * CHUNK_SIZE
	var local_y = world_grid_y - current_chunk.y * CHUNK_SIZE
	
	return "玩家世界位置: (%d, %d), 当前区块: %s, 区块内位置: (%d, %d), 已生成区块数: %d" % [
		world_grid_x, world_grid_y, str(current_chunk), local_x, local_y, generated_chunks.size()
	]
