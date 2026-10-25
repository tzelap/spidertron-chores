-- The brain: one small state machine per spider.
--   priority: resupply > defend > build > nests > lights > patrol / shuttle > go home
local lights = require("lights")
local C = {}

C.JOBS = {"defense", "resupply", "turrets", "builder", "lights", "nests", "patrol", "shuttle"}
C.JOB_NAMES = {
  defense = "Defend against attacks", resupply = "Restock when low", turrets = "Restock turrets", builder = "Build outposts",
  lights = "Put up lamps (homey)", nests = "Clear nearby nests", patrol = "Patrol / guard home", shuttle = "Shuttle A <-> B",
}

local SEC = 60
local function cfg(n) return settings.global["sc-" .. n].value end
local function on(s, job) return s.jobs[job] and cfg("enable-" .. job) end
local function dist2(a, b) local dx, dy = a.x - b.x, a.y - b.y return dx * dx + dy * dy end
local function dist(a, b) return math.sqrt(dist2(a, b)) end
local function gps(p, surface) return string.format("[gps=%d,%d,%s]", math.floor(p.x), math.floor(p.y), surface.name) end
local function label(e) return e.entity_label or ("Spidertron #" .. e.unit_number) end
-- problems go to the alert bar (bottom right, click to jump there), like the bots' own alerts
local ALERT_ICON = {type = "item", name = "spidertron"}
local function custom_alert_type() return defines.alert_type and defines.alert_type.custom end
local function clear_alert(entity)
  if not (entity and entity.valid) then return end
  for _, p in pairs(entity.force.connected_players or {}) do
    pcall(p.remove_alert, {entity = entity, type = custom_alert_type()})
  end
end
local function alert(force, entity, text)
  if not (entity and entity.valid) then force.print(text); return end
  local shown = false
  for _, p in pairs(force.connected_players or {}) do
    pcall(p.remove_alert, {entity = entity, type = custom_alert_type()})
    if pcall(p.add_custom_alert, entity, ALERT_ICON, text, true) then shown = true end
  end
  if not shown then force.print(text) end
end
local function say(s, text)
  alert(s.entity.force, s.entity, label(s.entity) .. ": " .. text)
  s.alert_until = game.tick + 2 * 60 * 60          -- spider alerts clear themselves after 2 minutes
end

------------------------------------------------------------------------------------------
-- what the spider has
local function ammo(e)
  local inv = e.get_inventory(defines.inventory.spider_ammo)
  if not inv then return 0, 0 end
  local n = 0
  for _, it in pairs(inv.get_contents()) do n = n + it.count end
  return n, #inv
end

local function has_bots(e)
  local grid = e.grid
  if not grid then return false end
  for _, eq in pairs(grid.equipment) do
    if eq.type == "roboport-equipment" then return true end
  end
  return false
end

local function health(e) return e.get_health_ratio() or 1 end

local function low(s)
  local e = s.entity
  if health(e) < cfg("low-health") then return true end
  local n = ammo(e)
  return s.ammo_full > 0 and n < s.ammo_full * cfg("low-ammo")
end

local function combat_ready(s, min_health)
  local e = s.entity
  local n, slots = ammo(e)
  return slots > 0 and n > 0 and not low(s) and health(e) >= (min_health or 0)
end

------------------------------------------------------------------------------------------
-- weapon range: the longest reach among guns that actually have matching ammo loaded
-- (gun i fires from ammo slot i). 0 = nothing to shoot with.
local FOES = {"unit", "spider-unit", "unit-spawner", "turret", "segmented-unit"}

local function weapon_range(e)
  local guns = e.prototype.indexed_guns
  local inv = e.get_inventory(defines.inventory.spider_ammo)
  if not (guns and inv) then return 0 end
  local best = 0
  for i, gun in pairs(guns) do
    local stack = inv[i]
    local ap = gun.attack_parameters
    if ap and stack and stack.valid_for_read then
      local ammo = stack.prototype
      local cat = ammo.ammo_category and ammo.ammo_category.name
      local fits = false
      for _, c in pairs(ap.ammo_categories or {}) do if c == cat then fits = true end end
      if fits then
        local at = ammo.get_ammo_type("vehicle") or ammo.get_ammo_type()
        local r = ap.range * ((at and at.range_modifier) or 1)
        if r > best then best = r end
      end
    end
  end
  return best
end

------------------------------------------------------------------------------------------
-- movement
local function go(s, pos)
  local e = s.entity
  e.autopilot_destination = pos
  s.dest = {x = pos.x, y = pos.y}
  s.moved_tick, s.moved_pos = game.tick, {x = e.position.x, y = e.position.y}
end

local function arrived(s, pos, r)
  local e = s.entity
  local d = dist(e.position, pos)
  if d <= (r or 6) then return true end
  return e.autopilot_destination == nil and d <= 20      -- it stopped close enough (blocked by buildings)
end

-- true if it has been trying to walk somewhere but hasn't moved for 30 s
local function stuck(s)
  local e = s.entity
  if not e.autopilot_destination then return false end
  if dist(e.position, s.moved_pos or e.position) > 2 then
    s.moved_tick, s.moved_pos = game.tick, {x = e.position.x, y = e.position.y}
    return false
  end
  return game.tick - (s.moved_tick or game.tick) > 30 * SEC
end

-- Fight from range: stand at ~85% of weapon reach from the nearest enemy around `focus`,
-- on the side the spider is already on. Returns "fight", "clear" (no enemies) or "no-ammo".
local function engage(s, focus, target)
  local e = s.entity
  local range = weapon_range(e)
  if range <= 0 then return "no-ammo" end
  local foe = (target and target.valid) and target or nil
  if not foe then
    local near = e.surface.find_entities_filtered{position = focus, radius = 60, type = FOES, force = "enemy"}
    local bd
    for _, f in pairs(near) do
      local d2 = dist2(f.position, e.position)
      if not bd or d2 < bd then foe, bd = f, d2 end
    end
  end
  if not foe then return "clear" end
  local fp, sp = foe.position, e.position
  local d = dist(fp, sp)
  local want = math.max(8, range * 0.85)
  if math.abs(d - want) > 4 then
    local dx, dy = sp.x - fp.x, sp.y - fp.y
    if d < 0.5 then dx, dy, d = 0, 1, 1 end
    local stand = {x = fp.x + dx / d * want, y = fp.y + dy / d * want}
    if not s.dest or dist(s.dest, stand) > 3 then go(s, stand) end
  elseif e.autopilot_destination then
    e.autopilot_destination = nil          -- in range: stop and shoot
  end
  return "fight"
end
C.weapon_range = weapon_range

local function set_state(s, state, task, status)
  if state ~= "pack" and state ~= "build" then s.build_needs = nil end
  if s.ferry_active and state ~= "shuttle" and C.ferry_set then C.ferry_set(s, nil) end
  s.state, s.task, s.status = state, task or {}, status or state
  s.state_tick = game.tick
