--[[
TargetBar - target HP% as a bar centered on the screen.
Copyright (c) 2026 seekey13. MIT License, see LICENSE.

The bar matches Sidekick3's HUD HP bar (ui/window.lua, ui/kit.lua):
rose fill #EE6F78, near-black track #0C0C0C, both at 70%, a 1px #0C0C0C
edge at 70%, and 4px corners. A partial fill rounds the left end only.
Sidekick3 tints that track gray while the pointer is over its panel.
This bar stays on the near-black combat color, so it does not flash when
the cursor crosses the middle of the screen.

HP comes from the main target, the same read as HXUI's target bar:
GetTarget():GetTargetIndex(0), then that entity's HP percent.
]]--

addon.name     = 'TargetBar';
addon.author   = 'Seekey';
addon.version  = '1.0.0';
addon.desc     = 'Target HP% bar, anchored to the horizontal center of the screen.';
addon.commands = { '/tb', '/targetbar' };

require('common');
local chat     = require('chat');
local imgui    = require('imgui');
local settings = require('settings');

-- Defaults put a 480x28 bar on the center of a 3440x1440 screen.
local DEFAULT_WIDTH  = 480;
local DEFAULT_HEIGHT = 28;
local DEFAULT_Y      = 706;

local WIDTH_MIN, WIDTH_MAX   = 40, 5120;
local HEIGHT_MIN, HEIGHT_MAX = 8, 160;
local Y_MIN, Y_MAX           = 0, 2160;

local FILL   = '#EE6F78';
local TRACK  = '#0C0C0C';
local EDGE   = '#0C0C0C';
local BAR_A  = 0.70;
local RADIUS = 4;
local EASE   = 12; -- share of the remaining fill covered per second

-- 1.92 names the flag one way, 1.81 another. Nil rounds every corner.
local LEFT_CORNERS = ImDrawFlags_RoundCornersLeft or ImDrawCornerFlags_Left;

local defaults = T{
    width  = DEFAULT_WIDTH,
    height = DEFAULT_HEIGHT,
    y      = DEFAULT_Y,
};

local cfg = settings.load(defaults);

local config_open  = false;
local config_state = { true };
local dirty        = false;
local drag_origin  = nil;
local drag_state   = { true };
local shown_hpp   = nil;
local shown_id    = nil;
local shown_at    = nil;
local sized_text  = true;

local DRAG_FLAGS = bit.bor(
    ImGuiWindowFlags_NoDecoration,
    ImGuiWindowFlags_NoBackground,
    ImGuiWindowFlags_NoNavInputs,
    ImGuiWindowFlags_NoMove,
    ImGuiWindowFlags_NoFocusOnAppearing,
    ImGuiWindowFlags_NoBringToFrontOnFocus,
    ImGuiWindowFlags_NoSavedSettings
);

local CONFIG_FLAGS = bit.bor(
    ImGuiWindowFlags_AlwaysAutoResize,
    ImGuiWindowFlags_NoNavInputs
);

local function say(text)
    print(chat.header(addon.name) .. chat.message(text));
end

local function clamp(v, lo, hi, fallback)
    v = tonumber(v);
    if v == nil or v ~= v then return fallback; end
    v = math.floor(v + 0.5);
    if v < lo then return lo; end
    if v > hi then return hi; end
    return v;
end

local function sanitize()
    cfg.width  = clamp(cfg.width, WIDTH_MIN, WIDTH_MAX, DEFAULT_WIDTH);
    cfg.height = clamp(cfg.height, HEIGHT_MIN, HEIGHT_MAX, DEFAULT_HEIGHT);
    cfg.y      = clamp(cfg.y, Y_MIN, Y_MAX, DEFAULT_Y);
end

sanitize();

settings.register('settings', 'targetbar_settings', function (s)
    if s ~= nil then cfg = s; end
    sanitize();
    settings.save();
end);

