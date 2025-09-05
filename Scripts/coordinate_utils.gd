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

# 纯静态工具类，不需要继承任何父类
class_name CoordinateUtils

## 统一的坐标转换工具类
## 提供世界坐标、区块坐标、本地坐标之间的转换工具函数
## 消除代码重复，提供一致的坐标系统接口

# ============================================================================
# 核心坐标转换函数
# ============================================================================

## 将世界像素位置转换为世界网格坐标
static func world_pixel_to_grid(pixel_pos: Vector2) -> Vector2i:
	return Vector2i(
		int(pixel_pos.x / Config.RenderConfig.TILE_SIZE),
		int(pixel_pos.y / Config.RenderConfig.TILE_SIZE)
	)

## 将世界网格坐标转换为世界像素位置
static func world_grid_to_pixel(grid_pos: Vector2i) -> Vector2:
	return Vector2(
		grid_pos.x * Config.RenderConfig.TILE_SIZE,
		grid_pos.y * Config.RenderConfig.TILE_SIZE
	)

## 将世界网格坐标转换为区块坐标
static func world_grid_to_chunk(world_grid_pos: Vector2i) -> Vector2i:
	return Vector2i(
		int(floor(float(world_grid_pos.x) / Config.RenderConfig.CHUNK_SIZE)),
		int(floor(float(world_grid_pos.y) / Config.RenderConfig.CHUNK_SIZE))
	)

## 将世界像素位置转换为区块坐标
static func world_pixel_to_chunk(pixel_pos: Vector2) -> Vector2i:
	var grid_pos = world_pixel_to_grid(pixel_pos)
	return world_grid_to_chunk(grid_pos)

## 获取区块的世界起始坐标（网格坐标）
static func chunk_to_world_start(chunk_coord: Vector2i) -> Vector2i:
	return Vector2i(
		chunk_coord.x * Config.RenderConfig.CHUNK_SIZE,
		chunk_coord.y * Config.RenderConfig.CHUNK_SIZE
	)

## 将区块内本地坐标转换为世界坐标
static func local_to_world(local_pos: Vector2i, chunk_coord: Vector2i) -> Vector2i:
	var world_start = chunk_to_world_start(chunk_coord)
	return Vector2i(world_start.x + local_pos.x, world_start.y + local_pos.y)

## 将世界坐标转换为区块内本地坐标
static func world_to_local(world_pos: Vector2i, chunk_coord: Vector2i) -> Vector2i:
	var world_start = chunk_to_world_start(chunk_coord)
	return Vector2i(world_pos.x - world_start.x, world_pos.y - world_start.y)

## 检查世界坐标是否在指定区块范围内
static func is_world_pos_in_chunk(world_pos: Vector2i, chunk_coord: Vector2i) -> bool:
	var world_start = chunk_to_world_start(chunk_coord)
	return (world_pos.x >= world_start.x and world_pos.x < world_start.x + Config.RenderConfig.CHUNK_SIZE and
			world_pos.y >= world_start.y and world_pos.y < world_start.y + Config.RenderConfig.CHUNK_SIZE)

# ============================================================================
# 边界检查函数
# ============================================================================

## 检查区块内本地坐标是否在边界范围内
static func is_local_inbounds(local_pos: Vector2i, border: int = 0) -> bool:
	return (local_pos.x >= border and local_pos.x < Config.RenderConfig.CHUNK_SIZE - border and
			local_pos.y >= border and local_pos.y < Config.RenderConfig.CHUNK_SIZE - border)

## 检查世界坐标是否在指定区块的边界范围内
static func is_world_inbounds_in_chunk(world_pos: Vector2i, chunk_coord: Vector2i, border: int = 0) -> bool:
	var local_pos = world_to_local(world_pos, chunk_coord)
	return is_local_inbounds(local_pos, border)

# ============================================================================
# 距离计算函数
# ============================================================================

## 计算两点间的平方距离（避免开方运算提高性能）
static func square_distance(p1: Vector2i, p2: Vector2i) -> int:
	var dx = p1.x - p2.x
	var dy = p1.y - p2.y
	return dx * dx + dy * dy

## 计算两点间的欧几里得距离
static func euclidean_distance(p1: Vector2i, p2: Vector2i) -> float:
	return sqrt(float(square_distance(p1, p2)))

# ============================================================================
# 方向处理函数（使用简单的整数0-3表示北东南西）
# ============================================================================

## 方向常量
const NORTH = 0
const EAST = 1
const SOUTH = 2
const WEST = 3

## 将方向转换为向量
static func direction_to_vector(direction: int) -> Vector2i:
	match direction:
		0: return Vector2i(0, -1)  # 北
		1: return Vector2i(1, 0)   # 东
		2: return Vector2i(0, 1)   # 南  
		3: return Vector2i(-1, 0)  # 西
		_: return Vector2i.ZERO

## 获取相反方向
static func opposite_direction(direction: int) -> int:
	return (direction + 2) % 4

## 向右转90度
static func turn_right(direction: int) -> int:
	return (direction + 1) % 4

