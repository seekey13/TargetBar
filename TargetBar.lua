--[[
TargetBar - target HP% as a bar centered on the screen.
Copyright (c) 2026 seekey13. MIT License, see LICENSE.

The bar matches Sidekick3's HUD HP bar (ui/window.lua, ui/kit.lua):
rose fill #EE6F78, near-black track #0C0C0C, both at 70%, a 1px #0C0C0C
edge at 70%, and 4px corners. A partial fill rounds the left end only.
Sidekick3 tints that track gray while the pointer is over its panel.
This bar stays on the near-black combat color, so it does not flash when
the cursor crosses the middle of the screen.

The target's name is centered above the bar. Under it, a mob's damage
weakness and resistance: mobdb's icons, strongest first, one percentage
on the last icon of each equal group. That row is how Floaties draws it
(lib/mobinfo.lua M.resist, drawn under the panel).

Text is Sidekick3's HUD face (ui/kit.lua): Segoe UI Semibold, a 1px black
halo at 85%. The name is name_size and the numbers are text_size, the
sizes this HUD is set to.

HP comes from the main target, the same read as HXUI's target bar:
GetTarget():GetTargetIndex(0), then that entity's HP percent.
]]--

addon.name     = 'TargetBar';
addon.author   = 'Seekey';
addon.version  = '1.1.0';
addon.desc     = 'Target HP% bar, anchored to the horizontal center of the screen.';
addon.commands = { '/tb', '/targetbar' };

require('common');
local chat     = require('chat');
local imgui    = require('imgui');
local settings = require('settings');

local ffi_ok, ffi = pcall(require, 'ffi');
local d3d_ok, d3d = pcall(require, 'd3d8');
local textures = ffi_ok and d3d_ok;

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

-- Sidekick3 ui/kit.lua draws HUD names in Segoe UI Semibold (seguisb.ttf)
-- and stamps a 1px black halo under the fill. name_size and text_size are
-- the sizes that HUD is set to (config/addons/Sidekick3/<character>/ui.lua).
local NAME_PX = 25;
local TEXT_PX = 20;
local HALO_A  = 0.85;
local GAP     = 4;
local ICON    = 32; -- Floaties' resist row: icon side, and the gap after a group

local AROUND = {
    { -1, -1 }, { 0, -1 }, { 1, -1 },
    { -1,  0 },            { 1,  0 },
    { -1,  1 }, { 0,  1 }, { 1,  1 },
};

-- Damage types, in the order they are collected. Physical before magical,
-- matching mobdb's $physmagic; within each, the game's own element order.
local PHYSICAL = { 'Slashing', 'Piercing', 'H2H', 'Impact' };
local MAGICAL  = { 'Fire', 'Ice', 'Wind', 'Earth', 'Lightning', 'Water', 'Light', 'Dark' };
local SHORT    = { Slashing = 'Slash', Piercing = 'Pierce', Impact = 'Blunt' };

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

-- Segoe UI Semibold, once ImGui can take a font at a size (1.92). Until the
-- face is ready, text is ImGui's own font scaled to the same pixel size.
local face         = nil;
local face_custom  = false;
local face_pending = nil;
local face_tried   = false;
local dynamic_font = (tonumber(IMGUI_VERSION_NUM) or 0) >= 19200;

local mob_db   = nil;
local mob_zone = -1;
local icon_cache = {};

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

local function is_mob(flags)
    return type(flags) == 'number' and bit.band(flags, 0x10) ~= 0;
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

        local name, hpp, sid, mob;
        if type(GetEntity) == 'function' then
            local ent_ok, ent = pcall(GetEntity, index);
            if ent_ok and ent ~= nil then
                name = ent.Name;
                hpp  = ent.HPPercent;
                sid  = ent.ServerId;
                local flags_ok, flags = pcall(function () return ent.SpawnFlags; end);
                if flags_ok then mob = is_mob(flags); end
            end
        end
        local entities = mm:GetEntity();
        if type(name) ~= 'string' or name == '' or hpp == nil then
            if entities == nil then return nil; end
            name = entities:GetName(index);
            hpp  = entities:GetHPPercent(index);
            sid  = entities:GetServerId(index);
        end
        if not mob and entities ~= nil and type(entities.GetSpawnFlags) == 'function' then
            local flags_ok, flags = pcall(function () return entities:GetSpawnFlags(index); end);
            if flags_ok then mob = is_mob(flags); end
        end
        if type(name) ~= 'string' or name == '' then return nil; end
        hpp = tonumber(hpp) or 0;
        if hpp < 0 then hpp = 0; elseif hpp > 100 then hpp = 100; end
        if sid == nil or sid == 0 then sid = index; end
        return { id = sid, hpp = hpp, name = name, index = index, mob = mob == true };
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

