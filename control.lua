local chores = require("chores")
local gui = require("gui")

local function init()
  storage.spiders = storage.spiders or {}
  storage.alerts = storage.alerts or {}
  storage.sites = storage.sites or {}
  chores.scan_turrets()
end
script.on_init(init)
script.on_configuration_changed(init)

-- keep a list of turrets so restocking doesn't have to search the map
local function on_turret_built(event) chores.add_turret(event.entity) end
for _, ev in pairs({"on_robot_built_entity", "script_raised_built", "script_raised_revive", "on_space_platform_built_entity"}) do
  if defines.events[ev] then
    script.on_event(defines.events[ev], on_turret_built,
      {{filter = "type", type = "ammo-turret"}, {filter = "type", type = "artillery-turret"}})
  end
end

script.on_nth_tick(30, function()
  chores.tick()
  for _, p in pairs(game.connected_players) do
    if p.gui.relative.sc_frame then gui.refresh(p) end
  end
end)

-- attacks on your stuff
local DEFENSE_TYPES = {"wall", "gate", "ammo-turret", "electric-turret", "fluid-turret", "artillery-turret",
  "radar", "electric-pole", "roboport", "mining-drill", "assembling-machine", "furnace", "lab",
  "container", "logistic-container", "transport-belt", "inserter", "pipe", "rocket-silo"}
local function type_filters(list)
  local f = {}
  for _, t in pairs(list) do f[#f + 1] = {filter = "type", type = t} end
  return f
end
script.on_event(defines.events.on_entity_damaged, chores.on_damaged, type_filters(DEFENSE_TYPES))

-- ghosts / deconstruction outside roboport coverage
script.on_event(defines.events.on_built_entity, function(event)
  local e = event.entity
  if not (e and e.valid) then return end
  if e.type == "entity-ghost" or e.type == "tile-ghost" then chores.on_build_order(e, e.force)
  else chores.add_turret(e) end
end, {{filter = "type", type = "entity-ghost"}, {filter = "type", type = "tile-ghost"},
      {filter = "type", type = "ammo-turret"}, {filter = "type", type = "artillery-turret"}})

script.on_event(defines.events.on_marked_for_deconstruction, function(event)
  local p = event.player_index and game.get_player(event.player_index)
  if p then chores.on_build_order(event.entity, p.force) end
end)

-- things destroyed outside roboport coverage leave ghosts: rebuild them like bots would
script.on_event(defines.events.on_post_entity_died, function(event)
  local g = event.ghost
  if g and g.valid then chores.on_build_order(g, g.force) end
end)

-- upgrade planner marks
script.on_event(defines.events.on_marked_for_upgrade, function(event)
  local p = event.player_index and game.get_player(event.player_index)
  local e = event.entity
  if e and e.valid then chores.on_build_order(e, p and p.force or e.force) end
end)

-- deconstruction planner drags (catches marked tiles, which have no event of their own)
script.on_event(defines.events.on_player_deconstructed_area, function(event)
  if event.alt then return end
  local p = game.get_player(event.player_index)
  if p then chores.on_deconstructed_area(event.surface, event.area, p.force) end
end)

-- you took control: pause chores for the selected spiders
script.on_event(defines.events.on_player_used_spidertron_remote, function(event)
  local p = game.get_player(event.player_index)
  if not p then return end
  local ok, sel = pcall(function() return p.spidertron_remote_selection end)
  for _, e in pairs(ok and sel or {}) do
    local s = e.valid and chores.get(e, false)
    if s and s.on then chores.manual(s) end
  end
end)

-- the pin tool from the panel: set home / restock point / shuttle stops by clicking a spot
local function on_pick(event)
  if event.item ~= "sc-pick-point" then return end
  local player = game.get_player(event.player_index)
  local pick = storage.picking and storage.picking[event.player_index]
  if not (player and pick) then return end
  local s = storage.spiders and storage.spiders[pick.unit]
  local e = s and s.entity
  if not (e and e.valid) then
    storage.picking[event.player_index] = nil
    player.clear_cursor()
    return
  end
  if event.surface.index ~= e.surface.index then
    player.create_local_flying_text{text = "Pick a spot on " .. e.surface.name .. ", where this spider is", create_at_cursor = true}
    return
  end
  local a = event.area
  local lt, rb = a.left_top or a[1], a.right_bottom or a[2]
  local p = {x = ((lt.x or lt[1]) + (rb.x or rb[1])) / 2, y = ((lt.y or lt[2]) + (rb.y or rb[2])) / 2}
  gui.set_point(s, pick.what, p, e.surface.index)
  storage.picking[event.player_index] = nil
  player.clear_cursor()
  player.print((e.entity_label or ("Spidertron #" .. e.unit_number)) .. ": " .. gui.POINT_NAMES[pick.what] ..
               string.format(" set to [gps=%d,%d,%s]", math.floor(p.x), math.floor(p.y), e.surface.name))
end
script.on_event(defines.events.on_player_selected_area, on_pick)
script.on_event(defines.events.on_player_alt_selected_area, on_pick)

-- the panel
script.on_event(defines.events.on_gui_opened, function(event)
  local e = event.entity
  if event.gui_type == defines.gui_type.entity and e and e.valid and e.type == "spider-vehicle" then
    gui.build(game.get_player(event.player_index), e)
  end
end)
script.on_event(defines.events.on_gui_checked_state_changed, gui.on_checked)
script.on_event(defines.events.on_gui_click, gui.on_click)

commands.add_command("chores", "List spiders doing chores and what they're up to", function(cmd)
  local p = cmd.player_index and game.get_player(cmd.player_index)
  local out = {}
  for _, s in pairs(storage.spiders or {}) do
    if s.entity.valid and s.on then
      out[#out + 1] = (s.entity.entity_label or ("Spidertron #" .. s.entity.unit_number)) .. ": " .. (s.status or s.state)
    end
  end
  local msg = #out > 0 and table.concat(out, "\n") or "No spiders are doing chores. Open a spidertron and tick \"Do chores automatically\"."
  if p then p.print(msg) else game.print(msg) end
end)
