-- Headless test + benchmark for belt-balancer-redux (Factorio 2.1+). Run through tests/run.sh.
--   test           correctness, exit code 1 on failure
--   bench          wall time of 3600 ticks with 240 balancers (includes engine time)
--   bench-nomod    same layout with plain belts instead of balancer parts (engine-only time)
--   bench-onlyN    one balancer category only (1 flowing express, 2 uneven yellow, 3 backed up, 4 starved)
local D = defines.direction
local s, f
local cases, sinks = {}, {}
local failures = {}

local function check(ok, msg)
    if not ok then failures[#failures + 1] = msg end
    print((ok and "PASS " or "FAIL ") .. msg)
end

local function c(p)
    p.force = f
    p.direction = p.direction or D.north
    if p.raise_built == nil then p.raise_built = true end
    local e = s.create_entity(p)
    assert(e, p.name .. " at " .. serpent.line(p.position))
    return e
end

local function source(x, y_loader, item)
    local ch = c { name = "infinity-chest", position = { x + 0.5, y_loader + 1.5 } }
    ch.set_infinity_container_filter(1, { name = item or "iron-plate", count = 100, mode = "exactly" })
    c { name = "express-loader", position = { x + 0.5, y_loader }, type = "output" }
end

local function sink(x, y_loader)
    c { name = "express-loader", position = { x + 0.5, y_loader }, type = "input" }
    local ch = c { name = "infinity-chest", position = { x + 0.5, y_loader - 1.5 } }
    local k = { chest = ch, total = 0 }
    sinks[#sinks + 1] = k
    return k
end

local function count(k)
    return k.total + k.chest.get_item_count()
end

-- w parts at (ox..ox+w-1, oy); input belts below (moving north into the parts), output belts above.
-- opts.fed: set of columns that get a source; opts.no_sink: outputs dead-end (back up);
-- opts.parts_last: place the parts after the belts
local function balancer(ox, oy, w, belt, opts)
    local b = { parts = {}, outs = {}, out_belts = {} }
    local part = script.test_arg:find("nomod") and belt or "balancer-part"
    local function parts()
        for i = 0, w - 1 do b.parts[i] = c { name = part, position = { ox + i + 0.5, oy + 0.5 } } end
    end
    if not opts.parts_last then parts() end
    for i = 0, w - 1 do
        c { name = belt, position = { ox + i + 0.5, oy + 1.5 } }
        c { name = belt, position = { ox + i + 0.5, oy + 2.5 } }
        if opts.fed[i] then source(ox + i, oy + 4, opts.item) end
        b.out_belts[i] = c { name = belt, position = { ox + i + 0.5, oy - 0.5 } }
        c { name = belt, position = { ox + i + 0.5, oy - 1.5 } }
        if not opts.no_sink then b.outs[i] = sink(ox + i, oy - 3) end
    end
    if opts.parts_last then parts() end
    return b
end

local function prep(radius_chunks)
    s = game.surfaces[1]
    f = game.forces.player
    s.always_day = true
    s.request_to_generate_chunks({ 0, 0 }, radius_chunks)
    s.force_generate_chunk_requests()
    local r = radius_chunks * 32
    for _, e in pairs(s.find_entities_filtered { area = { { -r, -r }, { r, r } } }) do
        if e.type ~= "character" then e.destroy() end
    end
    local tiles = {}
    for x = -r, r - 1 do for y = -r, r - 1 do tiles[#tiles + 1] = { name = "lab-white", position = { x, y } } end end
    s.set_tiles(tiles)
end

local function all_outs(b)
    local t = {}
    for i = 0, #b.parts do if b.outs[i] then t[#t + 1] = count(b.outs[i]) end end
    return t
end

local function balanced(t, tol)
    local sum = 0
    for _, v in ipairs(t) do sum = sum + v end
    local mean = sum / #t
    for _, v in ipairs(t) do if math.abs(v - mean) > mean * tol then return false, sum end end
    return true, sum
end

---------------------------------------------------------------------------------------------------
local T_END = 3600

local function setup_test()
    prep(3)
    -- 1) one yellow input, four outputs: must be spread evenly at full belt speed
    cases.uneven = balancer(-60, 0, 4, "transport-belt", { fed = { [0] = true } })
    -- 2) express in, express out, all fed: balancer must not bottleneck (45/s per belt)
    cases.express = balancer(-50, 0, 4, "express-transport-belt", { fed = { [0] = true, [1] = true, [2] = true, [3] = true } })
    -- 3) remove the middle part mid-run (balancer splits)
    cases.split = balancer(-40, 0, 3, "transport-belt", { fed = { [0] = true } })
    -- 4) rotate an output belt without an event (poller must notice)
    cases.rotate = balancer(-30, 0, 2, "transport-belt", { fed = { [0] = true } })
    -- 5) items with extra data must survive: damaged item + armor with equipment
    cases.data = balancer(-20, 0, 1, "transport-belt", { fed = {} })
    -- 6) splitter feeding two parts, underground belt as an output
    do
        local ox, oy = -10, 0
        c { name = "balancer-part", position = { ox + 0.5, oy + 0.5 } }
        c { name = "balancer-part", position = { ox + 1.5, oy + 0.5 } }
        c { name = "splitter", position = { ox + 1, oy + 1.5 } }
        c { name = "transport-belt", position = { ox + 0.5, oy + 2.5 } }
        source(ox, oy + 4)
        -- col 0: underground entrance right above the part, exit 2 tiles further
        c { name = "underground-belt", position = { ox + 0.5, oy - 0.5 }, type = "input" }
        c { name = "underground-belt", position = { ox + 0.5, oy - 2.5 }, type = "output" }
        c { name = "transport-belt", position = { ox + 0.5, oy - 3.5 } }
        -- col 1: plain belt, same length
        for y = -1, -4, -1 do c { name = "transport-belt", position = { ox + 1.5, oy + y + 0.5 } } end
        cases.splitter = { outs = { [0] = sink(ox, oy - 5), [1] = sink(ox + 1, oy - 5) } }
    end
    -- 7) parts placed after the belts (the path used when state is rebuilt from the world)
    cases.parts_last = balancer(0, 0, 3, "fast-transport-belt", { fed = { [1] = true }, parts_last = true })
    -- 9) four inputs with different items into one output: every input must be drawn from equally
    do
        local ox, oy = 20, 0
        local items = { "iron-plate", "copper-plate", "coal", "stone" }
        for i = 0, 3 do
            c { name = "balancer-part", position = { ox + i + 0.5, oy + 0.5 } }
            c { name = "transport-belt", position = { ox + i + 0.5, oy + 1.5 } }
            c { name = "transport-belt", position = { ox + i + 0.5, oy + 2.5 } }
            source(ox + i, oy + 4, items[i + 1])
        end
        c { name = "transport-belt", position = { ox + 0.5, oy - 0.5 } }
        c { name = "transport-belt", position = { ox + 0.5, oy - 1.5 } }
        cases.fair = { items = items, out = sink(ox, oy - 3) }
    end
    -- 10) one input, two outputs, one of them dead-ends: the open output must get the whole input
    cases.blocked = balancer(30, 0, 2, "transport-belt", { fed = { [0] = true } })
    cases.blocked.outs[1].chest.destroy() -- output 1 now ends in a loader with nowhere to go
    sinks[#sinks] = nil
    -- 8) player rotates an underground output: both ends turn around, balancer must drop that output
    do
        local ox, oy = 10, 0
        c { name = "balancer-part", position = { ox + 0.5, oy + 0.5 } }
        c { name = "balancer-part", position = { ox + 1.5, oy + 0.5 } }
        for i = 0, 1 do
            c { name = "transport-belt", position = { ox + i + 0.5, oy + 1.5 } }
            c { name = "transport-belt", position = { ox + i + 0.5, oy + 2.5 } }
        end
        source(ox, oy + 4)
        cases.ug = {}
        cases.ug.entrance = c { name = "underground-belt", position = { ox + 0.5, oy - 0.5 }, type = "input" }
        c { name = "underground-belt", position = { ox + 0.5, oy - 2.5 }, type = "output" }
        c { name = "transport-belt", position = { ox + 0.5, oy - 3.5 } }
        for y = -1, -4, -1 do c { name = "transport-belt", position = { ox + 1.5, oy + y + 0.5 } } end
        cases.ug.outs = { [0] = sink(ox, oy - 5), [1] = sink(ox + 1, oy - 5) }
    end
