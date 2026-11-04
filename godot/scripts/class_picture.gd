class_name ClassPicture
extends Control

## A small picture of a class, as it looks on the island (the Scout's
## telescope, the Digger's shovel...), in a crew's colours: for the landing
## party lists on the setup and campaign screens.

func _init(kind: int, team: int = Character.Team.NAVS) -> void:
	custom_minimum_size = Vector2(34, 40)
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var figure := Character.new()
	figure.setup(Vector2i.ZERO, CharacterStats.make(kind), team)
	figure.energy = 100.0
	figure.bare = true
	figure.position = Vector2(17, 23)
	figure.scale = Vector2(1.35, 1.35)
	add_child(figure)
