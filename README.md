# Drop In

A 3D skateboarding rhythm game built in Godot 4.7. Early prototype.

- **Rhythm Run** — the skater rolls down a street locked to a 110 BPM beat.
  Steer into line with each hoop and hit its key as the approach ring closes.
- **Free Skate** — an open park with quarter pipes, banks, kickers, rails and
  ledges. No timer, no beat.

## Running it

1. Install [Godot 4.7](https://godotengine.org/download) (standard build).
2. Open the project folder in the Godot editor once, so it imports the assets.
3. Press F5, or run from a terminal:

   ```
   godot --path .
   ```

## Controls

| Key | Rhythm Run | Free Skate |
|---|---|---|
| A / D | Steer | Steer |
| W / S | — | Push / brake |
| Space | Ollie | Ollie |
| J | Kickflip | Kickflip (in the air) |
| K | Hold to grind | Shove-it (in the air) |
| R | — | Reset to spawn |
| Enter | Retry (results screen) | — |
| Esc | Back to menu | Back to menu |

Landing on a rail in Free Skate starts a grind automatically.

## Project layout

| Path | What it is |
|---|---|
| `scripts/main.gd` | Menu, input bindings, mode switching |
| `scripts/rhythm_mode.gd` | Rhythm Run: chart, judging, street, HUD |
| `scripts/free_skate.gd` | Free Skate park and chase camera |
| `scripts/skater.gd` | Free Skate physics, tricks, grinds |
| `scripts/skater_model.gd` | Skater model, board, and skeleton poses |
| `scripts/build.gd` | Cel shader, ink outlines, geometry helpers |
| `scripts/metronome.gd` | Synthesised click track |
| `tools/make_skater.py` | Blender script that generates the skater |
| `assets/skater/` | Generated skater model and preview renders |

The world is built in code from primitive meshes. The only imported asset is
the skater.

## Rebuilding the skater

The skater is generated with Blender and the
[MPFB](https://extensions.blender.org/add-ons/mpfb/) extension:

```
blender --background --python tools/make_skater.py
```

Body proportions, colours and clothing fit are named values near the top of
the script. Characters produced with MPFB are CC0.

## Testing hooks

`main.gd` accepts arguments after `--` for scripted runs:

```
godot --path . -- --mode=rhythm --autoplay --shot=out.png --delay=12
godot --path . -- --mode=free --demo
```

## Status

Prototype. Known gaps: metronome click only (no music), placeholder skater and
environment art, no audio offset calibration, straight rhythm track.