end

local marks = {}
local function tick_test(tick)
    if tick == 1 then setup_test() end
    if tick == 100 then
        local inv = game.create_inventory(2)
        inv.insert { name = "iron-chest", count = 1, health = 0.5 }
        inv.insert { name = "power-armor", count = 1 }
        inv[2].grid.put { name = "solar-panel-equipment" }
        local belt = s.find_entity("transport-belt", { -20 + 0.5, 2.5 })
        belt.get_transport_line(1).insert_at_back(inv[1])
        belt.get_transport_line(2).insert_at_back(inv[2])
        inv.destroy()
    end
    if tick == 1500 then
        cases.split.parts[1].destroy { raise_destroy = true }
        marks.split0 = count(cases.split.outs[0])
        marks.split2 = count(cases.split.outs[2])
        cases.rotate.out_belts[1].rotate() -- north -> east, no event raised
        if game.players[1] then
            marks.ug_rotated = cases.ug.entrance.rotate { by_player = game.players[1] }
        end
    end
    if tick == 1700 then
        marks.rot1 = count(cases.rotate.outs[1])
        marks.ug0, marks.ug1 = count(cases.ug.outs[0]), count(cases.ug.outs[1])
    end
    if tick ~= T_END then return end

    local secs = (T_END - 120) / 60 -- generous warm-up allowance
    do
        local ok, sum = balanced(all_outs(cases.uneven), 0.15)
        check(ok, "uneven: outputs balanced " .. serpent.line(all_outs(cases.uneven)))
        check(sum >= 0.85 * 15 * secs, "uneven: throughput " .. sum .. " >= " .. math.floor(0.85 * 15 * secs))
    end
    do
        local ok, sum = balanced(all_outs(cases.express), 0.1)
        check(ok, "express: outputs balanced " .. serpent.line(all_outs(cases.express)))
        check(sum >= 0.95 * 4 * 45 * secs, "express: throughput " .. sum .. " >= " .. math.floor(0.95 * 4 * 45 * secs))
    end
    do
        local d0 = count(cases.split.outs[0]) - marks.split0
        local d2 = count(cases.split.outs[2]) - marks.split2
        check(d0 > 7.5 * 30, "split: remaining part keeps working (" .. d0 .. ")")
        check(d2 <= 16, "split: detached part gets nothing new (" .. d2 .. ")")
    end
    do
        local d1 = count(cases.rotate.outs[1]) - marks.rot1
        local d0 = count(cases.rotate.outs[0])
        check(d1 <= 8, "rotate: rotated belt no longer fed (" .. d1 .. ")")
        check(d0 > 0, "rotate: other output still fed")
    end
    do
        local inv = cases.data.outs[0].chest.get_inventory(defines.inventory.chest)
        local chest_ok, armor_ok = false, false
        for i = 1, #inv do
            local st = inv[i]
            if st.valid_for_read then
                if st.name == "iron-chest" then chest_ok = math.abs(st.health - 0.5) < 0.01 end
                if st.name == "power-armor" then armor_ok = st.grid ~= nil and st.grid.get_contents()[1] ~= nil end
            end
        end
        check(chest_ok, "data: item health preserved")
        check(armor_ok, "data: armor equipment preserved")
    end
    do
        local a, b = count(cases.splitter.outs[0]), count(cases.splitter.outs[1])
        check(a > 100 and b > 100 and math.abs(a - b) <= 0.15 * (a + b) / 2, "splitter/underground: both outputs fed " .. a .. " " .. b)
    end
    do
        local ok, sum = balanced(all_outs(cases.parts_last), 0.15)
        check(ok and sum >= 0.85 * 30 * secs, "parts placed last: balanced at full speed " .. serpent.line(all_outs(cases.parts_last)))
    end
    if marks.ug_rotated then
        local d0 = count(cases.ug.outs[0]) - marks.ug0
        local d1 = count(cases.ug.outs[1]) - marks.ug1
        check(d0 <= 8 and d1 > 7.5 * 2 * 20, "player-rotated underground: output dropped, other output gets everything (" .. d0 .. ", " .. d1 .. ")")
    else
        print("SKIP player-rotated underground (no player in this run)")
    end
    do
        local got = {}
        for _, item in ipairs(cases.fair.items) do got[#got + 1] = cases.fair.out.chest.get_item_count(item) end
        local ok, sum = balanced(got, 0.1)
        check(ok and sum >= 0.85 * 15 * secs, "fairness: 4 inputs share 1 output equally " .. serpent.line(got))
    end
    do
        local open = count(cases.blocked.outs[0])
        check(open >= 0.85 * 15 * secs, "blocked output: open output gets the whole input (" .. open .. ")")
    end
    check((prototypes.recipe["belt-balancer-turbo-belt"] ~= nil) == (script.active_mods["space-age"] ~= nil), "turbo recipe exists iff space-age")
    script.finish_test(#failures == 0)
end

---------------------------------------------------------------------------------------------------
local BENCH_N = 60 -- balancers per category
local profiler, moved_from

local function setup_bench()
    prep(5)
    local full = { [0] = true, [1] = true, [2] = true, [3] = true }
    local only = tonumber(script.test_arg:match("only(%d)"))
    for k = 0, BENCH_N - 1 do
        local ox, oy = -150 + (k % 20) * 5, -140 + math.floor(k / 20) * 12
        if not only or only == 1 then balancer(ox, oy, 4, "express-transport-belt", { fed = full }) end                    -- flowing, express
        if not only or only == 2 then balancer(ox, oy + 40, 4, "transport-belt", { fed = { [0] = true } }) end             -- flowing, uneven, yellow
        if not only or only == 3 then balancer(ox, oy + 80, 4, "express-transport-belt", { fed = full, no_sink = true }) end -- backed up
        if not only or only == 4 then balancer(ox, oy + 120, 4, "fast-transport-belt", { fed = {} }) end                   -- starved
    end
end

local function moved()
    local n = 0
    for _, k in pairs(sinks) do n = n + count(k) end
    return n
end

local function tick_bench(tick)
    if tick == 1 then setup_bench() end
    if tick == 600 then
        moved_from = moved()
        profiler = helpers.create_profiler()
    end
    if tick == 600 + 3600 then
        profiler.stop()
        localised_print { "", "BENCH 3600 ticks: ", profiler, " items moved: ", tostring(moved() - moved_from) }
        script.finish_test(true)
    end
end

script.on_event(defines.events.on_tick, function(e)
    if e.tick % 300 == 0 then
        for _, k in pairs(sinks) do
            if k.chest.get_item_count() > 2000 then
                k.total = k.total + k.chest.get_item_count()
                k.chest.clear_items_inside()
            end
        end
    end
    if script.test_arg:find("bench") then tick_bench(e.tick) else tick_test(e.tick) end
end)