-- One ImVec2, or a pair of numbers, as x, y.
local function xy(a, b)
    if type(a) == 'number' then return a, tonumber(b) or 0; end
    if a == nil then return 0, 0; end
    local x = a.x or a[1];
    local y = a.y or a[2];
    return tonumber(x) or 0, tonumber(y) or 0;
end

local function screen()
    local ok, d = pcall(function () return imgui.GetIO().DisplaySize; end);
    if ok and d ~= nil then
        local w, h = xy(d);
        if w > 0 and h > 0 then return w, h; end
    end
    return 3440, 1440;
end

-- '#RRGGBB' and an alpha to an ImU32 (0xAABBGGRR).
local function u32(hex, alpha)
    local r = tonumber(hex:sub(2, 3), 16);
    local g = tonumber(hex:sub(4, 5), 16);
    local b = tonumber(hex:sub(6, 7), 16);
    local a = math.floor(math.max(0, math.min(1, alpha or 1)) * 255 + 0.5);
    return ((a * 256 + b) * 256 + g) * 256 + r;
end

local function fill(dl, x, y, w, h, color, radius, alpha, corners)
    if w <= 0 or h <= 0 then return; end
    local p, q, col = { x, y }, { x + w, y + h }, u32(color, alpha);
    if corners then
        dl:AddRectFilled(p, q, col, radius or 0, corners);
    else
        dl:AddRectFilled(p, q, col, radius or 0);
    end
end

-- The main target. Index 0 is "no target". HXUI reads this same index and HPPercent.
local function read_target()
    local ok, found = pcall(function ()
        local mm = AshitaCore:GetMemoryManager();
        if mm == nil then return nil; end
        local target = mm:GetTarget();
        if target == nil then return nil; end
        local index = target:GetTargetIndex(0);
        if type(index) ~= 'number' or index <= 0 or index > 2303 then return nil; end
        index = math.floor(index);

        local name, hpp, sid;
        if type(GetEntity) == 'function' then
            local ent_ok, ent = pcall(GetEntity, index);
            if ent_ok and ent ~= nil then
                name = ent.Name;
                hpp  = ent.HPPercent;
                sid  = ent.ServerId;
            end
        end
        if type(name) ~= 'string' or name == '' or hpp == nil then
            local entities = mm:GetEntity();
            if entities == nil then return nil; end
            name = entities:GetName(index);
            hpp  = entities:GetHPPercent(index);
            sid  = entities:GetServerId(index);
        end
        if type(name) ~= 'string' or name == '' then return nil; end
        hpp = tonumber(hpp) or 0;
        if hpp < 0 then hpp = 0; elseif hpp > 100 then hpp = 100; end
        if sid == nil or sid == 0 then sid = index; end
        return { id = sid, hpp = hpp };
    end);
    if ok then return found; end
    return nil;
end

-- Ease the fill toward `hpp`. A new id snaps, so a new target does not drain from the last one.
local function smooth(id, hpp)
    local now = os.clock();
    local dt = 0;
    if shown_at ~= nil then
        dt = now - shown_at;
        if dt < 0 then dt = 0; elseif dt > 0.1 then dt = 0.1; end
    end
    shown_at = now;
    if shown_hpp == nil or shown_id ~= id then
        shown_hpp, shown_id = hpp, id;
        return hpp;
    end
    shown_hpp = shown_hpp + (hpp - shown_hpp) * math.min(1, dt * EASE);
    if math.abs(shown_hpp - hpp) < 0.05 then shown_hpp = hpp; end
    return shown_hpp;
end

