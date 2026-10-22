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
(lib/mobinfo.lua M.resist, drawn under the panel). Beside the bar, the
same source's detection (M.threat, M.senses): aggro or passive, then
Link, on the left, and TrueSight, Sight, Sound, Scent, Magic, JA, Blood
on the right. The settings window can hide the name, the percent on the
bar, the detection icons, the weakness icons, and the resistance icons.
The bar itself stays.

Text is Sidekick3's HUD face (ui/kit.lua): Segoe UI Semibold, a 1px black
halo at 85%. The name is name_size and the numbers are text_size, the
sizes this HUD is set to.

HP comes from the main target, the same read as HXUI's target bar:
GetTarget():GetTargetIndex(0), then that entity's HP percent.

The settings window is drawn the way Sidekick Settings is (see the
comment above P).
]]--

addon.name     = 'TargetBar';
addon.author   = 'Seekey';
addon.version  = '1.3.0';
addon.desc     = 'Target HP% bar, anchored to the horizontal center of the screen.';
addon.commands = { '/tb', '/targetbar' };

require('common');
local chat     = require('chat');
local imgui    = require('imgui');
local settings = require('settings');

local ffi_ok, ffi = pcall(require, 'ffi');
local d3d_ok, d3d = pcall(require, 'd3d8');
local textures = ffi_ok and d3d_ok;

-- A 480x28 bar. Until it is placed, it sits on the vertical center of the screen.
local DEFAULT_WIDTH  = 480;
local DEFAULT_HEIGHT = 28;

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

-- What the mob notices you with, in the order it is worth reading.
-- TrueSight leads Sight because it supersedes it. Link is not a sense:
-- it sits with aggro (see threat). Same list as Floaties' SENSES.
local SENSES = { 'TrueSight', 'Sight', 'Sound', 'Scent', 'Magic', 'JA', 'Blood' };

-- 1.92 names the flag one way, 1.81 another. Nil rounds every corner.
local LEFT_CORNERS = ImDrawFlags_RoundCornersLeft or ImDrawCornerFlags_Left;

-- No y: the bar is centered until it is placed (see bar_rect).
local defaults = T{
    width  = DEFAULT_WIDTH,
    height = DEFAULT_HEIGHT,
    show_name = true,
    show_hp = true,
    show_detection = true,
    show_weakness = true,
    show_resistance = true,
};

local cfg = settings.load(defaults);

local config_open  = false;
local config_state = { true };
local dirty        = false;
local drag_origin  = nil;
local drag_state   = { true };
local drag_fault   = nil;
local shown_hpp    = nil;
local shown_id     = nil;
local shown_at     = nil;

-- Segoe UI, once ImGui can take a font at a size (1.92): semibold for the
-- HUD and the window's title, regular for its labels, semibold italic for
-- its group headings. Until a face is ready, and always on 1.81, each is
-- ImGui's own font scaled to the same pixel size. A face added this frame
-- is not in the atlas yet, so it is drawn from the next frame.
local fonts         = {};
local custom        = false;
local fonts_tried   = false;
local fonts_pending = nil;
local dynamic_font  = (tonumber(IMGUI_VERSION_NUM) or 0) >= 19200;

local mob_db   = nil;
local mob_zone = -1;
local icon_cache = {};

local function flag_set(...)
    local n = 0;
    for i = 1, select('#', ...) do
        local f = select(i, ...);
        if type(f) == 'number' then n = bit.bor(n, f); end
    end
    return n;
end

local DRAG_FLAGS = flag_set(
    ImGuiWindowFlags_NoDecoration,
    ImGuiWindowFlags_NoBackground,
    ImGuiWindowFlags_NoNavInputs,
    ImGuiWindowFlags_NoMove,
    ImGuiWindowFlags_NoFocusOnAppearing,
    ImGuiWindowFlags_NoBringToFrontOnFocus,
    ImGuiWindowFlags_NoSavedSettings
);

-- ImGui draws none of the settings window. NoNavInputs: Tab stays the game's.
-- It is not NoMove: a drag on any empty part of it moves it, as Sidekick
-- Settings does. The controls' invisible buttons take their own presses.
local PANEL_FLAGS = flag_set(
    ImGuiWindowFlags_NoTitleBar,
    ImGuiWindowFlags_NoResize,
    ImGuiWindowFlags_NoScrollbar,
    ImGuiWindowFlags_NoScrollWithMouse,
    ImGuiWindowFlags_NoCollapse,
    ImGuiWindowFlags_NoBackground,
    ImGuiWindowFlags_NoNavInputs
);

