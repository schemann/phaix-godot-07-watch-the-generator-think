# Watch the Generator Think in Godot 4

Project files for tutorial 07 of the Godot 4 series by Phaix on YouTube (https://www.youtube.com/@Phaix).

Draw and step through the room generator of a game like Roblox DOORS in Godot 4.
We build debug views in 3D: the bounds and markers of every room, the rooms it turned down, one room per key press, and seeds pinned so that nobody changes the generator by accident.

Lines in 3D with an ImmediateMesh, three pixels wide at any distance, a debug view that only reads and draws, the markers of a room drawn as arrows and crosses with the room's transform, a generate-and-test loop that writes down what it turned down so the rejected rooms flash red where they would have stood, a coroutine that plans the same chain one room per key press and the ticket that stops the old one, and a headless check that pins five seeds so a change by accident fails loudly. Every step is its own project folder.

![Screenshot](screenshot.png)

## Steps

Every step of the video is its own folder in `steps/`, the exact state at the end of that
part. Open the project in Godot 4.7, then open `steps/<step>/main.tscn` and press F6 to run
that step. The project's main scene is the final step.

| Folder | Part of the video |
|---|---|
| `steps/step_00_start` | Starting point (the final state of tutorial S1) |
| `steps/step_01_room_bounds` | Step 1 - Lines in 3D |
| `steps/step_02_markers` | Step 2 - A marker is a transform |
| `steps/step_03_rejected` | Step 3 - The generator writes down what it turned down |
| `steps/step_04_step_through` | Step 4 - One room per key press |
| `steps/step_05_pinned_seeds` | Step 5 - Pin the seeds |

## Controls

WASD or arrow keys or the left stick to walk, mouse or right stick to look, Space to jump,
Esc gives the mouse back, a click captures it again. Further keys per tutorial are shown
in the video and in the HUD.

## Tests

```sh
godot --headless --path . -s res://tests/run_tests.gd
```

## Support

Support the channel: https://ko-fi.com/phaix or https://github.com/sponsors/schemann

## License

Code and scenes: MIT (see LICENSE).
The figure and its animations: Animated Characters Protagonists by Kenney (www.kenney.nl), CC0, see character/License.txt.
