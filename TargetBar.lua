--[[
TargetBar - target HP% as a bar centered on the screen.
Copyright (c) 2026 seekey13. GPL-3.0-or-later, see LICENSE.

UI style: VanaCore by Vekien (Copyright (C) 2026 Vekien, GPL-3.0-or-later).
TargetBar is not VanaCore, and isn't made or endorsed by Vekien.

The bar is a rose fill #EE6F78 on a near-black #0C0C0C track, both at
70%, with a 1px #0C0C0C edge and 4px corners. A partial fill rounds the
left end only. It draws for mobs, players, pets and trusts. An NPC or an
object gets its name in #C2FFC2 on black at 40%, only as wide as the name,
and no percent.

The target's name is inside the bar on the left, white over 75% HP, then
yellow, orange at 50% and red at 25%. The percent is on the right. Both
sit the edge offset in from the bar's ends. Under the bar, a mob's damage
weakness and resistance: mobdb's icons, strongest first, one percentage
on the last icon of each equal group. Beside the bar, its detection:
aggro or passive, then Link, on the left, and TrueSight, Sight, Sound,
Scent, Magic, JA, Blood on the right. Both rows are built as Floaties'
lib/mobinfo.lua builds them (M.resist, M.threat, M.senses). The settings
window can hide the name, the percent on the bar, the detection icons,
the weakness icons, the resistance icons, and the bar for the target's
target. The bar itself stays.

Locked on (the game's Notice), a transparent red stroke sits around the
bar, softer a few pixels out. "Locked" is LOCK_TEXT, centred just above
the bar, and its outline is that same fringe: a fainter red copy of the
word at each step, then the letters on top. The fringe stops at the gap
the detection icons start in, so it does not cover them.

To the right of the bar, an equilateral triangle points at a second bar:
who that target is targeting. The triangle's left edge is vertical and as
tall as the HP bar, and it is Sidekick3's MP bar (#E8B45C) at 70%. The
second bar's name is on the left and the HP% is on the right, in the same
colours, at the same edge offset. Its width is a setting. It never draws
narrower than that name and the percent on one line, and no shorter than
that line, so both sit inside it. Senses sit one gap past it. The client
keeps that target on the entity (TargetedIndex). It is empty when there
is none, and it is not filled in for the local player.

Text is Segoe UI Semibold over a 1px black halo at 85%. The name, the
numbers and the icons each have a size in the settings window.

HP comes from the main target, the same read as HXUI's target bar:
GetTarget():GetTargetIndex(0), then that entity's HP percent.
]]--

addon.name     = 'TargetBar';
addon.author   = 'Seekey';
addon.version  = '1.4.1';
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
-- The target's target starts at 280, wide enough for a short name and the
-- percent. A longer name widens the bar (see tot_need).
local DEFAULT_WIDTH  = 480;
local DEFAULT_HEIGHT = 28;
local DEFAULT_TOT    = 280;

local WIDTH_MIN, WIDTH_MAX   = 40, 5120;
local HEIGHT_MIN, HEIGHT_MAX = 8, 160;
local Y_MIN, Y_MAX           = 0, 2160;

-- Text and icon sizes, and their slider ranges. An icon's size is also the
-- gap after a damage group. The offset is the space between the bar's ends
-- and the name and the percent inside it.
local DEFAULT_NAME, DEFAULT_TEXT, DEFAULT_ICON, DEFAULT_OFFSET = 25, 20, 32, 8;
local NAME_MIN, NAME_MAX = 8, 64;
local TEXT_MIN, TEXT_MAX = 8, 48;
local ICON_MIN, ICON_MAX = 8, 64;
local OFFSET_MIN, OFFSET_MAX = 0, 64;

local FILL   = '#ee6f78';
local TRACK  = '#0C0C0C';
local EDGE   = '#0C0C0C';
local BAR_A  = 0.70;
local RADIUS = 4;
local EASE   = 12; -- share of the remaining fill covered per second

-- Text is stamped over a 1px black halo. GAP is the space between the bar
-- and the text and icons around it, and between the name and the percent.
local HALO_A  = 0.85;
local GAP     = 4;

-- The name's color: white over 75% HP, then yellow, orange at 50% and red at 25%.
local NAME_WHITE, NAME_YELLOW, NAME_ORANGE, NAME_RED = '#FFFFFF', '#E8C84A', '#E8883A', '#E8454E';

-- An NPC's bar: its name in pale green on black at 40%.
local NPC_TEXT, PLATE, PLATE_A = '#C2FFC2', '#000000', 0.40;

-- Lock-on. LOCK is the fringe on the bar and around the word. LOCK_TEXT
-- is the letters, its own colour so it can be tried apart from the name.
-- The fringe is that red gone transparent, not a second colour. The reach
-- is the gap beside the bar (see GAP). The pointer and the second bar
-- start past that fringe, so the stroke does not cover them.
local LOCK = '#FF4A40';
local LOCK_TEXT = '#ffb4b4';
local LOCK_REACH = 4;
-- Sidekick3's MP bar. The pointer is this yellow, at the bars' 70%.
local MP = '#E8B45C';
-- Altitude of an equilateral triangle, as a share of its side.
local TRI_K = math.sqrt(3) / 2;
local LOCK_GLOW = {
    { 4, 0.14 },
    { 3, 0.22 },
    { 2, 0.34 },
    { 1, 0.50 },
    { 0, 0.72 },
};

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
-- it sits with aggro (see threat).
local SENSES = { 'TrueSight', 'Sight', 'Sound', 'Scent', 'Magic', 'JA', 'Blood' };

-- 1.92 names the flag one way, 1.80 another. Nil rounds every corner.
local LEFT_CORNERS = ImDrawFlags_RoundCornersLeft or ImDrawCornerFlags_Left;

-- No y: the bar is centered until it is placed (see bar_rect).
local defaults = T{
    width  = DEFAULT_WIDTH,
    height = DEFAULT_HEIGHT,
    name_size = DEFAULT_NAME,
    text_size = DEFAULT_TEXT,
    icon_size = DEFAULT_ICON,
    edge_offset = DEFAULT_OFFSET,
    show_name = true,
    show_hp = true,
    show_detection = true,
    show_weakness = true,
    show_resistance = true,
    show_tot = true,
    tot_width = DEFAULT_TOT,
};

local cfg = settings.load(defaults);

local config_open  = false;
local dirty        = false;
local drag_origin  = nil;
local drag_fault   = nil;
local main_fill = { hpp = nil, id = nil, at = nil };
local tot_fill  = { hpp = nil, id = nil, at = nil };

-- Segoe UI: semibold for the HUD and the window's title, regular for its
-- labels, semibold italic for its group headings. Baked once at BAKE_PX
-- from the load event, outside any frame, as Chains and Tracker do: adding
-- to the shared atlas mid-frame can crash 1.80 (Ashita 4.16). 1.92 draws a
-- face at any size. Before it, a draw list scales the bake, and ImGui's
-- own widgets take the window's font scale. There the HUD's semibold has
-- its own bake at HUD_BAKE_PX: its 20 and 25px defaults scale down from
-- it, which stays sharper than scaling 18 up. Without the files, each is
-- ImGui's own font scaled to the same pixel size.
local BAKE_PX      = 18;
local HUD_BAKE_PX  = 32;
local fonts        = {};
local custom       = false;
local dynamic_font = (tonumber(IMGUI_VERSION_NUM) or 0) >= 19200;

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
-- It is not NoMove: a drag on any empty part of it moves it. The controls'
-- invisible buttons take their own presses.
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
    cfg.name_size = clamp(cfg.name_size, NAME_MIN, NAME_MAX, DEFAULT_NAME);
    cfg.text_size = clamp(cfg.text_size, TEXT_MIN, TEXT_MAX, DEFAULT_TEXT);
    cfg.icon_size = clamp(cfg.icon_size, ICON_MIN, ICON_MAX, DEFAULT_ICON);
    cfg.edge_offset = clamp(cfg.edge_offset, OFFSET_MIN, OFFSET_MAX, DEFAULT_OFFSET);
    cfg.show_name = on_unless_off(cfg.show_name);
    cfg.show_hp = on_unless_off(cfg.show_hp);
    cfg.show_detection = on_unless_off(cfg.show_detection);
    cfg.show_weakness = on_unless_off(cfg.show_weakness);
    cfg.show_resistance = on_unless_off(cfg.show_resistance);
    cfg.show_tot = on_unless_off(cfg.show_tot);
    cfg.tot_width = clamp(cfg.tot_width, WIDTH_MIN, WIDTH_MAX, DEFAULT_TOT);
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

-- The screen's size, 1920 by 1080 until ImGui says.
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

-- (corners nil rounds all four: it isn't passed, as 1.80 reads 0 as none and 1.92 as all.)
local function fill(dl, x, y, w, h, color, radius, alpha, corners)
    if w <= 0 or h <= 0 then return; end
    local p, q, col = { x, y }, { x + w, y + h }, u32(color, alpha);
    if corners then
        dl:AddRectFilled(p, q, col, radius or 0, corners);
    else
        dl:AddRectFilled(p, q, col, radius or 0);
    end
end

-- Spawn flags: 0x01 a player, 0x10 a mob. An NPC (0x02) or an object has
-- neither, and gets only its name: a shopkeeper with an HP bar is noise.
-- Its HP% is no tell, as the server sends 100 for it. A pet or a trust has
-- neither flag either (see is_pet and is_trust).
local function has_flag(flags, bit_)
    return type(flags) == 'number' and bit.band(flags, bit_) ~= 0;
end

-- A pet is flagged as an NPC is, but it has an owner: a player whose
-- PetTargetIndex is the pet's index. Players hold indices 0x400 to 0x6FF.
-- A pet, as anything spawned after the zone loads, is 0x700 or up, so a
-- shopkeeper is never scanned. The answer is kept for a second per target.
local pet_sid, pet_yes, pet_at = nil, false, nil;
local function is_pet(entities, index, sid)
    if index < 0x700 or type(entities.GetPetTargetIndex) ~= 'function' then return false; end
    local now = os.clock();
    if sid == pet_sid and pet_at ~= nil and now - pet_at >= 0 and now - pet_at < 1 then return pet_yes; end
    local yes = false;
    for i = 0x400, 0x6FF do
        if entities:GetPetTargetIndex(i) == index then yes = true; break; end
    end
    pet_sid, pet_yes, pet_at = sid, yes, now;
    return yes;
end

-- One's own trust is a party member. Were it to carry the mob flag, its
-- mobdb row, if one matched, would be a namesake's (a BCNM's Shantotto, say).
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

-- A trust is flagged as an NPC is, but the client keeps its owner's index
-- (TrustOwnerTargetIndex), a player's: 0x400 to 0x6FF. Anyone's trust has
-- it. One's own is also in the party, should the index be left unset.
local function is_trust(entities, index, sid)
    if entities ~= nil and type(entities.GetTrustOwnerTargetIndex) == 'function' then
        local owner = tonumber(entities:GetTrustOwnerTargetIndex(index));
        if owner ~= nil and owner >= 0x400 and owner <= 0x6FF then return true; end
    end
    return in_party(sid);
end

-- One entity, by index. `npc` is neither a mob, a player, a pet, nor a trust.
-- Flags that cannot be read keep the bar: an unknown is not taken for an NPC.
local function entity_info(index)
    if type(index) ~= 'number' or index <= 0 or index > 2303 then return nil; end
    index = math.floor(index);
    local mm = AshitaCore:GetMemoryManager();
    if mm == nil then return nil; end

    local name, hpp, sid, flags;
    if type(GetEntity) == 'function' then
        local ent_ok, ent = pcall(GetEntity, index);
        if ent_ok and ent ~= nil then
            name = ent.Name;
            hpp  = ent.HPPercent;
            sid  = ent.ServerId;
            local flags_ok, read = pcall(function () return ent.SpawnFlags; end);
            if flags_ok then flags = tonumber(read); end
        end
    end
    local entities = mm:GetEntity();
    if type(name) ~= 'string' or name == '' or hpp == nil then
        if entities == nil then return nil; end
        name = entities:GetName(index);
        hpp  = entities:GetHPPercent(index);
        sid  = entities:GetServerId(index);
    end
    if flags == nil and entities ~= nil and type(entities.GetSpawnFlags) == 'function' then
        local flags_ok, read = pcall(function () return entities:GetSpawnFlags(index); end);
        if flags_ok then flags = tonumber(read); end
    end
    if type(name) ~= 'string' or name == '' then return nil; end
    local mob = has_flag(flags, 0x10);
    hpp = tonumber(hpp) or 0;
    if hpp < 0 then hpp = 0; elseif hpp > 100 then hpp = 100; end
    if sid == nil or sid == 0 then sid = index; end
    local npc = flags ~= nil and not mob and not has_flag(flags, 0x01)
        and not is_trust(entities, index, sid)
        and not (entities ~= nil and is_pet(entities, index, sid));
    mob = mob and not in_party(sid);
    return { id = sid, hpp = hpp, name = name, index = index, mob = mob, npc = npc };
end

-- The main target. Index 0 is "no target". HXUI reads this same index and HPPercent.
local function read_target()
    local ok, found = pcall(function ()
        local mm = AshitaCore:GetMemoryManager();
        if mm == nil then return nil; end
        local target = mm:GetTarget();
        if target == nil then return nil; end
        return entity_info(target:GetTargetIndex(0));
    end);
    if ok then return found; end
    return nil;
end

-- Who this entity is targeting. TargetedIndex is the client's copy. It is 0
-- with no target, and the local player's is left empty.
local function targeted_index(index)
    local tot;
    if type(GetEntity) == 'function' then
        local ent_ok, ent = pcall(GetEntity, index);
        if ent_ok and ent ~= nil then tot = tonumber(ent.TargetedIndex); end
    end
    if tot == nil or tot <= 0 then
        local mm = AshitaCore:GetMemoryManager();
        local entities = mm ~= nil and mm:GetEntity() or nil;
        if entities ~= nil and type(entities.GetTargetedIndex) == 'function' then
            local read_ok, read = pcall(function () return entities:GetTargetedIndex(index); end);
            if read_ok then tot = tonumber(read); end
        end
    end
    return tot;
end

-- The target's target. The same entity twice is not a second bar.
local function read_tot(target)
    if target == nil or type(target.index) ~= 'number' then return nil; end
    local ok, found = pcall(function ()
        local tot = targeted_index(target.index);
        if tot == nil then return nil; end
        tot = math.floor(tot);
        if tot <= 0 or tot > 2303 or tot == target.index then return nil; end
        return entity_info(tot);
    end);
    if ok then return found; end
    return nil;
end

-- True while the main target is locked on. The game calls that Notice.
-- GetIsLockedOn is the direct read where this client has it; otherwise
-- LockedOnFlags bit 0, the same fallback XIUI uses. A miss is not locked.
local function target_locked()
    local ok, yes = pcall(function ()
        local mm = AshitaCore:GetMemoryManager();
        if mm == nil then return false; end
        local target = mm:GetTarget();
        if target == nil then return false; end
        if type(target.GetIsLockedOn) == 'function' then
            local locked = target:GetIsLockedOn();
            return locked == 1 or locked == true;
        end
        if type(target.GetLockedOnFlags) ~= 'function' then return false; end
        return bit.band(tonumber(target:GetLockedOnFlags()) or 0, 0x01) ~= 0;
    end);
    return ok and yes == true;
end

-- Ease the fill toward `hpp`. A new id snaps, so a new target does not drain from the last one.
local function smooth(state, id, hpp)
    local now = os.clock();
    local dt = 0;
    if state.at ~= nil then
        dt = now - state.at;
        if dt < 0 then dt = 0; elseif dt > 0.1 then dt = 0.1; end
    end
    state.at = now;
    if state.hpp == nil or state.id ~= id then
        state.hpp, state.id = hpp, id;
        return hpp;
    end
    state.hpp = state.hpp + (hpp - state.hpp) * math.min(1, dt * EASE);
    if math.abs(state.hpp - hpp) < 0.05 then state.hpp = hpp; end
    return state.hpp;
end

local function clear_fill(state)
    state.hpp, state.id = nil, nil;
end

-- Segoe UI from Windows, from the load event. Its faces draw from the first frame.
local function bake_fonts()
    local dir = ((os.getenv and os.getenv('WINDIR')) or 'C:\\Windows') .. '\\Fonts\\';
    local function add(file, px)
        local path = dir .. file;
        local handle = io.open(path, 'rb');
        if handle == nil then return nil; end
        handle:close();
        local ok, loaded = pcall(imgui.AddFontFromFileTTF, path, px or BAKE_PX);
        if ok and loaded then return loaded; end
        return nil;
    end
    local text = add('segoeui.ttf');
    local semi = add('seguisb.ttf') or text;
    local semi_italic = add('seguisbi.ttf') or semi;
    text = text or semi;
    if text ~= nil then
        local hud = (not dynamic_font and add('seguisb.ttf', HUD_BAKE_PX)) or semi;
        fonts, custom = { text = text, semi = semi, semi_italic = semi_italic, hud = hud }, true;
    end
end

-- Without Segoe, every face is ImGui's own.
local function font_frame()
    if custom then return; end
    local own = imgui.GetFont();
    fonts.text, fonts.semi, fonts.semi_italic, fonts.hud = own, own, own, own;
end

-- `font` at `px` for ImGui's own widgets, inside a window. Before 1.92
-- PushFont takes no size: the face goes on at its bake and the window's
-- font scale makes up the rest. pop_font puts the scale back to 1, as a
-- tooltip's window is shared with every other addon.
local function push_font(font, px)
    if dynamic_font then
        imgui.PushFont(font, px);
        return;
    end
    imgui.PushFont(font);
    imgui.SetWindowFontScale(px / BAKE_PX);
end

local function pop_font()
    if not dynamic_font then imgui.SetWindowFontScale(1); end
    imgui.PopFont();
end

local measured, measured_n = {}, 0;

-- Width and height of `text` in `font` (the HUD's unless given) at `px`.
-- CalcTextSize measures at the size ImGui has on (px on 1.92, the bake
-- before it, the UI font's own without Segoe), scaled to px as a draw list
-- scales a face. That size is GetFontSize's, window font scale and all, so
-- the ratio holds inside the settings window too. Cached: the same strings
-- are measured every frame.
local function measure(text, px, font)
    font = font or fonts.hud;
    text = tostring(text);
    local key = tostring(font) .. '|' .. px .. '|' .. text;
    local m = measured[key];
    if m ~= nil then return m[1], m[2]; end
    local w, h, base;
    if custom and font ~= nil then
        local pushed = false;
        local ok, a, b, size = pcall(function ()
            if dynamic_font then imgui.PushFont(font, px); else imgui.PushFont(font); end
            pushed = true;
            local cw, ch = imgui.CalcTextSize(text);
            local fs = imgui.GetFontSize();
            imgui.PopFont();
            pushed = false;
            return cw, ch, fs;
        end);
        if pushed then pcall(imgui.PopFont); end
        if ok then
            w, h = xy(a, b);
            base = tonumber(size) or 0;
            if base <= 0 then base = dynamic_font and px or BAKE_PX; end
        end
    end
    if w == nil then
        w, h = xy(imgui.CalcTextSize(text));
        base = tonumber(imgui.GetFontSize()) or 0;
        if base <= 0 then base = 13; end
    end
    w, h = w * px / base, h * px / base;
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

-- The halo: the string in black a pixel out each way, then the fill (white unless given).
local function halo(dl, x, y, px, text, color)
    local font = fonts.hud;
    if font == nil or text == nil or text == '' then return; end
    x, y = math.floor(x + 0.5), math.floor(y + 0.5);
    local dark, ink = u32('#000000', HALO_A), u32(color or '#FFFFFF', 1);
    for _, o in ipairs(AROUND) do
        dl:AddText(font, px, { x + o[1], y + o[2] }, dark, text);
    end
    dl:AddText(font, px, { x, y }, ink, text);
end

local function name_color(hpp)
    if hpp <= 25 then return NAME_RED; end
    if hpp <= 50 then return NAME_ORANGE; end
    if hpp <= 75 then return NAME_YELLOW; end
    return NAME_WHITE;
end

local cuts, cuts_n = {}, 0;

-- `text` cut short to fit `room` pixels at `px`, ending in '...'. Whole when
-- it fits, '' when not even a letter and the dots do. Cached, as measure is.
local function fit(text, px, room)
    if measure(text, px) <= room then return text; end
    local key = px .. '|' .. math.floor(room) .. '|' .. text;
    local cut = cuts[key];
    if cut ~= nil then return cut; end
    cut = '';
    for n = #text - 1, 1, -1 do
        local s = text:sub(1, n):gsub('%s+$', '') .. '...';
        if measure(s, px) <= room then cut = s; break; end
    end
    if cuts_n >= 1000 then cuts, cuts_n = {}, 0; end
    cuts[key] = cut;
    cuts_n = cuts_n + 1;
    return cut;
end

-- The name inside the bar, the edge offset in from its left end, its middle
-- on the bar's, in `color` (its HP's unless given). With the percent beside
-- it, it stops a gap short of the widest percent, so the cut does not move
-- as HP does.
local function draw_name(dl, x, y, w, h, name, hpp, beside_hp, color)
    local room = w - cfg.edge_offset * 2;
    if beside_hp then room = room - measure('100%', cfg.text_size) - GAP; end
    name = fit(name, cfg.name_size, room);
    local _, th = measure(name, cfg.name_size);
    halo(dl, x + cfg.edge_offset, y + (h - th) / 2 - lift(th), cfg.name_size, name, color or name_color(hpp));
end

-- The percent inside the bar, the edge offset in from its right end.
local function draw_label(dl, x, y, w, h, hpp)
    local label = ('%d%%'):format(math.floor(hpp + 0.5));
    local tw, th = measure(label, cfg.text_size);
    local ty = y + (h - th) / 2 - lift(th);
    halo(dl, x + w - cfg.edge_offset - tw, ty, cfg.text_size, label);
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
        width = cfg.icon_size;
    elseif seg.alt ~= nil then
        width = measure(seg.alt, cfg.text_size);
    end
    if seg.text ~= nil then width = width + measure(seg.text, cfg.text_size); end
    return width;
end

-- One segment, top-left at (cursor, row_y), in a row icon_size tall. A
-- missing texture draws `alt` in the icon's place, the same fallback the
-- damage row uses. Returns the x the next segment starts at, before any
-- gap the caller adds.
local function paint_segment(dl, cursor, row_y, seg)
    local icon, px = cfg.icon_size, cfg.text_size;
    local handle = icon_handle(seg.icon);
    if handle ~= nil then
        local drawn = pcall(function ()
            dl:AddImage(handle, { cursor, row_y }, { cursor + icon, row_y + icon },
                { 0, 0 }, { 1, 1 }, 0xFFFFFFFF);
        end);
        if drawn then
            cursor = cursor + icon;
        elseif seg.alt ~= nil then
            local aw, ah = measure(seg.alt, px);
            halo(dl, cursor, row_y + (icon - ah) / 2 - lift(ah), px, seg.alt);
            cursor = cursor + aw;
        end
    elseif seg.alt ~= nil then
        local aw, ah = measure(seg.alt, px);
        halo(dl, cursor, row_y + (icon - ah) / 2 - lift(ah), px, seg.alt);
        cursor = cursor + aw;
    end
    if seg.text ~= nil then
        local tw, th = measure(seg.text, px);
        halo(dl, cursor, row_y + (icon - th) / 2 - lift(th), px, seg.text);
        cursor = cursor + tw;
    end
    return cursor;
end

-- The damage row under the bar. A group ends with an icon's width of space,
-- so its percentage reads as its own.
local function draw_resists(dl, x, y, w, h, segments)
    if segments == nil then return; end
    local total = 0;
    for i, seg in ipairs(segments) do
        total = total + segment_width(seg);
        if i < #segments and seg.group_end then total = total + cfg.icon_size; end
    end
    local cursor = math.floor(x + (w - total) / 2 + 0.5);
    local row_y = math.floor(y + h + GAP + 0.5);
    for i, seg in ipairs(segments) do
        cursor = paint_segment(dl, cursor, row_y, seg);
        if i < #segments and seg.group_end then cursor = cursor + cfg.icon_size; end
    end
end

-- Detection, centered on the bar's height. The left group grows left from
-- one gap off the bar, the right group grows right from the bar, or from
-- `right_at` when the target's target takes that side. Icons in a group
-- sit flush: the PNGs carry their own padding.
-- Neither group changes the bar's width or its place on the screen.
local function draw_flanks(dl, x, y, w, h, left, right, right_at)
    local row_y = math.floor(y + (h - cfg.icon_size) / 2 + 0.5);
    if left ~= nil and #left > 0 then
        local width = 0;
        for i = 1, #left do width = width + segment_width(left[i]); end
        local cursor = math.floor(x - GAP - width + 0.5);
        for i = 1, #left do cursor = paint_segment(dl, cursor, row_y, left[i]); end
    end
    if right ~= nil and #right > 0 then
        local cursor = math.floor((right_at or (x + w)) + GAP + 0.5);
        for i = 1, #right do cursor = paint_segment(dl, cursor, row_y, right[i]); end
    end
end

-- `fill_hpp` is the eased width. The text goes on after (see d3d_present).
local function draw_bar(dl, x, y, w, h, fill_hpp)
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
end

-- The lock frame: the same rounded rect as the bar, grown a pixel at a
-- time. The outer passes are the faint fringe, the last is the border on
-- the bar's own edge. Thickness stays 1, so the corner flags can be left
-- off (0 would square them on 1.80).
local function lock_stroke(dl, x, y, w, h, radius, alpha)
    dl:AddRect({ x, y }, { x + w, y + h }, u32(LOCK, alpha), radius);
end

local function draw_lock(dl, x, y, w, h)
    x, y = math.floor(x + 0.5), math.floor(y + 0.5);
    w, h = math.floor(w + 0.5), math.floor(h + 0.5);
    local r0 = math.min(RADIUS, math.floor(h / 2), math.floor(w / 2));
    for i = 1, #LOCK_GLOW do
        local e, a = LOCK_GLOW[i][1], LOCK_GLOW[i][2];
        local rr = math.min(r0 + e, math.floor((h + e * 2) / 2), math.floor((w + e * 2) / 2));
        lock_stroke(dl, x - e, y - e, w + e * 2, h + e * 2, rr, a);
    end
end

-- "Locked" in LOCK_TEXT. The outline is the frame's fringe: a fainter red
-- copy of the word at each step, then the letters on top. The box sits
-- 1px above the bar, so the glow meets the stroke. The text size is the
-- numbers' size. Drawn after the icons so a tall one does not cover it.
local function draw_locked(dl, x, y, w)
    local font = fonts.hud;
    if font == nil then return; end
    local px = cfg.text_size;
    local text = 'Locked';
    local tw, th = measure(text, px);
    local tx = math.floor(x + (w - tw) / 2 + 0.5);
    local ty = math.floor(y - 1 - th + 0.5);
    for i = 1, #LOCK_GLOW do
        local e, a = LOCK_GLOW[i][1], LOCK_GLOW[i][2];
        if e > 0 then
            local col = u32(LOCK, a);
            for _, o in ipairs(AROUND) do
                dl:AddText(font, px, { tx + o[1] * e, ty + o[2] * e }, col, text);
            end
        end
    end
    dl:AddText(font, px, { tx, ty }, u32(LOCK_TEXT, 1), text);
end

-- An NPC's bar: the background alone, PLATE at PLATE_A, cornered as the bar is.
local function draw_plate(dl, x, y, w, h)
    fill(dl, x, y, w, h, PLATE, math.min(RADIUS, math.floor(h / 2), math.floor(w / 2)), PLATE_A);
end

-- The pointer: equilateral, left edge vertical, point to the right. The
-- edge is the HP bar's height, so the triangle is as tall as that bar.
-- It starts past the lock fringe. Returns how far the point reaches past
-- the bar's right edge.
local function pointer_reach(h)
    return LOCK_REACH + h * TRI_K;
end

local function draw_pointer(dl, x, y, w, h)
    x, y = math.floor(x + 0.5), math.floor(y + 0.5);
    w, h = math.floor(w + 0.5), math.floor(h + 0.5);
    local left = x + w + LOCK_REACH;
    -- Top, point, bottom. That order is clockwise on screen, which is what
    -- ImGui's anti-aliasing fills.
    dl:AddTriangleFilled(
        { left, y },
        { left + h * TRI_K, y + h / 2 },
        { left, y + h },
        u32(MP, BAR_A));
end

-- Pixels the name and the widest percent need on one line: the edge offset
-- in from each end, and one gap between them. "100%" is the widest percent,
-- so the floor does not move as HP does.
local function tot_need(name)
    local nw = measure(name, cfg.name_size);
    local pw = measure('100%', cfg.text_size);
    return math.ceil(nw + GAP + pw + cfg.edge_offset * 2);
end

-- The target's target, just past the pointer. The main bar's height, unless
-- the name or the percent is taller: then it grows, and stays centred on
-- the main bar, so the line sits inside it. One gap after the point, so
-- the tip does not sit on the bar.
local function tot_rect(name, bx, by, bw, bh)
    local w = cfg.tot_width;
    local need = tot_need(name);
    if w < need then w = need; end
    local _, nh = measure(name, cfg.name_size);
    local _, ph = measure('100%', cfg.text_size);
    local h = bh;
    -- Two pixels over the text box, for the halo, so the line stays inside.
    local need_h = math.ceil((nh > ph and nh or ph) + 2);
    if h < need_h then h = need_h; end
    return bx + bw + pointer_reach(bh) + GAP, by + (bh - h) / 2, w, h;
end

-- The bar's box, `width` wide (the setting's unless given): centered
-- across, at cfg.y down, or centered down too until it has been placed.
-- Held on the screen.
local function bar_rect(width)
    local sw, sh = screen();
    local w = math.min(width or cfg.width, math.floor(sw));
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
-- `anchor` is the main bar's top when the hit box is taller than it.
local function drag_y(x, y, w, h, anchor)
    imgui.SetNextWindowPos({ x, y }, ImGuiCond_Always);
    imgui.SetNextWindowSize({ w, h }, ImGuiCond_Always);
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 0, 0 });
    imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0);
    imgui.PushStyleVar(ImGuiStyleVar_WindowMinSize, { 1, 1 });
    anchor = anchor or y;
    local ok, fault = true, nil;
    if imgui.Begin('TargetBar###targetbar_drag', true, DRAG_FLAGS) then
        ok, fault = pcall(function ()
            imgui.SetCursorPos({ 0, 0 });
            imgui.InvisibleButton('##targetbar_drag', { w, h });
            if imgui.IsItemHovered() and ImGuiMouseCursor_ResizeNS ~= nil then
                imgui.SetMouseCursor(ImGuiMouseCursor_ResizeNS);
            end
            if imgui.IsItemActivated() then drag_origin = anchor; end
            if imgui.IsItemActive() and drag_origin ~= nil then
                local _, dy = xy(imgui.GetMouseDragDelta(0));
                local _, sh = screen();
                local ny = clamp(drag_origin + dy, Y_MIN, math.max(Y_MIN, math.floor(sh - cfg.height)), anchor);
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

-- The settings window, in VanaCore's style (by Vekien): one palette, every
-- size through S(), every control drawn on the window's list over an
-- invisible button, its states eased.
local P = {
    bg = '#161822', border = '#2A2E3E', hover = '#1F2334',
    well = '#0E1017', well_edge = '#272B3C', popup = '#0F1118',
    white = '#FFFFFF', text = '#E8EAF1', text2 = '#BDC1D0', dim = '#7B8095', faint = '#4E536A',
    accent = '#7AA2F7', accent2 = '#A9C1FF', accent_lo = '#3E5CB3',
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
-- 0.75 and 1.6, then times 1.1.
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

local function text_at(dl, x, y, s, color, font, px)
    dl:AddText(font, px, { math.floor(x + 0.5), math.floor(y + 0.5) }, u32(color), s);
end

-- Text with its middle at cy: from x, ending at `right`, or centred on cx.
local function text_mid(dl, x, cy, s, color, font, px)
    local _, h = measure(s, px, font);
    text_at(dl, x, cy - h / 2 - lift(h), s, color, font, px);
end

local function text_right(dl, right, cy, s, color, font, px)
    local w, h = measure(s, px, font);
    text_at(dl, right - w, cy - h / 2 - lift(h), s, color, font, px);
end

local function text_centred(dl, cx, cy, s, color, font, px)
    local w, h = measure(s, px, font);
    text_at(dl, cx - w / 2, cy - h / 2 - lift(h), s, color, font, px);
end

-- Capitals one glyph at a time, `spacing` pixels apart (ImGui has no
-- tracking), for group headings. Returns the width.
local function text_spaced(dl, x, cy, s, color, font, px, spacing)
    local start = x;
    for letter in s:gmatch('.') do
        text_mid(dl, x, cy, letter, color, font, px);
        x = x + measure(letter, px, font) + spacing;
    end
    if x == start then return 0; end
    return x - start - spacing;
end

-- A tooltip by the mouse, in the palette. The face goes on inside the
-- tooltip's window, as before 1.92 its size is that window's font scale.
local function tooltip(s)
    if s == nil or s == '' then return; end
    imgui.PushStyleColor(ImGuiCol_PopupBg, rgba(P.popup, 0.97));
    imgui.PushStyleColor(ImGuiCol_Border, rgba(P.border));
    imgui.PushStyleColor(ImGuiCol_Text, rgba(P.text));
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { S(9), S(6) });
    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, S(4));
    imgui.PushStyleVar(ImGuiStyleVar_PopupBorderSize, 1);
    -- 1.80 returns nothing from BeginTooltip and 1.92 true: open either way.
    -- Only false skips EndTooltip. A throw in the text still reaches it, or
    -- the rest of the window would pour into the tooltip.
    if imgui.BeginTooltip() ~= false then
        local font_on = false;
        pcall(function ()
            if custom then
                push_font(fonts.text, S(SMALL + 0.5));
                font_on = true;
            end
            imgui.TextUnformatted(tostring(s));
        end);
        if font_on then pop_font(); end
        imgui.EndTooltip();
    end
    imgui.PopStyleVar(3);
    imgui.PopStyleColor(3);