-- Load Segoe UI Semibold the frame before it is drawn, the same handoff
-- Sidekick3's kit.frame uses: a face added this frame is not in the atlas yet.
local function font_frame()
    if face_pending ~= nil then
        face, face_custom, face_pending = face_pending, true, nil;
        return;
    end
    if face_custom or face_tried or not dynamic_font then return; end
    face_tried = true;
    local dir = ((os.getenv and os.getenv('WINDIR')) or 'C:\\Windows') .. '\\Fonts\\';
    local path = dir .. 'seguisb.ttf';
    local file = io.open(path, 'rb');
    if file == nil then return; end
    file:close();
    local ok, loaded = pcall(imgui.AddFontFromFileTTF, path, 18);
    if ok and loaded then face_pending = loaded; end
end

local function font_now()
    return face or imgui.GetFont();
end

local function measure_wh(a, b)
    if type(a) ~= 'number' then a, b = xy(a); end
    return a or 0, b or 0;
end

-- Width and height of `text` at `px`. With the Semibold face, ImGui measures
-- at that size. Otherwise CalcTextSize is the UI font, scaled by the ratio.
local function measure(text, px)
    local font = font_now();
    if face_custom and font ~= nil then
        local ok, a, b = pcall(function ()
            imgui.PushFont(font, px);
            local w, h = imgui.CalcTextSize(text);
            imgui.PopFont();
            return w, h;
        end);
        if ok then return measure_wh(a, b); end
    end
    local w, h = measure_wh(imgui.CalcTextSize(text));
    local base = imgui.GetFontSize();
    if base == nil or base <= 0 then base = 13; end
    local k = px / base;
    return w * k, h * k;
end

-- Segoe UI's box holds a tall ascent. Centred by the box, the letters sit low.
local function lift(h)
    if not face_custom then return 0; end
    return math.floor(h * 0.06 + 0.5);
end

-- Sidekick3's halo: the string in black a pixel out each way, then the fill.
local function halo(dl, x, y, px, text)
    local font = font_now();
    if font == nil or text == nil or text == '' then return; end
    x, y = math.floor(x + 0.5), math.floor(y + 0.5);
    local dark, ink = u32('#000000', HALO_A), u32('#FFFFFF', 1);
    local ok = pcall(function ()
        for _, o in ipairs(AROUND) do
            dl:AddText(font, px, { x + o[1], y + o[2] }, dark, text);
        end
        dl:AddText(font, px, { x, y }, ink, text);
    end);
    if ok then return; end
    dl:AddText({ x, y }, ink, text);
end

local function draw_name(dl, x, y, w, name)
    local tw, th = measure(name, NAME_PX);
    halo(dl, x + (w - tw) / 2, y - GAP - th, NAME_PX, name);
end

local function draw_label(dl, x, y, w, h, hpp)
    local label = ('%d%%'):format(math.floor(hpp + 0.5));
    local tw, th = measure(label, TEXT_PX);
    local ty = y + (h - th) / 2 - lift(th);
    halo(dl, x + (w - tw) / 2, ty, TEXT_PX, label);
end

-- "+25%" / "-12.5%" from a 1.25 / 0.875 multiplier. One decimal, trailing
-- ".0" dropped: the data is eighths, so 12.5 stays and 25 does not print "25.0".
local function percent(potency)
    local delta  = (potency - 1) * 100;
    local digits = string.format('%.1f', math.abs(delta)):gsub('%.0$', '');
    return (delta > 0 and '+' or '-') .. digits .. '%';
end

-- One icon per damage type the mob does not take at 1. Sorted by potency
-- descending, so a weakness reads before a resistance. Equal potencies keep
-- collection order. A run of the same potency draws its icons together and
-- puts the percentage on the last of them.
local function resist_line(res)
    if res == nil or res.Modifiers == nil then return nil; end
    local mods = {};
    for _, names in ipairs({ PHYSICAL, MAGICAL }) do
        for _, name in ipairs(names) do
            local potency = res.Modifiers[name];
            if potency ~= nil and potency ~= 1 then
                mods[#mods + 1] = {
                    icon    = name,
                    alt     = SHORT[name] or name,
                    text    = percent(potency),
                    potency = potency,
                    rank    = #mods + 1,
                };
            end
        end
    end
    if #mods == 0 then return nil; end
    table.sort(mods, function (a, b)
        if a.potency ~= b.potency then return a.potency > b.potency; end
        return a.rank < b.rank;
    end);
    for i = 1, #mods do
        if i < #mods and mods[i].potency == mods[i + 1].potency then
            mods[i].text = nil;
        else
            mods[i].group_end = true;
        end
    end
    return mods;
end