local INPUT_FLAGS = flag_set(
    ImGuiInputTextFlags_CharsDecimal,
    ImGuiInputTextFlags_EnterReturnsTrue,
    ImGuiInputTextFlags_AutoSelectAll
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

-- A missing flag stays on, so an older settings file keeps the current look.
local function on_unless_off(value)
    if value == nil then return true; end
    return value == true;
end

local function sanitize()
    cfg.width  = clamp(cfg.width, WIDTH_MIN, WIDTH_MAX, DEFAULT_WIDTH);
    cfg.height = clamp(cfg.height, HEIGHT_MIN, HEIGHT_MAX, DEFAULT_HEIGHT);
    if cfg.y ~= nil then cfg.y = clamp(cfg.y, Y_MIN, Y_MAX, nil); end
    cfg.show_name = on_unless_off(cfg.show_name);
    cfg.show_hp = on_unless_off(cfg.show_hp);
    cfg.show_detection = on_unless_off(cfg.show_detection);
    cfg.show_weakness = on_unless_off(cfg.show_weakness);
    cfg.show_resistance = on_unless_off(cfg.show_resistance);
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

-- The screen's size, 1920 by 1080 until ImGui says (Sidekick3's kit.screen).
local function screen()
    local ok, d = pcall(function () return imgui.GetIO().DisplaySize; end);
    if ok and d ~= nil then
        local w, h = xy(d);
        if w > 0 and h > 0 then return w, h; end
    end
    return 1920, 1080;
end

-- '#RRGGBB' and an alpha to an ImU32 (0xAABBGGRR).
local function u32(hex, alpha)
    local r = tonumber(hex:sub(2, 3), 16);
    local g = tonumber(hex:sub(4, 5), 16);
    local b = tonumber(hex:sub(6, 7), 16);
    local a = math.floor(math.max(0, math.min(1, alpha or 1)) * 255 + 0.5);
    return ((a * 256 + b) * 256 + g) * 256 + r;
end

-- (corners nil rounds all four: it isn't passed, as 1.81 reads 0 as none and 1.92 as all.)
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

-- A trust carries the mob flag but is a party member. Its mobdb row, if
-- one matched, would be a namesake's (a BCNM's Shantotto, say).
local function in_party(sid)
    local ok, yes = pcall(function ()
        local party = AshitaCore:GetMemoryManager():GetParty();
        for i = 0, 17 do
            if party:GetMemberIsActive(i) == 1 and party:GetMemberServerId(i) == sid then return true; end
        end
        return false;
    end);
    return ok and yes == true;
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
        mob = mob == true and not in_party(sid);
        return { id = sid, hpp = hpp, name = name, index = index, mob = mob };
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

local function font_frame()
    if fonts_pending ~= nil then
        fonts, fonts_pending, custom = fonts_pending, nil, true;
        return;
    end
    if custom then return; end
    local own = imgui.GetFont();
    fonts.text, fonts.semi, fonts.semi_italic = own, own, own;
    if fonts_tried or not dynamic_font then return; end
    fonts_tried = true;
    local dir = ((os.getenv and os.getenv('WINDIR')) or 'C:\\Windows') .. '\\Fonts\\';
    local function add(file)
        local path = dir .. file;
        local handle = io.open(path, 'rb');
        if handle == nil then return nil; end
        handle:close();
        local ok, loaded = pcall(imgui.AddFontFromFileTTF, path, 18);
        if ok and loaded then return loaded; end
        return nil;
    end
    local text = add('segoeui.ttf');
    local semi = add('seguisb.ttf') or text;
    local semi_italic = add('seguisbi.ttf') or semi;
    text = text or semi;
    if text ~= nil then
        fonts_pending = { text = text, semi = semi, semi_italic = semi_italic };
    end
end

local measured, measured_n = {}, 0;

-- Width and height of `text` in `font` at `px`. With Segoe UI in, ImGui
-- measures at that size. Otherwise CalcTextSize is the UI font, scaled by
-- the ratio. Cached: the same strings are measured every frame.
local function measure(text, px, font)
    font = font or fonts.semi;
    text = tostring(text);
    local key = tostring(font) .. '|' .. px .. '|' .. text;
    local m = measured[key];
    if m ~= nil then return m[1], m[2]; end
    local w, h;
    if custom and font ~= nil then
        local pushed = false;
        local ok, a, b = pcall(function ()
            imgui.PushFont(font, px);
            pushed = true;
            local cw, ch = imgui.CalcTextSize(text);
            imgui.PopFont();
            pushed = false;
            return cw, ch;
        end);
        if pushed then pcall(imgui.PopFont); end
        if ok then w, h = xy(a, b); end
    end
    if w == nil then
        w, h = xy(imgui.CalcTextSize(text));
        local base = tonumber(imgui.GetFontSize()) or 0;
        if base <= 0 then base = 13; end
        w, h = w * px / base, h * px / base;
    end
    if measured_n >= 4000 then measured, measured_n = {}, 0; end
    measured[key] = { w, h };
    measured_n = measured_n + 1;
    return w, h;
end

-- Segoe UI's box holds a tall ascent. Centred by the box, the letters sit low.
local function lift(h)
    if not custom then return 0; end
    return math.floor(h * 0.06 + 0.5);
end

