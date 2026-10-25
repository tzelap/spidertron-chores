-- "Homey": plan small-lamp ghosts around buildings. Where there's no power yet, plan a pole
-- too, but only one that can wire up to an existing (or just-planned) pole, so the grid grows
-- outward instead of leaving dead islands. Never more lamps/poles than the spider carries;
-- its own bots build them.
local L = {}
local LAMP = "small-lamp"
local SECTOR = 20          -- tiles; spider stands in the middle so its bots reach every corner

-- things that don't count as "a building worth lighting"
local IGNORE = {
  ["electric-pole"] = true, ["lamp"] = true, ["character"] = true, ["spider-vehicle"] = true,
  ["spider-leg"] = true, ["car"] = true, ["entity-ghost"] = true, ["tile-ghost"] = true,
  ["construction-robot"] = true, ["logistic-robot"] = true, ["combat-robot"] = true,
  ["item-entity"] = true, ["corpse"] = true, ["character-corpse"] = true,
}

local function proto_supply(proto, quality)
  local ok, r = pcall(function() return proto.get_supply_area_distance(quality) end)
  return (ok and r) or 2.5
end
local function proto_reach(proto, quality)
  local ok, r = pcall(function() return proto.get_max_wire_distance(quality) end)
  return (ok and r) or 7.5
end

-- every pole that powers (or will power, once built) this spot
local function covered(surface, force, p)
  for _, pole in pairs(surface.find_entities_filtered{type = "electric-pole", force = force, position = p, radius = 20}) do
    local r = proto_supply(pole.prototype, pole.quality)
    if math.abs(pole.position.x - p.x) <= r + 0.5 and math.abs(pole.position.y - p.y) <= r + 0.5 then return true end
  end
  for _, g in pairs(surface.find_entities_filtered{ghost_type = "electric-pole", force = force, position = p, radius = 20}) do
    local r = proto_supply(g.ghost_prototype, g.quality)
    if math.abs(g.position.x - p.x) <= r + 0.5 and math.abs(g.position.y - p.y) <= r + 0.5 then return true end
  end
  return false
end

-- can a new pole at q wire up to an existing pole or a planned one?
local function connectable(surface, force, q, reach)
  local function near(list)
    for _, e in pairs(list) do
      local other = e.type == "entity-ghost" and proto_reach(e.ghost_prototype, e.quality) or proto_reach(e.prototype, e.quality)
      local r = math.min(reach, other)
      if (e.position.x - q.x) ^ 2 + (e.position.y - q.y) ^ 2 <= r * r then return true end
    end
    return false
  end
  return near(surface.find_entities_filtered{type = "electric-pole", force = force, position = q, radius = reach})
      or near(surface.find_entities_filtered{ghost_type = "electric-pole", force = force, position = q, radius = reach})
end

local function nearest_pole(surface, force, p, maxd)
  local best, bd, breach
  local function look(list, ghostly)
    for _, e in pairs(list) do
      local d2 = (e.position.x - p.x) ^ 2 + (e.position.y - p.y) ^ 2
      if not bd or d2 < bd then
        best, bd = e, d2
        breach = ghostly and proto_reach(e.ghost_prototype, e.quality) or proto_reach(e.prototype, e.quality)
      end
    end
  end
  look(surface.find_entities_filtered{type = "electric-pole", force = force, position = p, radius = maxd}, false)
  look(surface.find_entities_filtered{ghost_type = "electric-pole", force = force, position = p, radius = maxd}, true)
  if best then return best.position, math.sqrt(bd), breach end
end

local function lamp_near(surface, p, r)
  return surface.count_entities_filtered{type = "lamp", position = p, radius = r, limit = 1} > 0
      or surface.count_entities_filtered{ghost_type = "lamp", position = p, radius = r, limit = 1} > 0
end

local function building_near(surface, force, p)
  for _, e in pairs(surface.find_entities_filtered{force = force, position = p, radius = 5, limit = 16}) do
    if not IGNORE[e.type] then return true end
  end
  return false
end

local function can(surface, force, name, q)
  return surface.can_place_entity{name = name, position = q, force = force,
                                  build_check_type = defines.build_check_type.manual_ghost}
end

local function ghost(surface, force, name, q)
  return surface.create_entity{name = "entity-ghost", inner_name = name, position = q, force = force}
end

local OFFSETS = {{0, 0}, {1, 0}, {-1, 0}, {0, 1}, {0, -1}, {1, 1}, {-1, -1}, {1, -1}, {-1, 1}, {2, 0}, {-2, 0}, {0, 2}, {0, -2}}

