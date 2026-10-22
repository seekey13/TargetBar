# TargetBar

Ashita v4 addon that draws your target's HP% as a bar anchored to the horizontal center of the screen.

The fill is Sidekick3's Vanacore HP red (`#EE6F78`) at 70%. The track behind it is the near-black Sidekick3 uses while you are fighting (`#0C0C0C`) at 70%, with a 1px edge and 4px corners. The number on the bar is the target's current HP%. The fill eases toward that number.

The target's name is centered above the bar. Text uses Sidekick3's HUD face, Segoe UI Semibold, with the same 1px black halo. The name is 25px and the numbers are 20px, the sizes that HUD is set to. On an older ImGui the same sizes are drawn in ImGui's own font.

Under the bar, a mob shows the damage types it does not take normally. The icons and the order are mobdb's, drawn the way Floaties draws them: weakest damage first (a positive percentage), resistances last, and one percentage on the last icon of each equal group. A target mobdb does not know, or a player, shows the name and the HP% only. The row needs `addons/mobdb`. Without it, the name and the bar still draw.

The settings window can hide the name, the percent on the bar, the weakness icons, and the resistance icons. The bar itself stays.

On a 3440x1440 display the bar starts at 480 by 28, with its top at Y 706, so it sits on the center of the screen. Width, height, and Y are saved per character. X is always the center of the display.

## Load

```
/addon load TargetBar
```

## Place it

`/tb` opens the settings window and, until you target something, a full bar, the name "Target", and sample weakness and resistance icons (`Fire +25%`, `Ice -50%`) so you can see the layout. Those parts follow the toggles. The window is the Vanacore panel, with the body sized the way XPBar's card is. Drag its title to move it. Click a slider's number to type one.

- Drag the bar up or down. It stays centered.
- Show name, Show HP%, Show weakness, and Show resistance each hide that part.
- Width, height, and Y are the sliders. Reset position returns Y to the default.
- `/tb` again closes the window. The bar hides when you have no target.

```
/tb width <px>
/tb height <px>
/tb y <px>
/tb reset
/tb help
```

`/targetbar` is the same command. Width is 40 to 5120 px, height is 8 to 160 px, and Y is pixels from the top of the screen. `/tb reset` returns width, height, and Y. The Reset position button returns Y only. The toggles are kept.

The bar reads the main target (target index 0), the same HP percent HXUI's target bar reads. It does not follow a subtarget.