-- Sidekick3's halo: the string in black a pixel out each way, then the fill.
local function halo(dl, x, y, px, text)
    local font = fonts.semi;
    if font == nil or text == nil or text == '' then return; end
    x, y = math.floor(x + 0.5), math.floor(y + 0.5);
    local dark, ink = u32('#000000', HALO_A), u32('#FFFFFF', 1);
    for _, o in ipairs(AROUND) do
        dl:AddText(font, px, { x + o[1], y + o[2] }, dark, text);
    end
    dl:AddText(font, px, { x, y }, ink, text);
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

-- Aggro or passive, then Link. Aggro/passive always draws: a mob that does
-- not aggro is a different fact from a mob with no detection data. Notorious
-- has no icon of its own. It is the gold frame on the aggro/passive glyph.
-- The text fallback spells the frame out, since there is nothing to see.
local function threat(res)
    if res == nil then return nil; end
    local mood = res.Aggro and 'Aggro' or 'Passive';
    local out = {
        {
            icon = mood .. (res.Notorious and 'HQ' or 'NQ'),
            alt  = (res.Notorious and 'NM ' or '') .. mood,
        },
    };
    if res.Link == true then
        out[#out + 1] = { icon = 'Link', alt = 'Link' };
    end
    return out;
end

-- One icon per sense the mob actually has. Empty is a real answer (it
-- notices nothing that way), not a missing mobdb row.
local function senses(res)
    if res == nil then return nil; end
    local out = {};
    for _, flag in ipairs(SENSES) do
        if res[flag] == true then
            out[#out + 1] = { icon = flag, alt = flag };
        end
    end
    return out;
end

-- A mob's rows are the same every frame, so each mobdb entry builds them
-- once. Weak keys: a zone's entries go with its data.
local built = setmetatable({}, { __mode = 'k' });

local function rows_of(res)
    local rows = built[res];
    if rows == nil then
        rows = { marks = resist_line(res), left = threat(res), right = senses(res) };
        built[res] = rows;
    end
    return rows;
end

-- No target, settings open. Both flanks and both sides of the row under
-- the bar, so the bar can be placed against them. A real mob replaces this
-- with its own flags.
local PREVIEW_MOB = {
    Aggro = true,
    Link = true,
    TrueSight = true,
    Sight = true,
    Sound = true,
    Modifiers = { Fire = 1.25, Ice = 0.5 },
};

-- Weakness is a potency above 1. Resistance is below 1. The two never share
-- a group, so dropping one side leaves the other's percentages in place.
local function shown_marks(segments)
    if segments == nil then return nil; end
    if cfg.show_weakness and cfg.show_resistance then return segments; end
    if not cfg.show_weakness and not cfg.show_resistance then return nil; end
    local keep = {};
    for i = 1, #segments do
        local seg = segments[i];
        local weak = (tonumber(seg.potency) or 1) > 1;
        if (weak and cfg.show_weakness) or (not weak and cfg.show_resistance) then
            keep[#keep + 1] = seg;
        end
    end
    if #keep == 0 then return nil; end
    return keep;
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
    return width;
end

-- One segment, top-left at (cursor, row_y). A missing texture draws `alt`
-- in the icon's place, the same fallback the damage row uses. Returns the
-- x the next segment starts at, before any gap the caller adds.
local function paint_segment(dl, cursor, row_y, seg)
    local handle = icon_handle(seg.icon);
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
    return cursor;
end

local function draw_resists(dl, x, y, w, h, segments)
    if segments == nil then return; end
    local total = 0;
    for i, seg in ipairs(segments) do
        total = total + segment_width(seg);
        if i < #segments and seg.group_end then total = total + ICON; end
    end
    local cursor = math.floor(x + (w - total) / 2 + 0.5);
    local row_y = math.floor(y + h + GAP + 0.5);
    for i, seg in ipairs(segments) do
        cursor = paint_segment(dl, cursor, row_y, seg);
        if i < #segments and seg.group_end then cursor = cursor + ICON; end
    end
end

-- Detection, centered on the bar's height. The left group grows left from
-- one gap off the bar, the right group grows right. Icons in a group sit
-- flush: Floaties' own gap is 0, and the PNGs carry their own padding.
-- Neither group changes the bar's width or its place on the screen.
local function draw_flanks(dl, x, y, w, h, left, right)
    local row_y = math.floor(y + (h - ICON) / 2 + 0.5);
    if left ~= nil and #left > 0 then
        local width = 0;
        for i = 1, #left do width = width + segment_width(left[i]); end
        local cursor = math.floor(x - GAP - width + 0.5);
        for i = 1, #left do cursor = paint_segment(dl, cursor, row_y, left[i]); end
    end
    if right ~= nil and #right > 0 then
        local cursor = math.floor(x + w + GAP + 0.5);
        for i = 1, #right do cursor = paint_segment(dl, cursor, row_y, right[i]); end
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
    if cfg.show_hp then pcall(draw_label, dl, x, y, w, h, hpp); end
end

-- The bar's box: centered across, at cfg.y down, or centered down too
-- until it has been placed. Held on the screen.
local function bar_rect()
    local sw, sh = screen();
    local w = math.min(cfg.width, math.floor(sw));
    local h = cfg.height;
    local x = math.floor((sw - w) / 2 + 0.5);
    local limit = math.max(0, math.floor(sh - h));
    local y = cfg.y or math.floor((sh - h) / 2 + 0.5);
    if y < 0 then y = 0; elseif y > limit then y = limit; end
    return x, y, w, h;
end

-- While the sliders are open, the bar takes the pointer so a drag sets Y
-- and the click does not also select a monster under it. An error inside
-- still reaches End, so ImGui stays balanced, and is said once.
local function drag_y(x, y, w, h)
    imgui.SetNextWindowPos({ x, y }, ImGuiCond_Always);
    imgui.SetNextWindowSize({ w, h }, ImGuiCond_Always);
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 0, 0 });
    imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0);
    imgui.PushStyleVar(ImGuiStyleVar_WindowMinSize, { 1, 1 });
    drag_state[1] = true;
    local ok, fault = true, nil;
    if imgui.Begin('TargetBar###targetbar_drag', drag_state, DRAG_FLAGS) then
        ok, fault = pcall(function ()
            imgui.SetCursorPos({ 0, 0 });
            imgui.InvisibleButton('##targetbar_drag', { w, h });
            if imgui.IsItemHovered() and ImGuiMouseCursor_ResizeNS ~= nil then
                imgui.SetMouseCursor(ImGuiMouseCursor_ResizeNS);
            end
            if imgui.IsItemActivated() then drag_origin = y; end
            if imgui.IsItemActive() and drag_origin ~= nil then
                local _, dy = xy(imgui.GetMouseDragDelta(0));
                local _, sh = screen();
                local ny = clamp(drag_origin + dy, Y_MIN, math.max(Y_MIN, math.floor(sh - h)), y);
                if ny ~= cfg.y then
                    cfg.y = ny;
                    dirty = true;
                end
            end
        end);
    end
    imgui.End();
    imgui.PopStyleVar(3);
    if not imgui.IsMouseDown(0) then drag_origin = nil; end
    if ok then
        drag_fault = nil;
    elseif fault ~= drag_fault then
        drag_fault = fault;
        say('Bar drag: ' .. tostring(fault));
    end