end

local POPUP_COLOURS = {
    { ImGuiCol_PopupBg, rgba(P.popup) }, { ImGuiCol_Border, rgba(P.border) }, { ImGuiCol_Text, rgba(P.text) },
    { ImGuiCol_FrameBg, rgba(P.well) },
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
            push_font(fonts.text, S(SMALL + 1));
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
    if font_on then pop_font(); end
    if opened then imgui.EndPopup(); end
    pop_popup_style();
    return got;
end

-- A whole-number slider, `w` wide: the track, then the value in px. A
-- click on the value opens a box to type one.
local function slider(id, x, cy, w, value, min, max)
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
    text_right(dl, vx + value_w - S(4), cy, tostring(value) .. 'px', P.text2, fonts.text, S(SMALL + 0.5));
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

-- The close mark: an X, `box` square, the cross 0.72 of it, dim
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

-- A group's heading: small capitals in teal, a line after.
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

-- A faint line of text in a 22px line.
local function note(pg, s)
    text_mid(pg.dl, pg.lx, pg.y + S(11), s, P.faint, fonts.text, S(SMALL + 0.5));
    pg.y = pg.y + S(22);
end

-- The page's groups, top to bottom. A switch: { label, id, key, help }.
-- A slider: { label, id, key, help, min, max }. Bar's sliders are built as
-- the page is drawn: Width and Y follow the screen, and the target's
-- target follows the name it has to hold.
local SHOW = {
    { 'Name', '##tb_name', 'show_name', 'The name, on the left of the bar. Without it, an NPC draws nothing.' },
    { 'HP %', '##tb_hp', 'show_hp', 'The percent, on the right of the bar.' },
    { 'Detection', '##tb_detect', 'show_detection', 'Aggro and Link on the left of the bar. Senses on the right.' },
    { 'Weakness', '##tb_weak', 'show_weakness', 'Damage the mob takes more from.' },
    { 'Resistance', '##tb_resist', 'show_resistance', 'Damage the mob takes less from.' },
    { 'Target of target', '##tb_tot', 'show_tot', 'A second bar, to the right, with that target\'s name and HP%.' },
};
local SIZES = {
    { 'Name font size', '##tb_name_px', 'name_size', 'Pixels.', NAME_MIN, NAME_MAX },
    { 'Text font size', '##tb_text_px', 'text_size', 'Pixels: the HP % and the percentages and words beside the icons.',
        TEXT_MIN, TEXT_MAX },
    { 'Icon size', '##tb_icon_px', 'icon_size', 'Pixels: the detection and damage icons, and the space between damage groups.',
        ICON_MIN, ICON_MAX },
    { 'Edge offset', '##tb_offset_px', 'edge_offset', 'Pixels from the ends of the bar to the name and the HP %.',
        OFFSET_MIN, OFFSET_MAX },
};
local BAR_ROWS = 4;

-- The page from the top: the title bar and its line, 10 more, each group's
-- heading (8 above, 26 for it) and rows, the button's row (a row and 4),
-- the note (22), and 14 under it. draw_config lays it out in this order.
local function page_height()
    return S(TITLE_H) + 1 + S(10)
        + 3 * (S(8) + S(26)) + (#SHOW + #SIZES + BAR_ROWS) * S(ROW_H)
        + S(ROW_H) + S(4) + S(22) + S(14);
end

-- A labelled slider row that writes cfg[key].
local function slider_row(pg, row, value, min, max)
    local cy = line(pg, row[1], row[4]);
    local v, moved = slider(row[2], pg.right - S(SLIDER_W), cy, S(SLIDER_W), value, min, max);
    if moved and v ~= cfg[row[3]] then
        cfg[row[3]] = v;
        dirty = true;
    end
end

local function draw_config(has_target, tot_name)
    tick();
    local sw, sh = screen();
    local _, bar_y, _, bar_h = bar_rect();
    local wmax = math.max(WIDTH_MIN, math.min(WIDTH_MAX, math.floor(sw)));
    local ymax = math.max(Y_MIN, math.floor(sh - bar_h));
    -- The slider cannot go below the name and the percent on one line.
    -- A longer name than this one still widens the bar when it is drawn.
    local tneed = tot_need(tot_name or 'Target');
    local tmax = math.max(WIDTH_MIN, math.min(WIDTH_MAX, math.floor(sw)));
    local tmin = tneed;
    if tmin < WIDTH_MIN then tmin = WIDTH_MIN; end
    if tmin > tmax then tmin = tmax; end
    local tval = cfg.tot_width;
    if tval < tmin then tval = tmin; end
    if tval > tmax then tval = tmax; end
    local bar_rows = {
        { { 'Width', '##tb_w', 'width', 'Pixels, up to the screen\'s width.' }, math.min(cfg.width, wmax), WIDTH_MIN, wmax },
        { { 'Height', '##tb_h', 'height', 'Pixels.' }, cfg.height, HEIGHT_MIN, HEIGHT_MAX },
        { { 'Y', '##tb_y', 'y', 'Pixels from the top of the screen to the bar.' }, bar_y, Y_MIN, ymax },
        { { 'Target of target', '##tb_tot_w', 'tot_width',
            'Pixels. Never narrower than the name and the HP% on one line.' }, tval, tmin, tmax },
    };
    local pw, ph, m = S(PAGE_W), page_height(), S(MARGIN);
    imgui.SetNextWindowPos({ sw / 2, sh / 2 }, ImGuiCond_FirstUseEver, { 0.5, 0.5 });
    imgui.SetNextWindowSize({ pw + m * 2, ph + m * 2 }, ImGuiCond_Always);
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 0, 0 });
    imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0);
    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, { 0, 0 });
    local drew, fault = true, nil;
    if imgui.Begin('TargetBar###tb_settings', true, PANEL_FLAGS) then
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
            for _, item in ipairs(SHOW) do
                local cy = line(pg, item[1], item[4]);
                local on, flipped = switch(item[2], pg.right - S(SW_W), cy, cfg[item[3]] == true);
                if imgui.IsItemHovered() then tooltip(item[4]); end
                if flipped then cfg[item[3]] = on; dirty = true; end
            end
            subheader(pg, 'Text and icons');
            for _, row in ipairs(SIZES) do slider_row(pg, row, cfg[row[3]], row[5], row[6]); end
            subheader(pg, 'Bar');
            for _, r in ipairs(bar_rows) do slider_row(pg, r[1], r[2], r[3], r[4]); end

            local by = line(pg, nil, nil, S(ROW_H) + S(4));
            if button('##tb_reset', pg.lx, by, 'Reset position') then
                if cfg.y ~= nil then
                    cfg.y = nil;
                    dirty = true;
                end
            end
            if imgui.IsItemHovered() then tooltip('Back to the middle of the screen.'); end
            note(pg, has_target and 'Drag the bar up or down. It stays centered.'
                or 'No target: a preview shows where it goes.');
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
end

