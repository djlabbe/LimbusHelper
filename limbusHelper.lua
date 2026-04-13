--[[
    LimbusHelper
    Tracks treasure chest openings in Apollyon and Temenos (Limbus).
    Monitors whether each of the 4 zone sectors yields the standard reward
    (3,000) or the bonus reward (5,000).

    Apollyon sector detection (nearest-chest by 3-D distance):
      NW (-211,  542,  0)
      NE ( 214,  542,  0)
      SW (-109, -429,  0)
      SE ( 112, -430,  0)

    Temenos sector detection (nearest-chest by 3-D distance):
      N  (-598,  457,  84)
      W  (-596,  177,   4)
      E  (-596, -102,  84)
      C  (-281, -423, -162)

    Use //lh pos in-game to verify that your sector reads correctly.
    Use //lh sector <sector> [3000|5000] to log a chest manually.
    Use //lh debug to capture all incoming text lines for troubleshooting.
]]

_addon.name     = 'LimbusHelper'
_addon.author   = 'Kaius @ Bahamut'
_addon.version  = '1.05'
_addon.commands = {'limbushelper', 'lh'}

config = require('config')
texts  = require('texts')
require('logger')
require('coroutine')

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------
local APOLLYON = 38
local TEMENOS  = 37

local zone_name = {
    [APOLLYON] = 'Apollyon',
    [TEMENOS]  = 'Temenos',
}

-- Per-zone ordered sector lists (order controls display)
local zone_sectors = {
    [APOLLYON] = {'NW', 'SW', 'NE', 'SE'},
    [TEMENOS]  = {'N', 'W', 'E', 'C'},
}

-- Known chest positions (3-D nearest-neighbour detection)
local APOLLYON_CHESTS = {
    NW = {x = -211, y =  542, z = 0},
    NE = {x =  214, y =  542, z = 0},
    SW = {x = -109, y = -429, z = 0},
    SE = {x =  112, y = -430, z = 0},
}

local TEMENOS_CHESTS = {
    N = {x = -598, y =  457, z =  84},
    W = {x = -596, y =  177, z =   4},
    E = {x = -596, y = -102, z =  84},
    C = {x = -281, y = -423, z = -162},
}

local STANDARD_AMT   = 3000
local BONUS_AMT      = 5000
local CHEST_DIST     = 20   -- yalms; must be within this range to count as a chest open
local last_bonus = nil  -- {zone_id, sector} of most recent bonus chest

-- ---------------------------------------------------------------------------
-- Config
-- Display settings are global (settings.xml).
-- Sector state is per-character (data/state.xml): the config library writes
-- each character's data to its own <CharName> section automatically.
-- ---------------------------------------------------------------------------
local display_defaults = T{}
display_defaults.pos_x     = 8
display_defaults.pos_y     = 8
display_defaults.font_size = 11
display_defaults.bg_alpha  = 200

settings = config.load(display_defaults)

-- Sector state: one file per character (data/state_CharName.xml) so that
-- simultaneous Windower instances never write to the same file.
-- Loaded lazily in init_player_state() once the player object is available.
local state_defaults = T{}
state_defaults.apollyon_NW = false
state_defaults.apollyon_NE = false
state_defaults.apollyon_SW = false
state_defaults.apollyon_SE = false
state_defaults.temenos_N   = false
state_defaults.temenos_E   = false
state_defaults.temenos_W   = false
state_defaults.temenos_C   = false

local function init_player_state()
    if state then return end  -- already initialized
    local player = windower.ffxi.get_player()
    if not player then return end  -- defer; login event will handle it
    state = config.load('data/state_'..player.name..'.xml', state_defaults)
end

local disp = texts.new('treasureLog')
texts.size(disp, settings.font_size)
texts.pos_x(disp, settings.pos_x)
texts.pos_y(disp, settings.pos_y)
texts.bg_alpha(disp, settings.bg_alpha)
texts.color(disp, 255, 255, 255)

