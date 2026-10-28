# TargetBar

Ashita v4 addon that draws your target's HP% as a bar anchored to the horizontal center of the screen.

The fill is Sidekick3's Vanacore HP red (`#EE6F78`) at 70%. The track behind it is the near-black Sidekick3 uses while you are fighting (`#0C0C0C`) at 70%, with a 1px edge and 4px corners. The number on the right end of the bar is the target's current HP%. The fill eases toward that number.

The HP bar is for mobs, players, pets, and trusts. An NPC (a shopkeeper, a door, a Home Point) has no HP to show, so it gets only its name, in pale green (`#C2FFC2`), on a black background at 40% no wider than the name, centered on the screen at the bar's height. There is no HP% on it. With the name hidden, an NPC draws nothing.

The target's name sits inside the bar, on the left. Both the name and the HP% sit the edge offset (8px to start) in from the ends of the bar. A name too long to fit before the HP% is cut short with `...`. The name is white over 75% HP, yellow at 75%, orange at 50%, and red at 25%, the colors Sidekick3 gives a name on an HP bar. Text uses Sidekick3's HUD face, Segoe UI Semibold, with the same 1px black halo. The name starts at 25px, the numbers at 20px, and the icons at 32px. Each has a slider. On Ashita 4.16's ImGui 1.80, which bakes a font at one size, each face is baked once and scaled: the HUD's at 32px, the settings window's at 18px. Text well past its bake is a little soft. Without Segoe UI installed, the same sizes are drawn in ImGui's own font.

Under the bar, a mob shows the damage types it does not take normally. The icons and the order are mobdb's, drawn the way Floaties draws them: weakest damage first (a positive percentage), resistances last, and one percentage on the last icon of each equal group.

Beside the bar, a mob shows what it notices, in the order Floaties uses. On the left, aggro or passive, then Link when it links. Aggro and passive always draw: a mob that does not aggro is not the same as a mob with no data. A notorious monster uses the gold-framed icon. On the right, whichever of TrueSight, Sight, Sound, Scent, Magic, JA, and Blood it has, in that order. The groups sit one gap off the bar and grow outward, so the bar stays centered. When the target's target is shown, the right group starts one gap past that bar.

A target mobdb does not know, a player, or a trust in your party shows the name and the HP% only. (A trust carries the game's mob flag, and a few share a name with a battlefield's mob.) The icons need `addons/mobdb`. Without it, the name and the bar still draw.

The settings window can hide the name, the percent on the bar, the detection icons, the weakness icons, the resistance icons, and the target's target. The bar itself stays. Detection is on until you hide it. The target's target is on until you hide it.

Locked on, a transparent red fringe (`#FF4A40`) outlines the bar, softer a few pixels out. The word Locked sits just above it in `#ffb4b4`, with that same red fringe as its outline.

Between the bar and a second bar, an equilateral triangle points at who your target is targeting. Its left edge is vertical and as tall as the HP bar. It is Sidekick3's MP yellow (`#E8B45C`) at 70%. The second bar shows that target's name on the left and the HP% on the right, in the same colours and at the same edge offset. It is the same height as the bar, unless the name or the percent is taller, in which case it grows so that line sits inside it. Its width starts at 280. It never draws narrower than the name and `100%` on one line, so a long name widens it and neither is cut short. A player's target is read from the entity (`TargetedIndex`). It is empty when that player has none, and it is not filled in for you. A mob's battle target is not stored there. The second bar takes it from the mob's last swing, spell, or skill, keeps that for 30 seconds, and shows whoever has claim until the mob acts.

The bar starts at 480 by 28, centered on the screen both ways, whatever its size. Width, height, Y, and the target-of-target width are saved per character. Until you move it, Y follows the screen's center. X is always the center of the display. The second bar does not move that center: it hangs off the right.

## Load

```
/addon load TargetBar
```

## Place it

`/tb` opens the settings window and, until you target something, a full bar, the name "Target", a second bar with the same name and 100%, and sample icons so you can see the layout. Detection shows aggro, Link, TrueSight, Sight, and Sound. Weakness shows `Fire +25%` and `Ice -50%`. Those parts follow the toggles. The window is drawn the way Sidekick3's Sidekick Settings is (`ui/kit.lua`, after VanaCore's `/vana` window): the same palette, Segoe UI faces, scale, title bar, close mark, group headings, switches, sliders, button, and tooltips, on a card XPBar's width. Drag any empty part of it to move it. Click a slider's number to type one.

- Drag the bar up or down. It stays centered. The second bar moves with it.
- Under Show, Name, HP %, Detection, Weakness, Resistance, and Target of target each hide that part. The second bar always draws its own name and HP%.
- Under Text and icons, Name font size and Text font size set the name and the numbers (Sidekick3's ranges, 8 to 64 and 8 to 48 px). Icon size sets the detection and damage icons, 8 to 64 px. Edge offset sets the space between the ends of the bar and the name and HP%, 0 to 64 px. It also sets the padding on each side of an NPC's name, and on the second bar.
- Under Bar, Width, Height, Y, and Target of target are the sliders. Width goes up to the screen's width. Target of target cannot go below the name and the HP% on one line. Reset position puts the bar back on the middle of the screen.
- `/tb` again closes the window. The bar hides when you have no target.

```
/tb width <px>
/tb totwidth <px>
/tb height <px>
/tb y <px>
/tb reset
/tb help
```

`/targetbar` is the same command. Width and the target-of-target width are 40 to 5120 px (the main bar is drawn no wider than the screen). The second bar still widens past that setting when its name and HP% need the room. Height is 8 to 160 px, and Y is pixels from the top of the screen. `/tb reset` returns the width, the target-of-target width, the height, the three text and icon sizes, and the edge offset, and centers the bar. The Reset position button centers it only. The toggles are kept.

The bar reads the main target (target index 0), the same HP percent HXUI's target bar reads. The second bar reads who that target is targeting. It does not follow a subtarget.

## Licence

TargetBar is free software under the GNU General Public License, version 3 or (at your option) any later version: see [LICENSE](LICENSE). Copyright (c) 2026 Seekey.

Its settings window is based on Sidekick3's UI kit (`ui/kit.lua`) and Sidekick Settings' layout (`ui/window.lua`), which are based on VanaCore's `/vana` window (`addons/vanacore/vana/draw.lua` and `vana.lua`, Copyright (C) 2026 Vekien, GPL-3.0-or-later). TargetBar is not VanaCore, and isn't made or endorsed by Vekien; VanaCore's name and logo aren't licensed with it.