end

-- guard posts: your saved route if there is one, otherwise a ring around home
local function guard_posts(s)
  local e = s.entity
  if s.route and #s.route >= 2 and s.route_surface == e.surface.index then return s.route, "route" end
  if not (s.home and s.home_surface == e.surface.index) then return nil end
  local n, r = cfg("guard-posts"), cfg("guard-radius")
  if not s.ring or s.ring_n ~= n or s.ring_r ~= r or s.ring_x ~= s.home.x or s.ring_y ~= s.home.y then
    local ring = {}
    for i = 0, n - 1 do
      local a = 2 * math.pi * i / n
      ring[#ring + 1] = {x = s.home.x + r * math.cos(a), y = s.home.y + r * math.sin(a)}
    end
    s.ring, s.ring_n, s.ring_r, s.ring_x, s.ring_y = ring, n, r, s.home.x, s.home.y
  end
  return s.ring, "ring"
end
C.guard_posts = guard_posts

local function home_or_idle(s)
  -- a guarding spider goes back to its rounds instead of walking home first
  if on(s, "patrol") and guard_posts(s) then
    s.entity.autopilot_destination = nil
    set_state(s, "idle", nil, "Back to guard duty")
    return
  end
  if s.home and s.home_surface == s.entity.surface.index then
    set_state(s, "returning", nil, "Going home")
    go(s, s.home)
  else
    s.entity.autopilot_destination = nil
    set_state(s, "idle", nil, "Idle")
  end
end

-- where it restocks: its restock point if you set one (e.g. your main factory), else home
local function depot(s)
  local e = s.entity
  if s.depot and s.depot_surface == e.surface.index then return s.depot end
  if s.home and s.home_surface == e.surface.index then return s.home end
end
C.depot = depot

------------------------------------------------------------------------------------------
-- managed logistic requests: one logistic group per spider, "Spider chores #<n>",
-- so your own request sections are never touched
local function group_name(e) return "Spider chores #" .. e.unit_number end

local function our_section(e, create)
  local secs = e.get_logistic_sections()
  if not secs then return nil end
  local name = group_name(e)
  for _, sec in pairs(secs.sections) do
    if sec.valid and sec.group == name then return sec end
  end
  if create then return secs.add_section(name) end
end

local function key(name, quality) return name .. "/" .. (quality or "normal") end

-- Ferry: two request sections the player fills in ("Ferry A #n", "Ferry B #n").
-- Only the section for the stop the spider is standing at is switched on.
local function ferry_name(e, which) return "Ferry " .. string.upper(which) .. " #" .. e.unit_number end

function C.ferry_section(e, which, create)
  local secs = e.get_logistic_sections()
  if not secs then return nil end
  local name = ferry_name(e, which)
  for _, sec in pairs(secs.sections) do
    if sec.valid and sec.group == name then return sec end
  end
  if create then
    local sec = secs.add_section(name)
    if sec then sec.active = false end
    return sec
  end
end

function C.ferry_ensure(s)
  if not (s.shuttle_a and s.shuttle_b) then return end
  C.ferry_section(s.entity, "a", true)
  C.ferry_section(s.entity, "b", true)
end

-- which = "a", "b" or nil (both off)
function C.ferry_set(s, which)
  local e = s.entity
  if not (e and e.valid) then return end
  for _, w in pairs({"a", "b"}) do
    local sec = C.ferry_section(e, w, false)
    if sec then pcall(function() sec.active = (w == which) end) end
  end
  s.ferry_active = which
end

local function add_need(t, name, quality, count)
  if not (name and prototypes.item[name]) or count <= 0 then return end
  local k = key(name, quality)
  local cur = t[k]
  if cur then cur.count = math.max(cur.count, count) else t[k] = {name = name, quality = quality or "normal", count = count} end
end

-- the ammo type it's using: whatever fills most of its gun slots (remembered once seen)
local function ammo_item(s)
  local inv = s.entity.get_inventory(defines.inventory.spider_ammo)
  if not inv then return nil, 0 end
  local best, bc = nil, 0
  for _, it in pairs(inv.get_contents()) do
    if it.count > bc then best, bc = it, it.count end
  end
  if best then s.ammo_item = {name = best.name, quality = best.quality or "normal"} end
  return s.ammo_item, #inv
end

function C.desired(s)
  local want = {}
  local e = s.entity
  if not s.manage then return want end
  local bots = has_bots(e)
  if on(s, "defense") or on(s, "nests") or on(s, "resupply") then
    local it, slots = ammo_item(s)
    if it and slots > 0 then
      add_need(want, it.name, it.quality, slots * prototypes.item[it.name].stack_size)
    end
  end
  if bots then
    add_need(want, "repair-pack", "normal", cfg("request-repair"))
    if on(s, "builder") or on(s, "lights") then add_need(want, "construction-robot", "normal", cfg("request-robots")) end
  end
  if on(s, "lights") then
    add_need(want, "small-lamp", "normal", cfg("request-lamps"))
    if cfg("light-poles") then add_need(want, cfg("light-pole"), "normal", cfg("request-poles")) end
  end
  if on(s, "turrets") then
    local n = 0
    for _, k in pairs(s.turret_kinds or {}) do
      if n >= 4 then break end
      local amount
      if k.art then
        amount = cfg("art-request")                                   -- artillery: shells
      else
        local ip = prototypes.item[k.name]
        amount = math.ceil(cfg("request-turret-stacks") * (ip and ip.stack_size or 1))   -- others: stacks
      end
      add_need(want, k.name, k.quality, amount)
      n = n + 1
    end
  end
  for _, n in pairs(s.build_needs or {}) do
    local k = key(n.name, n.quality)
    if want[k] then want[k].count = want[k].count + n.count else want[k] = {name = n.name, quality = n.quality, count = n.count} end
  end
  return want
end

-- write the group only when it changed
function C.sync_requests(s)
  local e = s.entity
  local want = C.desired(s)
  local list, parts = {}, {}
  for k, n in pairs(want) do parts[#parts + 1] = k .. "=" .. n.count end
  table.sort(parts)
  local sig = table.concat(parts, ",")
  if sig == s.req_sig then return end
  local sec = our_section(e, next(want) ~= nil)
  if not sec then s.req_sig = sig; return end
  local ks = {}
  for k in pairs(want) do ks[#ks + 1] = k end
  table.sort(ks)
  for _, k in ipairs(ks) do
    local n = want[k]
    list[#list + 1] = {value = {type = "item", name = n.name, quality = n.quality, comparator = "="}, min = n.count}
  end
  local ok = pcall(function() sec.filters = list end)
  if ok then s.req_sig = sig end
end

function C.clear_requests(s)
  local e = s.entity
  if not (e and e.valid) then return end
  local sec = our_section(e, false)
  if sec then
    pcall(function() sec.filters = {} end)
    local secs = e.get_logistic_sections()
    if secs then pcall(secs.remove_section, sec.index) end
  end
  s.req_sig = nil
end

-- what the ghosts / tile ghosts at a site are made of
local function site_needs(surface, area, force)
  local needs = {}
  for _, g in pairs(surface.find_entities_filtered{area = area, type = {"entity-ghost", "tile-ghost"}, force = force}) do
    local proto = g.ghost_prototype
    local items = proto and proto.items_to_place_this
    local it = items and items[1]
    if it then
      local q = g.quality and g.quality.name or "normal"
      if g.type == "tile-ghost" then q = "normal" end
      local k = key(it.name, q)
      local cur = needs[k]
      if cur then cur.count = cur.count + it.count else needs[k] = {name = it.name, quality = q, count = it.count} end
    end
  end
  return needs
end

local function missing(e, needs)
  local inv = e.get_inventory(defines.inventory.spider_trunk)
  local out = {}
  for _, n in pairs(needs) do
    local have = inv and inv.get_item_count({name = n.name, quality = n.quality}) or 0
    if have < n.count then out[#out + 1] = {name = n.name, quality = n.quality, short = n.count - have} end
  end
  return out
end
C.site_needs, C.missing = site_needs, missing

------------------------------------------------------------------------------------------
-- world jobs, shared by all spiders: attack alerts and outpost build sites
local function ensure()
  storage.spiders = storage.spiders or {}
  storage.alerts = storage.alerts or {}
  storage.sites = storage.sites or {}
end

local function release_alert(s, handled)
  local key = s.task and s.task.alert
  local a = key and storage.alerts[key]
  if a then
    a.assigned[s.entity.unit_number] = nil
    if handled then a.handled = game.tick end      -- only a NEW hit after this sends someone again
  end
end

function C.on_damaged(event)
  if not cfg("enable-defense") then return end
  ensure()
  local e, attacker = event.entity, event.force
  if not (e and e.valid and attacker) then return end
  if not e.force.is_enemy(attacker) then return end
  local p = e.position
  local key = e.surface.index .. ":" .. e.force.index .. ":" .. math.floor(p.x / 32) .. "," .. math.floor(p.y / 32)
  local a = storage.alerts[key]
  if a then
    a.tick = game.tick
  else
    storage.alerts[key] = {surface = e.surface.index, force = e.force.index, pos = {x = p.x, y = p.y},
                           tick = game.tick, assigned = {}}
  end
end

local function covered_by_base(surface, force, p)
  for _, net in pairs(surface.find_logistic_networks_by_construction_area(p, force)) do
    for _, cell in pairs(net.cells) do
      if not cell.mobile then return true end
    end
  end
  return false
end

-- force = the player's force (ghosts carry it; for deconstruction marks it comes from the player)
function C.add_site(surface, p, force)
  if not cfg("enable-builder") then return end
  if not (surface and force) then return end
  ensure()
  local key = surface.index .. ":" .. math.floor(p.x / 32) .. "," .. math.floor(p.y / 32)
  local site = storage.sites[key]
  if not site then
    site = {surface = surface.index, force = force and force.index, cx = math.floor(p.x / 32), cy = math.floor(p.y / 32),
            sx = 0, sy = 0, n = 0, checked = false}
    storage.sites[key] = site
  end
  site.force = site.force or (force and force.index)
  site.sx, site.sy, site.n = site.sx + p.x, site.sy + p.y, site.n + 1
  site.pos = {x = site.sx / site.n, y = site.sy / site.n}
  site.scan, site.eval, site.warned = nil, nil, nil       -- something new to look at
end

function C.on_build_order(entity, force)
  if entity and entity.valid then C.add_site(entity.surface, entity.position, force) end
end

-- a deconstruction planner drag: one site per 32x32 block that has marked entities or tiles
-- (marked tiles don't fire their own event)
function C.on_deconstructed_area(surface, area, force)
  if not (cfg("enable-builder") and surface and force) then return end
  local lt, rb = area.left_top or area[1], area.right_bottom or area[2]
  local x0, y0 = math.floor((lt.x or lt[1]) / 32), math.floor((lt.y or lt[2]) / 32)
  local x1, y1 = math.floor((rb.x or rb[1]) / 32), math.floor((rb.y or rb[2]) / 32)
  if (x1 - x0 + 1) * (y1 - y0 + 1) > 400 then return end         -- huge drags: per-entity events cover those
  for cx = x0, x1 do
    for cy = y0, y1 do
      local box = {{cx * 32, cy * 32}, {cx * 32 + 32, cy * 32 + 32}}
      local ok, n = pcall(surface.count_tiles_filtered, {area = box, to_be_deconstructed = true, limit = 1})
      if ok and n > 0 then C.add_site(surface, {x = cx * 32 + 16, y = cy * 32 + 16}, force) end
    end
  end
end

local function site_area(site)
  local x0, y0 = site.cx * 32, site.cy * 32
  return {{x0 - 8, y0 - 8}, {x0 + 40, y0 + 40}}
end

-- marked for removal: entities (not the stand-in proxies of marked tiles) plus the tiles themselves
local function decon_count(surface, area)
  local n = surface.count_entities_filtered{area = area, to_be_deconstructed = true}
          - surface.count_entities_filtered{area = area, type = "deconstructible-tile-proxy"}
  local ok, tiles = pcall(surface.count_tiles_filtered, {area = area, to_be_deconstructed = true})
  return math.max(0, n) + (ok and tiles or 0)
end

local function site_remaining(surface, site, force)
  local area = site_area(site)
  return surface.count_entities_filtered{area = area, type = {"entity-ghost", "tile-ghost"}, force = force}
       + surface.count_entities_filtered{area = area, to_be_upgraded = true, force = force}
       + decon_count(surface, area)
end

------------------------------------------------------------------------------------------
-- The builder works like construction bots: it only takes work inside its work area
-- around home, and only ghosts it has the items for (or can fetch from its home network).
local function trunk(e) return e.get_inventory(defines.inventory.spider_trunk) end

-- what a ghost or an upgrade-marked entity turns into: key, prototype, quality name
local function job_kind(x)
  if x.type == "entity-ghost" or x.type == "tile-ghost" then
    local q = (x.type ~= "tile-ghost" and x.quality and x.quality.name) or "normal"
    return (x.ghost_name or "?") .. "/" .. q, x.ghost_prototype, q
  end
  local ok, target, tq = pcall(x.get_upgrade_target)
  if ok and target then
    local q = tq and tq.name or "normal"
    return "upgrade:" .. target.name .. "/" .. q, target, q
  end
end

local function site_jobs(surface, area, force)
  local list = surface.find_entities_filtered{area = area, type = {"entity-ghost", "tile-ghost"}, force = force}
  for _, u in pairs(surface.find_entities_filtered{area = area, to_be_upgraded = true, force = force}) do list[#list + 1] = u end
  return list
end

-- one look at a site: each kind of job (ghost or upgrade), how many, and the items that can do it
local function scan_site(surface, site, force)
  local area = site_area(site)
  local kinds, ghosts = {}, 0
  for _, g in pairs(site_jobs(surface, area, force)) do
    local k, proto, q = job_kind(g)
    if k then
      local kind = kinds[k]
      if not kind then
        kind = {n = 0, q = q, items = {}}
        for _, it in pairs(proto and proto.items_to_place_this or {}) do
          kind.items[#kind.items + 1] = {name = it.name, count = it.count}
        end
        kinds[k] = kind
      end
      kind.n = kind.n + 1
      ghosts = ghosts + 1
    end
  end
  return {kinds = kinds, ghosts = ghosts, decon = decon_count(surface, area), tick = game.tick}
end

local function get_scan(surface, site, force, max_age)
  if not site.scan or game.tick - site.scan.tick > (max_age or 5 * SEC) then
    site.scan = scan_site(surface, site, force)
  end
  return site.scan
end

-- how many jobs at the site it can do with what's in its trunk right now
-- (second result: the ghost kinds it has items for)
local function can_do(e, scan)
  local inv = trunk(e)
  if not inv then return 0, {} end
  local n, ok = 0, {}
  for k, kind in pairs(scan.kinds) do
    for _, it in pairs(kind.items) do
      if inv.get_item_count({name = it.name, quality = kind.q}) >= it.count then
        n, ok[k] = n + kind.n, true
        break
      end
    end
  end
  if scan.decon > 0 and inv.count_empty_stacks() > 0 then n = n + scan.decon end
  return n, ok
end

-- everything the site's ghosts are made of, for managed requests
local function scan_needs(scan)
  local needs = {}
  for _, kind in pairs(scan.kinds) do
    local it = kind.items[1]
    if it then
      local k = key(it.name, kind.q)
      local c = it.count * kind.n
      local cur = needs[k]
      if cur then cur.count = cur.count + c else needs[k] = {name = it.name, quality = kind.q, count = c} end
    end
  end
  return needs
end

-- the base's logistic network at its home (not its own personal one)
local function fixed_net(net)
  if not (net and net.valid) then return false end
  for _, cell in pairs(net.cells) do
    if not cell.mobile then return true end        -- has a real roboport
  end
  return false
end

local function home_network(s)
  local e = s.entity
  local d = depot(s)
  if not d then return nil end
  local net = e.surface.find_logistic_network_by_position(d, e.force)
  if fixed_net(net) then return net end
  for _, n in pairs(e.surface.find_logistic_networks_by_construction_area(d, e.force)) do
    if fixed_net(n) then return n end
  end
end

-- the missing items its home network actually has in stock
local function fetchable(s, short)
  if #short == 0 then return short end
  local net = home_network(s)
  if not net then return {} end
  local out = {}
  for _, m in pairs(short) do
    if net.get_item_count({name = m.name, quality = m.quality}) > 0 then out[#out + 1] = m end
  end
  return out
end

local function in_zone(s, site)
  local r = cfg("build-radius")
  if r <= 0 then return true end
  local center = (s.home and s.home_surface == site.surface) and s.home or s.entity.position
  return dist2(center, site.pos) <= r * r
end

-- let go of its site; skip = seconds before THIS spider looks at it again
local function release_site(s, skip)
  local site = s.task and s.task.site and storage.sites[s.task.site]
  if not site then return end
  site.taken = nil
  if skip then
    site.skip_for = site.skip_for or {}
    site.skip_for[s.entity.unit_number] = game.tick + skip * SEC
  end
end

local function short_text(short)
  local names = {}
  for i, m in ipairs(short) do
    if i > 5 then names[#names + 1] = "..."; break end
    names[#names + 1] = m.short .. "x [item=" .. m.name .. "]"
  end
  return table.concat(names, " ")
end

-- drop alerts that went quiet and sites that are done or that the base's own bots can reach
local function tidy_world()
  local now = game.tick
  for key, a in pairs(storage.alerts) do
    if now - a.tick > 60 * SEC and next(a.assigned) == nil then storage.alerts[key] = nil end
  end
  for key, site in pairs(storage.sites) do
    local surface = game.get_surface(site.surface)
    local force = site.force and game.forces[site.force]
    if not (surface and force) then
      storage.sites[key] = nil
    elseif not site.checked or (now + site.cx) % (10 * SEC) < 30 then
      site.checked = true
      if covered_by_base(surface, force, site.pos) or site_remaining(surface, site, force) == 0 then
        if not site.taken then storage.sites[key] = nil end
      end
    end
  end
end

------------------------------------------------------------------------------------------
-- choosing work
local BUSY_FOR_DEFENSE = {resupply = true, defend = true, manual = true}
local BUSY_FOR_BUILD = {resupply = true, defend = true, build = true, pack = true, nests = true, turrets = true,
                        manual = true, shuttle = true, lights = true}
-- free to build: idle, walking home, or standing guard at a post (not mid-walk between posts)
local function free_for_build(s)
  if BUSY_FOR_BUILD[s.state] then return false end
  if s.state == "patrol" and not (s.task and s.task.phase == "wait") then return false end
  return true
end

local function dispatch(spiders)
  local now = game.tick
  -- attacks: send the nearest ready spiders
  for key, a in pairs(storage.alerts) do
    if now - a.tick < 30 * SEC and a.tick > (a.handled or -1) then
      local count = 0
      for _ in pairs(a.assigned) do count = count + 1 end
      local want = cfg("defense-count") - count
      local range2 = cfg("defense-range") ^ 2
      while want > 0 do
        local best, bd
        for _, s in pairs(spiders) do
          local e = s.entity
          if s.on and on(s, "defense") and not BUSY_FOR_DEFENSE[s.state]
             and e.surface.index == a.surface and e.force.index == a.force and combat_ready(s) then
            local d2 = dist2(e.position, a.pos)
            if d2 <= range2 and (not bd or d2 < bd) then best, bd = s, d2 end
          end
        end
        if not best then break end
        if best.state == "build" or best.state == "pack" then
          local site = storage.sites[best.task.site]; if site then site.taken = nil end
        end
        a.assigned[best.entity.unit_number] = true
        set_state(best, "defend", {alert = key, pos = a.pos, quiet = now}, "Defending " .. gps(a.pos, best.entity.surface))
        go(best, a.pos)
        want = want - 1
      end
    end
  end
  -- outpost build sites, picked the way construction bots pick work: a spider only takes a
  -- site inside its work area, and only if it carries something that can be built there
  -- (or, with managed requests on, its home network has some of what's missing)
  for key, site in pairs(storage.sites) do
    if not site.taken and (site.skip_until or 0) <= now and site.force and (site.eval or 0) <= now then
      site.eval = now + 2 * SEC
      local surface = game.get_surface(site.surface)
      local force = game.forces[site.force]
      -- spiders that could take it at all; a site nobody's work area reaches is never scanned
      local cands = {}
      if surface and force and site.pos then
        for _, s in pairs(spiders) do
          local e = s.entity
          if s.on and on(s, "builder") and free_for_build(s) and e.surface.index == site.surface
             and e.force.index == site.force and in_zone(s, site)
             and (not site.skip_for or (site.skip_for[e.unit_number] or 0) <= now) and has_bots(e) then
            cands[#cands + 1] = s
          end
        end
      end
      if #cands == 0 then site.eval = now + 10 * SEC end
      local scan = #cands > 0 and get_scan(surface, site, force)
      if scan and scan.ghosts + scan.decon > 0 then
        local best, bd, mode
        for _, s in pairs(cands) do
          local e = s.entity
          local m
          if s.manage and #fetchable(s, missing(e, scan_needs(scan))) > 0 then m = "pack"
          elseif can_do(e, scan) > 0 then m = "build" end
          if m then
            local d2 = dist2(e.position, site.pos)
            if not bd or d2 < bd then best, bd, mode = s, d2, m end
          end
        end
        if best then
          site.taken = best.entity.unit_number
          local e = best.entity
          if mode == "pack" then
            -- fetch the materials first: request them, wait at home, then go
            best.build_needs = scan_needs(scan)
            local inv = trunk(e)
            set_state(best, "pack", {site = key, since = now, sig = inv and inv.get_item_count() or 0, stable = now},
                      "Packing materials for " .. gps(site.pos, e.surface))
            C.sync_requests(best)
            go(best, depot(best))
          else
            set_state(best, "build", {site = key, last = math.huge, progress = now},
                      "Building at " .. gps(site.pos, e.surface))
            go(best, site.pos)
          end
        elseif not site.warned and scan.ghosts > 0 then
          -- like the bots' "missing materials" alert, once per site, on one of its ghosts
          site.warned = true
          local g = site_jobs(surface, site_area(site), force)[1]
          alert(force, g, "Spider chores: these need items none of your builder spiders carry (or can get from their restock point).")
        end
      end
    end
  end
end

------------------------------------------------------------------------------------------
-- turret restocking
local TURRET_TYPES = {["ammo-turret"] = true, ["artillery-turret"] = true}

function C.add_turret(e)
  if e and e.valid and TURRET_TYPES[e.type] then
    storage.turrets = storage.turrets or {}
    storage.turrets[e.unit_number] = e
  end
end

function C.scan_turrets()
  storage.turrets = {}
  for _, surf in pairs(game.surfaces) do
    for _, e in pairs(surf.find_entities_filtered{type = {"ammo-turret", "artillery-turret"}}) do C.add_turret(e) end
  end
end

local cat_cache = {}
local function turret_cats(e)
  local c = cat_cache[e.name]
  if c then return c end
  c = {}
  local proto = e.prototype
  local function take(ap) for _, x in pairs(ap and ap.ammo_categories or {}) do c[x] = true end end
  take(proto.attack_parameters)
  for _, g in pairs(proto.indexed_guns or {}) do take(g.attack_parameters) end
  cat_cache[e.name] = c
  return c
end

local function turret_inv(e)
  return e.get_inventory(e.type == "artillery-turret" and defines.inventory.artillery_turret_ammo
                          or defines.inventory.turret_ammo)
end

-- restock threshold and fill level, in items, for this turret and the ammo it uses.
-- Artillery counts shells; everything else counts stacks of its ammo (stack sizes differ a lot).
local function turret_levels(e, ammo_name)
  if e.type == "artillery-turret" then
    local lo, fill = cfg("art-low"), cfg("art-fill")
    return lo, math.max(lo, fill)
  end
  local ip = ammo_name and prototypes.item[ammo_name]
  local stack = ip and ip.stack_size or 1
  local lo = math.max(1, math.floor(cfg("turret-low-stacks") * stack + 0.5))
  local fill = math.max(lo, math.floor(cfg("turret-fill-stacks") * stack + 0.5))
  return lo, fill
end

-- current ammo in a turret (name, quality, count) or nil
local function turret_ammo(e)
  local inv = turret_inv(e)
  if not inv then return nil, 0 end
  local best, total = nil, 0
  for _, it in pairs(inv.get_contents()) do
    total = total + it.count
    if not best or it.count > best.count then best = it end
  end
  return best, total
end

-- pick ammo from the spider's trunk for this turret: same as loaded if possible, else any that fits
local function pick_ammo(s, turret)
  local inv = s.entity.get_inventory(defines.inventory.spider_trunk)
  if not inv then return nil end
  local cur = turret_ammo(turret)
  if cur and inv.get_item_count({name = cur.name, quality = cur.quality}) > 0 then
    return {name = cur.name, quality = cur.quality or "normal"}
  end
  if cur then return nil end                 -- don't mix ammo types in one turret
  local cats, best, bc = turret_cats(turret), nil, 0
  for _, it in pairs(inv.get_contents()) do
    local ip = prototypes.item[it.name]
    local cat = ip and ip.type == "ammo" and ip.ammo_category and ip.ammo_category.name
    if cat and cats[cat] and it.count > bc then best, bc = {name = it.name, quality = it.quality or "normal"}, it.count end
  end
  return best
end

-- low turrets this spider can top up, in a short walking order
local function turret_run(s)
  local e = s.entity
  local r2 = cfg("turret-radius") ^ 2
  local low, kinds = {}, {}
  for un, t in pairs(storage.turrets or {}) do
    if not t.valid then
      storage.turrets[un] = nil
    elseif t.surface.index == e.surface.index and t.force.index == e.force.index and dist2(t.position, s.home) <= r2 then
      local cur, n = turret_ammo(t)
      if cur then kinds[key(cur.name, cur.quality)] = {name = cur.name, quality = cur.quality or "normal", art = t.type == "artillery-turret"} end
      local am = pick_ammo(s, t)
      if am then
        local lo = turret_levels(t, am.name)
        if n < lo then low[#low + 1] = t end
      end
    end
  end
  s.turret_kinds = kinds
  -- nearest-neighbour order from where the spider is, at most 20 stops
  local route, here = {}, e.position
  while #low > 0 and #route < 20 do
    local bi, bd
    for i, t in ipairs(low) do
      local d2 = dist2(here, t.position)
      if not bd or d2 < bd then bi, bd = i, d2 end
    end
    local t = table.remove(low, bi)
    route[#route + 1] = t
    here = t.position
  end
  return route
end

local function top_up(s, t)
  local _, n = turret_ammo(t)
  local am = pick_ammo(s, t)
  if not am then return 0 end
  local _, fill = turret_levels(t, am.name)
  local want = fill - n
  if want <= 0 then return 0 end
  local trunk = s.entity.get_inventory(defines.inventory.spider_trunk)
  local have = trunk.get_item_count(am)
  local give = math.min(want, have)
  if give <= 0 then return 0 end
  local put = t.insert({name = am.name, quality = am.quality, count = give})
  if put > 0 then trunk.remove({name = am.name, quality = am.quality, count = put}) end
  return put
end

------------------------------------------------------------------------------------------
-- idle choices (only when nothing urgent)
local function enemy_types() return {"unit-spawner", "turret"} end

local function find_nest(s, from)
  local e = s.entity
  local found = e.surface.find_entities_filtered{type = enemy_types(), position = s.home, radius = cfg("nest-radius")}
  local best, bd
  s.nest_skip = s.nest_skip or {}
  for _, n in pairs(found) do
    if n.valid and e.force.is_enemy(n.force) and not s.nest_skip[n.unit_number or 0]
       and (not cfg("nest-polluted-only") or e.surface.get_pollution(n.position) > 0) then
      local d2 = dist2(from, n.position)
      if not bd or d2 < bd then best, bd = n, d2 end
    end
  end
  return best
end

local function try_nests(s)
  if not (on(s, "nests") and s.home) then return false end
  if (s.nest_search or 0) > game.tick then return false end
  s.nest_search = game.tick + 10 * SEC
  if not combat_ready(s, cfg("nest-min-health")) then return false end
  local n = find_nest(s, s.entity.position)
  if not n then return false end
  set_state(s, "nests", {target = n, since = game.tick}, "Clearing nest at " .. gps(n.position, s.entity.surface))
  engage(s, n.position, n)
  return true
end

local function try_lights(s)
  if not (on(s, "lights") and s.home) then return false end
  if (s.lights_rest or 0) > game.tick then return false end
  local e = s.entity
  local surface = e.surface
  local carried = lights.lamps_carried(e)
  local budget = carried - lights.pending(surface, s.home, cfg("lights-radius") + lights.SECTOR)
  if budget <= 0 then
    s.lights_rest = game.tick + 30 * SEC
    if carried == 0 then s.status = "Lamps: none in the trunk" end
    return false
  end
  local radius = cfg("lights-radius")
  if not s.lsec or s.lsec_r ~= radius or not s.lsec_home or dist(s.lsec_home, s.home) > 1 then
    s.lsec, s.lsec_r, s.lsec_home, s.lcur, s.lempty = lights.sectors(s.home, radius), radius, s.home, 1, 0
  end
  -- poles for dark spots: whatever it carries, minus poles already planned
  local pole = cfg("light-pole")
  if not prototypes.entity[pole] then pole = nil end
  local pole_budget = 0
  if pole and cfg("light-poles") then
    pole_budget = lights.carried(e, pole) - surface.count_entities_filtered{ghost_name = pole,
      position = s.home, radius = radius + lights.SECTOR}
  end
  for _ = 1, 2 do                                  -- look at a couple of sectors per check
    local c = s.lsec[s.lcur]
    s.lcur = s.lcur % #s.lsec + 1
    local placed, poles = lights.plan_sector(surface, e.force, c, budget, cfg("lamp-spacing"),
                                             pole_budget > 0 and pole or nil, pole_budget)
    if placed > 0 then
      s.lempty = 0
      local what = "Putting up " .. placed .. " lamps" .. (poles > 0 and (" and " .. poles .. " poles") or "")
      set_state(s, "lights", {pos = c, progress = game.tick, last = math.huge}, what)
      go(s, c)
      return true
    end
    s.lempty = s.lempty + 1
    if s.lempty >= #s.lsec then                    -- whole area is lit: rest for a while
      s.lempty = 0
      s.lights_rest = game.tick + 5 * 60 * SEC
      return false
    end
  end
  return false
end

local function try_patrol(s)
  if not on(s, "patrol") then return false end
  local posts = guard_posts(s)
  if not posts then return false end
  -- start at the nearest post
  local first, bd = 1, nil
  for i, p in ipairs(posts) do
    local d2 = dist2(s.entity.position, p)
    if not bd or d2 < bd then first, bd = i, d2 end
  end
  set_state(s, "patrol", {i = first, phase = "walk"}, "Walking to guard post " .. first .. "/" .. #posts)
  go(s, posts[first])
  return true
end

local function trunk_sig(e)
  local inv = e.get_inventory(defines.inventory.spider_trunk)
  if not inv then return "" end
  local parts = {}
  for _, it in pairs(inv.get_contents()) do parts[#parts + 1] = it.name .. (it.quality or "") .. "=" .. it.count end
  table.sort(parts)
  return table.concat(parts, ",")
end

local function try_shuttle(s)
  if not (on(s, "shuttle") and s.shuttle_a and s.shuttle_b and s.shuttle_surface == s.entity.surface.index) then return false end
  local leg = (s.shuttle_leg == "b") and "b" or "a"
  set_state(s, "shuttle", {leg = leg}, "Shuttling to " .. string.upper(leg))
  C.ferry_ensure(s)
  C.ferry_set(s, nil)                          -- nothing loads or unloads on the way
  go(s, leg == "a" and s.shuttle_a or s.shuttle_b)
  return true
end

------------------------------------------------------------------------------------------
-- per-state behaviour
local step = {}

local function try_turrets(s)
  if not (on(s, "turrets") and s.home and s.home_surface == s.entity.surface.index) then return false end
  if (s.turret_search or 0) > game.tick then return false end
  s.turret_search = game.tick + 10 * SEC
  local route = turret_run(s)
  if #route == 0 then return false end
  set_state(s, "turrets", {route = route, i = 1, given = 0}, "Restocking " .. #route .. " turrets")
  go(s, route[1].position)
  return true
end

function step.idle(s)
  if try_turrets(s) or try_nests(s) or try_lights(s) or try_patrol(s) or try_shuttle(s) then return end
  if s.home and s.home_surface == s.entity.surface.index and dist(s.entity.position, s.home) > 10 then
    home_or_idle(s)
  else
    s.status = (s.status and s.status:find("^Lamps")) and s.status or "Idle"
  end
end

function step.returning(s)
  if arrived(s, s.home, 6) then set_state(s, "idle", nil, "Idle at home"); return end
  if stuck(s) then set_state(s, "idle", nil, "Couldn't reach home") end
end

function step.resupply(s)
  local e, t = s.entity, s.task
  local d = depot(s)
  if not d then home_or_idle(s); return end
  if not t.at_home then
    if arrived(s, d, 6) then
      t.at_home, t.since = true, game.tick
      s.status = (d == s.home) and "Restocking at home" or "Restocking at the restock point"
    elseif stuck(s) then
      t.at_home, t.since = true, game.tick
    end
    return
  end
  local n = ammo(e)
  local full = s.ammo_full == 0 or n >= s.ammo_full * 0.9
  if full and health(e) >= 0.9 then
    clear_alert(e)
    set_state(s, "idle", nil, "Restocked")
  elseif game.tick - t.since > cfg("restock-timeout") * SEC then
    if not t.warned then
      say(s, "can't restock at " .. gps(d, e.surface) ..
          " - is it inside your logistic network with ammo / repair packs available? Carrying on.")
      t.warned = true
    end
    s.resupply_cool = game.tick + 5 * 60 * SEC      -- don't loop straight back into restocking
    set_state(s, "idle", nil, "Restock timed out")
  end
end

function step.defend(s)
  local e, t = s.entity, s.task
  local a = storage.alerts[t.alert]
  local r = engage(s, t.pos)
  if r == "no-ammo" then                     -- nothing to shoot with: don't walk into them
    release_alert(s, false)
    home_or_idle(s)
    return
  end
  if r == "fight" then
    t.arrived, t.quiet = true, game.tick
    s.status = "Fighting at " .. gps(t.pos, e.surface)
  elseif not t.arrived then
    if (s.dest and dist(s.dest, t.pos) > 3) then go(s, t.pos) end   -- enemies gone: finish walking to the spot
    if arrived(s, t.pos, 8) or stuck(s) then t.arrived, t.quiet = true, game.tick end
    return
  end
  local recent = a and (game.tick - a.tick) < 10 * SEC
  if recent then t.quiet = math.max(t.quiet, a.tick) end
  if game.tick - t.quiet > 10 * SEC or game.tick - s.state_tick > 5 * 60 * SEC then
    release_alert(s, true)
    home_or_idle(s)
  end
end

function step.turrets(s)
  local e, t = s.entity, s.task
  local tur = t.route[t.i]
  while tur and not tur.valid do t.i = t.i + 1; tur = t.route[t.i] end
  if not tur then
    if t.given > 0 then s.status = "Restocked turrets (" .. t.given .. " rounds)" end
    s.turret_search = game.tick + 10 * SEC
    home_or_idle(s)
    return
  end
  if dist(e.position, tur.position) <= 10 or stuck(s) then
    if dist(e.position, tur.position) <= 10 then t.given = t.given + top_up(s, tur) end
    t.i = t.i + 1
    local nxt = t.route[t.i]
    if nxt and nxt.valid then
      s.status = string.format("Restocking turrets (%d/%d)", t.i, #t.route)
      go(s, nxt.position)
    end
  elseif not e.autopilot_destination then
    go(s, tur.position)
  end
end

function step.pack(s)
  local e, t = s.entity, s.task
  local site = storage.sites[t.site]
  local d = depot(s)
  if not (site and d) then home_or_idle(s); return end
  if not t.at_home then
    if arrived(s, d, 6) or stuck(s) then t.at_home, t.since = true, game.tick end
    return
  end
  -- refresh the list in case ghosts were added or built meanwhile
  local scan = get_scan(e.surface, site, e.force, 2 * SEC)
  if scan.ghosts + scan.decon == 0 then
    storage.sites[t.site] = nil
    home_or_idle(s)
    return
  end
  s.build_needs = scan_needs(scan)
  C.sync_requests(s)
  local short = missing(e, s.build_needs)
  local inv = trunk(e)
  local sig = inv and inv.get_item_count() or 0
  if sig ~= t.sig then t.sig, t.stable = sig, game.tick end
  -- done waiting when it has everything, or the network has nothing more to send
  -- (and the bots have stopped bringing things for 5 s), or it timed out
  local coming = fetchable(s, short)
  local settled = (#coming == 0 and game.tick - (t.stable or t.since) >= 5 * SEC)
  if #short == 0 or settled or game.tick - t.since > cfg("restock-timeout") * SEC then
    if can_do(e, scan) == 0 then
      s.status = "Nothing to build with for " .. gps(site.pos, e.surface)
      release_site(s, 5 * 60)
      set_state(s, "idle", nil, s.status)
      return
    end
    if #short > 0 then
      say(s, "builds what it can at " .. gps(site.pos, e.surface) .. "; your network doesn't have " ..
          short_text(short) .. ".")
    end
    set_state(s, "build", {site = t.site, last = math.huge, progress = game.tick},
              "Building at " .. gps(site.pos, e.surface))
    go(s, site.pos)
  else
    s.status = "Packing: waiting for " .. #coming .. " kinds of items"
  end
end

function step.build(s)
  local e, t = s.entity, s.task
  local site = storage.sites[t.site]
  if not site then home_or_idle(s); return end
  if not t.arrived then
    if arrived(s, site.pos, 6) then
      t.arrived, t.progress = true, game.tick
    elseif stuck(s) then
      t.arrived, t.progress = true, game.tick
    end
    return
  end
  local scan = get_scan(e.surface, site, e.force, SEC)
  local left = scan.ghosts + scan.decon
  if left == 0 then
    clear_alert(e)
    storage.sites[t.site] = nil
    home_or_idle(s)
    return
  end
  if left < t.last then t.last, t.progress = left, game.tick end
  local mine, ok = can_do(e, scan)
  if mine == 0 then
    -- built everything it had items for; the rest waits for whoever has them, like bots do
    say(s, "built what it had items for at " .. gps(site.pos, e.surface) .. "; " .. left ..
        " left there need items it doesn't carry (or trunk space).")
    release_site(s, 60)
    home_or_idle(s)
    return
  end
  s.status = "Building: " .. mine .. " left at " .. gps(site.pos, e.surface)
  -- no progress for 15 s: the rest may be out of the bots' reach, walk to the nearest job it can do
  if game.tick - t.progress > 15 * SEC and game.tick - (t.nudged or 0) > 15 * SEC and not e.autopilot_destination then
    local area = site_area(site)
    local near = {}
    for _, g in pairs(site_jobs(e.surface, area, e.force)) do
      local k = job_kind(g)
      if k and ok[k] then near[#near + 1] = g end
    end
    if #near == 0 then near = e.surface.find_entities_filtered{area = area, to_be_deconstructed = true} end
    local best, bd
    for _, g in pairs(near) do
      local d2 = dist2(g.position, e.position)
      if not bd or d2 < bd then best, bd = g, d2 end
    end
    if best and bd > 64 then go(s, best.position) end
    t.nudged = game.tick
  end
  if game.tick - t.progress > cfg("build-giveup") * SEC then
    say(s, "gave up building at " .. gps(site.pos, e.surface) .. " (" .. left ..
        " jobs left) - missing items or robots? Will retry in 5 minutes.")
    site.taken, site.skip_until = nil, game.tick + 5 * 60 * SEC
    home_or_idle(s)
  end
end

function step.nests(s)
  local e, t = s.entity, s.task
  local n = t.target
  if not combat_ready(s, 0.25) then home_or_idle(s); return end
  if not (n and n.valid) then
    local nxt = find_nest(s, e.position)
    if nxt and dist(nxt.position, e.position) < 80 then
      t.target, t.since = nxt, game.tick
      s.status = "Clearing nest at " .. gps(nxt.position, e.surface)
      n = nxt
    else
      home_or_idle(s)
      return
    end
  end
  -- shoot whatever is closest around the nest (worms, defenders), from range
  local foe = n
  local near = e.surface.find_entities_filtered{position = n.position, radius = 30, type = FOES, force = "enemy"}
  local bd = dist2(n.position, e.position)
  for _, f in pairs(near) do
    local d2 = dist2(f.position, e.position)
    if d2 < bd then foe, bd = f, d2 end
  end
  if engage(s, n.position, foe) == "no-ammo" then home_or_idle(s); return end
  if game.tick - t.since > 3 * 60 * SEC or stuck(s) then
    s.nest_skip[n.unit_number or 0] = true          -- can't get it: leave it alone
    t.target = nil
  end
end

function step.lights(s)
  local e, t = s.entity, s.task
  if not t.arrived then
    if arrived(s, t.pos, 4) or stuck(s) then t.arrived, t.progress = true, game.tick end
    return
  end
  local left = lights.pending(e.surface, t.pos, lights.SECTOR, cfg("light-poles") and cfg("light-pole") or nil)
  if left < t.last then t.last, t.progress = left, game.tick end
  if left == 0 or game.tick - t.progress > 60 * SEC then
    set_state(s, "idle", nil, "Lamps done here")
  else
    s.status = "Putting up lamps: " .. left .. " left"
  end
end

function step.patrol(s)
  local e, t = s.entity, s.task
  local posts = on(s, "patrol") and guard_posts(s)
  if not posts then home_or_idle(s); return end
  if t.i > #posts then t.i = 1 end
  local post = posts[t.i]
  if t.phase == "walk" then
    if arrived(s, post, 5) or stuck(s) then
      t.phase, t.since = "wait", game.tick
      e.autopilot_destination = nil
    end
    return
  end
  -- standing guard: a good moment to see if anything else needs doing
  if try_turrets(s) or try_nests(s) or try_lights(s) then return end
  local waited = game.tick - t.since
  local wait = cfg("guard-wait") * SEC
  local hurt = health(e) < 0.95
  if hurt then
    s.status = string.format("On guard at post %d/%d, repairing (%d%%)", t.i, #posts, math.floor(health(e) * 100))
  else
    s.status = string.format("On guard at post %d/%d", t.i, #posts)
  end
  if waited >= wait and (not hurt or waited >= wait + 120 * SEC) then
    t.i = t.i % #posts + 1
    t.phase = "walk"
    s.status = "Walking to guard post " .. t.i .. "/" .. #posts
    go(s, posts[t.i])
  end
end

function step.shuttle(s)
  local e, t = s.entity, s.task
  if not on(s, "shuttle") or not (s.shuttle_a and s.shuttle_b) then home_or_idle(s); return end
  local target = t.leg == "a" and s.shuttle_a or s.shuttle_b
  if not t.arrived then
    if arrived(s, target, 4) or stuck(s) then
      t.arrived, t.since, t.sig, t.stable = true, game.tick, trunk_sig(e), game.tick
      C.ferry_set(s, t.leg)                    -- this stop's loads and drops go live
      s.status = "Loading/unloading at " .. string.upper(t.leg)
    end
    return
  end
  local sig = trunk_sig(e)
  if sig ~= t.sig then t.sig, t.stable = sig, game.tick end
  -- leave once the minimum wait is over and robots have stopped changing the trunk for 10 s
  if game.tick - t.since >= cfg("shuttle-wait") * SEC and game.tick - t.stable >= 10 * SEC then
    s.shuttle_leg = (t.leg == "a") and "b" or "a"
    try_shuttle(s)
  end
end

function step.manual(s)
  local e = s.entity
  if game.tick >= (s.manual_until or 0) and not e.get_driver() and #e.autopilot_destinations == 0 then
    set_state(s, "idle", nil, "Back on chores")
  end
end

------------------------------------------------------------------------------------------
local function leave_state(s)
  if s.state == "defend" then release_alert(s) end
  if s.state == "build" or s.state == "pack" then
    local site = storage.sites[s.task.site]; if site then site.taken = nil end
  end
end

function C.manual(s, seconds)
  if s.state ~= "manual" then leave_state(s) end
  set_state(s, "manual", nil, "Paused (you're controlling it)")
  s.manual_until = game.tick + (seconds or cfg("manual-pause")) * SEC
end

function C.stop(s)
  leave_state(s)
  if s.entity.valid and s.state ~= "manual" then s.entity.autopilot_destination = nil end
  set_state(s, "idle", nil, "Off")
end

function C.get(entity, create)
  ensure()
  local s = storage.spiders[entity.unit_number]
  if not s and create then
    local _, slots = ammo(entity)
    s = {entity = entity, on = false, jobs = {
           defense = slots > 0, resupply = true, builder = has_bots(entity),
           turrets = false, lights = false, nests = false, patrol = false, shuttle = false},
         home = {x = entity.position.x, y = entity.position.y}, home_surface = entity.surface.index,
         ammo_full = ammo(entity), state = "idle", task = {}, status = "Off", state_tick = game.tick}
    storage.spiders[entity.unit_number] = s
  end
  return s
end

function C.tick()
  ensure()
  storage.autotarget = storage.autotarget or {}
  local active = {}
  for un, s in pairs(storage.spiders) do
    local e = s.entity
    if not (e and e.valid) then
      leave_state(s)
      storage.spiders[un] = nil
    elseif s.on and not e.surface.platform then
      if not storage.autotarget[un] then
        pcall(function() e.vehicle_automatic_targeting_parameters = {auto_target_without_gunner = true, auto_target_with_gunner = true} end)
        storage.autotarget[un] = true
      end
      local n = ammo(e)
      local it = ammo_item(s)
      local kind = it and it.name
      if kind ~= s.full_kind then s.full_kind, s.ammo_full = kind, n end   -- new ammo type: start over
      if n > s.ammo_full then s.ammo_full = n end
      if s.alert_until and game.tick > s.alert_until then clear_alert(e); s.alert_until = nil end
      if e.get_driver() and s.state ~= "manual" then C.manual(s, 5) end
      active[#active + 1] = s
    end
  end
  for _, s in pairs(storage.spiders) do
    if s.entity.valid and (s.req_sig or s.manage) then
      if s.on and s.manage then C.sync_requests(s)
      elseif s.req_sig then C.clear_requests(s) end
    end
  end
  tidy_world()
  -- resupply beats everything
  for _, s in pairs(active) do
    local d = depot(s)
    if s.state ~= "manual" and s.state ~= "resupply" and on(s, "resupply") and d
       and (s.resupply_cool or 0) <= game.tick and low(s) then
      leave_state(s)
      set_state(s, "resupply", {}, d == s.home and "Low - heading home to restock" or "Low - heading to the restock point")
      go(s, d)
    end
  end
  dispatch(active)
  for _, s in pairs(active) do
    local f = step[s.state] or step.idle
    f(s)
  end
end

return C