-- ---------------------------------------------------------------------------
-- Runtime state
-- ---------------------------------------------------------------------------
-- tracking[zone_id][sector] = nil | 'std' | 'bonus'
local tracking = {
    [APOLLYON] = {},
    [TEMENOS]  = {},
}

local active_zone    = nil
local debug_mode     = false
local bonus_found    = false  -- true while bonus sector is visible
local auto_resetting = false  -- true only when the 5s coroutine is live
local manual_show    = false  -- true when user forces display outside a tracked zone

-- ---------------------------------------------------------------------------
-- Persistence helpers
-- ---------------------------------------------------------------------------
local function save_state()
    if not state then return end  -- not yet initialized (player not logged in)
    local a = tracking[APOLLYON]
    local t = tracking[TEMENOS]
    state.apollyon_NW = a.NW ~= nil
    state.apollyon_NE = a.NE ~= nil
    state.apollyon_SW = a.SW ~= nil
    state.apollyon_SE = a.SE ~= nil
    state.temenos_N   = t.N  ~= nil
    state.temenos_E   = t.E  ~= nil
    state.temenos_W   = t.W  ~= nil
    state.temenos_C   = t.C  ~= nil
    state:save()
end

local function load_state()
    tracking[APOLLYON] = {
        NW = state.apollyon_NW and 'std' or nil,
        NE = state.apollyon_NE and 'std' or nil,
        SW = state.apollyon_SW and 'std' or nil,
        SE = state.apollyon_SE and 'std' or nil,
    }
    tracking[TEMENOS] = {
        N = state.temenos_N and 'std' or nil,
        E = state.temenos_E and 'std' or nil,
        W = state.temenos_W and 'std' or nil,
        C = state.temenos_C and 'std' or nil,
    }
    -- Restore bonus_found from saved data (no live countdown after reload)
    bonus_found    = false
    auto_resetting = false
    if active_zone then
        for _, s in ipairs(zone_sectors[active_zone]) do
            if tracking[active_zone][s] == 'bonus' then
                bonus_found = true
                break
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Colour helpers
-- ---------------------------------------------------------------------------
local C_STD   = '\\cs(80,255,128)'  -- green      : opened (standard)
local C_BONUS = '\\cs(80,255,128)'  -- green      : bonus chest
local C_UNK   = '\\cs(255,80,80)'   -- red        : not yet opened
local C_HEAD  = '\\cs(200,220,255)' -- light blue : header
local C_END   = '\\cr'

-- ---------------------------------------------------------------------------
-- Sector detection
-- ---------------------------------------------------------------------------
local function detect_sector_apollyon(x, y, z)
    local best, best_d2 = nil, math.huge
    for sector, pos in pairs(APOLLYON_CHESTS) do
        local dx = x - pos.x
        local dy = y - pos.y
        local dz = z - pos.z
        local d2 = dx*dx + dy*dy + dz*dz
        if d2 < best_d2 then best_d2 = d2 ; best = sector end
    end
    return best
end

local function detect_sector_temenos(x, y, z)
    local best, best_d2 = nil, math.huge
    for sector, pos in pairs(TEMENOS_CHESTS) do
        local dx = x - pos.x
        local dy = y - pos.y
        local dz = z - pos.z
        local d2 = dx*dx + dy*dy + dz*dz
        if d2 < best_d2 then best_d2 = d2 ; best = sector end
    end
    return best
end

local function detect_sector()
    if not active_zone then return nil end
    local me = windower.ffxi.get_mob_by_target('me')
    if not me then return nil end
    if active_zone == APOLLYON then
        return detect_sector_apollyon(me.x, me.y, me.z)
    else
        return detect_sector_temenos(me.x, me.y, me.z)
    end
end

