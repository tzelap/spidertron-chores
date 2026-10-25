-- the "pick a spot" tool the panel puts in your cursor (works on the map too)
data:extend({
  {
    type = "selection-tool",
    name = "sc-pick-point",
    icon = "__spidertron-chores__/graphics/pick.png",
    icon_size = 64,
    flags = {"only-in-cursor", "not-stackable", "spawnable"},
    hidden = true,
    stack_size = 1,
    select = {border_color = {0.3, 0.9, 0.35}, cursor_box_type = "entity", mode = {"nothing"}},
    alt_select = {border_color = {0.3, 0.9, 0.35}, cursor_box_type = "entity", mode = {"nothing"}},
  },
})