local function load_zone(zone)
    zone = tonumber(zone) or 0;
    if zone == mob_zone then return; end
    mob_zone = zone;
    mob_db = nil;
    if zone <= 0 then return; end
    local path = ('%saddons/mobdb/data/%u.lua'):format(AshitaCore:GetInstallPath(), zone);
    local chunk = loadfile(path);
    if chunk == nil then return; end
    local ok, data = pcall(chunk);
    if not ok or type(data) ~= 'table' then return; end
    mob_db = { Names = data.Names or {}, Indices = data.Indices or {} };
end

local function current_zone()
    local ok, zone = pcall(function ()
        return AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0);
    end);
    if ok then return tonumber(zone) or 0; end
    return 0;
end

-- Index first, name second, matching mobdb. The client puts a marker in
-- front of some names; the key drops everything before the first letter.
local function find_mob(index, name)
    if mob_db == nil then return nil; end
    local by_index = mob_db.Indices[index];
    if by_index ~= nil then return by_index; end
    if type(name) ~= 'string' then return nil; end
    return mob_db.Names[name:match('^[^%a]*(.*)')];
end

local function icon_handle(name)
    if not textures or name == nil then return nil; end
    local hit = icon_cache[name];
    if hit ~= nil then return hit and hit.id or nil; end
    local ok, entry = pcall(function ()
        local out = ffi.new('IDirect3DTexture8*[1]');
        local path = ('%saddons/mobdb/icons/%s.png'):format(AshitaCore:GetInstallPath(), name);
        if ffi.C.D3DXCreateTextureFromFileA(d3d.get_device(), path, out) ~= ffi.C.S_OK then
            return nil;
        end
        local tex = d3d.gc_safe_release(ffi.cast('IDirect3DTexture8*', out[0]));
        return { tex = tex, id = tonumber(ffi.cast('uint32_t', tex)) };
    end);
    -- A miss is cached, including a throw: a missing icon or a D3DX this
    -- build does not export would otherwise be retried for every icon, every frame.
    if not ok then entry = nil; end
    icon_cache[name] = entry or false;
    return entry and entry.id or nil;
end

local function segment_width(seg)
    local width = 0;
    local handle = icon_handle(seg.icon);
    if handle ~= nil then
        width = ICON;
    elseif seg.alt ~= nil then
        width = measure(seg.alt, TEXT_PX);
    end
    if seg.text ~= nil then width = width + measure(seg.text, TEXT_PX); end
    return width, handle;
end

local function draw_resists(dl, x, y, w, h, segments)
    if segments == nil then return; end
    local handles, total = {}, 0;
    for i, seg in ipairs(segments) do
        local sw, handle = segment_width(seg);
        handles[i] = handle;
        total = total + sw;
        if i < #segments and seg.group_end then total = total + ICON; end
    end
    local cursor = math.floor(x + (w - total) / 2 + 0.5);
    local row_y = math.floor(y + h + GAP + 0.5);
    for i, seg in ipairs(segments) do
        local handle = handles[i];
        if handle ~= nil then
            local drawn = pcall(function ()
                dl:AddImage(handle, { cursor, row_y }, { cursor + ICON, row_y + ICON },
                    { 0, 0 }, { 1, 1 }, 0xFFFFFFFF);
            end);
            if drawn then
                cursor = cursor + ICON;
            elseif seg.alt ~= nil then
                local aw, ah = measure(seg.alt, TEXT_PX);
                halo(dl, cursor, row_y + (ICON - ah) / 2 - lift(ah), TEXT_PX, seg.alt);
                cursor = cursor + aw;
            end
        elseif seg.alt ~= nil then
            local aw, ah = measure(seg.alt, TEXT_PX);
            halo(dl, cursor, row_y + (ICON - ah) / 2 - lift(ah), TEXT_PX, seg.alt);
            cursor = cursor + aw;
        end
        if seg.text ~= nil then
            local tw, th = measure(seg.text, TEXT_PX);
            halo(dl, cursor, row_y + (ICON - th) / 2 - lift(th), TEXT_PX, seg.text);
            cursor = cursor + tw;
        end
        if i < #segments and seg.group_end then cursor = cursor + ICON; end
    end
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
        imgui.TextUnformatted('The name sits above the bar. Weakness and resistance sit below it.');
        if not has_target then
            imgui.TextUnformatted('No target: a full bar and the name "Target" are shown so you can place it.');
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
    font_frame();
    load_zone(current_zone());

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
    if target ~= nil then
        draw_name(dl, x, y, w, target.name);
        if target.mob then
            draw_resists(dl, x, y, w, h, resist_line(find_mob(target.index, target.name)));
        end
    elseif config_open then
        draw_name(dl, x, y, w, 'Target');
    end
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