local function draw_label(dl, x, y, w, h, hpp)
    if h < 14 then return; end
    local font = imgui.GetFont();
    if font == nil then return; end
    local label = ('%d%%'):format(math.floor(hpp + 0.5));
    local base = imgui.GetFontSize();
    if base == nil or base <= 0 then base = 13; end
    local px = math.floor(h * 0.62 + 0.5);
    if px > h - 2 then px = math.floor(h - 2); end
    if px < 8 then return; end

    local tw, th = imgui.CalcTextSize(label);
    if type(tw) ~= 'number' then tw, th = xy(tw); end
    tw, th = (tw or 0) * (px / base), (th or 0) * (px / base);
    if tw <= 0 or tw > w - 8 then return; end

    local tx = math.floor(x + (w - tw) / 2 + 0.5);
    local ty = math.floor(y + (h - th) / 2 - th * 0.06 + 0.5);
    local shadow, ink = u32('#000000', 0.90), u32('#FFFFFF', 1);
    local function text_at(ox, oy, col)
        if sized_text then
            local ok = pcall(function ()
                dl:AddText(font, px, { tx + ox, ty + oy }, col, label);
            end);
            if ok then return; end
            sized_text = false;
        end
        dl:AddText({ tx + ox, ty + oy }, col, label);
    end
    text_at(-1, 0, shadow);
    text_at(1, 0, shadow);
    text_at(0, -1, shadow);
    text_at(0, 1, shadow);
    text_at(0, 0, ink);
end

-- `hpp` is the number drawn. `fill_hpp` is the eased width.
local function draw_bar(dl, x, y, w, h, hpp, fill_hpp)
    x, y = math.floor(x + 0.5), math.floor(y + 0.5);
    w, h = math.floor(w + 0.5), math.floor(h + 0.5);
    local r = math.min(RADIUS, math.floor(h / 2), math.floor(w / 2));
    fill(dl, x, y, w, h, TRACK, r, BAR_A);
    local f = math.max(0, math.min(1, fill_hpp / 100));
    local fw = math.floor(w * f + 0.5);
    if fw > 0 then
        local partial = fw < w;
        fill(dl, x, y, fw, h, FILL, math.min(r, fw / 2), BAR_A, partial and LEFT_CORNERS or nil);
    end
    dl:AddRect({ x, y }, { x + w, y + h }, u32(EDGE, BAR_A), r);
    pcall(draw_label, dl, x, y, w, h, hpp);
end

local function bar_rect()
    sanitize();
    local sw, sh = screen();
    local w = math.min(cfg.width, math.floor(sw));
    local h = cfg.height;
    local x = math.floor((sw - w) / 2 + 0.5);
    local y = cfg.y;
    local limit = math.max(0, math.floor(sh - h));
    if y < 0 then y = 0; elseif y > limit then y = limit; end
    return x, y, w, h;
end

-- While the sliders are open, the bar takes the pointer so a drag sets Y
-- and the click does not also select a monster under it.
local function drag_y(x, y, w, h)
    imgui.SetNextWindowPos({ x, y }, ImGuiCond_Always);
    imgui.SetNextWindowSize({ w, h }, ImGuiCond_Always);
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 0, 0 });
    imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0);
    imgui.PushStyleVar(ImGuiStyleVar_WindowMinSize, { 1, 1 });
    drag_state[1] = true;
    if imgui.Begin('TargetBar###targetbar_drag', drag_state, DRAG_FLAGS) then
        imgui.SetCursorPos({ 0, 0 });
        imgui.InvisibleButton('##targetbar_drag', { w, h });
        if imgui.IsItemHovered() and ImGuiMouseCursor_ResizeNS ~= nil then
            imgui.SetMouseCursor(ImGuiMouseCursor_ResizeNS);
        end
        if imgui.IsItemActivated() then drag_origin = cfg.y; end
        if imgui.IsItemActive() and drag_origin ~= nil then
            local _, dy = xy(imgui.GetMouseDragDelta(0));
            local ny = clamp(drag_origin + dy, Y_MIN, Y_MAX, cfg.y);
            if ny ~= cfg.y then
                cfg.y = ny;
                dirty = true;
            end
        end
    end
    imgui.End();
    imgui.PopStyleVar(3);
    if not imgui.IsMouseDown(0) then drag_origin = nil; end
end

