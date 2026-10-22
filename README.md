# TargetBar

Ashita v4 addon that draws your target's HP% as a bar anchored to the horizontal center of the screen.

The fill is Sidekick3's Vanacore HP red (`#EE6F78`) at 70%. The track behind it is the near-black Sidekick3 uses while you are fighting (`#0C0C0C`) at 70%, with a 1px edge and 4px corners. The number on the bar is the target's current HP%. The fill eases toward that number.

On a 3440x1440 display the bar starts at 480 by 28, with its top at Y 706, so it sits on the center of the screen. Width, height, and Y are saved per character. X is always the center of the display.

## Load

```
/addon load TargetBar
```

## Place it

`/tb` opens the sliders and, until you target something, a full bar so you can see the size.

- Drag the bar up or down. It stays centered.
- Width, height, and Y are the three sliders. Reset returns the defaults.
- `/tb` again closes the sliders. The bar hides when you have no target.

```
/tb width <px>
/tb height <px>
/tb y <px>
/tb reset
/tb help
```

`/targetbar` is the same command. Width is 40 to 5120 px, height is 8 to 160 px, and Y is pixels from the top of the screen.

The bar reads the main target (target index 0), the same HP percent HXUI's target bar reads. It does not follow a subtarget.
