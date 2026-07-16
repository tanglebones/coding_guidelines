## 6. Game Development (Godot / GDScript)

- One class per file, filename matches the class; `class_name` + `extends` on the first two lines; typed variables and constants throughout.
  ```gdscript
  class_name Widget
  extends RefCounted

  var widget_id: String = ""
  var hp: int = 100
  ```
- snake_case for files/functions, PascalCase for `class_name`; underscore-prefixed private members (`_dispatch_tick`).
- Scene-root scripts stay thin (wiring/composition only); real logic lives in plain data/model classes.
- Single mutation point per domain (one autoload/singleton owns the canonical state), exposed through verb-named methods that validate preconditions, return early on failure, and only emit a signal after the mutation succeeds. Signals are named past-tense (`inventory_changed`).
  ```gdscript
  # autoload/game_state.gd
  signal widget_status_changed(widget_id: String)

  func complete_widget(widget_id: String) -> void:
      var w = _find(widget_id)
      if w == null:
          return
      w.status = "complete"
      widget_status_changed.emit(widget_id) # only after the mutation succeeds
  ```
- Serialization via a paired `to_dict()` / `static from_dict()`, reading with defensive `.get(key, default)` and `.duplicate()` to avoid aliasing bugs.
  ```gdscript
  func to_dict() -> Dictionary:
      return { "id": widget_id, "traits": traits.duplicate() }

  static func from_dict(d: Dictionary) -> Widget:
      var w := Widget.new()
      w.widget_id = d.get("id", "")
      w.traits = d.get("traits", {}).duplicate()
      return w
  ```
- Errors surfaced via `push_error()` with an actionable message rather than raised exceptions (GDScript convention).
  ```gdscript
  push_error("SaveManager: cannot open %s for writing" % save_path)
  ```
- Testing via GUT (`extends GutTest`, `tests/unit/test_<subject>.gd`, one test file per production script); float comparisons use `assert_almost_eq` with a descriptive message; round-trip serialization tests are a recurring, worthwhile pattern to keep.
  ```gdscript
  extends GutTest

  func test_round_trips_through_dict():
      var w := Widget.new()
      w.hp = 42
      var w2 := Widget.from_dict(w.to_dict())
      assert_eq(w2.hp, w.hp)

  func test_dodge_chance_is_within_tolerance():
      assert_almost_eq(widget.get_dodge_chance(), 0.04, 0.0001, "dodge chance formula drifted")
  ```
