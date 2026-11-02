extends SceneTree
## Headless tests for tutorial 07. From the repository root:
##   godot --headless --path godot/07-watch-the-generator-think -s res://tests/run_tests.gd
## Prints PASS or FAIL per test and exits with 0 only if every test passed.
## `-- --only=text` runs the tests whose name contains the text (for example `-- --only=pinned`).
##
## Saves: every level the tests load gets its own temporary save file (OS temp dir), so a test run never reads or
## writes the real best_times.json.

const Autopilot := preload("res://tools/autopilot.gd")
const Chain := preload("res://steps/step_05_pinned_seeds/room_chain.gd") ## The finished chain (from step 3 on a plan keeps the room types that were turned down for it).
const Pinned := preload("res://steps/step_05_pinned_seeds/check_pinned.gd") ## The pinned seeds, the test a viewer writes in step 5.

const STEPS: Array[String] = [
	"step_00_start",
	"step_01_room_bounds",
	"step_02_markers",
	"step_03_rejected",
	"step_04_step_through",
	"step_05_pinned_seeds",
]
const FINAL_STEP := "step_05_pinned_seeds"

## What each step changes against the one before (file names under the step folder, props/ included; .uid files do not count).
const CHANGES: Dictionary[String, Dictionary] = {
	"step_01_room_bounds": {changed = ["main.tscn"], added = ["gizmos.gd", "lines.gd"]},
	"step_02_markers": {changed = ["gizmos.gd", "lines.gd", "main.tscn", "room_chain.gd"], added = []},
	"step_03_rejected": {changed = ["gizmos.gd", "main.tscn", "room_chain.gd"], added = []},
	"step_04_step_through": {changed = ["main.tscn", "room_camera.gd"], added = ["generation_watch.gd"]},
	"step_05_pinned_seeds": {changed = [], added = ["accidental_change.gd", "check_pinned.gd"]},
}

const STATE_READY := 0 ## Level.State
const STATE_FINISHED := 2
const BODY_LAYER_BIT := 4 ## Render layer 3: the player's body, which only the first-person camera leaves out.
const CEILING_LAYER := 2 ## Render layer 2: the ceilings and lamp blocks. The camera of the watch leaves it out.
const SPEED_UP := 4 ## The full runs go this many times faster than real time.
const LOCK_CHANCE := 0.4 ## The level's default.
const SHORT_GOAL := 3 ## Goal room of the quick runs.
const PLAN_SEEDS := 200 ## Seeds 1..200 for the comparisons between steps.
const REJECT_SEEDS := 300 ## Seeds 1..300 for the record of rejected rooms.
const WATCH_SEEDS := 40 ## Seeds 1..40 planned room by room by the watch.
const VIEW_TICKS := 600 ## Physics ticks (10 s of game time) the two runs of a seed are compared over.
const VIEW_STEP_FIRST := 4 ## The first step with a watch.
const ENTER_EVERY_TICKS := 12 ## The views-on runs press Enter this often (every 0.2 s of game time) to let the watch plan next to the run.

