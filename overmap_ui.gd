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

extends Control
class_name OvermapUI

# Overmap调试UI - 显示地图状态信息和建筑物类型

@onready var debug_label: Label = $DebugLabel
@onready var building_info_label: Label = $BuildingInfoLabel
var overmap_manager: Node
var show_enhanced_info: bool = false  # 是否显示增强信息
var ui_disabled: bool = false  # 临时禁用所有UI来测试tilemap闪烁问题

func _ready():
	# 如果UI被禁用，隐藏所有UI元素
	if ui_disabled:
		visible = false
		return
	
	# 查找OvermapRenderer
	overmap_manager = get_tree().get_first_node_in_group("overmap_manager")
	if not overmap_manager:
		# 通过节点路径查找 - 现在UI在CanvasLayer下，需要向上两级再找到OvermapRenderer
		overmap_manager = get_node("../../OvermapRenderer")
	
	if not overmap_manager:
		pass 
	else:
		pass 
	
	# 创建建筑信息标签（如果不存在）
	if not building_info_label:
		building_info_label = Label.new()
		building_info_label.name = "BuildingInfoLabel"
		building_info_label.position = Vector2(10, 200)
		building_info_label.size = Vector2(300, 150)
		building_info_label.add_theme_color_override("font_color", Color.CYAN)
		building_info_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
		add_child(building_info_label)

func _process(_delta):
	# 如果UI被禁用，跳过所有处理
	if ui_disabled:
		return
		
	# 更新基本调试信息
	if overmap_manager and debug_label:
		if show_enhanced_info and overmap_manager.has_method("get_enhanced_info"):
			debug_label.text = overmap_manager.get_enhanced_info()
		elif overmap_manager.has_method("get_simple_info"):
			debug_label.text = overmap_manager.get_simple_info()
	
	# 更新鼠标位置建筑信息
	if overmap_manager and building_info_label and overmap_manager.has_method("get_building_info_at_mouse"):
		var building_info = overmap_manager.get_building_info_at_mouse()
		_update_building_info_display(building_info)

func _update_building_info_display(building_info: Dictionary):
	"""
	更新建筑信息显示
	"""
	if not building_info_label:
		return
	
	var info_text = "=== 鼠标位置信息 ===\n"
	info_text += "地形: " + building_info.get("terrain_type", "未知") + "\n"
	
	if building_info.get("has_building", false):
		info_text += "建筑: 是\n"
		info_text += "类型: " + building_info.get("building_type", "未知") + "\n"
		
		if building_info.get("is_special", false):
			info_text += "特殊建筑: 是\n"
			info_text += "建筑ID: " + building_info.get("building_id", "未知") + "\n"
		else:
			info_text += "特殊建筑: 否\n"
		
		if building_info.get("is_unique", false):
			info_text += "独特建筑: 是\n"
		else:
			info_text += "独特建筑: 否\n"
	else:
		info_text += "建筑: 无\n"
	
	building_info_label.text = info_text

func _input(event):
	"""
	处理输入事件，比如点击显示详细信息
	"""
	# 如果UI被禁用，跳过所有输入处理
	if ui_disabled:
		return
		
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			# 右键点击显示详细建筑信息
			_show_detailed_building_info()
	
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_TAB:
			# Tab键切换信息显示模式
			show_enhanced_info = not show_enhanced_info
			print("信息显示模式切换: ", "增强模式" if show_enhanced_info else "基本模式")
		elif event.keycode == KEY_I:
			# I键显示帮助信息
			_show_help_info()

func _show_detailed_building_info():
	"""
	显示详细的建筑信息（右键点击时）
	"""
	if not overmap_manager or not overmap_manager.has_method("get_building_info_at_mouse"):
		return
	
	var building_info = overmap_manager.get_building_info_at_mouse()
	if building_info.get("has_building", false):
		var detail_text = "=== 详细建筑信息 ===\n"
		detail_text += "建筑类型: " + building_info.get("building_type", "未知") + "\n"
		detail_text += "是否特殊: " + ("是" if building_info.get("is_special", false) else "否") + "\n"
		detail_text += "是否独特: " + ("是" if building_info.get("is_unique", false) else "否") + "\n"
		
		if building_info.get("building_id", ""):
			detail_text += "建筑ID: " + building_info.get("building_id", "") + "\n"
		
		print(detail_text)  # 输出到控制台，也可以弹出对话框

func _show_help_info():
	"""
	显示帮助信息
	"""
	var help_text = """
=== 建筑信息系统帮助 ===
鼠标操作：
- 悬停：显示建筑类型信息
- 右键：显示详细建筑信息

键盘操作：
- Tab键：切换基本/增强信息显示
- I键：显示此帮助信息

建筑类型说明：
- 住宅区：一般居住建筑
- 商店区：商业建筑（距离城市中心近）
- 公园区：休闲娱乐区域（中等距离）
- 特殊建筑：有特殊功能的建筑
- 独特建筑：全局或城市唯一建筑
"""
	print(help_text)