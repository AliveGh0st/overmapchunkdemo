extends Control
class_name OvermapUI

# Overmap调试UI - 显示地图状态信息

@onready var debug_label: Label = $DebugLabel
var overmap_manager: Node

func _ready():
	# 查找OvermapRenderer
	overmap_manager = get_tree().get_first_node_in_group("overmap_manager")
	if not overmap_manager:
		# 通过节点路径查找 - 现在UI在CanvasLayer下，需要向上两级再找到OvermapRenderer
		overmap_manager = get_node("../../OvermapRenderer")
	
	if not overmap_manager:
		pass 
	else:
		pass 

func _process(_delta):
	if overmap_manager and debug_label and overmap_manager.has_method("get_simple_info"):
		debug_label.text = overmap_manager.get_simple_info()
		debug_label.text += "\n\n控制说明："
		debug_label.text += "\nWASD或方向键 - 移动玩家"
		debug_label.text += "\n地图会自动扩展"
