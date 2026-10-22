# TargetBar

Ashita v4 addon that draws your target's HP% as a bar anchored to the horizontal center of the screen.

The fill is Sidekick3's Vanacore HP red (`#EE6F78`) at 70%. The track behind it is the near-black Sidekick3 uses while you are fighting (`#0C0C0C`) at 70%, with a 1px edge and 4px corners. The number on the bar is the target's current HP%. The fill eases toward that number.

The bar is for mobs and players. Targeting an NPC (a shopkeeper, a door, a Home Point) draws nothing, the rule Floaties uses for its target panel.

The target's name is centered above the bar. It is white over 75% HP, yellow at 75%, orange at 50%, and red at 25%, the colors Sidekick3 gives a name on an HP bar. Text uses Sidekick3's HUD face, Segoe UI Semibold, with the same 1px black halo. The name starts at 25px, the numbers at 20px, and the icons at 32px. Each has a slider. On an older ImGui the same sizes are drawn in ImGui's own font.

Under the bar, a mob shows the damage types it does not take normally. The icons and the order are mobdb's, drawn the way Floaties draws them: weakest damage first (a positive percentage), resistances last, and one percentage on the last icon of each equal group.

Beside the bar, a mob shows what it notices, in the order Floaties uses. On the left, aggro or passive, then Link when it links. Aggro and passive always draw: a mob that does not aggro is not the same as a mob with no data. A notorious monster uses the gold-framed icon. On the right, whichever of TrueSight, Sight, Sound, Scent, Magic, JA, and Blood it has, in that order. The groups sit one gap off the bar and grow outward, so the bar stays centered.

A target mobdb does not know, a player, or a trust in your party shows the name and the HP% only. (A trust carries the game's mob flag, and a few share a name with a battlefield's mob.) The icons need `addons/mobdb`. Without it, the name and the bar still draw.

The settings window can hide the name, the percent on the bar, the detection icons, the weakness icons, and the resistance icons. The bar itself stays. Detection is on until you hide it.

The bar starts at 480 by 28, centered on the screen both ways, whatever its size. Width, height, and Y are saved per character. Until you move it, Y follows the screen's center. X is always the center of the display.

## Load

```
/addon load TargetBar
```

## Place it

`/tb` opens the settings window and, until you target something, a full bar, the name "Target", and sample icons so you can see the layout. Detection shows aggro, Link, TrueSight, Sight, and Sound. Weakness shows `Fire +25%` and `Ice -50%`. Those parts follow the toggles. The window is drawn the way Sidekick3's Sidekick Settings is (`ui/kit.lua`, after VanaCore's `/vana` window): the same palette, Segoe UI faces, scale, title bar, close mark, group headings, switches, sliders, button, and tooltips, on a card XPBar's width. Drag any empty part of it to move it. Click a slider's number to type one.

- Drag the bar up or down. It stays centered.
- Under Show, Name, HP %, Detection, Weakness, and Resistance each hide that part.
- Under Text and icons, Name font size and Text font size set the name and the numbers (Sidekick3's ranges, 8 to 64 and 8 to 48 px). Icon size sets the detection and damage icons, 8 to 64 px.
- Under Bar, Width, Height, and Y are the sliders. Width goes up to the screen's width. Reset position puts the bar back on the middle of the screen.
- `/tb` again closes the window. The bar hides when you have no target.

```
/tb width <px>
/tb height <px>
/tb y <px>
/tb reset
/tb help
```

`/targetbar` is the same command. Width is 40 to 5120 px (drawn no wider than the screen), height is 8 to 160 px, and Y is pixels from the top of the screen. `/tb reset` returns the width, the height, and the three text and icon sizes, and centers the bar. The Reset position button centers it only. The toggles are kept.

The bar reads the main target (target index 0), the same HP percent HXUI's target bar reads. It does not follow a subtarget.

## Licence

TargetBar is free software under the GNU General Public License, version 3 or (at your option) any later version: see [LICENSE](LICENSE). Copyright (c) 2026 Seekey.

Its settings window is based on Sidekick3's UI kit (`ui/kit.lua`) and Sidekick Settings' layout (`ui/window.lua`), which are based on VanaCore's `/vana` window (`addons/vanacore/vana/draw.lua` and `vana.lua`, Copyright (C) 2026 Vekien, GPL-3.0-or-later). TargetBar is not VanaCore, and isn't made or endorsed by Vekien; VanaCore's name and logo aren't licensed with it.
