require("helper.math")
require("util")

balancer_functions = {}

-- longest wait (ticks) of a balancer whose last run moved nothing (all outputs full or all inputs empty)
local MAX_SLEEP = 16

---creates a new balancer object in the storage stack
---This will NOT set the parts and the lanes!!
---@return Balancer the created balancer
function balancer_functions.new()
    ---@type Balancer
    local balancer = {}

    balancer.unit_number = get_next_balancer_unit_number()
    balancer.parts = {}
    balancer.nth_tick = 0
    balancer.input_lanes = {}
    balancer.output_lanes = {}

    storage.balancer[balancer.unit_number] = balancer

    return balancer
end

---merge two balancer, the first balancer_index is the base, to merge things into.
---The second balancer (balancer_index2) will be deleted after it is merged.
---@param balancer_index uint
---@param balancer_index2 uint
function balancer_functions.merge(balancer_index, balancer_index2)
    local balancer = storage.balancer[balancer_index]
    local balancer2 = storage.balancer[balancer_index2]

    for k, part_index in pairs(balancer2.parts) do
        balancer.parts[k] = part_index

        -- change balancer link on part too
        local part = storage.parts[part_index]
        part.balancer = balancer_index

        -- change balancer link on belts too
        for _, belt_index in pairs(part.input_belts) do
            local belt = storage.belts[belt_index]
            belt.output_balancer[balancer_index2] = nil
            belt.output_balancer[balancer_index] = balancer_index
        end

        for _, belt_index in pairs(part.output_belts) do
            local belt = storage.belts[belt_index]
            belt.input_balancer[balancer_index2] = nil
            belt.input_balancer[balancer_index] = balancer_index
        end
    end

    for k, v in pairs(balancer2.input_lanes) do
        balancer.input_lanes[k] = v
    end

    for k, v in pairs(balancer2.output_lanes) do
        balancer.output_lanes[k] = v
    end

    -- remove merged balancer from the storage stack
    storage.balancer[balancer_index2] = nil

    -- unregister nth_tick
    unregister_on_tick(balancer_index2)
end

---This will find nearby balancer, creates/adds/merges balancer if needed.
---The part is automatically added to the balancer!
---@param part Part The part entity to work from
---@return uint The balancer index, that the part is part of :)
function balancer_functions.find_from_part(part)
    if part.balancer ~= nil then
        return part.balancer
    end

    local entity = part.entity

    local nearby_balancer_indices = part_functions.find_nearby_balancer(entity)
    local nearby_balancer_amount = table_size(nearby_balancer_indices)

    if nearby_balancer_amount == 0 then
        -- create new balancer
        local balancer = balancer_functions.new()
        balancer.parts[entity.unit_number] = entity.unit_number
        return balancer.unit_number
    elseif nearby_balancer_amount == 1 then
        -- add to existing balancer
        local balancer
        for _, index in pairs(nearby_balancer_indices) do
            balancer = storage.balancer[index]
            balancer.parts[entity.unit_number] = entity.unit_number
        end
        return balancer.unit_number
    elseif nearby_balancer_amount >= 2 then
        -- add to existing balancer and merge them
        -- merge fond balancer
        local base_balancer_index
        for _, nearby_balancer_index in pairs(nearby_balancer_indices) do
            if not base_balancer_index then
                base_balancer_index = nearby_balancer_index

                -- add splitter to balancer
                local balancer = storage.balancer[nearby_balancer_index]
                balancer.parts[entity.unit_number] = entity.unit_number
            else
                -- merge balancer and remove them from storage table
                balancer_functions.merge(base_balancer_index, nearby_balancer_index)
            end
        end
        return base_balancer_index
    end
end