## Counts the errors the engine logs. A test that hits a script error stops at that line and the engine hands back an
## empty array, which reads as a pass: `_report` charges the count to the test that ran.
class ScriptErrorCounter extends Logger:
	var count := 0
	var script_only := true ## false: warnings and errors of the engine count, too.
	var _lock := Mutex.new() ## The engine calls a logger from any thread.

	func _log_error(_function: String, _file: String, _line: int, _code: String, _rationale: String, _editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		if script_only and error_type != ERROR_TYPE_SCRIPT:
			return
		_lock.lock()
		count += 1
		_lock.unlock()

## Calls its callback once per physics tick, before the player's own tick.
class Driver extends Node:
	signal finished
	var tick: Callable

	func _physics_process(_delta: float) -> void:
		if tick.is_valid() and tick.call():
			tick = Callable()
			finished.emit()

var _passed := 0
var _failed := 0
var _skipped := 0
var _script_errors := ScriptErrorCounter.new() ## Registered with the engine's logger for the whole run.
var _script_errors_reported := 0 ## How many script errors the tests reported so far have been charged with.
var _save_dir := ""
var _save_counter := 0

func _initialize() -> void:
	OS.add_logger(_script_errors)
	await process_frame
	var started := Time.get_ticks_msec()
	_save_dir = OS.get_temp_dir().path_join("phaix-godot-07-tests-%d" % OS.get_process_id()) # one folder per run: two runs at the same time must not wipe each other's save files
	_wipe_save_dir()

	await _run("code rules: no class_name, no global random, no wall clock, input only through named actions", test_code_rules)
	await _run("code rules: the debug views only read and draw: no write to the level, the chain or a plan, no random numbers drawn, the game code does not know them", test_views_read_only)
	await _run("steps: each step changes only what its concept needs, everything else is copied forward", test_copy_forward)
	await _run("step_00_start: the final state of the character tutorial, file for file (only the folder names differ)", test_step_zero_is_the_character_tutorial)
	await _run("project: the actions of the character tutorial and F3, F4 and Enter for the views, render layer 3 is named Body, the main scene is the final step", test_project_settings)
	await _run("lines (steps 1 and 2): begin, line, box, cross, arrow, end: a box is 12 edges, the mesh gets the points and colours (as strips of 3 pixels, or as plain lines), an empty frame is no surface", test_lines)
	await _run("lines (steps 1 to 5): the mesh of a Lines node is its own ImmediateMesh in main.tscn, so the editor shows no warning for the node", test_lines_get_their_mesh_from_the_scene)
	await _run("plans: all six steps plan the run of step 0 (type, place, lock, key, props and lamp of seeds 1-%d): the views and the record move nothing" % PLAN_SEEDS, test_steps_plan_the_same)
	for step in _steps_from("step_01_room_bounds"):
		await _run("%s gizmos: F3 shows and hides them, hidden they draw nothing, the hint says F3" % step, test_gizmos_toggle.bind(step))
		await _run("%s gizmos: the plan's bounds of every room, in the colour of where the player is (current, live, removed)" % step, test_gizmo_bounds.bind(step))
	for step in _steps_from("step_02_markers"):
		await _run("%s gizmos: entrance, exit, key spots and prop spots are where the room's scene has them; the plan's key spot and props are the bright ones" % step, test_gizmo_markers.bind(step))
	await _run("rejected (step 3): every room type the chain turned down is recorded with where it would have stood, why and whom it hit; the tried types are the head of the drawn order (seeds 1-%d)" % REJECT_SEEDS, test_rejections_recorded)
	await _run("rejected (step 3): a goal room that does not fit is the first record of the next plan, and the chain waits", test_rejections_goal)
	for step in _steps_from("step_03_rejected"):
		await _run("%s gizmos: the rejected rooms flash red where they would have stood, once per plan, and fade out within 1.5 s" % step, test_rejection_flash.bind(step))
	for step in _steps_from("step_04_step_through"):
		await _run("%s watch: F4 looks from above and back, Enter plans one room, the watch's chain is the seed's chain and the level's is not touched" % step, test_watch_steps.bind(step))
		await _run("%s watch: after a restart only the latest coroutine plans; leaving stops it, even in the middle of a room" % step, test_watch_restart.bind(step))
		await _run("%s watch: stepping through reaches the plans of the normal run for seeds 1-%d, and the plans of walked levels" % [step, WATCH_SEEDS], test_watch_same_plans.bind(step))
		await _run("%s cameras: F4 and V hand the view back to the camera that had it (the player's, or the room camera), whatever the order; the body stays out of the first-person view only; nothing is logged" % step, test_watch_and_room_camera.bind(step))
	for step in _steps_from("step_01_room_bounds"):
		await _run("%s: a run with every debug view on is the run it is with them off (seeds 42 and 1000, %d ticks)" % [step, VIEW_TICKS], test_views_change_nothing.bind(step))
	await _run("views: the finished game, seeds 42 and 1000 from the first door to the goal pad with every view on: the same time, keys and plans", test_views_full_run)
	await _run("pinned (step 5): the pins hold in every step and are the chain's letters, locks and end points (worked out a second time)", test_pinned_holds)
	await _run("pinned (step 5): five accidents, each a small change that looks harmless, fail 3 to 5 of the 5 pinned seeds and name the room that moved", test_pinned_fails)
	await _run("pinned (step 5): check_pinned.gd from the command line: exit 0 and PINNED OK, exit 1 and PINNED FAILED for the accident, --print prints the pins of the file", test_pinned_command)
	for step: String in [STEPS[0], FINAL_STEP]:
		await _run("%s: a room stays until the door behind it has closed, nothing goes while it stands open" % step, test_rooms_wait_for_the_door.bind(step))
	await _run("full run: seed 42, goal room 20: the autopilot fetches every key and finishes with the body on", test_full_run)
	await _run("restart: R while running leaves the body standing in room 0, in Move, at blend position 0", test_restart)
	for step in STEPS:
		await _run("%s: main scene runs 30 frames" % step, test_scene_runs.bind(step))

	_wipe_save_dir()
	OS.remove_logger(_script_errors)
	print("\n%d passed, %d failed, %d skipped in %.1f s" % [_passed, _failed, _skipped, (Time.get_ticks_msec() - started) / 1000.0])
	quit(1 if _failed > 0 else 0)

#region Source rules

func test_code_rules() -> Array[String]:
	var failures: Array[String] = []
	var global_random := RegEx.create_from_string("(^|[^.\\w])(randi|randf|randi_range|randf_range|randomize|pick_random)\\(")
	var wall_clock := RegEx.create_from_string("(Time\\.get_|OS\\.get_ticks|OS\\.get_unix|OS\\.delay)")
	var scripts := _scripts_in("res://steps")
	_expect(failures, scripts.size() >= 100, "found only %d scripts under steps" % scripts.size())
	for path in scripts:
		var lines := FileAccess.get_file_as_string(path).split("\n")
		for i in lines.size():
			var line := lines[i].strip_edges()
			if line.begins_with("#"):
				continue
			var where := "%s:%d" % [path.trim_prefix("res://"), i + 1]
			_expect(failures, not line.begins_with("class_name"), "%s: class_name" % where)
			_expect(failures, global_random.search(line) == null, "%s: global random call" % where)
			_expect(failures, wall_clock.search(line) == null, "%s: reads the wall clock" % where)
			_expect(failures, not line.contains("Input.is_key_pressed") and not line.contains("Input.is_physical_key_pressed"), "%s: reads a key directly" % where)
			_expect(failures, not line.contains("event is InputEventKey") and not line.contains("event is InputEventJoypad"), "%s: reads a key or button event directly" % where)
	return failures

func _scripts_in(dir_path: String) -> Array[String]:
	var found: Array[String] = []
	var dir := DirAccess.open(dir_path)
	for sub in dir.get_directories():
		found.append_array(_scripts_in(dir_path.path_join(sub)))
	for file in dir.get_files():
		if file.ends_with(".gd"):
			found.append(dir_path.path_join(file))
	return found

func test_copy_forward() -> Array[String]:
	var failures: Array[String] = []
	for i in range(1, STEPS.size()):
		var before := STEPS[i - 1]
		var after := STEPS[i]
		var before_files := _step_files(before)
		var after_files := _step_files(after)
		var changed: Array[String] = []
		var added: Array[String] = []
		for file in before_files:
			if not after_files.has(file):
				failures.append("%s lost %s" % [after, file])
			elif _step_text(before, file) != _step_text(after, file):
				changed.append(file)
		for file in after_files:
			if not before_files.has(file):
				added.append(file)
		changed.sort()
		added.sort()
		var expected: Dictionary = CHANGES[after]
		_expect(failures, changed == expected.changed, "%s changes %s, expected %s" % [after, changed, expected.changed])
		_expect(failures, added == expected.added, "%s adds %s, expected %s" % [after, added, expected.added])
	return failures

func _step_files(step: String) -> Array[String]:
	var files: Array[String] = []
	for file in DirAccess.get_files_at("res://steps/" + step):
		if not file.ends_with(".uid"):
			files.append(file)
	if DirAccess.dir_exists_absolute("res://steps/%s/props" % step):
		for file in DirAccess.get_files_at("res://steps/%s/props" % step):
			if not file.ends_with(".uid"):
				files.append("props/" + file)
	return files

## The file's text with the step folder name blanked out, so copies compare equal.
func _step_text(step: String, file: String) -> String:
	return FileAccess.get_file_as_string("res://steps/%s/%s" % [step, file]).replace(step, "STEP")

## Step 0 is the last step of the character tutorial, copied. When that tutorial is not next to this project the test skips.
func test_step_zero_is_the_character_tutorial() -> Array[String]:
	var failures: Array[String] = []
	var original := ProjectSettings.globalize_path("res://").path_join("../s01-a-real-player-character/steps/step_07_a_skin_of_your_own").simplify_path()
	if not DirAccess.dir_exists_absolute(original):
		_skip("step_00_start equals the last step of the character tutorial", "the character tutorial is not next to this project")
		return failures
	var original_files: Array[String] = []
	for file in DirAccess.get_files_at(original):
		if not file.ends_with(".uid"):
			original_files.append(file)
	for file in DirAccess.get_files_at(original.path_join("props")):
		if not file.ends_with(".uid"):
			original_files.append("props/" + file)
	for file in original_files:
		var theirs := _without_step_names(FileAccess.get_file_as_string(original.path_join(file))).replace("godot/s01-a-real-player-character", "godot/PROJECT")
		var ours := _without_step_names(FileAccess.get_file_as_string("res://steps/step_00_start/" + file)).replace("godot/07-watch-the-generator-think", "godot/PROJECT")
		_expect(failures, theirs == ours, "%s differs from the character tutorial's last step" % file)
	_expect(failures, original_files.size() == _step_files("step_00_start").size(), "step_00_start has %d files, the character tutorial's last step has %d" % [_step_files("step_00_start").size(), original_files.size()])
	return failures

## The character tutorial's files point at its own step folder, the copies here at the start folder.
func _without_step_names(text: String) -> String:
	return RegEx.create_from_string("step_\\d\\d_[a-z_]+").sub(text, "STEP", true)

func test_project_settings() -> Array[String]:
	var failures: Array[String] = []
	_expect(failures, ProjectSettings.has_setting("input/walk"), "no walk action")
	_expect(failures, ProjectSettings.has_setting("input/toggle_view"), "no toggle_view action")
	_expect(failures, _physical_keys("toggle_gizmos") == ["F3"], "toggle_gizmos is %s, expected F3" % [_physical_keys("toggle_gizmos")])
	_expect(failures, _physical_keys("toggle_watch") == ["F4"], "toggle_watch is %s, expected F4" % [_physical_keys("toggle_watch")])
	_expect(failures, _physical_keys("step_generation") == ["Enter", "Kp Enter"], "step_generation is %s, expected Enter and Kp Enter" % [_physical_keys("step_generation")])
	_expect(failures, ProjectSettings.get_setting("layer_names/3d_render/layer_3") == "Body", "render layer 3 is not named Body")
	_expect(failures, ProjectSettings.get_setting("application/run/main_scene") == "res://steps/%s/main.tscn" % FINAL_STEP, "the main scene is not the final step")
	return failures

#endregion

#region Chains (pure data, no scene)

## A chain of any step's script.
func _new_chain(chain_script: GDScript, chain_seed: int, goal_room: int, chance := 0.0) -> RefCounted:
	return chain_script.new(chain_seed, goal_room, chance)

## The room_chain.gd of a step.
func _chain_script(step: String) -> GDScript:
	return load("res://steps/%s/room_chain.gd" % step) as GDScript

## What the chain's Type enum calls the goal room.
func _goal_type(chain_script: GDScript) -> int:
	return (chain_script.get_script_constant_map()["Type"] as Dictionary)["GOAL"]

## The first `count` plans, the goal room far behind them.
func _plans(chain_script: GDScript, chain_seed: int, count: int, chance := LOCK_CHANCE) -> Array:
	var chain := _new_chain(chain_script, chain_seed, 100000, chance)
	for i in count:
		chain.next_plan()
	return chain.plans

func _same_plans(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if not _same_plan(a[i], b[i]):
			return false
	return true

## One plan against another: the room, its lock, its props and its lamp.
func _same_plan(a: Object, b: Object) -> bool:
	if a.index != b.index or a.type != b.type or a.transform != b.transform or a.bounds != b.bounds:
		return false
	return a.locked == b.locked and a.key_spot == b.key_spot and a.props == b.props and a.lamp == b.lamp

## All plans of a chain up to and including its goal room (at most `limit` plans).
func _plans_to_goal(chain_script: GDScript, chain_seed: int, goal_room: int, chance := LOCK_CHANCE, limit := 400) -> RefCounted:
	var chain := _new_chain(chain_script, chain_seed, goal_room, chance)
	while chain.plans.size() < limit:
		var plan: Object = chain.next_plan()
		if plan.type == _goal_type(chain_script):
			break
	return chain

## The name of a room type in a step's Type enum ("straight", "vault", "goal").
func _room_name(chain_script: GDScript, type: int) -> String:
	return str((chain_script.get_script_constant_map()["Type"] as Dictionary).find_key(type)).to_lower()

## The seeds.gd of a step.
func _seeds_script(step: String) -> GDScript:
	return load("res://steps/%s/seeds.gd" % step) as GDScript

## The prop bodies in a room: direct children that are static bodies (the door's hinge is deeper down).
func _props_in(room: Node3D) -> Array[Node3D]:
	var found: Array[Node3D] = []
	for child in room.get_children():
		if child is StaticBody3D and not child.is_queued_for_deletion():
			found.append(child as Node3D)
	return found

## The lines of a script without comments, trailing ## comments cut off.
func _code_lines(path: String) -> Array[String]:
	var lines: Array[String] = []
	for line in FileAccess.get_file_as_string(path).split("\n"):
		var code := line.split("##")[0].strip_edges()
		if not code.is_empty() and not code.begins_with("#"):
			lines.append(code)
	return lines

## The chain of a step with the experiment of tutorial 06 written into its source: a feature that calls randf() `count` more
## times in room `room`, on the lock generator, right before the lock number is drawn.
const EXPERIMENT_ANCHOR := "\tvar value := _content_rng.randf()\n"
const EXPERIMENT_LINES := "\tif plan.index == %d:\n\t\tfor i in %d:\n\t\t\t_content_rng.randf()\n"
var _patched_chains := {}
func _chain_with_extra_calls(step: String, room: int, count: int) -> GDScript:
	var key := "%s/%d/%d" % [step, room, count]
	if _patched_chains.has(key):
		return _patched_chains[key]
	var source := FileAccess.get_file_as_string("res://steps/%s/room_chain.gd" % step)
	if source.count(EXPERIMENT_ANCHOR) != 1:
		return null
	var script := GDScript.new()
	script.source_code = source.replace(EXPERIMENT_ANCHOR, EXPERIMENT_LINES % [room, count] + EXPERIMENT_ANCHOR)
	script.resource_path = "res://steps/%s/room_chain_extra_calls_%d_%d.gd" % [step, room, count] # the chain's preloads are relative to this path
	if script.reload() != OK:
		return null
	_patched_chains[key] = script
	return script

#endregion

#region Walking the real player

## Runs tick once per physics tick until it returns true. (With Engine.time_scale above 1
## several ticks happen per frame, and `await physics_frame` would only see one of them.)
func _drive(tick: Callable) -> void:
	var driver := Driver.new()
	driver.process_priority = -100
	driver.tick = tick
	root.add_child(driver)
	await driver.finished
	root.remove_child(driver)
	driver.queue_free()

## Walks until the player is in room `goal`. dawdle: ticks of standing still at the start and at every new door.
func _walk(level: Node3D, pilot: RefCounted, goal: int, dawdle: int, on_tick: Callable) -> bool:
	var state := {"budget": 1500 * goal, "wait": dawdle, "target": pilot.door_index}
	await _drive(func() -> bool:
		if state["wait"] > 0:
			state["wait"] -= 1
		else:
			pilot.physics_step()
			if pilot.door_index != state["target"]:
				state["target"] = pilot.door_index
				state["wait"] = dawdle
				pilot.release()
		if on_tick.is_valid():
			on_tick.call()
		state["budget"] -= 1
		return level.current >= goal or state["budget"] <= 0)
	pilot.release()
	return level.current >= goal

## Walks until the run is FINISHED (the player stands on the goal pad). dawdle: ticks of standing
## still at every new door after the first, which makes the run slower. Returns true if it finished.
func _walk_to_finish(level: Node3D, pilot: RefCounted, dawdle := 0, budget := 40000, on_tick := Callable()) -> bool:
	var state := {"budget": budget, "wait": 0, "target": pilot.door_index}
	await _drive(func() -> bool:
		if state["wait"] > 0:
			state["wait"] -= 1
		else:
			pilot.physics_step()
			if pilot.door_index != state["target"]:
				state["target"] = pilot.door_index
				state["wait"] = dawdle
				pilot.release()
		if on_tick.is_valid():
			on_tick.call()
		state["budget"] -= 1
		return level.state == STATE_FINISHED or state["budget"] <= 0)
	pilot.release()
	return level.state == STATE_FINISHED

#endregion

#region Debug views, the record of rejected rooms, the watch, pinned seeds


const VIEW_FILES: Array[String] = ["gizmos.gd", "lines.gd", "generation_watch.gd"]
const PIN_LETTERS := {"STRAIGHT": "S", "LONG": "L", "TURN_LEFT": "<", "TURN_RIGHT": ">", "WIDE": "W", "VAULT": "V", "GOAL": "G"} ## The letters of the pinned seeds, written down here a second time on purpose.

func _step_has(step: String, file: String) -> bool:
	return FileAccess.file_exists("res://steps/%s/%s" % [step, file])

## The lines a Lines node drew in its last frame: from, to, colour.
func _drawn(lines: Node) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	var points: PackedVector3Array = lines.points
	var colors: PackedColorArray = lines.colors
	for i in range(0, points.size(), 2):
		found.append({from = points[i], to = points[i + 1], color = colors[i]})
	return found

## True if a line from a to b (or from b to a) in this colour was drawn.
func _has_line(drawn: Array[Dictionary], a: Vector3, b: Vector3, color: Color) -> bool:
	for entry in drawn:
		var from: Vector3 = entry.from
		var to: Vector3 = entry.to
		var shade: Color = entry.color
		if shade.is_equal_approx(color) and ((from.is_equal_approx(a) and to.is_equal_approx(b)) or (from.is_equal_approx(b) and to.is_equal_approx(a))):
			return true
	return false

## The 12 edges of a box, each as two corners.
func _box_edges(bounds: AABB) -> Array[PackedVector3Array]:
	var edges: Array[PackedVector3Array] = []
	for a in 8:
		for b in range(a + 1, 8):
			if [1, 2, 4].has(a ^ b): # AABB.get_endpoint() counts z in bit 0, y in bit 1, x in bit 2: corners that differ in one bit share an edge
				edges.append(PackedVector3Array([bounds.get_endpoint(a), bounds.get_endpoint(b)]))
	return edges

func _has_box(drawn: Array[Dictionary], bounds: AABB, color: Color) -> bool:
	for edge in _box_edges(bounds):
		if not _has_line(drawn, edge[0], edge[1], color):
			return false
	return true

## An arrow as Lines.arrow draws it, from a marker's transform raised by `height`.
func _has_arrow(drawn: Array[Dictionary], placed: Transform3D, color: Color, height: float, length := 1.2) -> bool:
	var from := placed.origin + Vector3.UP * height
	var forward := -placed.basis.z
	var tip := from + forward * length
	return _has_line(drawn, from, tip, color) and _has_line(drawn, tip, tip - forward * 0.3 + placed.basis.x * 0.2, color) and _has_line(drawn, tip, tip - forward * 0.3 - placed.basis.x * 0.2, color)

func _has_cross(drawn: Array[Dictionary], center: Vector3, half: float, color: Color) -> bool:
	return _has_line(drawn, center - Vector3.RIGHT * half, center + Vector3.RIGHT * half, color) and _has_line(drawn, center - Vector3.UP * half, center + Vector3.UP * half, color) and _has_line(drawn, center - Vector3.BACK * half, center + Vector3.BACK * half, color)

#region Source rules

## The views read data and draw. They write nothing to the level, the chain or a plan, draw no random numbers and plan only a chain
## of their own; and the game code (the level, the doors, the chain, the HUD ...) does not know that they exist.
func test_views_read_only() -> Array[String]:
	var failures: Array[String] = []
	var writes := RegEx.create_from_string("\\b(level|plan|rejection|module)\\.[\\w.]*\\s*(=|\\+=|-=|\\*=|/=)[^=]")
	var changes := RegEx.create_from_string("\\blevel\\.(start|use_seed|_set_state|_spawn_room|_spawn_key|_on_\\w+|chain\\.next_plan|chain\\.clear_prop_spots|chain\\.plans\\.\\w+)\\(")
	var views_in_game := RegEx.create_from_string("\\b(Gizmos|Lines)\\b|generation_watch|toggle_gizmos|toggle_watch|step_generation")
	var game_files: Array[String] = ["level.gd", "door.gd", "room.gd", "key.gd", "player.gd", "hud.gd", "room_chain.gd", "debug_map.gd", "seed_entry.gd", "best_times.gd", "seeds.gd", "prop_set.gd", "room_weights.gd", "room_camera.gd"]
	var views_seen := 0
	for step in _steps_from("step_01_room_bounds"):
		for file in VIEW_FILES:
			if not _step_has(step, file):
				continue
			views_seen += 1
			var source := "\n".join(_code_lines("res://steps/%s/%s" % [step, file]))
			for line in source.split("\n"):
				_expect(failures, writes.search(line) == null, "%s/%s writes to game data: %s" % [step, file, line])
				_expect(failures, changes.search(line) == null, "%s/%s changes the run: %s" % [step, file, line])
				_expect(failures, not line.contains("RandomNumberGenerator") and not line.contains("level.player") and not line.contains("level.rooms["), "%s/%s draws random numbers or reaches into the player or a room: %s" % [step, file, line])
			var plans_a_chain := source.contains(".next_plan(")
			_expect(failures, plans_a_chain == (file == "generation_watch.gd"), "%s/%s: only the watch plans, and only a chain of its own" % [step, file])
			if file == "generation_watch.gd":
				_expect(failures, source.contains("chain = Chain.new(level.chain_seed, level.goal_room, level.lock_chance)") and not source.contains("= level.chain") and source.count("chain.next_plan()") == 1, "%s/%s does not plan a chain of its own from the level's seed" % [step, file])
	_expect(failures, views_seen == 2 + 2 + 2 + 3 + 3, "found %d view scripts, expected 12 (gizmos and lines from step 1, the watch from step 4)" % views_seen)
	for step in STEPS:
		for file in game_files:
			for line in _code_lines("res://steps/%s/%s" % [step, file]):
				_expect(failures, views_in_game.search(line) == null, "%s/%s knows about the debug views: %s" % [step, file, line])
	return failures

#endregion

#region Lines (step 1)

## The mesh of a Lines node is a resource of main.tscn, one of its own for every node: a MeshInstance3D without a mesh shows a warning triangle in the
## editor's scene tree, and two nodes that shared one ImmediateMesh would draw each other's lines.
func test_lines_get_their_mesh_from_the_scene() -> Array[String]:
	var failures: Array[String] = []
	for step in _steps_from("step_01_room_bounds"):
		var state := (load("res://steps/%s/main.tscn" % step) as PackedScene).get_state()
		var meshes: Array[Mesh] = []
		var script_path := "res://steps/%s/lines.gd" % step
		for i in state.get_node_count():
			var scripted := false
			var mesh: Mesh = null
			for j in state.get_node_property_count(i):
				var key := String(state.get_node_property_name(i, j))
				if key == "script":
					scripted = (state.get_node_property_value(i, j) as Script).resource_path == script_path
				elif key == "mesh":
					mesh = state.get_node_property_value(i, j) as Mesh
			if scripted:
				_expect(failures, mesh is ImmediateMesh, "%s: the node %s has lines.gd but no ImmediateMesh in the scene" % [step, state.get_node_path(i)])
				meshes.append(mesh)
		_expect(failures, meshes.size() == (1 if step in ["step_01_room_bounds", "step_02_markers", "step_03_rejected"] else 2), "%s: %d nodes carry lines.gd" % [step, meshes.size()])
		for a in meshes.size():
			for b in range(a + 1, meshes.size()):
				_expect(failures, meshes[a] != meshes[b], "%s: two Lines nodes share one mesh" % step)
		var main := (load("res://steps/%s/main.tscn" % step) as PackedScene).instantiate()
		var lines := main.get_node("Gizmos/Lines") as MeshInstance3D
		_expect(failures, lines.mesh is ImmediateMesh, "%s: Gizmos/Lines has no ImmediateMesh before _ready" % step)
		main.free()
	return failures

func test_lines() -> Array[String]:
	var failures: Array[String] = []
	for step in _steps_from("step_01_room_bounds"):
		var lines: MeshInstance3D = (load("res://steps/%s/lines.gd" % step) as GDScript).new()
		lines.mesh = ImmediateMesh.new() # what the scene gives the node (test_lines_get_their_mesh_from_the_scene)
		root.add_child(lines) # _ready makes the material
		var immediate := lines.mesh as ImmediateMesh
		_expect(failures, immediate != null and lines.points.is_empty(), "%s: _ready lost the ImmediateMesh" % step)
		var material := lines.material_override as StandardMaterial3D
		_expect(failures, material != null and material.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED and material.vertex_color_use_as_albedo and material.no_depth_test and material.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA, "%s: the lines' material is not unlit, vertex-coloured, see-through-walls and alpha" % step)
		_expect(failures, lines.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "%s: lines cast shadows" % step)
		# Nothing drawn is no surface (a surface without a point is an engine error).
		lines.begin()
		lines.end()
		_expect(failures, immediate.get_surface_count() == 0, "%s: an empty frame left %d surfaces" % [step, immediate.get_surface_count()])
		# One line.
		lines.begin()
		lines.line(Vector3.ZERO, Vector3(1.0, 2.0, 3.0), Color.RED)
		_expect(failures, lines.points == PackedVector3Array([Vector3.ZERO, Vector3(1.0, 2.0, 3.0)]) and lines.colors == PackedColorArray([Color.RED, Color.RED]), "%s: line() collected %s %s" % [step, lines.points, lines.colors])
		lines.end()
		_expect(failures, immediate.get_surface_count() == 1 and immediate.get_aabb().is_equal_approx(AABB(Vector3.ZERO, Vector3(1.0, 2.0, 3.0))), "%s: one line is %d surfaces, its box is %s" % [step, immediate.get_surface_count(), immediate.get_aabb()])
		# A box: 12 edges, four of each length, every corner used three times.
		lines.begin()
		_expect(failures, lines.points.is_empty() and lines.colors.is_empty(), "%s: begin() keeps the lines of the last frame" % step)
		var bounds := AABB(Vector3(1.0, 2.0, 3.0), Vector3(4.0, 5.0, 6.0))
		lines.box(bounds, Color.GREEN)
		_expect(failures, lines.points.size() == 24 and lines.colors.size() == 24, "%s: a box is %d points, expected 24" % [step, lines.points.size()])
		var lengths := {4.0: 0, 5.0: 0, 6.0: 0}
		var corner_use := {}
		for i in range(0, lines.points.size(), 2):
			var length: float = lines.points[i].distance_to(lines.points[i + 1])
			for known: float in lengths:
				if is_equal_approx(length, known):
					lengths[known] += 1
			for point: Vector3 in [lines.points[i], lines.points[i + 1]]:
				corner_use[point] = corner_use.get(point, 0) + 1
		_expect(failures, lengths == {4.0: 4, 5.0: 4, 6.0: 4}, "%s: the edge lengths of a 4 x 5 x 6 box are %s" % [step, lengths])
		_expect(failures, corner_use.size() == 8 and corner_use.values().all(func(count: int) -> bool: return count == 3), "%s: the corners are %s" % [step, corner_use])
		_expect(failures, lines.points.size() == lines.colors.size() and lines.colors.count(Color.GREEN) == 24, "%s: the box colours" % step)
		for corner: Vector3 in corner_use:
			_expect(failures, bounds.grow(0.001).has_point(corner), "%s: a corner outside the box" % step)
		lines.end()
		_expect(failures, immediate.get_surface_count() == 1 and immediate.get_aabb().is_equal_approx(bounds), "%s: the box mesh has %d surfaces and the box %s, expected %s" % [step, immediate.get_surface_count(), immediate.get_aabb(), bounds])
		# With a thickness every line is a strip that is `thickness` pixels wide on the screen, at any distance and in either projection.
		lines.thickness = 3.0
		var camera := Camera3D.new()
		camera.fov = 75.0
		root.add_child(camera)
		camera.make_current()
		var screen_height := root.get_visible_rect().size.y
		for depth: float in [5.0, 20.0]:
			lines.begin()
			lines.line(Vector3(-1.0, 0.0, -depth), Vector3(1.0, 0.0, -depth), Color.WHITE)
			lines.end()
			var expected := 3.0 * 2.0 * depth * tan(deg_to_rad(75.0) / 2.0) / screen_height
			var strip := immediate.get_aabb()
			_expect(failures, immediate.get_surface_count() == 1 and absf(strip.size.y - expected) < expected * 0.01 and absf(strip.size.x - 2.0) < 0.001, "%s: a strip at %.0f m is %.4f m wide and %.3f long, expected %.4f and 2" % [step, depth, strip.size.y, strip.size.x, expected])
		camera.projection = Camera3D.PROJECTION_ORTHOGONAL
		camera.size = 20.0
		lines.begin()
		lines.line(Vector3(-1.0, 0.0, -9.0), Vector3(1.0, 0.0, -9.0), Color.WHITE)
		lines.end()
		_expect(failures, absf(immediate.get_aabb().size.y - 3.0 * 20.0 / screen_height) < 0.0001, "%s: an orthographic strip is %.4f m wide, expected %.4f" % [step, immediate.get_aabb().size.y, 3.0 * 20.0 / screen_height])
		camera.projection = Camera3D.PROJECTION_PERSPECTIVE
		lines.begin()
		lines.line(Vector3(0.0, 0.0, -3.0), Vector3(0.0, 0.0, -8.0), Color.WHITE) # straight away from the camera: no width to see
		lines.end()
		_expect(failures, immediate.get_surface_count() == 0, "%s: a line that points at the camera left %d surfaces" % [step, immediate.get_surface_count()])
		root.remove_child(camera)
		camera.free()
		lines.thickness = 0.0
		# Markers, from step 2.
		if lines.has_method("cross"):
			lines.begin()
			lines.cross(Vector3(1.0, 1.0, 1.0), 0.5, Color.GOLD)
			_expect(failures, lines.points.size() == 6, "%s: a cross is %d points" % [step, lines.points.size()])
			var mid := Vector3.ZERO
			for point: Vector3 in lines.points:
				mid += point / 6.0
				_expect(failures, is_equal_approx(point.distance_to(Vector3(1.0, 1.0, 1.0)), 0.5), "%s: a cross arm is not 0.5 long" % step)
			_expect(failures, mid.is_equal_approx(Vector3(1.0, 1.0, 1.0)), "%s: a cross is not centred on its point" % step)
			lines.begin()
			var turned := Transform3D(Basis(Vector3.UP, PI / 2.0), Vector3(2.0, 0.0, 0.0)) # -Z turned a quarter: it faces -X
			lines.arrow(turned, Color.GREEN, 2.0)
			_expect(failures, lines.points.size() == 6, "%s: an arrow is %d points" % [step, lines.points.size()])
			_expect(failures, lines.points[0].is_equal_approx(Vector3(2.0, 0.0, 0.0)) and lines.points[1].is_equal_approx(Vector3(0.0, 0.0, 0.0)), "%s: the shaft of an arrow goes %s to %s, expected 2 m along the way the marker faces" % [step, lines.points[0], lines.points[1]])
			_expect(failures, lines.points[2].is_equal_approx(lines.points[1]) and lines.points[4].is_equal_approx(lines.points[1]) and lines.points[3].x > 0.0 and lines.points[5].x > 0.0 and not lines.points[3].is_equal_approx(lines.points[5]), "%s: the head of the arrow does not start at the tip and point back" % step)
		root.remove_child(lines)
		lines.free()
		await process_frame
	return failures

#endregion

#region The plans do not change

## The run of every seed is the run of tutorial 06 in every step: the views and the record of rejected rooms move nothing.
func test_steps_plan_the_same() -> Array[String]:
	var failures: Array[String] = []
	var scripts: Array[GDScript] = []
	for step in STEPS:
		scripts.append(_chain_script(step))
	for chain_seed in range(1, PLAN_SEEDS + 1):
		if chain_seed % 20 == 0:
			await process_frame
		var base: Array = _plans_to_goal(scripts[0], chain_seed, 20).plans
		for i in range(1, scripts.size()):
			var other: Array = _plans_to_goal(scripts[i], chain_seed, 20).plans
			_expect(failures, _same_plans(base, other), "seed %d: %s plans another run than %s" % [chain_seed, STEPS[i], STEPS[0]])
		if failures.size() > 8:
			return failures
	return failures

#endregion

#region Gizmos (steps 1 and 2)

func test_gizmos_toggle(step: String) -> Array[String]:
	var failures: Array[String] = []
	_expect(failures, _physical_keys("toggle_gizmos") == ["F3"], "toggle_gizmos is %s, expected F3" % [_physical_keys("toggle_gizmos")])
	var main := await _load_step(step, true, {"goal_room": SHORT_GOAL})
	var level: Node3D = main.get_node("Level")
	var gizmos: Node3D = main.get_node("Gizmos")
	var lines: MeshInstance3D = gizmos.get_node("Lines")
	_expect(failures, not gizmos.visible and not lines.is_visible_in_tree() and lines.points.is_empty() and (lines.mesh as ImmediateMesh).get_surface_count() == 0, "the gizmos do not start hidden and empty")
	await _key(KEY_F3)
	await process_frame
	_expect(failures, gizmos.visible and lines.is_visible_in_tree() and lines.points.size() >= 24 and (lines.mesh as ImmediateMesh).get_surface_count() == 1, "F3 does not show the gizmos (%d points)" % lines.points.size())
	var shown: int = lines.points.size()
	await _key(KEY_F3)
	_expect(failures, not gizmos.visible and not lines.is_visible_in_tree(), "F3 does not hide the gizmos")
	level.typing = true # the seed box is up: its keys are not ours
	await _key(KEY_F3)
	_expect(failures, not gizmos.visible, "F3 reached the gizmos while the seed box was up")
	level.typing = false
	# Hidden, the node draws nothing, even when the level moves on.
	level._spawn_room(level.chain.next_plan())
	await _wait_physics(2)
	_expect(failures, lines.points.size() == shown, "a hidden gizmo node drew %d points more" % (lines.points.size() - shown))
	await _key(KEY_F3)
	await process_frame
	_expect(failures, lines.points.size() > shown, "shown again, the gizmos do not draw the new room")
	var hint: Label = main.get_node("HUD/Stats/DebugHint")
	_expect(failures, hint.text.begins_with("F3") and hint.get_parent() == main.get_node("HUD/Stats"), "the hint reads \"%s\"" % hint.text)
	await _unload(main)
	return failures

## One box per planned room: the plan's own bounds, in the colour of where the player is.
func test_gizmo_bounds(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step, true, {"goal_room": 8})
	var level: Node3D = main.get_node("Level")
	var gizmos: Node3D = main.get_node("Gizmos")
	var lines: MeshInstance3D = gizmos.get_node("Lines")
	await _key(KEY_F3)
	_fast_forward(true)
	var arrived := await _walk(level, Autopilot.new(level), 3, 0, Callable())
	_fast_forward(false)
	_expect(failures, arrived, "did not reach room 3")
	for tick in 180: # the door behind the player swings shut, then the rooms behind it go: wait until the level stands still
		if not level.rooms.has(0):
			break
		await physics_frame
	await _wait_physics(3)
	gizmos._process(0.0) # draw from the state the level has now, not from the frame before
	var drawn := _drawn(lines)
	var plans: Array = level.chain.plans
	var current := 0
	var live := 0
	var removed := 0
	for plan: Object in plans:
		var expected: Color = gizmos.CURRENT_COLOR
		if plan.index == level.current:
			current += 1
		elif level.rooms.has(plan.index):
			expected = gizmos.LIVE_COLOR
			live += 1
		else:
			expected = gizmos.REMOVED_COLOR
			removed += 1
		_expect(failures, _has_box(drawn, plan.bounds, expected), "room %d: its bounds are not drawn in %s" % [plan.index, expected])
		_expect(failures, gizmos.color_of(plan) == expected, "room %d: color_of() says %s" % [plan.index, gizmos.color_of(plan)])
	_expect(failures, current == 1 and live >= 1 and removed >= 1, "the colours: %d current, %d live, %d removed rooms" % [current, live, removed])
	if step == STEPS[1]:
		_expect(failures, lines.points.size() == plans.size() * 24, "step 1 draws only the bounds: %d points for %d rooms" % [lines.points.size(), plans.size()])
	await _unload(main)
	return failures

## The markers are drawn where the room's scene has them, and the plan's choices are the bright ones.
func test_gizmo_markers(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step, true, {"goal_room": 7, "lock_chance": 1.0, "seed_text": "BLUE-FOX"})
	var level: Node3D = main.get_node("Level")
	var gizmos: Node3D = main.get_node("Gizmos")
	var lines: MeshInstance3D = gizmos.get_node("Lines")
	for i in 7:
		level._spawn_room(level.chain.next_plan())
	await _wait_physics(2)
	await _key(KEY_F3)
	await process_frame
	var drawn := _drawn(lines)
	var height: float = gizmos.ARROW_HEIGHT
	var keys := 0
	var held := 0
	var empty := 0
	for plan: Object in level.chain.plans:
		var room: Node3D = level.rooms[plan.index]
		var where := "room %d (%s)" % [plan.index, _room_name(_chain_script(step), plan.type)]
		_expect(failures, _has_arrow(drawn, room.entrance.global_transform, gizmos.ENTRANCE_COLOR, height), "%s: no entrance arrow at the room's entrance" % where)
		if plan.type == Chain.Type.GOAL:
			_expect(failures, room.exit == null, "%s: the goal room has an exit" % where)
		else:
			_expect(failures, _has_arrow(drawn, room.exit.global_transform, gizmos.EXIT_COLOR, height), "%s: no exit arrow at the room's exit" % where)
		for i: int in room.key_spots.size():
			var spot: Vector3 = room.key_spots[i].global_position
			if i == plan.key_spot:
				var key := room.get_node_or_null("Key") as Node3D
				_expect(failures, key != null and key.global_position.is_equal_approx(spot), "%s: the key does not lie at the spot the plan chose" % where)
				_expect(failures, _has_cross(drawn, spot + Vector3.UP * gizmos.KEY_CROSS_HEIGHT, gizmos.KEY_SIZE, gizmos.KEY_COLOR) and _has_line(drawn, spot, spot + Vector3.UP * gizmos.KEY_POST_HEIGHT, gizmos.KEY_COLOR), "%s: the key spot %d is not marked in gold" % [where, i])
				keys += 1
			else:
				var faint: Color = gizmos.KEY_COLOR
				faint.a = gizmos.UNUSED_ALPHA
				_expect(failures, _has_cross(drawn, spot + Vector3.UP * gizmos.SPOT_HEIGHT, gizmos.SPOT_SIZE, faint), "%s: the unused key spot %d is not marked faint" % [where, i])
		_expect(failures, (room.get_node_or_null("Key") != null) == (plan.key_spot >= 0), "%s: key spot %d and a key in the room: %s" % [where, plan.key_spot, room.get_node_or_null("Key")])
		var props := _props_in(room)
		var held_here := 0
		for i: int in room.prop_spots.size():
			var spot: Transform3D = room.prop_spots[i].global_transform
			var base: Vector3 = spot.origin + Vector3.UP * gizmos.SPOT_HEIGHT
			var color: Color = gizmos.PROP_COLOR
			if plan.props[i] != Chain.NO_PROP:
				held_here += 1
				held += 1
				_expect(failures, props.any(func(prop: Node3D) -> bool: return prop.global_position.is_equal_approx(spot.origin)), "%s: the plan holds a prop at spot %d, the room has none there" % [where, i])
			else:
				color.a = gizmos.UNUSED_ALPHA
				empty += 1
			_expect(failures, _has_cross(drawn, base, gizmos.SPOT_SIZE, color) and _has_line(drawn, base, base - spot.basis.z * gizmos.FACING_LENGTH, color), "%s: prop spot %d is not marked (%s)" % [where, i, "held" if plan.props[i] != Chain.NO_PROP else "empty"])
		_expect(failures, held_here == props.size(), "%s: %d props in the room, %d held in the plan" % [where, props.size(), held_here])
	var exit_lines := 0
	for entry in drawn:
		exit_lines += 1 if (entry.color as Color).is_equal_approx(gizmos.EXIT_COLOR) else 0
	_expect(failures, exit_lines == 3 * (level.chain.plans.size() - 1), "%d exit lines for %d rooms with an exit" % [exit_lines, level.chain.plans.size() - 1])
	_expect(failures, keys >= 2 and held >= 10 and empty >= 5, "the seed shows %d keys, %d held and %d empty prop spots: too little to check" % [keys, held, empty])
	await _unload(main)
	return failures

#endregion

#region The record of rejected rooms (step 3)

func _turns_back(plans: Array, placed: Transform3D, exit_local: Transform3D) -> bool:
	var heading := -(placed * exit_local).basis.z
	var to_start := ((plans[0].transform as Transform3D).origin - placed.origin).normalized()
	return heading.dot(Chain.START_HEADING) < -Chain.BACK_LIMIT or heading.dot(to_start) > Chain.BACK_LIMIT

## The index of the first of the first `count` plans that the box runs into, or -1.
func _first_overlap(plans: Array, count: int, box: AABB) -> int:
	var inner := box.grow(-Chain.SHRINK)
	for i in count:
		if inner.intersects(plans[i].bounds):
			return i
	return -1

## Checks every room type the chain turned down against the rules, worked out here a second time: where it would have stood,
## why it was turned down and whom it hit; and that the types it tried are the head of the order it drew.
func test_rejections_recorded() -> Array[String]:
	var failures: Array[String] = []
	for step: String in ["step_03_rejected", FINAL_STEP]:
		var script := _chain_script(step)
		var overlap := 0
		var heading := 0
		var rooms := 0
		var rooms_with_record := 0
		for chain_seed in range(1, REJECT_SEEDS + 1):
			if chain_seed % 25 == 0:
				await process_frame
			var chain := _new_chain(script, chain_seed, 20, LOCK_CHANCE)
			for room in 40:
				var before: int = chain.plans.size()
				var order: Array[int] = chain._weighted_types() # the order the chain is about to try: its generator is started from the seed and the room's number, drawing it again changes nothing
				var goal_turn: bool = before > 0 and before == chain.goal_index
				var last: Object = chain.plans[-1] if before > 0 else null
				var plan: Object = chain.next_plan()
				var recorded: Array = plan.rejected
				var where := "%s seed %d room %d" % [step, chain_seed, plan.index]
				rooms += 1
				rooms_with_record += 1 if not recorded.is_empty() else 0
				if before == 0:
					_expect(failures, recorded.is_empty(), "%s: room 0 has a record" % where)
					continue
				var exit_point: Transform3D = last.transform * chain.module_of(last.type).exit
				var first_ordinary := 0
				if goal_turn:
					if plan.type == Chain.Type.GOAL:
						_expect(failures, recorded.is_empty(), "%s: the goal room fit, and has a record of %d rooms" % [where, recorded.size()])
						break
					first_ordinary = 1
				for r: Object in recorded:
					var module: Object = chain.module_of(r.type)
					var placed: Transform3D = exit_point * module.entrance.affine_inverse()
					_expect(failures, r.transform == placed and r.bounds == placed * module.bounds, "%s: a rejected %s is not where it would have stood" % [where, _room_name(script, r.type)])
					if r.reason == Chain.Reason.HEADING:
						heading += 1
						_expect(failures, r.hit == -1 and _turns_back(chain.plans, placed, module.exit), "%s: %s is recorded as turning back, but its heading is fine (hit %d)" % [where, _room_name(script, r.type), r.hit])
					else:
						overlap += 1
						var hit := _first_overlap(chain.plans, plan.index, r.bounds)
						_expect(failures, r.hit >= 0 and r.hit < plan.index and r.hit == hit, "%s: %s is recorded as running into room %d, it runs into room %d" % [where, _room_name(script, r.type), r.hit, hit])
						_expect(failures, not _turns_back(chain.plans, placed, module.exit), "%s: %s is recorded as an overlap, but it turns back first (the heading rule is tested first)" % [where, _room_name(script, r.type)])
				if goal_turn:
					_expect(failures, recorded.size() >= 1 and recorded[0].type == Chain.Type.GOAL and recorded[0].reason == Chain.Reason.OVERLAP, "%s: the goal room that did not fit is not the first record" % where)
				var tried: Array[int] = []
				for i in range(first_ordinary, recorded.size()):
					tried.append(recorded[i].type)
				var position := order.find(plan.type)
				_expect(failures, position >= 0, "%s: the room type %d was built, but it is not in the order (a fallback)" % [where, plan.type])
				var expected: Array[int] = []
				for i in position:
					expected.append(order[i])
				_expect(failures, tried == expected, "%s: tried %s, the order says %s" % [where, tried, expected])
				# The room that was built is the first that fits.
				var snapped_to_exit: Transform3D = exit_point * chain.module_of(plan.type).entrance.affine_inverse()
				_expect(failures, plan.transform == snapped_to_exit and not _turns_back(chain.plans, snapped_to_exit, chain.module_of(plan.type).exit) and _first_overlap(chain.plans, plan.index, plan.bounds) == -1, "%s: the room that was built does not fit" % where)
				if plan.type == Chain.Type.GOAL:
					break
			if failures.size() > 8:
				return failures
		print("        %s, seeds 1-%d: %d rooms, %d with a record; %d rooms turned down for their heading, %d for an overlap" % [step, REJECT_SEEDS, rooms, rooms_with_record, heading, overlap])
		_expect(failures, heading >= 300 and overlap >= 20 and rooms_with_record >= rooms * 0.1, "the record is too thin to prove anything: %d heading, %d overlap, %d rooms with a record of %d" % [heading, overlap, rooms_with_record, rooms])
	# Before step 3 there is no record at all.
	for step: String in ["step_00_start", "step_01_room_bounds", "step_02_markers"]:
		for plan: Object in _plans(_chain_script(step), 42, 10):
			_expect(failures, plan.get("rejected") == null, "%s keeps a record of rejected rooms" % step)
	return failures

## A goal room that does not fit is the first record of the next plan: the chain waits one room. (The goal box is made huge by hand,
## as test_goal_waits does, because a goal room almost always fits.)
func test_rejections_goal() -> Array[String]:
	var failures: Array[String] = []
	for step: String in ["step_03_rejected", FINAL_STEP]:
		var script := _chain_script(step)
		for chain_seed: int in [42, 7, 313]:
			var chain := _new_chain(script, chain_seed, 6, 1.0)
			var real_bounds: AABB = chain._modules[Chain.Type.GOAL].bounds
			for i in 6:
				chain.next_plan()
			chain._modules[Chain.Type.GOAL].bounds = AABB(Vector3(-1000.0, -10.0, -1000.0), Vector3(2000.0, 20.0, 2000.0))
			var last: Object = chain.plans[-1]
			var exit_point: Transform3D = last.transform * chain.module_of(last.type).exit
			var plan: Object = chain.next_plan()
			var record: Object = plan.rejected[0] if not plan.rejected.is_empty() else null
			_expect(failures, record != null and record.type == Chain.Type.GOAL and record.reason == Chain.Reason.OVERLAP and record.hit == 0, "%s seed %d: the goal room that did not fit is not recorded as an overlap with room 0 (%s)" % [step, chain_seed, plan.rejected])
			if record != null:
				var placed: Transform3D = exit_point * chain.module_of(Chain.Type.GOAL).entrance.affine_inverse()
				_expect(failures, record.transform == placed and record.bounds == placed * chain.module_of(Chain.Type.GOAL).bounds, "%s seed %d: the goal room's record is not where it would have stood" % [step, chain_seed])
			_expect(failures, plan.type != Chain.Type.GOAL and plan.index == 6 and chain.goal_index == 7, "%s seed %d: the chain did not wait one room" % [step, chain_seed])
			chain._modules[Chain.Type.GOAL].bounds = real_bounds
			var goal: Object = chain.next_plan()
			_expect(failures, goal.type == Chain.Type.GOAL and goal.rejected.is_empty(), "%s seed %d: the goal room that fits has a record" % [step, chain_seed])
	return failures

## What a plan says about its rejected rooms, without the objects: for comparing two chains.
func _rejections_of(plan: Object) -> Array:
	var summary: Array = []
	var rejected: Variant = plan.get("rejected")
	if rejected == null:
		return summary
	for r: Object in rejected:
		summary.append([r.type, r.reason, r.transform, r.bounds, r.hit])
	return summary

func _same_rejections(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if _rejections_of(a[i]) != _rejections_of(b[i]):
			return false
	return true

#endregion

#region The flash of the rejected rooms (step 3)

func test_rejection_flash(step: String) -> Array[String]:
	var failures: Array[String] = []
	# A seed in which a room from room 2 on turned a room type down, so that the flash has something to show.
	var seed_number := 0
	var at := 0
	for candidate in range(1, 60):
		for plan: Object in _plans(_chain_script(step), candidate, 8):
			if not plan.rejected.is_empty():
				seed_number = candidate
				at = plan.index
				break
		if seed_number > 0:
			break
	_expect(failures, seed_number > 0, "no seed with a rejected room in its first rooms")
	var main := await _load_step(step, true, {"goal_room": 10, "chain_seed": seed_number})
	var level: Node3D = main.get_node("Level")
	var gizmos: Node3D = main.get_node("Gizmos")
	var lines: MeshInstance3D = gizmos.get_node("Lines")
	await _key(KEY_F3)
	var plan: Object = null
	for i in at:
		plan = level.chain.next_plan() # as a door asks for it
		_expect(failures, i + 1 < at or not plan.rejected.is_empty(), "the premise: room %d has a record" % at)
	await process_frame
	var flashes: Array = gizmos._flashes
	_expect(failures, flashes.size() == plan.rejected.size() and flashes.size() >= 1, "%d flashes for %d rejected rooms" % [flashes.size(), plan.rejected.size()])
	var red: Color = gizmos.REJECTED_COLOR
	var seconds: float = gizmos.FLASH_SECONDS
	_expect(failures, red.r > 0.9 and red.g < 0.2 and red.b < 0.2 and seconds > 1.0 and seconds <= 2.0, "the flash is not red or not a moment (%s, %.1f s)" % [red, seconds])
	var drawn := _drawn(lines)
	for i in flashes.size():
		var rejection: Object = plan.rejected[i]
		var alpha: float = 1.0 - (flashes[i].age as float) / seconds
		var shade := Color(red.r, red.g, red.b, alpha)
		_expect(failures, flashes[i].rejection == rejection and alpha > 0.5, "flash %d does not show rejection %d of the plan" % [i, i])
		_expect(failures, _has_box(drawn, rejection.bounds, shade), "the box of the rejected %s is not drawn in red" % _room_name(_chain_script(step), rejection.type))
		if rejection.reason == Chain.Reason.HEADING:
			var exit_marker: Transform3D = rejection.transform * level.chain.module_of(rejection.type).exit
			_expect(failures, _has_arrow(drawn, exit_marker, shade, gizmos.ARROW_HEIGHT), "the exit arrow of a room that turns back is not drawn")
	# The red fades: half the time, about half the alpha; then it is gone.
	var age_before: float = flashes[0].age
	gizmos._process(seconds / 2.0)
	var expected_alpha := 1.0 - (age_before + seconds / 2.0) / seconds
	var seen := false
	for entry in _drawn(lines):
		var shade: Color = entry.color
		if shade.r > 0.9 and shade.g < 0.2 and shade.b < 0.2:
			seen = true
			_expect(failures, absf(shade.a - expected_alpha) < 0.02, "half way through, the red has alpha %.2f, expected %.2f" % [shade.a, expected_alpha])
	_expect(failures, seen, "no red line half way through the flash")
	gizmos._process(seconds)
	_expect(failures, gizmos._flashes.is_empty(), "%d flashes left after %.1f s" % [gizmos._flashes.size(), seconds])
	var red_left := 0
	for entry in _drawn(lines):
		var shade: Color = entry.color
		red_left += 1 if shade.r > 0.9 and shade.g < 0.2 and shade.b < 0.2 else 0
	_expect(failures, red_left == 0, "%d red lines after the flash" % red_left)
	# A flash starts once per rejected room: the next frames find no new plan.
	await process_frame
	await process_frame
	_expect(failures, gizmos._flashes.is_empty(), "the same plan flashed again")
	# A room without a record flashes nothing, a restart starts the chain over.
	level.use_seed("1")
	await _wait_physics(2)
	await process_frame
	_expect(failures, gizmos._flashes.is_empty() and gizmos._chain == level.chain and gizmos._seen == 1, "after a restart the view has %d flashes and has seen %d plans" % [gizmos._flashes.size(), gizmos._seen])
	await _unload(main)
	return failures

#endregion

#region The watch (step 4)

## Asks for one room and waits until the watch has shown it. Returns false if it did not within `frames` frames.
## by_key: with a real press of Enter (four frames); without, the watch is sent the signal that Enter sends.
func _step_watch(watch: Node, by_key := false, frames := 200) -> bool:
	var shown: int = watch._shown
	if by_key:
		await _key(KEY_ENTER)
	else:
		watch.step_requested.emit()
	for i in frames:
		if watch._shown > shown:
			return true
		await process_frame
	return false

func _watch_done(watch: Node) -> bool:
	return watch.chain != null and not watch.chain.plans.is_empty() and watch.chain.plans[-1].type == Chain.Type.GOAL and watch._shown == watch.chain.plans.size()

func test_watch_steps(step: String) -> Array[String]:
	var failures: Array[String] = []
	_expect(failures, _physical_keys("toggle_watch") == ["F4"] and _physical_keys("step_generation") == ["Enter", "Kp Enter"], "toggle_watch is %s and step_generation %s, expected F4 and Enter" % [_physical_keys("toggle_watch"), _physical_keys("step_generation")])
	var main := await _load_step(step, true, {"goal_room": 12})
	var level: Node3D = main.get_node("Level")
	var watch: Node3D = main.get_node("Watch")
	watch.candidate_seconds = 0.0
	var player_camera: Camera3D = level.player.get_node("Head/Camera3D")
	_expect(failures, player_camera.current and not watch.watching and not watch.camera.current and not watch.screen.visible and not watch.lines.visible, "the watch is not asleep at the start")
	await _key(KEY_ENTER)
	_expect(failures, watch.chain == null and level.chain.plans.size() == 1, "Enter planned a room while nobody was watching")
	await _key(KEY_F4)
	_expect(failures, watch.watching and watch.camera.current and not player_camera.current and watch.screen.visible and watch.lines.visible, "F4 does not switch to the camera from above")
	_expect(failures, watch.chain != null and watch.chain.plans.is_empty() and watch.chain.get("_chain_seed") == level.chain_seed and watch.chain.goal_index == 12 and watch.chain.lock_chance == level.lock_chance and watch.chain != level.chain, "the watch's chain is not a chain of its own with the level's seed and settings")
	var look: Vector3 = -watch.camera.global_transform.basis.z
	_expect(failures, look.is_equal_approx(Vector3.DOWN) and watch.camera.projection == Camera3D.PROJECTION_ORTHOGONAL and (watch.camera.cull_mask & CEILING_LAYER) == 0 and (watch.camera.cull_mask & 1) != 0, "the camera does not look straight down, orthographic, past the ceilings")
	var aspect := root.get_visible_rect().size.aspect()
	var presses := 0
	while presses < 40 and not _watch_done(watch):
		var before: int = watch.chain.plans.size()
		var shown: bool = await _step_watch(watch, true)
		presses += 1
		_expect(failures, shown and watch.chain.plans.size() == before + 1, "press %d: %d plans after %d, one room per press" % [presses, watch.chain.plans.size(), before])
		_expect(failures, watch._shown == watch.chain.plans.size(), "press %d: %d rooms shown, %d planned" % [presses, watch._shown, watch.chain.plans.size()])
		# Everything that is shown is in the picture.
		var half := Vector2(watch.camera.size * aspect, watch.camera.size) / 2.0
		for i: int in watch._shown:
			var bounds: AABB = watch.chain.plans[i].bounds
			var middle := Vector2(watch.camera.position.x, watch.camera.position.z)
			_expect(failures, absf(bounds.position.x - middle.x) <= half.x and absf(bounds.end.x - middle.x) <= half.x and absf(bounds.position.z - middle.y) <= half.y and absf(bounds.end.z - middle.y) <= half.y, "press %d: room %d is outside the picture" % [presses, i])
		if failures.size() > 8:
			break
	_expect(failures, _watch_done(watch) and watch.chain.plans.size() == watch.chain.goal_index + 1, "the watch ended with %d plans and goal room %d" % [watch.chain.plans.size(), watch.chain.goal_index])
	_expect(failures, watch.report.text.contains("complete") and watch.report.text.contains("GOAL fits"), "the report does not say that the chain is complete: %s" % watch.report.text)
	var planned: int = watch.chain.plans.size()
	await _key(KEY_ENTER)
	await _wait_physics(3)
	_expect(failures, watch.chain.plans.size() == planned, "Enter planned a room after the goal room")
	# The level's own chain was never touched.
	_expect(failures, level.chain.plans.size() == 1 and level.state == STATE_READY and level.rooms.size() == 1, "the level's chain has %d plans after the watch" % level.chain.plans.size())
	# The seed box is up: its keys are its own.
	level.typing = true
	await _key(KEY_F4)
	_expect(failures, watch.watching, "F4 reached the watch while the seed box was up")
	level.typing = false
	await _key(KEY_F4)
	_expect(failures, not watch.watching and player_camera.current and not watch.camera.current and not watch.screen.visible and not watch.lines.visible, "F4 does not give the view back to the player")
	await _unload(main)
	return failures

## A coroutine cannot be stopped from outside: after R, N or a typed seed only the latest watch may plan, and leaving stops it.
func test_watch_restart(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step, true, {"goal_room": 12})
	var level: Node3D = main.get_node("Level")
	var watch: Node3D = main.get_node("Watch")
	watch.candidate_seconds = 0.0
	await _key(KEY_F4)
	for i in 3:
		await _step_watch(watch)
	_expect(failures, watch.chain.plans.size() == 3, "the premise: %d plans" % watch.chain.plans.size())
	# A restart while the coroutine waits for a key press: the watch starts again, and one press plans one room.
	var old_chain: RefCounted = watch.chain
	level.use_seed("7")
	await _wait_physics(2)
	_expect(failures, watch.chain != old_chain and watch.chain.plans.is_empty() and watch.chain.get("_chain_seed") == level.chain_seed and watch._shown == 0, "the restart did not start the watch again")
	await _step_watch(watch)
	_expect(failures, watch.chain.plans.size() == 1 and old_chain.plans.size() == 3, "after the restart one press planned %d rooms in the new chain and %d in the old one" % [watch.chain.plans.size(), old_chain.plans.size() - 3])
	await _step_watch(watch)
	_expect(failures, watch.chain.plans.size() == 2, "the second press planned %d rooms" % (watch.chain.plans.size() - 1))
	# A restart in the middle of a room: the old coroutine is still waiting for its timer.
	var seed_number := 0
	var at := 0
	for candidate in range(1, 60):
		for plan: Object in _plans(_chain_script(step), candidate, 8):
			if not plan.rejected.is_empty():
				seed_number = candidate
				at = plan.index
				break
		if seed_number > 0:
			break
	level.use_seed(str(seed_number))
	await _wait_physics(2)
	watch.candidate_seconds = 0.4
	for i in at:
		await _step_watch(watch)
	await _key(KEY_ENTER) # plans the room with the record: the coroutine waits for the first rejected room to leave
	_expect(failures, watch._rejection != null and watch._shown == at, "the premise: the rejected room is on the screen (%s), %d rooms shown, expected %d" % [watch._rejection, watch._shown, at])
	level.use_seed("42")
	await _wait_physics(2)
	var timer := create_timer(1.0)
	await timer.timeout # the old coroutine wakes up, finds another ticket and quits
	_expect(failures, watch._shown == 0 and watch._rejection == null and watch.chain.plans.is_empty(), "the old coroutine went on after a restart: %d rooms shown, rejection %s, %d plans" % [watch._shown, watch._rejection, watch.chain.plans.size()])
	# Leaving in the middle of a room stops the coroutine, too.
	level.use_seed(str(seed_number))
	await _wait_physics(2)
	for i in at:
		await _step_watch(watch)
	var count := [0]
	watch.room_planned.connect(func(_plan: Object) -> void: count[0] += 1)
	await _key(KEY_ENTER)
	_expect(failures, watch._rejection != null, "the premise: a rejected room is on the screen")
	await _key(KEY_F4)
	var timer_after_leaving := create_timer(1.0)
	await timer_after_leaving.timeout
	_expect(failures, count[0] == 0 and not watch.watching and watch._shown == at, "a room was shown after the watch was left (%d rooms, %d shown, expected %d)" % [count[0], watch._shown, at])
	await _unload(main)
	return failures

## Stepping through reaches the plans of the normal run, for many seeds; and the plans a walked level makes are the watch's plans.
func test_watch_same_plans(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step, true, {"goal_room": 20})
	var level: Node3D = main.get_node("Level")
	var watch: Node3D = main.get_node("Watch")
	watch.candidate_seconds = 0.0
	await _key(KEY_F4)
	var script := _chain_script(step)
	var total_presses := 0
	for chain_seed in range(1, WATCH_SEEDS + 1):
		level.use_seed(str(chain_seed))
		await _wait_physics(1)
		var presses := 0
		while presses < 60 and not _watch_done(watch):
			await _step_watch(watch)
			presses += 1
		total_presses += presses
		var normal: Array = _plans_to_goal(script, chain_seed, 20).plans
		_expect(failures, _same_plans(watch.chain.plans, normal) and _same_rejections(watch.chain.plans, normal), "seed %d: the stepped-through plans are not the plans of the normal run" % chain_seed)
		_expect(failures, presses == watch.chain.plans.size(), "seed %d: %d presses for %d rooms" % [chain_seed, presses, watch.chain.plans.size()])
		if failures.size() > 8:
			break
	print("        %s: %d seeds stepped through, %d presses, every plan and every rejected room the same as in the normal run" % [step, WATCH_SEEDS, total_presses])
	# The plans a walked level makes while the watch plans next to it.
	_fast_forward(true)
	for chain_seed: int in [42, 1000]:
		level.goal_room = 8
		level.use_seed(str(chain_seed))
		await _wait_physics(2)
		var presses := 0
		while presses < 60 and not _watch_done(watch):
			await _step_watch(watch)
			presses += 1
		var finished := await _walk_to_finish(level, Autopilot.new(level), 0, 60 * 60 * 6)
		_expect(failures, finished, "seed %d: the run did not finish" % chain_seed)
		_expect(failures, _same_plans(watch.chain.plans, level.chain.plans) and _same_rejections(watch.chain.plans, level.chain.plans), "seed %d: the plans of the walked level are not the watch's plans" % chain_seed)
	_fast_forward(false)
	await _unload(main)
	return failures

#endregion

#region All debug views on: the same run

func _run_snapshot(level: Node3D) -> Array:
	return [level.state, level.current, level.keys, level.run_time, level.player.global_position, level.player.rotation, level.player.blend_position, level.player.body.global_rotation, level.rooms.keys(), level.chain.plans.size(), level.seed_text]

## Everything the plans say, rejected rooms included.
func _plan_summary(plans: Array) -> Array:
	var summary: Array = []
	for plan: Object in plans:
		summary.append([plan.index, plan.type, plan.transform, plan.bounds, plan.locked, plan.key_spot, plan.props, plan.get("lamp"), _rejections_of(plan)])
	return summary

## The autopilot walks one run of a seed for `ticks` physics ticks (or to the finish). views: every debug view of the step is on,
## and the watch (from step 4) plans a chain of its own next to the run: Enter is pressed every 0.2 s (a press while the watch
## shows a turned-down room is ignored, as for a player), the turned-down rooms stay 0.15 s.
func _view_run(step: String, chain_seed: int, views: bool, goal: int, ticks: int) -> Dictionary:
	var main := await _load_step(step, true, {"goal_room": goal, "chain_seed": chain_seed})
	var level: Node3D = main.get_node("Level")
	var lines: Node = main.get_node("Gizmos/Lines")
	var watch := main.get_node_or_null("Watch")
	if views:
		await _key(KEY_F3)
		if watch != null:
			watch.candidate_seconds = 0.15
			await _key(KEY_F4)
	await _wait_physics(30)
	var pilot := Autopilot.new(level)
	var snapshots: Array = []
	var state := {"ticks": 0}
	_fast_forward(true)
	await _drive(func() -> bool:
		pilot.physics_step()
		state["ticks"] += 1
		if views and watch != null and state["ticks"] % ENTER_EVERY_TICKS == 0:
			_press_now(KEY_ENTER)
		if state["ticks"] % 30 == 0:
			snapshots.append(_run_snapshot(level))
		return state["ticks"] >= ticks or level.state == STATE_FINISHED)
	pilot.release()
	_fast_forward(false)
	snapshots.append(_run_snapshot(level))
	var result := {
		snapshots = snapshots,
		plans = _plan_summary(level.chain.plans),
		points = lines.points.size(),
		watched = watch.chain.plans.size() if watch != null and watch.chain != null else 0,
		finished = level.state == STATE_FINISHED,
	}
	await _unload(main)
	return result

func test_views_change_nothing(step: String) -> Array[String]:
	var failures: Array[String] = []
	var has_watch := STEPS.find(step) >= VIEW_STEP_FIRST
	for chain_seed: int in [42, 1000]:
		var off := await _view_run(step, chain_seed, false, 8, 600)
		var on := await _view_run(step, chain_seed, true, 8, 600)
		_expect(failures, off.points == 0, "seed %d: the views drew while they were off" % chain_seed)
		_expect(failures, on.points > 0 and (not has_watch or on.watched > 0), "seed %d: the views on did nothing (%d points, the watch planned %d rooms): the comparison would prove nothing" % [chain_seed, on.points, on.watched])
		var first_difference := -1
		for i in mini(off.snapshots.size(), on.snapshots.size()):
			if off.snapshots[i] != on.snapshots[i]:
				first_difference = i
				break
		_expect(failures, off.snapshots.size() == on.snapshots.size() and first_difference < 0, "seed %d: the run with the views differs after %d ticks: %s against %s" % [chain_seed, (first_difference + 1) * 30, off.snapshots[first_difference] if first_difference >= 0 else "", on.snapshots[first_difference] if first_difference >= 0 else ""])
		_expect(failures, off.plans == on.plans, "seed %d: the plans differ with the views on" % chain_seed)
		if first_difference < 0 and off.snapshots.size() == on.snapshots.size() and off.plans == on.plans:
			print("        %s, seed %d: %d snapshots equal, the player in room %d after %.1f s, %d line points drawn and %d rooms watched with the views on" % [step, chain_seed, on.snapshots.size(), on.snapshots[-1][1], on.snapshots[-1][3], on.points, on.watched])
	return failures

## The whole game with every view on: from the first door to the goal pad, the time, the keys and the plans are the ones of the run without.
func test_views_full_run() -> Array[String]:
	var failures: Array[String] = []
	for chain_seed: int in [42, 1000]:
		var off := await _view_run(FINAL_STEP, chain_seed, false, 8, 60 * 60 * 3)
		var on := await _view_run(FINAL_STEP, chain_seed, true, 8, 60 * 60 * 3)
		_expect(failures, off.finished and on.finished, "seed %d: a run did not finish (without %s, with %s)" % [chain_seed, off.finished, on.finished])
		_expect(failures, off.snapshots == on.snapshots and off.plans == on.plans, "seed %d: the run with every view on is not the run without: %s against %s" % [chain_seed, off.snapshots[-1], on.snapshots[-1]])
		_expect(failures, on.points > 0 and on.watched > 0, "seed %d: the views did nothing" % chain_seed)
		if off.snapshots == on.snapshots and off.plans == on.plans:
			print("        seed %d: %d snapshots equal, the finish at %.2f s with the views on and off, the watch planned %d rooms next to it" % [chain_seed, on.snapshots.size(), on.snapshots[-1][3], on.watched])
	return failures

#endregion

#region Pinned seeds (step 5)

## The letters of a chain, worked out here without the check's code.
func _pin_types(chain: RefCounted) -> String:
	var types := ""
	for plan: Object in chain.plans:
		types += PIN_LETTERS[str(Chain.Type.find_key(plan.type))]
	return types

func test_pinned_holds() -> Array[String]:
	var failures: Array[String] = []
	var pinned: Dictionary = Pinned.PINNED
	_expect(failures, pinned.size() == 5, "%d seeds are pinned, expected 5" % pinned.size())
	var all_types := ""
	var locked_rooms := 0
	for step in STEPS:
		var script := _chain_script(step)
		for seed_text: String in pinned:
			var problems := Pinned.problems_of(script, seed_text)
			_expect(failures, problems.is_empty(), "%s, seed %s: %s" % [step, seed_text, problems])
	for seed_text: String in pinned:
		var number: int = _seeds_script(FINAL_STEP).parse(seed_text)
		var chain := _plans_to_goal(Chain, number, 20)
		var pins: Dictionary = pinned[seed_text]
		_expect(failures, _pin_types(chain) == pins.types and (pins.types as String).length() == chain.plans.size() and (pins.types as String).ends_with("G"), "seed %s: the pinned letters %s are not the chain's %s" % [seed_text, pins.types, _pin_types(chain)])
		var locks: Array[String] = []
		for plan: Object in chain.plans:
			if plan.locked:
				locks.append("%d:%d" % [plan.index, plan.key_spot])
		_expect(failures, str(locks) == str(pins.locks), "seed %s: the pinned locks %s are not the chain's %s" % [seed_text, pins.locks, locks])
		var end: Vector3 = chain.plans[-1].transform.origin
		_expect(failures, pins.end == "%.1f %.1f" % [end.x, end.z], "seed %s: the pinned end %s is not the chain's (%.1f %.1f)" % [seed_text, pins.end, end.x, end.z])
		all_types += pins.types
		locked_rooms += locks.size()
	# The pins cover what can go wrong: five seeds of 21 rooms, every room type, both turns, and 39 locked rooms.
	_expect(failures, all_types.length() == 5 * 21 and locked_rooms == 39, "the pins hold %d rooms and %d locked rooms, expected 105 and 39" % [all_types.length(), locked_rooms])
	for letter: String in ["S", "L", "<", ">", "W", "V", "G"]:
		_expect(failures, all_types.contains(letter), "no pinned seed has a room of type %s" % letter)
	return failures

## A chain script with the source of room_chain.gd changed in one place: an accident, written down.
var _accidents := {}
func _accident(label: String, old: String, replacement: String) -> GDScript:
	if _accidents.has(label):
		return _accidents[label]
	var source := FileAccess.get_file_as_string("res://steps/%s/room_chain.gd" % FINAL_STEP)
	if source.count(old) != 1:
		return null
	var script := GDScript.new()
	script.source_code = source.replace(old, replacement)
	script.resource_path = "res://steps/%s/room_chain_accident_%d.gd" % [FINAL_STEP, _accidents.size()] # the chain's preloads are relative to this path
	if script.reload() != OK:
		return null
	_accidents[label] = script
	return script

## The pinned seeds fail on a deliberate change, loudly: the seed and the first room that moved are named. The unchanged chain passes (test_pinned_holds).
func test_pinned_fails() -> Array[String]:
	var failures: Array[String] = []
	var accidents := {
		"the vault spacing taken out (accidental_change.gd)": load("res://steps/%s/accidental_change.gd" % FINAL_STEP) as GDScript,
		"the heading rule loosened (BACK_LIMIT 0.05 to 0.5)": _accident("heading", "const BACK_LIMIT := 0.05", "const BACK_LIMIT := 0.5"),
		"the lock number and the key spot drawn in the other order": _accident("swap", "\tvar value := _content_rng.randf()\n\tvar spot := _content_rng.randi_range(0, spot_count - 1)\n", "\tvar spot := _content_rng.randi_range(0, spot_count - 1)\n\tvar value := _content_rng.randf()\n"),
		"one randf() call more before the lock number of room 5": _chain_with_extra_calls(FINAL_STEP, 5, 1),
		"the room weights are no longer read (every room type weighs 1)": _accident("weights", "weights.append(ROOM_WEIGHTS.weight_of(type))", "weights.append(1.0)"),
	}
	for label: String in accidents:
		var script: GDScript = accidents[label]
		_expect(failures, script != null, "%s: the accident does not compile or its anchor is gone" % label)
		if script == null:
			continue
		var failing := 0
		var message := ""
		for seed_text: String in Pinned.PINNED:
			var problems := Pinned.problems_of(script, seed_text)
			if not problems.is_empty():
				failing += 1
				if message.is_empty():
					message = problems[0]
		print("        %s: %d of %d pinned seeds fail, e.g. \"%s\"" % [label, failing, Pinned.PINNED.size(), message])
		_expect(failures, failing >= 3 and failing <= Pinned.PINNED.size(), "%s: %d of %d pinned seeds fail, expected 3 to 5" % [label, failing, Pinned.PINNED.size()])
		_expect(failures, message.contains("pinned") or message.contains("locks") or message.contains("stands at"), "%s: the message does not say what moved: %s" % [label, message])
	# The accident of the video: the vault spacing. Three of the five seeds fail, and seed 1 names room 12: pinned LONG, got WIDE.
	var vault_accident: GDScript = accidents["the vault spacing taken out (accidental_change.gd)"]
	var vault_failing: Array[String] = []
	for seed_text: String in Pinned.PINNED:
		if not Pinned.problems_of(vault_accident, seed_text).is_empty():
			vault_failing.append(seed_text)
	_expect(failures, vault_failing == ["1", "1000", "BLUE-FOX"], "the vault accident fails the seeds %s, expected 1, 1000 and BLUE-FOX" % [vault_failing])
	var seed_one := Pinned.problems_of(vault_accident, "1")
	_expect(failures, not seed_one.is_empty() and seed_one[0] == "room 12: pinned LONG, got WIDE", "seed 1 says %s, expected room 12: pinned LONG, got WIDE" % [seed_one])
	# A room that moved is named by its number and its type.
	var named := false
	var sentence := RegEx.create_from_string("^room \\d+: pinned [A-Z_]+, got [A-Z_]+$")
	for seed_text: String in Pinned.PINNED:
		for line in Pinned.problems_of(accidents["the heading rule loosened (BACK_LIMIT 0.05 to 0.5)"], seed_text):
			named = named or sentence.search(line) != null
	_expect(failures, named, "no difference is named by room and type")
	return failures

func test_pinned_command() -> Array[String]:
	var failures: Array[String] = []
	var executable := OS.get_executable_path()
	if executable.is_empty():
		_skip("check_pinned.gd from the command line", "no executable path")
		return failures
	var base: Array[String] = ["--headless", "--path", ProjectSettings.globalize_path("res://"), "-s", "res://steps/%s/check_pinned.gd" % FINAL_STEP]
	var output: Array = []
	var code := OS.execute(executable, base, output, true)
	var text := ""
	for chunk: String in output:
		text += str(chunk)
	_expect(failures, code == 0 and text.contains("PINNED OK") and text.contains("as pinned") and not text.contains("FAILED"), "the pinned seeds, unchanged: exit code %d, output: %s" % [code, text.substr(0, 500)])
	for seed_text: String in Pinned.PINNED:
		_expect(failures, text.contains("seed %-10s" % seed_text), "no row for seed %s" % seed_text)
	output = []
	var accident_arguments := base.duplicate()
	accident_arguments.append_array(["--", "--chain=res://steps/%s/accidental_change.gd" % FINAL_STEP])
	code = OS.execute(executable, accident_arguments, output, true)
	text = ""
	for chunk: String in output:
		text += str(chunk)
	_expect(failures, code == 1 and text.contains("PINNED FAILED") and text.contains(": pinned ") and text.contains("--print"), "the accident: exit code %d, output: %s" % [code, text.substr(0, 700)])
	# --print writes the pins the file holds, ready to paste.
	output = []
	var print_arguments := base.duplicate()
	print_arguments.append_array(["--", "--print"])
	code = OS.execute(executable, print_arguments, output, true)
	text = ""
	for chunk: String in output:
		text += str(chunk)
	_expect(failures, code == 0 and text.contains("const PINNED := {"), "--print: exit code %d" % code)
	for seed_text: String in Pinned.PINNED:
		var pins: Dictionary = Pinned.PINNED[seed_text]
		_expect(failures, text.contains("\"%s\": {types = \"%s\", locks = %s, end = \"%s\"}" % [seed_text, pins.types, pins.locks, pins.end]), "--print does not print the pins of seed %s as they are in the file" % seed_text)
	return failures

#endregion

#endregion

#region The game underneath (the character tutorial's final state, with the views next to it)

## Room 2 entered: the door of room 1 starts to close behind the player, room 0 is the oldest room.
func _door_closing_behind_room_2(step: String) -> Node:
	var main := await _load_step(step)
	var level: Node3D = main.get_node("Level")
	level.rooms[0].door.open() # builds room 1
	level._on_room_entered(level.player, 1)
	await _wait_physics(45)
	level.rooms[1].door.open() # builds room 2
	await _wait_physics(45)
	level._on_room_entered(level.player, 2)
	return main

## Through the door behind the player the picture goes along the room just left, to the doorway of the one before it.
func test_rooms_wait_for_the_door(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _door_closing_behind_room_2(step)
	var level: Node3D = main.get_node("Level")
	_expect(failures, level.rooms.has(0), "room 0 went while the door behind the player stood open")
	await _wait_physics(45)
	_expect(failures, not level.rooms.has(0), "room 0 is still there behind the shut door")
	_expect(failures, level.rooms.has(1), "the room just left went with room 0")
	_expect(failures, not level.rooms[1].get_node("Shell/WallEntrance/Opening").visible, "the room just left has no wall at its entrance")
	await _unload(main)
	main = await _door_closing_behind_room_2(step)
	level = main.get_node("Level")
	await _wait_physics(10)
	level.rooms[1].door.open() # the player turned around while the leaf still swings
	await _wait_physics(45)
	_expect(failures, level.rooms.has(0), "room 0 went while the door stood open again")
	level.start()
	if level.has_method("_on_door_closed"):
		level._on_door_closed(2) # a restart is faster than the door of the old run
		_expect(failures, level.rooms.has(0), "the door of the old run took room 0 of the new one")
	else:
		_expect(failures, false, "level.gd has no _on_door_closed")
	await _unload(main)
	return failures

func test_full_run() -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(FINAL_STEP)
	var level: Node3D = main.get_node("Level")
	var pilot := Autopilot.new(level)
	_fast_forward(true)
	var budget := [60 * 60 * 5]
	await _drive(func() -> bool:
		pilot.physics_step()
		budget[0] -= 1
		return level.state == STATE_FINISHED or budget[0] <= 0)
	pilot.release()
	_fast_forward(false)
	_expect(failures, level.state == STATE_FINISHED, "the run did not finish (room %d, %.1f s)" % [level.current, level.run_time])
	_expect(failures, level.current == 20, "finished in room %d" % level.current)
	_expect(failures, level.run_time > 30.0 and level.run_time < 150.0, "the run took %.1f s" % level.run_time)
	print("        full run, seed 42: %.2f s of game time" % level.run_time)
	await _unload(main)
	return failures

func _state(player: CharacterBody3D) -> String:
	var tree := player.get_node("Body/AnimationTree") as AnimationTree
	return (tree.get("parameters/playback") as AnimationNodeStateMachinePlayback).get_current_node()

func test_restart() -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(FINAL_STEP)
	var level: Node3D = main.get_node("Level")
	var player: CharacterBody3D = level.player
	var tree := player.get_node("Body/AnimationTree") as AnimationTree
	Input.action_press("move_forward")
	await _wait_physics(30)
	Input.action_release("move_forward")
	await _action("regenerate")
	await _wait_physics(40)
	_expect(failures, player.global_position.distance_to(Vector3(0.0, 0.0, 3.5)) < 0.05, "the player is at %s" % player.global_position)
	_expect(failures, _state(player) == "Move", "the tree is in %s" % _state(player))
	_expect(failures, is_zero_approx(tree.get("parameters/Move/blend_position")), "blend position %.2f" % tree.get("parameters/Move/blend_position"))
	await _unload(main)
	return failures

func test_scene_runs(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step, false)
	for i in 30:
		await process_frame
	_expect(failures, is_instance_valid(main) and main.is_inside_tree(), "scene left the tree")
	await _unload(main)
	return failures

#endregion

#region The watch and the room camera: three cameras, one view

func _viewing(main: Node) -> String:
	var camera := root.get_camera_3d()
	return str(main.get_path_to(camera)) if camera != null else "none"

## The paths of the cameras that say they are current: it must be exactly the one the viewport shows.
func _current_cameras(main: Node) -> Array[String]:
	var found: Array[String] = []
	for camera: Node in main.find_children("*", "Camera3D", true, false):
		if (camera as Camera3D).current:
			found.append(str(main.get_path_to(camera)))
	return found

## The first-person camera, the room camera (V) and the watch's camera (F4) take the view from each other. Whoever hands it
## back gives it to the one that had it: the player's camera, or the room camera if V was on when the watch started.
func test_watch_and_room_camera(step: String) -> Array[String]:
	var failures: Array[String] = []
	var logged := ScriptErrorCounter.new()
	logged.script_only = false
	OS.add_logger(logged)
	var main := await _load_step(step, true, {"goal_room": 12})
	var level: Node3D = main.get_node("Level")
	var player_camera: Camera3D = level.player.get_node("Head/Camera3D")
	var room_camera: Camera3D = main.get_node("RoomCamera")
	var watch: Node3D = main.get_node("Watch")
	var player_view := "Level/Player/Head/Camera3D"
	_expect(failures, _viewing(main) == player_view and _current_cameras(main) == [player_view], "the game does not start in first person: %s" % _viewing(main))
	# The body stays out of the first-person view, every other camera sees it.
	_expect(failures, player_camera.cull_mask & BODY_LAYER_BIT == 0, "the first-person camera sees the body")
	_expect(failures, room_camera.cull_mask & BODY_LAYER_BIT != 0 and watch.camera.cull_mask & BODY_LAYER_BIT != 0, "the room camera or the watch's camera does not see the body")
	_expect(failures, watch.camera.cull_mask & CEILING_LAYER == 0, "the watch's camera sees the ceilings")
	# V alone: on, and the view back (the watch's camera is in the scene, too, and must not get it).
	await _action("toggle_view")
	_expect(failures, _viewing(main) == "RoomCamera" and _current_cameras(main) == ["RoomCamera"], "V: the view is %s, current are %s" % [_viewing(main), _current_cameras(main)])
	await _action("toggle_view")
	_expect(failures, _viewing(main) == player_view and _current_cameras(main) == [player_view], "V again: the view is %s, current are %s" % [_viewing(main), _current_cameras(main)])
	# F4 on and off from first person.
	await _key(KEY_F4)
	_expect(failures, _viewing(main) == "Watch/Camera" and _current_cameras(main) == ["Watch/Camera"], "F4: the view is %s, current are %s" % [_viewing(main), _current_cameras(main)])
	await _key(KEY_F4)
	_expect(failures, _viewing(main) == player_view and _current_cameras(main) == [player_view], "F4 again: the view is %s, current are %s" % [_viewing(main), _current_cameras(main)])
	# V first, then F4: the view goes back to the room camera, and V gives it to the player.
	await _action("toggle_view")
	await _key(KEY_F4)
	_expect(failures, _viewing(main) == "Watch/Camera" and _current_cameras(main) == ["Watch/Camera"], "V, F4: the view is %s" % _viewing(main))
	await _key(KEY_F4)
	_expect(failures, _viewing(main) == "RoomCamera" and _current_cameras(main) == ["RoomCamera"], "V, F4, F4: the view is %s, expected the room camera" % _viewing(main))
	await _action("toggle_view")
	_expect(failures, _viewing(main) == player_view and _current_cameras(main) == [player_view], "V, F4, F4, V: the view is %s, current are %s" % [_viewing(main), _current_cameras(main)])
	# F4 first, then V: the room camera takes the view from the watch; V gives it to the player; F4 leaves to where it came from.
	await _key(KEY_F4)
	await _action("toggle_view")
	_expect(failures, _viewing(main) == "RoomCamera" and _current_cameras(main) == ["RoomCamera"], "F4, V: the view is %s, current are %s" % [_viewing(main), _current_cameras(main)])
	await _action("toggle_view")
	_expect(failures, _viewing(main) == player_view and _current_cameras(main) == [player_view], "F4, V, V: the view is %s, current are %s" % [_viewing(main), _current_cameras(main)])
	await _key(KEY_F4)
	_expect(failures, not watch.watching and _viewing(main) == player_view and _current_cameras(main) == [player_view], "F4, V, V, F4: the view is %s, current are %s" % [_viewing(main), _current_cameras(main)])
	await _key(KEY_F4)
	await _action("toggle_view")
	await _key(KEY_F4)
	_expect(failures, not watch.watching and _viewing(main) == player_view and _current_cameras(main) == [player_view], "F4, V, F4: the view is %s, current are %s" % [_viewing(main), _current_cameras(main)])
	await _action("toggle_view")
	_expect(failures, _viewing(main) == "RoomCamera" and _current_cameras(main) == ["RoomCamera"], "F4, V, F4, V: the view is %s, current are %s" % [_viewing(main), _current_cameras(main)])
	await _action("toggle_view")
	# A restart (R) while watching does not change whose view it is.
	await _key(KEY_F4)
	await _action("regenerate")
	await _wait_physics(2)
	_expect(failures, _viewing(main) == "Watch/Camera" and watch.watching, "R while watching: the view is %s" % _viewing(main))
	await _key(KEY_F4)
	_expect(failures, _viewing(main) == player_view and _current_cameras(main) == [player_view], "R while watching, then F4: the view is %s" % _viewing(main))
	await _unload(main)
	OS.remove_logger(logged)
	_expect(failures, logged.count == 0, "the engine logged %d errors or warnings while the cameras changed hands" % logged.count)
	return failures

#endregion

#region Harness

func _run(test_name: String, test: Callable) -> void:
	if not _selected(test_name):
		return
	await process_frame # the engine empties its message queue between tests: the chain tests build thousands of room scenes
	var failures: Array[String] = await test.call()
	_report(test_name, failures)

func _selected(test_name: String) -> bool:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--only=") and not test_name.contains(argument.trim_prefix("--only=")):
			return false
	return true

func _steps_from(first: String) -> Array[String]:
	var result: Array[String] = []
	for step: String in STEPS.slice(STEPS.find(first)):
		result.append(step)
	return result

func _report(test_name: String, failures: Array[String]) -> void:
	var script_errors := _script_errors.count - _script_errors_reported
	_script_errors_reported = _script_errors.count
	if script_errors > 0: # the test stopped at the failing line and the engine returned an empty array, which would read as a pass
		failures.insert(0, "the test stopped with a script error: see the log")
	if failures.is_empty():
		_passed += 1
		print("PASS  ", test_name)
		return
	_failed += 1
	print("FAIL  ", test_name)
	for message: String in failures.slice(0, 8):
		print("        ", message)
	if failures.size() > 8:
		print("        ... and %d more" % (failures.size() - 8))

func _skip(test_name: String, reason: String) -> void:
	_skipped += 1
	print("SKIP  ", test_name)
	print("        ", reason)

func _expect(failures: Array[String], condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)

## Instances a step's main scene. By default it waits until the CSG shapes have built their collision.
## props are set on the Level before it enters the tree (goal_room, seed_text, lock_chance ...; "chain_seed" is the
## text of the seed's digits).
## Every level gets a fresh temporary save file unless props bring one.
func _load_step(step: String, settle := true, props := {}) -> Node:
	var scene: PackedScene = load("res://steps/%s/main.tscn" % step)
	var main := scene.instantiate()
	var level := main.get_node("Level")
	if not props.has("save_path"):
		level.set("save_path", _fresh_save_path())
	for key: String in props:
		if key == "chain_seed":
			level.set("seed_text", str(props[key]))
		else:
			level.set(key, props[key])
	root.add_child(main)
	if settle:
		await _wait_physics(10)
	return main

func _unload(main: Node) -> void:
	for action: String in ["move_forward", "move_back", "move_left", "move_right", "look_left", "look_right", "look_up", "look_down", "jump", "walk"]:
		Input.action_release(action)
	root.remove_child(main)
	main.free()
	await process_frame

## A path in the temporary test folder that no file exists at.
func _fresh_save_path() -> String:
	_save_counter += 1
	DirAccess.make_dir_recursive_absolute(_save_dir)
	return _save_dir.path_join("best_times_%d.json" % _save_counter)

func _wipe_save_dir() -> void:
	if not DirAccess.dir_exists_absolute(_save_dir):
		return
	for file in DirAccess.get_files_at(_save_dir):
		DirAccess.remove_absolute(_save_dir.path_join(file))
	DirAccess.remove_absolute(_save_dir)

## Runs the simulation faster than real time with the same 1/60 s steps: the engine ticks
## SPEED_UP times as often and hands out SPEED_UP times the delta of each (smaller) tick.
func _fast_forward(on: bool) -> void:
	Engine.physics_ticks_per_second = 60 * (SPEED_UP if on else 1)
	Engine.time_scale = float(SPEED_UP) if on else 1.0

func _wait_physics(frames: int) -> void:
	for i in frames:
		await physics_frame

func _action(action: StringName) -> void:
	var press := InputEventAction.new()
	press.action = action
	press.pressed = true
	Input.parse_input_event(press)
	Input.flush_buffered_events()
	await process_frame

## The names of an action's keyboard keys ("F3"), by physical key.
func _physical_keys(action: StringName) -> Array[String]:
	var keys: Array[String] = []
	for event in InputMap.action_get_events(action):
		if event is InputEventKey:
			keys.append(OS.get_keycode_string((event as InputEventKey).physical_keycode))
	return keys

## Presses and releases a key like a player does: through the input system, so the control that has the focus gets it.
func _key(code: Key, unicode := 0) -> void:
	for pressed: bool in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.unicode = unicode
		event.pressed = pressed
		Input.parse_input_event(event)
		Input.flush_buffered_events()
		await process_frame
		await process_frame

## A press and a release of a key within this frame, for callbacks that cannot await (the physics driver).
func _press_now(code: Key) -> void:
	for pressed: bool in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = pressed
		Input.parse_input_event(event)
		Input.flush_buffered_events()

#endregion