end

-- The settings window is Sidekick Settings' look (Sidekick3's ui/kit.lua
-- and ui/window.lua, after VanaCore's /vana window): one palette, every
-- size through S(), every control drawn on the window's list over an
-- invisible button, its states eased. The sizes are Sidekick Settings':
-- a 44px title bar with the name in semibold 16 and Sidekick3's close mark,
-- small-capital teal group headings, 30px rows with a hover band, 32 by 17
-- switches, 180px sliders, values and buttons at 14, tooltips at 14, and
-- notes at 14 in 22px lines. The card is XPBar's width.
local P = {
    bg = '#161822', border = '#2A2E3E', line = '#242838', hover = '#1F2334',
    well = '#0E1017', well_edge = '#272B3C', popup = '#0F1118',
    white = '#FFFFFF', text = '#E8EAF1', text2 = '#BDC1D0', dim = '#7B8095', faint = '#4E536A',
    accent = '#7AA2F7', accent2 = '#A9C1FF', accent_lo = '#3E5CB3', accent_bg = '#1B2340',
    teal = '#5FD3B3', rose = '#EE6F78', knob = '#F2F3F8', off = '#2B2F42',
};
local BODY, SMALL = 16, 13.5;
local PAGE_W, MARGIN, TITLE_H, ROW_H = 360, 6, 44, 30;
local LEFT, PAD, SW_W, SW_H, SLIDER_W = 24, 18, 32, 17, 180;

local scale = 1;
local panel_anim, panel_at, panel_dt = {}, nil, 0;
local panel_fault = nil;
local typed = {};

local function S(n) return math.floor(n * scale + 0.5); end

-- Once a frame the window is drawn: the time since the last (capped, so a
-- hitch takes one step), and the scale: 1440 pixels tall is 1, held between
-- 0.75 and 1.6, then the 1.1 Sidekick Settings uses.
local function tick()
    local now = os.clock();
    panel_dt = panel_at and math.max(0, math.min(0.1, now - panel_at)) or 0;
    panel_at = now;
    local _, h = screen();
    scale = math.max(0.75, math.min(1.6, h / 1440)) * 1.1;
end

local function ease(id, target, speed)
    local v = panel_anim[id];
    if v == nil then
        v = target;
    else
        v = v + (target - v) * math.min(1, panel_dt * (speed or 18));
        if math.abs(v - target) < 0.003 then v = target; end
    end
    panel_anim[id] = v;
    return v;
end