-- ---------------------------------------------------------------------------
-- Validate a sector name for the current (or given) zone
-- ---------------------------------------------------------------------------
local function valid_sector(s, zone_id)
    zone_id = zone_id or active_zone
    if not zone_id then return false end
    for _, v in ipairs(zone_sectors[zone_id]) do
        if v == s then return true end
    end
    return false
end

-- Returns the zone_id that owns sector s, or nil if not found
local function zone_for_sector(s)
    for zone_id, list in pairs(zone_sectors) do
        for _, v in ipairs(list) do
            if v == s then return zone_id end
        end
    end
    return nil
end

local function sector_list_str(zone_id)
    return table.concat(zone_sectors[zone_id or active_zone], '|')
end

-- ---------------------------------------------------------------------------
-- Refresh the on-screen display
-- ---------------------------------------------------------------------------
local function render_zone_rows(zone_id, lines)
    local data = tracking[zone_id]
    lines[#lines+1] = C_HEAD..'=== '..zone_name[zone_id]..' ==='..C_END
    for _, s in ipairs(zone_sectors[zone_id]) do
        local st = data[s]
        local col, tag
        if st == 'bonus' then
            col = C_BONUS ; tag = 'BONUS!'
        elseif st == 'std' then
            col = C_STD   ; tag = 'Opened'
        else
            col = C_UNK   ; tag = 'Unopened'
        end
        local label      = s..string.rep(' ', 3 - #s)
        local padded_tag = tag..string.rep(' ', 8 - #tag)
        lines[#lines+1] = label..': '..col..padded_tag..C_END
    end
end

local function refresh_display()
    if not active_zone and not manual_show then
        disp:hide()
        return
    end

    local lines = {}

    if active_zone then
        render_zone_rows(active_zone, lines)
        if bonus_found then
            lines[#lines+1] = ''
            if auto_resetting then
                lines[#lines+1] = C_BONUS..'Bonus found!  Resetting in 5s...'..C_END
            else
                lines[#lines+1] = C_BONUS..'Bonus found!  Use //lh reset.'..C_END
            end
        end
    else
        -- Manual show outside tracked zones: display both
        render_zone_rows(APOLLYON, lines)
        lines[#lines+1] = ''
        render_zone_rows(TEMENOS, lines)
    end

    texts.text(disp, table.concat(lines, '\n'))
    disp:show()
end

-- ---------------------------------------------------------------------------
-- Reset tracking for a zone
-- ---------------------------------------------------------------------------
local function reset_zone(zone_id)
	-- Remember where the bonus was before clearing
    for _, s in ipairs(zone_sectors[zone_id]) do
        if tracking[zone_id][s] == 'bonus' then
            last_bonus = {zone_id = zone_id, sector = s}
            break
        end
    end
    tracking[zone_id] = {}
    bonus_found    = false
    auto_resetting = false
    save_state()
    refresh_display()
end

-- ---------------------------------------------------------------------------
-- Record a chest result
-- ---------------------------------------------------------------------------
local function record_chest(sector, amount)
    if not active_zone then return end

    local is_bonus = (amount == BONUS_AMT)
    tracking[active_zone][sector] = is_bonus and 'bonus' or 'std'
    save_state()

    if is_bonus then
        bonus_found    = true
        auto_resetting = true
        windower.add_to_chat(158,
            'LimbusHelper: BONUS ('..amount..') at '
            ..zone_name[active_zone]..' '..sector
            ..'!  Tracking resets in 5 seconds...')
        local captured_zone = active_zone
        coroutine.schedule(function()
            if active_zone == captured_zone then
                reset_zone(active_zone)
                windower.add_to_chat(167, 'LimbusHelper: Tracking reset. Find the next bonus!')
            end
        end, 5)
    else
        windower.add_to_chat(167,
            'LimbusHelper: Standard ('..amount..') at '
            ..zone_name[active_zone]..' '..sector..'.')
    end

    refresh_display()
end

-- Minimum seconds between automatic chest recordings (debounce)
local RECORD_COOLDOWN   = 10
local last_record_time  = 0

-- ---------------------------------------------------------------------------
-- Incoming text: detect chest reward messages
-- ---------------------------------------------------------------------------
windower.register_event('incoming text', function(original, modified, mode)
    if not active_zone then return end

    if debug_mode then
        log('[DBG mode='..mode..'] '..original)
    end

    -- Match "Acquired Temenos Units: 3000" / "Acquired Apollyon Units: 5000"
    local zone_str, amt_str = original:match('Acquired (%a+) Units: (%d+)')
    if not zone_str then return end

    local amount = tonumber(amt_str)
    if amount ~= STANDARD_AMT and amount ~= BONUS_AMT then return end

    -- Sanity-check: message zone matches active zone
    if (zone_str == 'Apollyon') ~= (active_zone == APOLLYON) then
        windower.add_to_chat(8, 'LimbusHelper: Units message zone ('..zone_str..') does not match active zone — ignored.')
        return
    end

    -- Debounce: guard against duplicate lines firing within the same opening
    local now = os.time()
    if now - last_record_time < RECORD_COOLDOWN then return end
    last_record_time = now

    -- Ignore if not near a known chest (e.g. ??? giving 3000)
    local me = windower.ffxi.get_mob_by_target('me')
    if me then
        local chests = active_zone == APOLLYON and APOLLYON_CHESTS or TEMENOS_CHESTS
        local min_d2 = math.huge
        for _, pos in pairs(chests) do
            local dx = me.x - pos.x
            local dy = me.y - pos.y
            local dz = me.z - pos.z
            local d2 = dx*dx + dy*dy + dz*dz
            if d2 < min_d2 then min_d2 = d2 end
        end
        if min_d2 > CHEST_DIST * CHEST_DIST then return end
    end

    local sector = detect_sector()
    if sector then
        record_chest(sector, amount)
    else
        windower.add_to_chat(8,
            'LimbusHelper: Chest reward ('..amount
            ..') detected but could not read position. '
            ..'Use //lh sector <'..sector_list_str()
            ..'> '..amount..' to log manually.')
    end
end)

-- ---------------------------------------------------------------------------
-- Zone change
-- ---------------------------------------------------------------------------
windower.register_event('zone change', function(new_zone, old_zone)
    if zone_name[new_zone] then
        active_zone = new_zone
        manual_show = false  -- active zone drives display
        if state then load_state() end
        refresh_display()
    else
        active_zone = nil
        if manual_show then
            refresh_display()  -- keep overlay visible with both zones
        else
            disp:hide()
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Load (already logged in when addon loads)
-- ---------------------------------------------------------------------------
windower.register_event('load', function()
    init_player_state()
    if not state then return end  -- player not yet available; login event will handle it
    local zone = windower.ffxi.get_info().zone
    if zone_name[zone] then
        active_zone = zone
        load_state()
        refresh_display()
    end
end)

-- ---------------------------------------------------------------------------
-- Login (fires when a character enters the world — catches the case where the
-- addon loaded before the player finished logging in, which would have caused
-- init_player_state() to defer above).
-- ---------------------------------------------------------------------------
windower.register_event('login', function()
    state = nil  -- clear any partial/default state so init can run fresh
    init_player_state()
    if not state then return end
    local zone = windower.ffxi.get_info().zone
    if zone_name[zone] then
        active_zone = zone
        load_state()
        refresh_display()
    end
end)

-- ---------------------------------------------------------------------------
-- Addon commands
-- ---------------------------------------------------------------------------
windower.register_event('addon command', function(cmd, ...)
    local args = {...}
    cmd = cmd and cmd:lower() or 'help'

    -- ---- reset ----
    if cmd == 'reset' then
        if active_zone then
            reset_zone(active_zone)
            log('Chest tracking reset for '..zone_name[active_zone]..'.')
        else
            log('Not currently in Apollyon or Temenos.')
        end

    -- ---- debug ----
    elseif cmd == 'debug' then
        debug_mode = not debug_mode
        log('Debug mode: '..(debug_mode and 'ON (logging all incoming text)' or 'OFF')..'.')

    -- ---- pos ----
    elseif cmd == 'pos' then
        local me = windower.ffxi.get_mob_by_target('me')
        if me then
            log(('Position  x=%.2f  y=%.2f  z=%.2f'):format(me.x, me.y, me.z))
            log('Detected sector: '..(detect_sector() or 'unknown'))
        else
            log('Cannot read player position.')
        end

    -- ---- sector (manual toggle) ----
    elseif cmd == 'sector' then
        local s = (args[1] or ''):upper()

        local zone_id = active_zone or zone_for_sector(s)
        if not zone_id then
            log('Unknown sector "'..s..'". Valid: Apollyon: NW NE SW SE  |  Temenos: N E W C')
        elseif not valid_sector(s, zone_id) then
            log('Valid sectors for '..zone_name[zone_id]..': '..sector_list_str(zone_id))
        else
            local current = tracking[zone_id][s]
            if current == 'std' then
                tracking[zone_id][s] = nil
                save_state()
                log(zone_name[zone_id]..' '..s..' marked Unopened.')
                refresh_display()
            else
                -- Use record_chest only when in the zone (it reads position etc.);
                -- outside the zone just set the state directly.
                if active_zone == zone_id then
                    record_chest(s, STANDARD_AMT)
                else
                    tracking[zone_id][s] = 'std'
                    save_state()
                    log(zone_name[zone_id]..' '..s..' marked Opened.')
                    refresh_display()
                end
            end
        end

    -- ---- show / hide ----
    elseif cmd == 'show' then
        manual_show = true
        refresh_display()

    elseif cmd == 'hide' then
        manual_show = false
        disp:hide()

    -- ---- help ----
    elseif cmd == 'help' or cmd == '' then
        windower.add_to_chat(167, 'LimbusHelper v'.._addon.version)
        windower.add_to_chat(167, '  //lh help                     - Show this help text')
        windower.add_to_chat(167, '  //lh reset                    - Reset tracking (auto-resets 5s after bonus)')
        windower.add_to_chat(167, '  //lh sector <sector>           - Toggle sector Opened/Unopened manually')
        windower.add_to_chat(167, '    Apollyon sectors: NW NE SW SE')
        windower.add_to_chat(167, '    Temenos  sectors: N  W  E  C')
        windower.add_to_chat(167, '  //lh pos                      - Print position and detected sector')
        windower.add_to_chat(167, '  //lh debug                    - Toggle verbose incoming-text logging')
        windower.add_to_chat(167, '  //lh show / hide              - Toggle the overlay')
		windower.add_to_chat(167, '  //lh lastbonus (lb)           - Re-mark the previous bonus sector')
		
	elseif cmd == 'lastbonus' or cmd == 'lb' then
		if not last_bonus then
			log('No bonus location recorded this session.')
		else
			local zname  = zone_name[last_bonus.zone_id]
			local sec    = last_bonus.sector
			tracking[last_bonus.zone_id][sec] = 'bonus'
			bonus_found = (active_zone == last_bonus.zone_id)
			save_state()
			refresh_display()
			log(zname..' '..sec..' restored as BONUS.')
		end

    -- ---- unknown ----
    else
        windower.add_to_chat(8, 'LimbusHelper: Unknown command "'..cmd..'". Type //lh help for usage.')
    end
end)

-- ---------------------------------------------------------------------------
-- Initialise if loaded while already inside a tracked zone.
-- If player is not yet available (addon auto-loaded before login), init_player_state()
-- returns nil; the login event handler will pick it up later.
-- ---------------------------------------------------------------------------
init_player_state()
if state then
    local initial_zone = windower.ffxi.get_info().zone
    if zone_name[initial_zone] then
        active_zone = initial_zone
        load_state()
        refresh_display()
    end
end
