data:extend {
    {
        type = "simple-entity-with-force",
        name = "balancer-part",
        icon = "__belt-balancer-redux__/graphics/icons/balancer.png",
        icon_size = 64,
        flags = { "placeable-neutral", "player-creation" },
        minable = { mining_time = 0.1, result = "balancer-part" },
        max_health = 170,
        corpse = "splitter-remnants",
        resistances = {
            {
                type = "fire",
                percent = 60
            }
        },
        collision_box = { { -0.35, -0.35 }, { 0.35, 0.35 } },
        selection_box = { { -0.5, -0.5 }, { 0.5, 0.5 } },
        collision_mask = { layers = { floor=true, meltable=true, object=true, transport_belt=true, water_tile=true } },
        animations = {
            layers = {
                {
                    filename = "__belt-balancer-redux__/graphics/entities/balancer.png",
                    priority = "high",
                    width = 112,
                    height = 112,
                    frame_count = 16,
                    line_length = 8,
                    animation_speed = 0.15,
                    scale = 0.5,
                },
                {
                    filename = "__belt-balancer-redux__/graphics/entities/balancer-shadow.png",
                    priority = "high",
                    width = 112,
                    height = 112,
                    repeat_count = 16,
                    draw_as_shadow = true,
                    scale = 0.5,
                },
            },
        },
    },
}