---Rebuild the lane arrays used by `run` and (re)register the balancer at the right tick interval.
---Must be called after every change to the parts or lanes of a balancer.
---@param balancer_index uint
function balancer_functions.recalculate_nth_tick(balancer_index)
    local balancer = storage.balancer[balancer_index]

    local in_list, out_list = {}, {}
    for _, lane in pairs(balancer.input_lanes) do in_list[#in_list + 1] = lane end
    for _, lane in pairs(balancer.output_lanes) do out_list[#out_list + 1] = lane end
    balancer.in_list, balancer.out_list = in_list, out_list
    balancer.wake, balancer.idle_since = nil, nil

    if #in_list == 0 or #out_list == 0 or next(balancer.parts) == nil then
        unregister_on_tick(balancer_index)
        balancer.nth_tick = 0
        return
    end

    -- An output lane takes at most one item per run, and a belt frees one item slot (0.25 tiles)
    -- every 0.25/speed ticks. Run exactly that often; when it isn't a whole number of ticks
    -- (express: 2.67) anything but every tick loses throughput (tested: every 2 ticks = -11%).
    local nth_tick, slot_ticks = nil, 1
    for _, part_index in pairs(balancer.parts) do
        for _, belt_index in pairs(storage.parts[part_index].output_belts) do
            local entity = storage.belts[belt_index].entity
            if entity.valid then
                local ticks = 0.25 / entity.prototype.belt_speed
                slot_ticks = math.max(slot_ticks, math.ceil(ticks))
                if ticks ~= math.floor(ticks) then ticks = 1 end
                nth_tick = nth_tick and math.gcd(nth_tick, ticks) or ticks
            end
        end
    end
    nth_tick = nth_tick or 1
    balancer.slot_ticks = slot_ticks

    if balancer.nth_tick ~= nth_tick then
        balancer.nth_tick = nth_tick
        unregister_on_tick(balancer_index)
        register_on_tick(nth_tick, balancer_index)
    end
end

---Move items straight from input lanes to output lanes, round-robin on both sides.
---Items are copied with all their data (quality, spoilage, health, equipment grids...) and then removed.
---@param balancer_index uint
---@param tick uint
function balancer_functions.run(balancer_index, tick)
    local balancer = storage.balancer[balancer_index]
    if not balancer or (balancer.wake and tick < balancer.wake) then
        return
    end

    local outs, ins = balancer.out_list, balancer.in_list
    local n_out, n_in = #outs, #ins
    local oi, ii = balancer.out_i or 0, balancer.in_i or 0
    local last_fed

    for _ = 1, n_out do
        oi = oi % n_out + 1
        local out = outs[oi]
        if out.valid and out.can_insert_at_back() then
            local stack
            for _ = 1, n_in do
                ii = ii % n_in + 1
                local lane = ins[ii]
                if lane.valid and #lane > 0 then
                    stack = lane[1]
                    break
                end
            end
            if not stack then
                break -- every input is empty
            end
            if out.insert_at_back(stack, stack.count) then
                stack.clear()
                last_fed = oi
            end
        end
    end

    balancer.in_i = ii
    if last_fed then
        balancer.out_i = last_fed
        balancer.wake, balancer.idle_since = nil, nil
    elseif not balancer.idle_since then
        balancer.idle_since = tick
    else
        -- Nothing moved for longer than an output belt needs to free a slot: the balancer is backed up
        -- or starved. Back off exponentially, so idle balancers cost next to nothing.
        -- ponytail: fixed cap; a just-unblocked output may wait up to MAX_SLEEP ticks for its first item
        local idle = tick - balancer.idle_since
        if idle >= balancer.slot_ticks then
            balancer.wake = tick + math.min(idle, MAX_SLEEP)
        end
    end
end

---check if this balancer still needs to be tracked, if not, remove it from storage stack!
---@param balancer_index uint
---@return boolean True if balancer is still tracked, false if balancer was removed
function balancer_functions.check_track(balancer_index)
    local balancer = storage.balancer[balancer_index]
    if next(balancer.parts) == nil then
        unregister_on_tick(balancer_index)
        storage.balancer[balancer_index] = nil
        return false
    end

    return true
end

---balancer_get_linked
---get all lined splitters into an array of LuaEntity
---@param balancer Balancer balancer to perform on
---@return LuaEntity[][]
function balancer_functions.get_linked(balancer)
    -- create matrix
    local matrix = {}
    for _, part_index in pairs(balancer.parts) do
        local part = storage.parts[part_index]
        local pos = part.entity.position
        if not matrix[pos.x] then
            matrix[pos.x] = {}
        end
        matrix[pos.x][pos.y] = part.entity
    end

    local curr_num = 0
    local result = {}
    repeat
        curr_num = curr_num + 1
        balancer_functions.expand_first(matrix, curr_num, result)
    until (table_size(matrix) == 0)
    return result
end

---balancer_expand_first
---expand the first found not expanded Element in the matrix
---@param matrix LuaEntity[][] matrix to perform logic on
---@param num number
function balancer_functions.expand_first(matrix, num, result)
    for x_key, _ in pairs(matrix) do
        local breaker = false
        for y_key, _ in pairs(matrix[x_key]) do
            if matrix[x_key][y_key] then
                result[num] = {}
                balancer_functions.expand_matrix(matrix, { x = x_key, y = y_key }, num, result)
                breaker = true
                break
            end
        end

        if breaker then
            break
        end
    end
end

---balancer_expand_matrix
---expand given element in the matrix and then expand its neighbours
---only expand if this element is not nil
function balancer_functions.expand_matrix(matrix, pos, num, result)
    if matrix[pos.x] and matrix[pos.x][pos.y] then
        local part_entity = matrix[pos.x][pos.y]
        result[num][part_entity.unit_number] = part_entity
        matrix[pos.x][pos.y] = nil
        if table_size(matrix[pos.x]) == 0 then
            matrix[pos.x] = nil
        end

        balancer_functions.expand_matrix(matrix, { x = pos.x - 1, y = pos.y }, num, result)
        balancer_functions.expand_matrix(matrix, { x = pos.x + 1, y = pos.y }, num, result)
        balancer_functions.expand_matrix(matrix, { x = pos.x, y = pos.y - 1 }, num, result)
        balancer_functions.expand_matrix(matrix, { x = pos.x, y = pos.y + 1 }, num, result)
    end
end

---create a new balancer with already created parts
---@param part_list LuaEntity[]
---@return Balancer
function balancer_functions.new_from_part_list(part_list)
    local balancer = balancer_functions.new()

    for _, part_entity in pairs(part_list) do
        local part = storage.parts[part_entity.unit_number]

        -- add part to balancer
        balancer.parts[part_entity.unit_number] = part_entity.unit_number

        -- add balancer to part
        part.balancer = balancer.unit_number

        for _, belt_index in pairs(part.input_belts) do
            local belt = storage.belts[belt_index]

            -- add balancer to belt
            belt.output_balancer[balancer.unit_number] = balancer.unit_number
        end

        for _, belt_index in pairs(part.output_belts) do
            local belt = storage.belts[belt_index]

            -- add balancer to belt
            belt.input_balancer[balancer.unit_number] = balancer.unit_number
        end

        -- add lanes to balancer
        for lane_index, lane in pairs(part.input_lanes) do
            balancer.input_lanes[lane_index] = lane
        end
        for lane_index, lane in pairs(part.output_lanes) do
            balancer.output_lanes[lane_index] = lane
        end
    end

    balancer_functions.recalculate_nth_tick(balancer.unit_number)

    return balancer
end

---check if this balancer still is one piece, if not, create multiple balancer if needed.
---@param balancer_index uint
function balancer_functions.check_connected(balancer_index)
    local balancer = storage.balancer[balancer_index]

    local linked = balancer_functions.get_linked(balancer)
    if table_size(linked) > 1 then
        -- unregister balancer, before splitting it
        unregister_on_tick(balancer_index)

        -- create multiple new balancer
        for _, parts in pairs(linked) do
            balancer_functions.new_from_part_list(parts)
        end

        -- remove old balancer from belts
        for _, part_index in pairs(balancer.parts) do
            local part = storage.parts[part_index]
            for _, belt_index in pairs(part.input_belts) do
                local belt = storage.belts[belt_index]
                belt.input_balancer[balancer_index] = nil
                belt.output_balancer[balancer_index] = nil
            end
            for _, belt_index in pairs(part.output_belts) do
                local belt = storage.belts[belt_index]
                belt.input_balancer[balancer_index] = nil
                belt.output_balancer[balancer_index] = nil
            end
        end

        -- finally, remove old balancer form storage stack
        storage.balancer[balancer_index] = nil
    end
end

return balancer_functions