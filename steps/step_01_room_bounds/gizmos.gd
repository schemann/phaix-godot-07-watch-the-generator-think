extends Node3D
## Draws what the generator knows into the world: the box of every room it has planned. F3 shows and hides it.
## It only reads. It looks at the level's plans and draws lines; it never changes the level, the chain or a plan,
## so a run with the gizmos on is the run it is with them off.

const Chain := preload("room_chain.gd")
const Level := preload("level.gd")
const Lines := preload("lines.gd")

const CURRENT_COLOR := Color(1.0, 0.8, 0.25) ## The room the player is in: the map's colour for it.
const LIVE_COLOR := Color(0.45, 0.75, 1.0) ## A room that exists right now.
const REMOVED_COLOR := Color(0.6, 0.6, 0.6, 0.6) ## A room the chain remembers but the level has removed. It still blocks new rooms.

@export var level: Level

@onready var lines: Lines = $Lines

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_gizmos") and not level.typing: # while the seed box is up, its keys are not ours
		visible = not visible # a hidden node hides its lines, too

func _process(_delta: float) -> void:
	if not visible:
		return
	lines.begin()
	for plan in level.chain.plans:
		draw_bounds(lines, plan, color_of(plan))
	lines.end()

## The colour of a room's box: where the player is, what exists, what is gone.
func color_of(plan: Chain.Plan) -> Color:
	if plan.index == level.current:
		return CURRENT_COLOR
	return LIVE_COLOR if level.rooms.has(plan.index) else REMOVED_COLOR

## A room as the generator sees it: its bounds, the box that the overlap test uses. Static: it needs
## the plan and a place to draw, nothing else, so any view can use it.
static func draw_bounds(pen: Lines, plan: Chain.Plan, color: Color) -> void:
	pen.box(plan.bounds, color)