local function mix(a, b, t)
    t = math.max(0, math.min(1, t));
    local out = '#';
    for i = 2, 6, 2 do
        local c = tonumber(a:sub(i, i + 1), 16);
        local d = tonumber(b:sub(i, i + 1), 16);
        out = out .. ('%02X'):format(math.floor(c + (d - c) * t + 0.5));
    end
    return out;
end

local function rgba(hex, alpha)
    return {
        tonumber(hex:sub(2, 3), 16) / 255,
        tonumber(hex:sub(4, 5), 16) / 255,
        tonumber(hex:sub(6, 7), 16) / 255,
        alpha or 1,
    };
end

-- The input half of every control: an invisible button over its box. Hovered, clicked, held.
local function hit(id, x, y, w, h)
    imgui.SetCursorScreenPos({ x, y });
    local clicked = imgui.InvisibleButton(id, { math.max(1, w), math.max(1, h) });
    return imgui.IsItemHovered(), clicked == true, imgui.IsItemActive();
end

-- The mouse over a box of this window, with no item made for it.
local function over(x, y, w, h)
    if not imgui.IsWindowHovered() then return false; end
    local ok, yes = pcall(imgui.IsMouseHoveringRect, { x, y }, { x + w, y + h });
    return ok and yes == true;
end

local function text_at(dl, x, y, s, color, font, px, alpha)
    dl:AddText(font, px, { math.floor(x + 0.5), math.floor(y + 0.5) }, u32(color, alpha), s);
end

-- Text with its middle at cy: from x, ending at `right`, or centred on cx.
local function text_mid(dl, x, cy, s, color, font, px, alpha)
    local _, h = measure(s, px, font);
    text_at(dl, x, cy - h / 2 - lift(h), s, color, font, px, alpha);
end

local function text_right(dl, right, cy, s, color, font, px, alpha)
    local w, h = measure(s, px, font);
    text_at(dl, right - w, cy - h / 2 - lift(h), s, color, font, px, alpha);
end

local function text_centred(dl, cx, cy, s, color, font, px, alpha)
    local w, h = measure(s, px, font);
    text_at(dl, cx - w / 2, cy - h / 2 - lift(h), s, color, font, px, alpha);
end

-- Capitals one glyph at a time, `spacing` pixels apart (ImGui has no
-- tracking): Sidekick3's group headings. Returns the width.
local function text_spaced(dl, x, cy, s, color, font, px, spacing)
    local start = x;
    for letter in s:gmatch('.') do
        text_mid(dl, x, cy, letter, color, font, px);
        x = x + measure(letter, px, font) + spacing;
    end
    if x == start then return 0; end
    return x - start - spacing;
end

-- A tooltip by the mouse, in the palette (SetTooltip takes a printf format: its '%' are doubled).
local function tooltip(s)
    if s == nil or s == '' then return; end
    imgui.PushStyleColor(ImGuiCol_PopupBg, rgba(P.popup, 0.97));
    imgui.PushStyleColor(ImGuiCol_Border, rgba(P.border));
    imgui.PushStyleColor(ImGuiCol_Text, rgba(P.text));
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { S(9), S(6) });
    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, S(4));
    imgui.PushStyleVar(ImGuiStyleVar_PopupRounding, S(4));
    imgui.PushStyleVar(ImGuiStyleVar_PopupBorderSize, 1);
    if custom then imgui.PushFont(fonts.text, S(SMALL + 0.5)); end
    pcall(imgui.SetTooltip, (tostring(s):gsub('%%', '%%%%')));
    if custom then imgui.PopFont(); end
    imgui.PopStyleVar(4);
    imgui.PopStyleColor(3);
end

local POPUP_COLOURS = {
    { ImGuiCol_PopupBg, rgba(P.popup) }, { ImGuiCol_Border, rgba(P.border) }, { ImGuiCol_Text, rgba(P.text) },
    { ImGuiCol_Header, rgba(P.accent_bg) }, { ImGuiCol_HeaderHovered, rgba(P.hover) },
    { ImGuiCol_HeaderActive, rgba(P.accent_lo) }, { ImGuiCol_Separator, rgba(P.line) },
    { ImGuiCol_FrameBg, rgba(P.well) }, { ImGuiCol_FrameBgHovered, rgba(P.well) }, { ImGuiCol_FrameBgActive, rgba(P.well) },
};

-- ImGui's own popups (a typed number) in the palette, with the padding and
-- spacing the window here takes away.
local function push_popup_style()
    for _, c in ipairs(POPUP_COLOURS) do imgui.PushStyleColor(c[1], c[2]); end
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { S(10), S(8) });
    imgui.PushStyleVar(ImGuiStyleVar_PopupRounding, S(5));
    imgui.PushStyleVar(ImGuiStyleVar_PopupBorderSize, 1);
    imgui.PushStyleVar(ImGuiStyleVar_FramePadding, { S(8), S(4) });
    imgui.PushStyleVar(ImGuiStyleVar_FrameRounding, S(4));
    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, { S(8), S(6) });
