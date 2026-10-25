-- Panel attached to the right side of every spidertron's window.
local chores = require("chores")
local G = {}

local function fmt(p) return p and string.format("%d, %d", math.floor(p.x), math.floor(p.y)) or "not set" end

local function opened_spider(player)
  local e = player.opened
  if e and e.object_name == "LuaEntity" and e.valid and e.type == "spider-vehicle" then return e end
end

local function info(s)
  local route = (s.route and #s.route or 0)
  return {
    home = "Home: " .. fmt(s.home),
    depot = "Restock at: " .. (s.depot and fmt(s.depot) or "home"),
    route = "Patrol: " .. (route > 0 and (route .. " saved posts") or "ring around home"),
    shuttle = "Shuttle: A " .. fmt(s.shuttle_a) .. "  |  B " .. fmt(s.shuttle_b),
  }
end

function G.build(player, entity)
  local rel = player.gui.relative
  if rel.sc_frame then rel.sc_frame.destroy() end
  local s = chores.get(entity, true)
  local frame = rel.add{type = "frame", name = "sc_frame", caption = "Spider chores", direction = "vertical",
    anchor = {gui = defines.relative_gui_type.spider_vehicle_gui, position = defines.relative_gui_position.right}}
  local inner = frame.add{type = "frame", name = "inner", style = "inside_shallow_frame_with_padding", direction = "vertical"}
  inner.add{type = "checkbox", name = "sc_on", state = s.on, caption = "[font=default-bold]Do chores automatically[/font]",
    tooltip = "Master switch for this spider. Driving it or using a remote pauses it for a bit."}
  inner.add{type = "checkbox", name = "sc_manage", state = s.manage and true or false,
    caption = "Manage my logistic requests",
    tooltip = "Adds a \"Spider chores #" .. entity.unit_number .. "\" logistic group to this spider with what its jobs need: its ammo, repair packs, construction robots, lamps, and the exact materials for each outpost it builds. Your own request sections are left alone. Untick to remove it."}
  inner.add{type = "line"}
  for _, job in ipairs(chores.JOBS) do
    if settings.global["sc-enable-" .. job].value then
      inner.add{type = "checkbox", name = "sc_job_" .. job, state = s.jobs[job] and true or false,
        caption = chores.JOB_NAMES[job], tooltip = {"sc-tip." .. job}}
    end
  end
  inner.add{type = "line"}
  local i = info(s)
  local PICK = "Pick the spot instead: puts a pin tool in your cursor. Click anywhere, on the map too, on this spider's planet."
  local function pick(flow, name) flow.add{type = "sprite-button", name = name, sprite = "item/sc-pick-point", style = "tool_button", tooltip = PICK} end
  inner.add{type = "label", name = "sc_home_l", caption = i.home}
  local fh = inner.add{type = "flow", direction = "horizontal"}
  fh.add{type = "button", name = "sc_home", caption = "Set home here",
    tooltip = "Its patch: where it guards and builds, and the centre for turrets, lamps and nest clearing. Also where it restocks unless you set a restock point."}
  pick(fh, "sc_pick_home")
  inner.add{type = "label", name = "sc_depot_l", caption = i.depot}
  local fd = inner.add{type = "flow", direction = "horizontal"}
  fd.add{type = "button", name = "sc_depot", caption = "Set restock here",
    tooltip = "Optional. Where it goes for ammo, repairs and building materials, e.g. your main factory, so home can be an outpost. Must be inside a logistic network that has the stuff."}
  pick(fd, "sc_pick_depot")
  fd.add{type = "button", name = "sc_depot_clear", caption = "Clear", tooltip = "Restock at home again."}
  inner.add{type = "label", name = "sc_route_l", caption = i.route}
  local f = inner.add{type = "flow", direction = "horizontal"}
  f.add{type = "button", name = "sc_route_save", caption = "Save waypoints as route",
    tooltip = "Optional. Shift-click waypoints with the spidertron remote, then press this to use them as guard posts instead of the ring around home."}
  f.add{type = "button", name = "sc_route_clear", caption = "Clear"}
  inner.add{type = "label", name = "sc_shuttle_l", caption = i.shuttle}
  local f2 = inner.add{type = "flow", direction = "horizontal"}
  f2.add{type = "button", name = "sc_shuttle_a", caption = "Set A here"}
  pick(f2, "sc_pick_a")
  f2.add{type = "button", name = "sc_shuttle_b", caption = "Set B here"}
  pick(f2, "sc_pick_b")
  f2.add{type = "button", name = "sc_shuttle_clear", caption = "Clear"}
  if s.shuttle_a and s.shuttle_b then
    local hint = inner.add{type = "label", caption = "[font=default-small]Ferry: in this spider's Logistics, fill in the [font=default-small-bold]Ferry A[/font] and [font=default-small-bold]Ferry B[/font] sections. A request loads at that stop; a request with max 0 drops it there.[/font]"}
    hint.style.single_line = false
    hint.style.maximal_width = 300
  end
  inner.add{type = "line"}
  inner.add{type = "label", name = "sc_status", caption = "Status: " .. (s.on and s.status or "Off")}
end

function G.refresh(player)
  local frame = player.gui.relative.sc_frame
  local e = opened_spider(player)
  if not (frame and e) then return end
  local s = chores.get(e, false)
  if not s then return end
  local inner = frame.inner
  local i = info(s)
  inner.sc_home_l.caption = i.home
  if inner.sc_depot_l then inner.sc_depot_l.caption = i.depot end
  inner.sc_route_l.caption = i.route
  inner.sc_shuttle_l.caption = i.shuttle
  inner.sc_status.caption = "Status: " .. (s.on and s.status or "Off")
end

function G.on_checked(event)
  local el = event.element
  if not (el and el.valid and el.name:sub(1, 3) == "sc_") then return end
  local player = game.get_player(event.player_index)
  local e = player and opened_spider(player)
  if not e then return end
  local s = chores.get(e, true)
  if el.name == "sc_manage" then
    s.manage = el.state
    if not s.manage then chores.clear_requests(s) end
  elseif el.name == "sc_on" then
    s.on = el.state
    if s.on then s.state, s.status = "idle", "Starting" else chores.stop(s) end
  else
    local job = el.name:match("^sc_job_(.+)$")
    if job then
      s.jobs[job] = el.state
      if not el.state and s.state ~= "manual" then chores.stop(s); s.status = s.on and "Idle" or "Off" end
    end
  end
  G.refresh(player)
end

-- what = "home", "depot", "a" or "b"
function G.set_point(s, what, p, surface_index)
  p = {x = p.x, y = p.y}
  if what == "home" then
    s.home, s.home_surface, s.lsec = p, surface_index, nil
  elseif what == "depot" then
    s.depot, s.depot_surface = p, surface_index
  elseif what == "a" then
    s.shuttle_a, s.shuttle_surface = p, surface_index
    chores.ferry_ensure(s)
  elseif what == "b" then
    s.shuttle_b, s.shuttle_surface = p, surface_index
    chores.ferry_ensure(s)
  end
end
G.POINT_NAMES = {home = "home", depot = "restock point", a = "shuttle stop A", b = "shuttle stop B"}

function G.on_click(event)
  local el = event.element
  if not (el and el.valid and el.name:sub(1, 3) == "sc_") then return end
  local player = game.get_player(event.player_index)
  local e = player and opened_spider(player)
  if not e then return end
  local s = chores.get(e, true)
  local here = {x = e.position.x, y = e.position.y}
  local n = el.name
  local picking = n:match("^sc_pick_(.+)$")
  if picking then
    storage.picking = storage.picking or {}
    storage.picking[player.index] = {unit = e.unit_number, what = picking}
    player.clear_cursor()
    local ok = player.cursor_stack and pcall(player.cursor_stack.set_stack, {name = "sc-pick-point", count = 1})
    if not ok then return end
    player.opened = nil
    player.create_local_flying_text{text = "Click the " .. G.POINT_NAMES[picking] .. " (press M to pick on the map)", create_at_cursor = true}
    return
  end
  if n == "sc_home" then
    G.set_point(s, "home", here, e.surface.index)
  elseif n == "sc_depot" then
    G.set_point(s, "depot", here, e.surface.index)
  elseif n == "sc_depot_clear" then
    s.depot, s.depot_surface = nil, nil
  elseif n == "sc_route_save" then
    local pts = {}
    for _, p in pairs(e.autopilot_destinations) do pts[#pts + 1] = {x = p.x, y = p.y} end
    if #pts < 2 then
      player.create_local_flying_text{text = "Queue at least 2 waypoints first (shift-click with the remote)", create_at_cursor = true}
      return
    end
    s.route, s.route_surface = pts, e.surface.index
    s.jobs.patrol = true
    if s.state == "patrol" then s.state = "idle" end
  elseif n == "sc_route_clear" then
    s.route = nil
    if s.state == "patrol" then chores.stop(s) end
  elseif n == "sc_shuttle_a" then
    G.set_point(s, "a", here, e.surface.index)
  elseif n == "sc_shuttle_b" then
    G.set_point(s, "b", here, e.surface.index)
  elseif n == "sc_shuttle_clear" then
    chores.ferry_set(s, nil)                -- keep your Ferry sections, just switch them off
    s.shuttle_a, s.shuttle_b = nil, nil
    if s.state == "shuttle" then chores.stop(s) end
  else
    return
  end
  G.build(player, e)      -- rebuild so checkboxes (e.g. patrol) reflect changes
end

return G