local function save_if_idle()
    if not dirty or imgui.IsMouseDown(0) or imgui.IsAnyItemActive() then return; end
    local ok = pcall(function () settings.save(); end);
    if ok then dirty = false; end
end

local function report()
    sanitize();
    local _, y = bar_rect();
    say(('Width %d, target of target %d, height %d, Y %d%s.'):format(
        cfg.width, cfg.tot_width, cfg.height, y, cfg.y == nil and ' (centered)' or ''));
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

-- Between frames, so Segoe can go into the shared atlas (see BAKE_PX).
ashita.events.register('load', 'targetbar_load', bake_fonts);

ashita.events.register('d3d_present', 'targetbar_present', function ()
    font_frame();
    load_zone(current_zone());

    local target = read_target();
    -- An NPC's bar is there to hold its name. Without the name, it is no target.
    if target ~= nil and target.npc and not cfg.show_name then target = nil; end
    local tot = target ~= nil and read_tot(target) or nil;
    local npc = target ~= nil and target.npc;
    local hpp, id;
    if target ~= nil then
        hpp, id = npc and 100 or target.hpp, target.id;
    elseif config_open then
        hpp, id = 100, 'preview';
    else
        clear_fill(main_fill);
        clear_fill(tot_fill);
        save_if_idle();
        return;
    end

    -- An NPC's bar is a plate with no fill or percent, only as wide as its name and an offset each side.
    local x, y, w, h;
    if npc then
        x, y, w, h = bar_rect(math.ceil(measure(target.name, cfg.name_size) + cfg.edge_offset * 2));
    else
        x, y, w, h = bar_rect();
    end
    local dl = imgui.GetBackgroundDrawList();
    local label = cfg.show_hp and not npc;
    local fill_hpp = smooth(main_fill, id, hpp);
    -- A real target's target, or the preview beside the preview bar. The
    -- name and the percent always both draw: that bar has its own switch.
    local tot_name, tot_hpp, tot_id = nil, nil, nil;
    if cfg.show_tot and tot ~= nil then
        tot_name, tot_hpp, tot_id = tot.name, tot.hpp, tot.id;
    elseif cfg.show_tot and target == nil then
        tot_name, tot_hpp, tot_id = 'Target', 100, 'tot-preview';
    end
    -- A real target only. The preview (settings open, nothing targeted) is not locked on.
    local locked = target ~= nil and target_locked();
    if npc then draw_plate(dl, x, y, w, h); else draw_bar(dl, x, y, w, h, fill_hpp); end
    -- The frame goes on after the fill, so the border sits on the edge, and
    -- before the icons, so a fringe that reaches the gap stays under them.
    if locked then draw_lock(dl, x, y, w, h); end
    if label then pcall(draw_label, dl, x, y, w, h, hpp); end
    if cfg.show_name then
        draw_name(dl, x, y, w, h, target ~= nil and target.name or 'Target', hpp, label, npc and NPC_TEXT or nil);
    end
    local right_at, tot_box = nil, nil;
    if tot_name ~= nil then
        draw_pointer(dl, x, y, w, h);
        local tx, ty, tw, th = tot_rect(tot_name, x, y, w, h);
        draw_bar(dl, tx, ty, tw, th, smooth(tot_fill, tot_id, tot_hpp));
        pcall(draw_label, dl, tx, ty, tw, th, tot_hpp);
        draw_name(dl, tx, ty, tw, th, tot_name, tot_hpp, true);
        right_at = tx + tw;
        tot_box = { x = tx, y = ty, w = tw, h = th };
    else
        clear_fill(tot_fill);
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
        if cfg.show_detection then draw_flanks(dl, x, y, w, h, rows.left, rows.right, right_at); end
    end
    if locked then draw_locked(dl, x, y, w); end
    if config_open then
        local dx, dy, dw, dh = x, y, w, h;
        if tot_box ~= nil then
            local x2 = math.max(x + w, tot_box.x + tot_box.w);
            local y1 = math.min(y, tot_box.y);
            local y2 = math.max(y + h, tot_box.y + tot_box.h);
            dx, dy, dw, dh = x, y1, x2 - x, y2 - y1;
        end
        drag_y(dx, dy, dw, dh, y);
        draw_config(target ~= nil, tot ~= nil and tot.name or 'Target');
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
        say('/tb opens settings. Toggles hide the name, the HP%, detection, weakness, resistance, and the target of target. /tb width <px>, /tb totwidth <px>, /tb height <px>, /tb y <px>. /tb reset returns the bar sizes and the edge offset, and centers the bar.');
    elseif sub == 'width' then
        set_number('width', args[3], WIDTH_MIN, WIDTH_MAX);
    elseif sub == 'totwidth' then
        set_number('tot_width', args[3], WIDTH_MIN, WIDTH_MAX);
    elseif sub == 'height' then
        set_number('height', args[3], HEIGHT_MIN, HEIGHT_MAX);
    elseif sub == 'y' then
        set_number('y', args[3], Y_MIN, Y_MAX);
    elseif sub == 'reset' then
        cfg.width, cfg.height, cfg.y = DEFAULT_WIDTH, DEFAULT_HEIGHT, nil;
        cfg.tot_width = DEFAULT_TOT;
        cfg.name_size, cfg.text_size, cfg.icon_size = DEFAULT_NAME, DEFAULT_TEXT, DEFAULT_ICON;
        cfg.edge_offset = DEFAULT_OFFSET;
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