-- returns lamps placed, poles placed in the sector around `c`
function L.plan_sector(surface, force, c, budget, spacing, pole_name, pole_budget)
  if budget <= 0 then return 0, 0 end
  local lamps, poles = 0, 0
  local pole_proto = pole_name and prototypes.entity[pole_name]
  local reach = pole_proto and proto_reach(pole_proto) or 0
  local supply = pole_proto and proto_supply(pole_proto) or 0
  local h = SECTOR / 2
  local x0 = math.floor((c.x - h) / spacing) * spacing
  local y0 = math.floor((c.y - h) / spacing) * spacing
  for gx = x0, c.x + h, spacing do
    for gy = y0, c.y + h, spacing do
      local p = {x = gx + 0.5, y = gy + 0.5}
      if math.abs(p.x - c.x) <= h and math.abs(p.y - c.y) <= h
         and not lamp_near(surface, p, spacing * 0.75)
         and building_near(surface, force, p) then
        local done = false
        -- 1. a powered spot: just a lamp
        for _, o in pairs(OFFSETS) do
          local q = {x = p.x + o[1], y = p.y + o[2]}
          if covered(surface, force, q) and can(surface, force, LAMP, q) then
            if ghost(surface, force, LAMP, q) then lamps = lamps + 1 end
            done = true
            break
          end
        end
        -- 2. dark spot: run a short chain of poles out from the nearest pole (real or planned),
        --    each within wire reach of the last, then a lamp beside the final pole.
        if not done and pole_proto and poles < pole_budget then
          local from, d, from_reach = nearest_pole(surface, force, p, 40)
          local hops = 0
          while from and poles < pole_budget and hops < 5 do
            local r = math.min(reach, from_reach) * 0.95
            -- last hop when a pole within wire reach can also power the lamp spot
            local last = d <= r + supply - 0.5
            local aim = (d <= r) and p or {x = from.x + (p.x - from.x) / d * r, y = from.y + (p.y - from.y) / d * r}
            local spot
            for _, o in pairs(OFFSETS) do
              local q = {x = math.floor(aim.x) + 0.5 + o[1], y = math.floor(aim.y) + 0.5 + o[2]}
              if (q.x - from.x) ^ 2 + (q.y - from.y) ^ 2 <= r * r and can(surface, force, pole_name, q) then spot = q; break end
            end
            if not spot then break end
            local lamp_spot
            if last then
              -- lamp as close to the intended spot as the new pole's power area allows
              local tries = {}
              for _, o in pairs(OFFSETS) do tries[#tries + 1] = {x = math.floor(p.x) + 0.5 + o[1], y = math.floor(p.y) + 0.5 + o[2]} end
              for _, lo in pairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}, {1, 1}, {-1, 1}, {1, -1}, {-1, -1}}) do
                tries[#tries + 1] = {x = spot.x + lo[1], y = spot.y + lo[2]}
              end
              for _, l in pairs(tries) do
                if (l.x ~= spot.x or l.y ~= spot.y) and math.abs(l.x - spot.x) <= supply and math.abs(l.y - spot.y) <= supply
                   and can(surface, force, LAMP, l) then
                  lamp_spot = l; break
                end
              end
              if not lamp_spot then break end
            end
            if not ghost(surface, force, pole_name, spot) then break end
            poles = poles + 1
            if last then
              if ghost(surface, force, LAMP, lamp_spot) then lamps = lamps + 1 end
              break
            end
            from, from_reach = spot, reach
            d = math.sqrt((p.x - from.x) ^ 2 + (p.y - from.y) ^ 2)
            hops = hops + 1
          end
        end
        if lamps >= budget then return lamps, poles end
      end
    end
  end
  return lamps, poles
end

-- sector centres in rings around home, nearest first
function L.sectors(home, radius)
  local list = {}
  local n = math.ceil(radius / SECTOR)
  for i = -n, n do
    for j = -n, n do
      local c = {x = home.x + i * SECTOR, y = home.y + j * SECTOR}
      local dx, dy = c.x - home.x, c.y - home.y
      if dx * dx + dy * dy <= radius * radius then list[#list + 1] = c end
    end
  end
  table.sort(list, function(a, b)
    local da = (a.x - home.x) ^ 2 + (a.y - home.y) ^ 2
    local db = (b.x - home.x) ^ 2 + (b.y - home.y) ^ 2
    if da ~= db then return da < db end
    if a.x ~= b.x then return a.x < b.x end
    return a.y < b.y
  end)
  return list
end

function L.carried(spider, name)
  local inv = spider.get_inventory(defines.inventory.spider_trunk)
  return inv and inv.get_item_count(name) or 0
end
function L.lamps_carried(spider) return L.carried(spider, LAMP) end

-- planned but not yet built: lamps, or lamps + poles
function L.pending(surface, c, r, pole_name)
  local n = surface.count_entities_filtered{ghost_name = LAMP, position = c, radius = r}
  if pole_name then n = n + surface.count_entities_filtered{ghost_name = pole_name, position = c, radius = r} end
  return n
end

L.LAMP = LAMP
L.SECTOR = SECTOR
return L