end

local function pop_popup_style()
    imgui.PopStyleVar(6);
    imgui.PopStyleColor(#POPUP_COLOURS);
end

-- The number typed into a slider's value, once Enter is pressed.
-- The styles and the popup are closed even when its widgets throw.
local function number_box(id, min, max)
    local buf, got = typed[id], nil;
    local opened, font_on, width_on = false, false, false;
    push_popup_style();
    pcall(function ()
        opened = imgui.BeginPopup(id .. '.number') == true;
        if not opened then
            typed[id] = nil;
            return;
        end
        if custom then
            imgui.PushFont(fonts.text, S(SMALL + 1));
            font_on = true;
        end
        if buf.focus then imgui.SetKeyboardFocusHere(); buf.focus = false; end
        imgui.PushItemWidth(S(90));
        width_on = true;
        if imgui.InputText('##' .. id .. '.typed', buf, 16, INPUT_FLAGS) then
            got = tonumber(buf[1]);
            imgui.CloseCurrentPopup();
        end
        imgui.PopItemWidth();
        width_on = false;
        imgui.TextDisabled(('%d to %d'):format(min, max));
    end);
    if width_on then imgui.PopItemWidth(); end
    if font_on then imgui.PopFont(); end
    if opened then imgui.EndPopup(); end
    pop_popup_style();
    return got;
end

-- A whole-number slider, `w` wide: the track, then the value (`unit` after
-- it). A click on the value opens a box to type one.
local function slider(id, x, cy, w, value, min, max, unit)
    local dl = imgui.GetWindowDrawList();
    local value_w = S(52);
    local track = w - value_w - S(10);
    -- The press area runs past the track's ends, so the knob drawn half past either end is still the slider's.
    local hovered, _, active = hit(id, x - S(4), cy - S(9), track + S(12), S(18));
    local changed = false;
    if active and track > 0 then
        local mx = xy(imgui.GetMousePos());
        local v = clamp(min + (max - min) * math.max(0, math.min(1, (mx - x) / track)), min, max, value);
        if v ~= value then value, changed = v, true; end
    end
    local f = (max > min) and math.max(0, math.min(1, (value - min) / (max - min))) or 0;
    local th = S(4);
    fill(dl, x, cy - th / 2, track, th, P.off, th / 2);
    if f > 0 then fill(dl, x, cy - th / 2, math.max(th, track * f), th, P.accent, th / 2); end
    local lit = ease(id .. '.lit', (hovered or active) and 1 or 0, 22);
    local knob = active and P.accent2 or mix(P.knob, P.accent2, lit * 0.5);
    dl:AddCircleFilled({ x + track * f, cy }, S(5.5) + S(1) * lit, u32(knob), 24);
    local vx = x + track + S(10);
    local vhov, vclick = hit(id .. '.value', vx, cy - S(10), value_w, S(20));
    if vhov then fill(dl, vx, cy - S(10), value_w, S(20), P.hover, S(3)); end
    text_right(dl, vx + value_w - S(4), cy, tostring(value) .. (unit or ''), P.text2, fonts.text, S(SMALL + 0.5));
    if vclick then
        typed[id] = { tostring(value), focus = true };
        imgui.OpenPopup(id .. '.number');
    end
    if typed[id] ~= nil then
        local entered = number_box(id, min, max);
        if entered ~= nil then
            local v = clamp(entered, min, max, value);
            if v ~= value then value, changed = v, true; end
        end
    end
    return value, changed;
end

-- A switch, 32 by 17: the track eases off to accent, the knob slides.
local function switch(id, x, cy, on)
    local w, h = S(SW_W), S(SW_H);
    local y = cy - h / 2;
    local hovered, clicked = hit(id, x, y, w, h);
    if clicked then on = not on; end
    local t = ease(id, on and 1 or 0);
    local dl = imgui.GetWindowDrawList();
    fill(dl, x, y, w, h, mix(P.off, P.accent, t), h / 2);
    if hovered then fill(dl, x, y, w, h, '#FFFFFF', h / 2, 0.08); end
    local r = (h - S(4)) / 2;
    dl:AddCircleFilled({ x + S(2) + r + (w - S(4) - r * 2) * t, cy }, r, u32(P.knob), 24);
    return on == true, clicked;
end

-- A ghost button: the text + 22 wide, 24 tall. Returns clicked.
local function button(id, x, cy, label)
    local px = S(SMALL + 0.5);
    local w, h = measure(label, px, fonts.text) + S(22), S(24);
    local y = cy - h / 2;
    local hovered, clicked, active = hit(id, x, y, w, h);
    local dl = imgui.GetWindowDrawList();
    local t = ease(id, hovered and 1 or 0, 22);
    fill(dl, x, y, w, h, mix(P.well, P.hover, t), S(4));
    dl:AddRect({ x, y }, { x + w, y + h }, u32(mix(P.well_edge, P.accent_lo, t)), S(4));
    if active then fill(dl, x, y, w, h, '#000000', S(4), 0.15); end
    text_centred(dl, x + w / 2, cy, label, mix(P.text2, P.text, t), fonts.text, px);
    return clicked;
end

-- Sidekick3's close mark: an X, `box` square, the cross 0.72 of it, dim
-- until the pointer is on it, then rose. Returns clicked, hovered.
local function close_mark(id, cx, cy, box)
    local hovered, clicked = hit(id, cx - box / 2, cy - box / 2, box, box);
    local k = box * 0.72 / 24;
    local col = u32(hovered and P.rose or P.dim);
    local thickness = math.max(1, 2 * k);
    local function p(px, py) return { cx + (px - 12) * k, cy + (py - 12) * k }; end
    local dl = imgui.GetWindowDrawList();
    dl:AddLine(p(6, 6), p(18, 18), col, thickness);
    dl:AddLine(p(18, 6), p(6, 18), col, thickness);
    return clicked, hovered;
end

--[[ pg: where the rows go, top to bottom: { dl, x, w, y (the next row's top),
     lx (where labels start), right (where controls end) }. ]]--

-- A group's heading: Sidekick3's small capitals in teal, a line after.
local function subheader(pg, s)
    pg.y = pg.y + S(8);
    local cy = pg.y + S(12);
    local tw = text_spaced(pg.dl, pg.lx, cy, s:upper(), P.teal, fonts.semi_italic, S(SMALL), math.max(1, S(1.2)));
    local tx = pg.lx + tw + S(10);
    if pg.right > tx then pg.dl:AddLine({ tx, cy }, { pg.right, cy }, u32(P.teal, 0.35), 1); end
    pg.y = pg.y + S(26);
end

-- A line `h` tall (a row unless given): the band under the mouse, `label`
-- at the left, `help` over the label's half. Returns its middle.
local function line(pg, label, help, h)
    h = h or S(ROW_H);
    local y = pg.y;
    pg.y = y + h;
    if over(pg.x + S(4), y, pg.w - S(8), h) then
        fill(pg.dl, pg.x + S(4), y, pg.w - S(8), h, P.hover, S(3), 0.8);
    end
    local cy = y + math.min(h, S(ROW_H)) / 2;
    if label then text_mid(pg.dl, pg.lx, cy, label, P.text, fonts.text, S(BODY)); end
    if help and over(pg.x, y, pg.w / 2, h) then tooltip(help); end
    return cy;
end

-- A line of text in a 22px line.
local function note(pg, s, color)
    text_mid(pg.dl, pg.lx, pg.y + S(11), s, color or P.dim, fonts.text, S(SMALL + 0.5));
    pg.y = pg.y + S(22);
end

local TOGGLES = {
    { 'Name', '##tb_name', 'show_name', 'The name above the bar.' },
    { 'HP %', '##tb_hp', 'show_hp', 'The percent on the bar.' },
    { 'Detection', '##tb_detect', 'show_detection', 'Aggro and Link on the left of the bar. Senses on the right.' },
    { 'Weakness', '##tb_weak', 'show_weakness', 'Damage the mob takes more from.' },
    { 'Resistance', '##tb_resist', 'show_resistance', 'Damage the mob takes less from.' },
};

-- The page from the top: the title bar and its line, 10 more, each group's
-- heading (8 above, 26 for it) and rows, the button's row (a row and 4),
-- the note (22), and 14 under it. draw_config lays it out in this order.
local function page_height()
    return S(TITLE_H) + 1 + S(10)
        + 2 * (S(8) + S(26)) + (#TOGGLES + 3) * S(ROW_H)
        + S(ROW_H) + S(4) + S(22) + S(14);
end

local function draw_config(has_target)
    tick();
    local sw, sh = screen();
    local _, bar_y, _, bar_h = bar_rect();
    local wmax = math.max(WIDTH_MIN, math.min(WIDTH_MAX, math.floor(sw)));
    local ymax = math.max(Y_MIN, math.floor(sh - bar_h));
    local sliders = {
        { 'Width', '##tb_w', 'width', math.min(cfg.width, wmax), WIDTH_MIN, wmax, 'Pixels, up to the screen\'s width.' },
        { 'Height', '##tb_h', 'height', cfg.height, HEIGHT_MIN, HEIGHT_MAX, 'Pixels.' },
        { 'Y', '##tb_y', 'y', bar_y, Y_MIN, ymax, 'Pixels from the top of the screen to the bar.' },
    };
    local pw, ph, m = S(PAGE_W), page_height(), S(MARGIN);
    imgui.SetNextWindowPos({ sw / 2, sh / 2 }, ImGuiCond_FirstUseEver, { 0.5, 0.5 });
    imgui.SetNextWindowSize({ pw + m * 2, ph + m * 2 }, ImGuiCond_Always);
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 0, 0 });
    imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0);
    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, { 0, 0 });
    config_state[1] = true;
    local drew, fault = true, nil;
    if imgui.Begin('TargetBar###tb_settings', config_state, PANEL_FLAGS) then
        drew, fault = pcall(function ()
            local wx, wy = xy(imgui.GetCursorScreenPos());
            local x, y = wx + m, wy + m;
            local dl = imgui.GetWindowDrawList();
            fill(dl, x - 1, y, pw + 2, ph + 2, '#000000', S(6), 0.35);
            fill(dl, x, y, pw, ph, P.bg, S(5));
            dl:AddRect({ x, y }, { x + pw, y + ph }, u32(P.border), S(5));

            local title_cy = y + S(TITLE_H) / 2;
            text_mid(dl, x + S(LEFT), title_cy, 'TargetBar', P.white, fonts.semi, S(BODY));
            local box = S(21);
            local closed, close_hov = close_mark('##tb_close', x + pw - S(PAD) - box / 2, title_cy, box);
            if close_hov then tooltip('Close'); end
            if closed then config_open = false; end
            dl:AddLine({ x, y + S(TITLE_H) }, { x + pw, y + S(TITLE_H) }, u32(P.border), 1);

            local pg = {
                dl = dl, x = x, w = pw, y = y + S(TITLE_H) + 1 + S(10),
                lx = x + S(LEFT), right = x + pw - S(PAD),
            };
            subheader(pg, 'Show');
            for _, item in ipairs(TOGGLES) do
                local cy = line(pg, item[1], item[4]);
                local on, flipped = switch(item[2], pg.right - S(SW_W), cy, cfg[item[3]] == true);
                if imgui.IsItemHovered() then tooltip(item[4]); end
                if flipped then cfg[item[3]] = on; dirty = true; end
            end
            subheader(pg, 'Bar');
            for _, row in ipairs(sliders) do
                local cy = line(pg, row[1], row[7]);
                local v, moved = slider(row[2], pg.right - S(SLIDER_W), cy, S(SLIDER_W), row[4], row[5], row[6], 'px');
                if moved and v ~= cfg[row[3]] then cfg[row[3]] = v; dirty = true; end
            end

            local by = line(pg, nil, nil, S(ROW_H) + S(4));
            if button('##tb_reset', pg.lx, by, 'Reset position') then
                if cfg.y ~= nil then
                    cfg.y = nil;
                    dirty = true;
                end
            end
            if imgui.IsItemHovered() then tooltip('Back to the middle of the screen.'); end
            note(pg, has_target and 'Drag the bar up or down. It stays centered.'
                or 'No target: a preview shows where it goes.', P.faint);
        end);
    end
    imgui.End();
    imgui.PopStyleVar(3);
    if drew then
        panel_fault = nil;
    elseif fault ~= panel_fault then
        panel_fault = fault;
        say('Settings window: ' .. tostring(fault));
    end
    if config_state[1] == false then config_open = false; end
