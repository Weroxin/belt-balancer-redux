require("objects.storage")
require("objects.balancer")
require("objects.part")
require("objects.belt")
require("helper.message-handler")

-- on new savegame and on adding mod to existing save
script.on_init(function()
    -- set defaults and initialize values in storage table
    storage.next_balancer_unit_number = 1
    storage.next_lane_unit_number = 1
    storage.next_belt_check = nil
    storage.balancer = {}
    storage.parts = {}
    storage.belts = {}
    storage.lanes = {}
    storage.events = {}
end)

script.on_load(reregister_on_tick)

-- Rebuild all tracking from the entities in the world. Runs on every mod/game version change, so it
-- also picks up balancers from a save that used Belt Balancer 2 (same prototype names) and repairs
-- entities removed by other mods without raising events.
script.on_configuration_changed(function()
    -- Belt Balancer 2 kept up to 2 items per output lane in a Lua buffer: hand those back.
    -- Factorio moves a replaced mod's storage here (info.json migrates_from).
    local old = storage._migrated and storage._migrated["belt-balancer-2"]
    for _, balancer in pairs(old and old.balancer or {}) do
        local _, part_index = next(balancer.parts)
        local part = part_index and old.parts[part_index]
        for _, item in pairs(balancer.buffer or {}) do
            local stack = {}
            for k, v in pairs(item) do
                if v ~= false then stack[k] = v end -- 2.0 accepted `false` fields, 2.1 does not
            end
            local inserted = false
            for _, lane in pairs(balancer.output_lanes) do
                if lane.valid and lane.insert_at_back(stack, stack.count) then
                    inserted = true
                    break
                end
            end
            if not inserted and part and part.entity.valid then
                part.entity.surface.spill_item_stack { position = part.entity.position, stack = stack, force = part.entity.force }
            end
        end
    end

    if old then storage._migrated["belt-balancer-2"] = nil end

    script.on_nth_tick(nil)
    storage.next_belt_check = nil
    storage.balancer = {}
    storage.parts = {}
    storage.belts = {}
    storage.lanes = {}
    storage.events = {}
    for _, surface in pairs(game.surfaces) do
        for _, entity in pairs(surface.find_entities_filtered { name = "balancer-part" }) do
            part_functions.built(entity)
        end
    end
end)


-- Custom command to print out some statistics
commands.add_command("belt-balancer-statistics", "Counts of tracked balancers, parts, belts and lanes", function(e)
    local balancer_amount = table_size(storage.balancer)
    local balancer_part_amount = table_size(storage.parts)
    local balancer_input_belt_amount = 0
    local balancer_output_belt_amount = 0
    local balancer_input_lane_amount = 0
    local balancer_output_lane_amount = 0

    for _, balancer in pairs(storage.balancer) do
        for _, v in pairs(balancer.parts) do
            balancer_input_belt_amount = balancer_input_belt_amount + table_size(storage.parts[v].input_belts)
            balancer_output_belt_amount = balancer_output_belt_amount + table_size(storage.parts[v].output_belts)
        end
        balancer_input_lane_amount = balancer_input_lane_amount + table_size(balancer.input_lanes)
        balancer_output_lane_amount = balancer_output_lane_amount + table_size(balancer.output_lanes)
    end

    local output = "balancers: " .. balancer_amount ..
        "\nbalancer-parts: " .. balancer_part_amount ..
        "\nbalancer_input_belts: " .. balancer_input_belt_amount ..
        "\nbalancer_output_belts: " .. balancer_output_belt_amount ..
        "\nbalancer_input_lanes: " .. balancer_input_lane_amount ..
        "\nbalancer_output_lanes: " .. balancer_output_lane_amount
    game.get_player(e.player_index).print(output)
    print(output)
end)

-- only the entities this mod cares about reach the handlers below
local entity_filters = {
    { filter = "name", name = "balancer-part" },
    { filter = "type", type = "transport-belt" },
    { filter = "type", type = "underground-belt" },
    { filter = "type", type = "splitter" },
}

function built_entity(e)
    local entity = e.entity or e.destination -- destination: on_entity_cloned

    if entity.name == "balancer-part" then
        part_functions.built(entity)
    elseif entity.type == "splitter" then
        belt_functions.built_splitter(entity)
    else
        belt_functions.built_belt(entity)
    end
end

for _, event in pairs {
    defines.events.on_built_entity,
    defines.events.on_robot_built_entity,
    defines.events.on_space_platform_built_entity,
    defines.events.script_raised_built,
    defines.events.script_raised_revive,
    defines.events.on_entity_cloned, -- fix compatability with region cloner
} do
    script.on_event(event, built_entity, entity_filters)
end

function remove_entity(e)
    local entity = e.entity

    if entity.name == "balancer-part" then
        part_functions.remove(entity)
    elseif entity.type == "splitter" then
        belt_functions.remove_splitter(entity)
    else
        belt_functions.remove_belt(entity)
    end
end

for _, event in pairs {
    defines.events.on_entity_died,
    defines.events.on_player_mined_entity,
    defines.events.on_robot_mined_entity,
    defines.events.on_space_platform_mined_entity,
    defines.events.script_raised_destroy,
} do
    script.on_event(event, remove_entity, entity_filters)
end

---Re-register a belt/underground/splitter whose direction changed, using the direction it was tracked with.
---@param entity LuaEntity
local function refresh_belt(entity)
    local belt = storage.belts[entity.unit_number]
    if entity.type == "splitter" then
        if belt then belt_functions.remove_splitter(entity, belt.direction) end
        belt_functions.built_splitter(entity)
    else
        if belt then belt_functions.remove_belt(entity, belt.direction) end
        belt_functions.built_belt(entity)
    end
end

script.on_event({ defines.events.on_player_rotated_entity, defines.events.on_player_flipped_entity }, function(e)
    local entity = e.entity
    local type = entity.type
    if type == "transport-belt" or type == "splitter" then
        refresh_belt(entity)
    elseif type == "underground-belt" then
        refresh_belt(entity)
        -- rotating one end of an underground also turns the other end around
        local neighbour = entity.underground_belt_neighbour
        if neighbour and neighbour.valid then
            refresh_belt(neighbour)
        end
    end
end)

-- Check one tracked belt per tick for changes no event tells us about
-- (rotated by a script, or removed without raising an event).
script.on_event(defines.events.on_tick, function()
    local unit_number = storage.next_belt_check
    local belt = storage.belts[unit_number]
    if not belt then
        storage.next_belt_check = next(storage.belts)
        return
    end
    storage.next_belt_check = next(storage.belts, unit_number)

    local entity = belt.entity
    if entity.valid then
        if belt.direction ~= entity.direction then
            refresh_belt(entity)
        end
    elseif belt.surface.valid then
        if belt.type == "splitter" then
            belt_functions.remove_splitter(entity, belt.direction, unit_number, belt.surface, belt.position)
        else
            belt_functions.remove_belt(entity, belt.direction, unit_number, belt.surface, belt.position)
        end
    end
end)