local function draw_config(has_target)
    imgui.SetNextWindowPos({ 80, 80 }, ImGuiCond_FirstUseEver);
    config_state[1] = true;
    if imgui.Begin('TargetBar settings', config_state, CONFIG_FLAGS) then
        imgui.PushItemWidth(200);
        local width = { cfg.width };
        if imgui.SliderInt('Width', width, WIDTH_MIN, WIDTH_MAX, '%d px') then
            cfg.width = width[1];
            dirty = true;
        end
        local height = { cfg.height };
        if imgui.SliderInt('Height', height, HEIGHT_MIN, HEIGHT_MAX, '%d px') then
            cfg.height = height[1];
            dirty = true;
        end
        local _, sh = screen();
        local ymax = math.max(0, math.floor(sh - cfg.height));
        local yv = { math.min(cfg.y, ymax) };
        if imgui.SliderInt('Y', yv, 0, ymax, '%d px') then
            cfg.y = yv[1];
            dirty = true;
        end
        imgui.PopItemWidth();
        if imgui.Button('Reset') then
            cfg.width, cfg.height, cfg.y = DEFAULT_WIDTH, DEFAULT_HEIGHT, DEFAULT_Y;
            dirty = true;
        end
        imgui.TextUnformatted('The bar stays on the horizontal center. Drag it, or set Y, to move it.');
        if not has_target then
            imgui.TextUnformatted('No target: a full bar is shown so you can place it.');
        end
    end
    imgui.End();
    if config_state[1] == false then config_open = false; end
end

local function save_if_idle()
    if not dirty or imgui.IsMouseDown(0) or imgui.IsAnyItemActive() then return; end
    local ok = pcall(function () settings.save(); end);
    if ok then dirty = false; end
end

local function report()
    sanitize();
    say(('Width %d, height %d, Y %d.'):format(cfg.width, cfg.height, cfg.y));
end

local function set_number(key, raw, lo, hi)
    local n = tonumber(raw);
    if n == nil then
        say(('Use a number from %d to %d.'):format(lo, hi));
        return;
    end
    cfg[key] = clamp(n, lo, hi, cfg[key]);
    sanitize();
    settings.save();
    dirty = false;
    report();
end

ashita.events.register('d3d_present', 'targetbar_present', function ()
    local target = read_target();
    local hpp, id = nil, nil;
    if target ~= nil then
        hpp, id = target.hpp, target.id;
    elseif config_open then
        hpp, id = 100, 'preview';
    else
        shown_hpp, shown_id = nil, nil;
        save_if_idle();
        return;
    end

    local x, y, w, h = bar_rect();
    local dl = imgui.GetBackgroundDrawList();
    draw_bar(dl, x, y, w, h, hpp, smooth(id, hpp));
    if config_open then
        drag_y(x, y, w, h);
        draw_config(target ~= nil);
    end
    save_if_idle();
end);

ashita.events.register('command', 'targetbar_command', function (e)
    local first = e.command:match('^(%S+)');
    if first == nil then return; end
    first = first:lower();
    if first ~= '/tb' and first ~= '/targetbar' then return; end
    e.blocked = true;

    local args = {};
    for word in e.command:gmatch('%S+') do args[#args + 1] = word; end
    local sub = args[2] and args[2]:lower() or '';

    if sub == '' or sub == 'config' then
        config_open = not config_open;
        say(config_open and 'Settings open. /tb closes them.' or 'Settings closed.');
        report();
    elseif sub == 'help' then
        say('/tb opens the sliders. /tb width <px>, /tb height <px>, /tb y <px>, /tb reset.');
    elseif sub == 'width' then
        set_number('width', args[3], WIDTH_MIN, WIDTH_MAX);
    elseif sub == 'height' then
        set_number('height', args[3], HEIGHT_MIN, HEIGHT_MAX);
    elseif sub == 'y' then
        set_number('y', args[3], Y_MIN, Y_MAX);
    elseif sub == 'reset' then
        cfg.width, cfg.height, cfg.y = DEFAULT_WIDTH, DEFAULT_HEIGHT, DEFAULT_Y;
        settings.save();
        dirty = false;
        say('Reset.');
        report();
    else
        say('Unknown command. /tb help');
    end
end);

ashita.events.register('unload', 'targetbar_unload', function ()
    pcall(function () settings.save(); end);
end);