## 向左转90度
static func turn_left(direction: int) -> int:
	return (direction + 3) % 4

## 随机转向（左或右）
static func turn_random(direction: int) -> int:
	return turn_left(direction) if randi() % 2 == 0 else turn_right(direction)

## 获取随机方向
static func random_direction() -> int:
	return randi() % 4

## 根据方向旋转点
static func rotate_point(point: Vector2i, direction: int) -> Vector2i:
	match direction:
		0: return point                               # 北 - 不旋转
		1: return Vector2i(-point.y, point.x)        # 东 - 顺时针90度
		2: return Vector2i(-point.x, -point.y)       # 南 - 180度
		3: return Vector2i(point.y, -point.x)        # 西 - 逆时针90度
		_: return point

# ============================================================================
# 区域操作函数
# ============================================================================

## 获取区块范围内的所有世界坐标
static func get_chunk_world_positions(chunk_coord: Vector2i) -> Array[Vector2i]:
	var positions: Array[Vector2i] = []
	var world_start = chunk_to_world_start(chunk_coord)
	
	for x in range(Config.RenderConfig.CHUNK_SIZE):
		for y in range(Config.RenderConfig.CHUNK_SIZE):
			positions.append(Vector2i(world_start.x + x, world_start.y + y))
	
	return positions

## 获取指定中心点和半径的圆形区域内的所有点
static func get_circular_area(center: Vector2i, radius: int) -> Array[Vector2i]:
	var points: Array[Vector2i] = []
	var radius_sq = radius * radius
	
	for x in range(center.x - radius, center.x + radius + 1):
		for y in range(center.y - radius, center.y + radius + 1):
			var point = Vector2i(x, y)
			if square_distance(center, point) <= radius_sq:
				points.append(point)
	
	return points

## 获取指定中心点和半径的圆形区域内，且在指定边界内的点
static func get_circular_area_bounded(center: Vector2i, radius: int, 
									 min_bound: Vector2i, max_bound: Vector2i) -> Array[Vector2i]:
	var points: Array[Vector2i] = []
	var radius_sq = radius * radius
	
	var min_x = max(center.x - radius, min_bound.x)
	var max_x = min(center.x + radius, max_bound.x)
	var min_y = max(center.y - radius, min_bound.y)
	var max_y = min(center.y + radius, max_bound.y)
	
	for x in range(min_x, max_x + 1):
		for y in range(min_y, max_y + 1):
			var point = Vector2i(x, y)
			if square_distance(center, point) <= radius_sq:
				points.append(point)
	
	return points

# ============================================================================
# 实用工具函数
# ============================================================================
## 概率性向上取整
static func roll_remainder(value: float) -> int:
	var base = int(value)
	var remainder = value - base
	if randf() < remainder:
		return base + 1
	return base

## 获取区块内玩家的相对位置
static func get_player_local_position_in_chunk(world_grid_pos: Vector2i, chunk_coord: Vector2i) -> Vector2i:
	return world_to_local(world_grid_pos, chunk_coord)

## 检查玩家是否接近区块边缘
static func is_near_chunk_border(world_grid_pos: Vector2i, threshold: int = 11) -> bool:
	var chunk_coord = world_grid_to_chunk(world_grid_pos)
	var local_pos = world_to_local(world_grid_pos, chunk_coord)
	
	return (local_pos.x < threshold or 
			local_pos.x >= Config.RenderConfig.CHUNK_SIZE - threshold or
			local_pos.y < threshold or 
			local_pos.y >= Config.RenderConfig.CHUNK_SIZE - threshold)

## 获取玩家附近需要生成的区块列表
static func get_adjacent_chunks_to_generate(current_chunk: Vector2i, world_grid_pos: Vector2i, threshold: int = 11) -> Array[Vector2i]:
	var chunks_to_generate: Array[Vector2i] = []
	var local_pos = world_to_local(world_grid_pos, current_chunk)
	
	var near_left = local_pos.x < threshold
	var near_right = local_pos.x >= Config.RenderConfig.CHUNK_SIZE - threshold
	var near_top = local_pos.y < threshold
	var near_bottom = local_pos.y >= Config.RenderConfig.CHUNK_SIZE - threshold
	
	# 8个方向的相邻区块
	if near_left:
		chunks_to_generate.append(current_chunk + Vector2i(-1, 0)) # 西
		if near_top:
			chunks_to_generate.append(current_chunk + Vector2i(-1, -1)) # 西北
		if near_bottom:
			chunks_to_generate.append(current_chunk + Vector2i(-1, 1)) # 西南
	
	if near_right:
		chunks_to_generate.append(current_chunk + Vector2i(1, 0)) # 东
		if near_top:
			chunks_to_generate.append(current_chunk + Vector2i(1, -1)) # 东北
		if near_bottom:
			chunks_to_generate.append(current_chunk + Vector2i(1, 1)) # 东南
	
	if near_top:
		chunks_to_generate.append(current_chunk + Vector2i(0, -1)) # 北
	
	if near_bottom:
		chunks_to_generate.append(current_chunk + Vector2i(0, 1)) # 南
	
	return chunks_to_generate