end

local function save_if_idle()
    if not dirty or imgui.IsMouseDown(0) or imgui.IsAnyItemActive() then return; end
    local ok = pcall(function () settings.save(); end);
    if ok then dirty = false; end
end

local function report()
    sanitize();
    local _, y = bar_rect();
    say(('Width %d, height %d, Y %d%s.'):format(cfg.width, cfg.height, y, cfg.y == nil and ' (centered)' or ''));
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
    local hpp, id;
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
    if cfg.show_name then
        draw_name(dl, x, y, w, target ~= nil and target.name or 'Target');
    end
    local res = nil;
    if target == nil then
        res = PREVIEW_MOB;
    elseif target.mob then
        res = find_mob(target.index, target.name);
    end
    if res ~= nil then
        local rows = rows_of(res);
        draw_resists(dl, x, y, w, h, shown_marks(rows.marks));
        if cfg.show_detection then draw_flanks(dl, x, y, w, h, rows.left, rows.right); end
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
        say('/tb opens settings. Toggles hide the name, the HP%, detection, weakness, and resistance. /tb width <px>, /tb height <px>, /tb y <px>. /tb reset returns width and height, and centers the bar.');
    elseif sub == 'width' then
        set_number('width', args[3], WIDTH_MIN, WIDTH_MAX);
    elseif sub == 'height' then
        set_number('height', args[3], HEIGHT_MIN, HEIGHT_MAX);
    elseif sub == 'y' then
        set_number('y', args[3], Y_MIN, Y_MAX);
    elseif sub == 'reset' then
        cfg.width, cfg.height, cfg.y = DEFAULT_WIDTH, DEFAULT_HEIGHT, nil;
        settings.save();
        dirty = false;
        say('Reset.');
        report();
    else
        say('Unknown command. /tb help');
    end
end);

ashita.events.register('unload', 'targetbar_unload', function ()
    if dirty then pcall(function () settings.save(); end); end
end);
