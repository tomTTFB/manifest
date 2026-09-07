local monitor = peripheral.find("monitor")
local monitor_name = monitor and peripheral.getName(monitor)
if monitor then
    -- default green is muddy and lime is neon, so sit the highlight between them
    monitor.setPaletteColour(colours.green, 0x6ABE5C)
end

local TABS = { "Manifest", "Spatial", "Settings" }
local SCALES = { 0.5, 1, 1.5, 2 }
local INTERVALS = { 0.25, 0.5, 1, 2 }
local MORE_BUTTON = 8
local OPTION_X = 14

local LIST_MIN = 5
local COLUMN_MIN = 34
local NAME_MIN = 16
local PAGER_BUTTON = 11
local PAGER_GAP = 6
local STEP_BUTTON = 4
local QTY_MIN = 3
local REQUEST_BUTTON = 9
local CLEAR_BUTTON = 7
local LOAD_BUTTON = 8
local STORE_BUTTON = 7
local CHANGE_BUTTON = 8

local KEY_MAX_W = 9
local KEY_MIN_W = 3
local KEY_ROWS = { "1234567890", "qwertyuiop", "asdfghjkl", "zxcvbnm_." }
local LIST_ROOM = 12

local CONFIG = "manifest.cfg"

local stock = {}
local items = {}
local queue = {}
local tab = 1
local tabs = {}
local controls = {}
local output_offset = 0
local barrel_offset = 0
local barrel_picking = false
local scale = 1
local interval = 0.5
local query = ""
local keys = {}
local keyboard_open = false
local page = 1
local selected = nil
local amount = 1
local output = nil
local barrel = nil
local pulse_side = "back"
local relay = nil
local cell_names = {}
local loaded = {}
local status = nil
local error_toast = nil
local stats = { chests = "0/0", elapsed = 0 }
local pager = { y = 1, prev_x = 1, next_x = 1 }
local request = { top = 1, y = 1, button_x = 1, clear_x = 1, steps = {} }

local function commas(n)
    local digits = tostring(n):reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (digits:gsub("^,", ""))
end

-- "minecraft:iron_ingot" -> "Iron Ingot". Good enough for vanilla; real display
-- names need getItemDetail, which is far too slow to call every scan.
local function format_name(id)
    local words = id:gsub("^.-:", ""):gsub("_", " ")
    return (words:gsub("%a[%w']*", function(word)
        return word:sub(1, 1):upper() .. word:sub(2)
    end))
end

-- hasType only exists on CC:Tweaked 1.99+, so fall back to probing for the
-- method on older versions rather than crashing
local function is_inventory(name)
    if peripheral.hasType then
        return peripheral.hasType(name, "inventory")
    end
    for _, method in ipairs(peripheral.getMethods(name) or {}) do
        if method == "list" then
            return true
        end
    end
    return false
end

local SIDES = { top = true, bottom = true, left = true, right = true, front = true, back = true }
local SIDE_ORDER = { "top", "bottom", "left", "right", "front", "back" }

local function load_config()
    if not fs.exists(CONFIG) then return {} end

    local f = fs.open(CONFIG, "r")
    local body = f.readAll()
    f.close()

    return {
        output = body:match("output=([^\r\n]+)"),
        scale = tonumber(body:match("scale=([^\r\n]+)")),
        interval = tonumber(body:match("interval=([^\r\n]+)")),
        barrel = body:match("barrel=([^\r\n]+)"),
        pulse = body:match("pulse=([^\r\n]+)"),
        relay = body:match("relay=([^\r\n]+)"),
        loaded = body:match("loaded=([^\r\n]+)"),
    }
end

local function save_config()
    local f = fs.open(CONFIG, "w")
    f.write("output=" .. (output or "") .. "\n")
    f.write("scale=" .. scale .. "\n")
    f.write("interval=" .. interval .. "\n")
    f.write("barrel=" .. (barrel or "") .. "\n")
    f.write("pulse=" .. pulse_side .. "\n")
    f.write("relay=" .. (relay or "") .. "\n")

    local marked = {}
    for slot in pairs(loaded) do
        marked[#marked + 1] = slot
    end
    table.sort(marked)

    f.write("loaded=" .. table.concat(marked, "|") .. "\n")
    f.close()
end

-- AE2 hands its blocks to CC as generic inventories, so a spatial IO port looks
-- like any other chest. Pulling someone's stored dimension out of one because it
-- counted as storage would be a bad afternoon.
local function is_relay(name)
    for _, method in ipairs(peripheral.getMethods(name) or {}) do
        if method == "setOutput" then
            return true
        end
    end
    return false
end

local function is_spatial(name)
    return peripheral.getType(name):find("spatial") ~= nil
end

local function storage()
    local networked = output and not SIDES[output]
    local found = {}

    for _, name in ipairs(peripheral.getNames()) do
        -- a side-attached inventory is off the wired network, so it could never
        -- push to a networked output; counting it promises stock we cannot move
        if is_inventory(name) and name ~= output and name ~= barrel and not is_spatial(name)
            and not (networked and SIDES[name]) then
            found[#found + 1] = name
        end
    end

    return found
end
-- Every chest is listed at once, so a scan costs about as long as the slowest
-- single chest rather than the sum of all of them.
local function scan(chests)
    local counts, reached = {}, 0
    local tasks = {}

    for _, name in ipairs(chests) do
        tasks[#tasks + 1] = function()
            local ok, slots = pcall(peripheral.call, name, "list")
            if ok and slots then
                reached = reached + 1
                for _, item in pairs(slots) do
                    counts[item.name] = (counts[item.name] or 0) + item.count
                end
            end
        end
    end

    if #tasks > 0 then
        parallel.waitForAll(table.unpack(tasks))
    end

    return counts, reached
end

local function sorted(counts)
    local list = {}
    for id, count in pairs(counts) do
        list[#list + 1] = { id = id, name = format_name(id), count = count }
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

-- ids are matched as well as names so "minecraft:" or a mod prefix narrows the
-- list to one mod's items
local function matching(list)
    if query == "" then return list end

    local needle = query:lower()
    local found = {}

    for _, item in ipairs(list) do
        if item.name:lower():find(needle, 1, true) or item.id:find(needle, 1, true) then
            found[#found + 1] = item
        end
    end

    return found
end

local function step_at(x)
    for _, step in ipairs(request.steps) do
        if x >= step.x and x < step.x + request.step_w then
            return step
        end
    end
end

local function queued(id)
    for i, entry in ipairs(queue) do
        if entry.id == id then
            return entry, i
        end
    end
end

-- searches stock rather than the filtered list, so typing doesn't drop a
-- selection that is already sitting in the request bar
local function selected_item()
    for _, item in ipairs(stock) do
        if item.id == selected then
            return item
        end
    end
end

-- Pull from one chest at a time until the request is filled. pushItems reports
-- what it actually moved, which is the only honest count once the output chest
-- starts filling up.
local function dispense(id, wanted)
    if not output then return 0, "no output inventory configured" end

    local moved = 0
    for _, name in ipairs(storage()) do
        local listed, slots = pcall(peripheral.call, name, "list")
        if listed and slots then
            for slot, item in pairs(slots) do
                if item.name == id then
                    local ok, sent = pcall(peripheral.call, name, "pushItems", output, slot, wanted - moved)
                    if not ok then return moved, tostring(sent) end
                    moved = moved + sent
                    if moved >= wanted then return moved end
                end
            end
        end
    end

    return moved
end

-- Everything here is sized in character cells, so at text scale 0.5 the same
-- numbers draw half-sized buttons on twice the grid. Where there is room the
-- chrome doubles up instead of shrinking away from the finger, and the list
-- spreads into columns rather than leaving the width empty.
local function layout()
    local w, h = monitor.getSize()
    local u = (w >= 70 and h >= 40) and 2 or 1
    -- odd, so a label sits dead centre in a button rather than against its top
    local box = 2 * u - 1
    local request_top = h - box - 1
    local pager_bottom = request_top - 2

    return {
        u = u,
        box = box,
        mid = math.floor((box - 1) / 2),
        w = w,
        h = h,
        search_top = box + 2,
        list_top = 2 * box + 3,
        pager_top = pager_bottom - box + 1,
        pager_bottom = pager_bottom,
        request_top = request_top,
        columns = math.max(1, math.min(3, math.floor(w / COLUMN_MIN))),
        pager_button = PAGER_BUTTON * u,
        step = STEP_BUTTON * u,
        request_button = REQUEST_BUTTON * u,
        clear_button = CLEAR_BUTTON * u,
        more_button = MORE_BUTTON * u,
        load_button = LOAD_BUTTON * u,
        store_button = STORE_BUTTON * u,
        change_button = CHANGE_BUTTON * u,
        option_x = OPTION_X * u,
    }
end

-- A 4x4 monitor at scale 1 is about 39 columns, nowhere near the 59 a row of
-- ten comfortable keys wants, so the keys size themselves to what is there and
-- the box is only ever as deep as the keys plus a row of padding.
local function key_metrics()
    if not monitor or not keyboard_open then return nil end

    local w, h = monitor.getSize()
    local gap = 1
    local key_w = math.floor((w - 2 - 9 * gap) / 10)

    -- dropping the gaps buys a column per key, which on a small monitor is the
    -- difference between a cramped keyboard and no keyboard at all
    if key_w < KEY_MIN_W then
        gap = 0
        key_w = math.floor((w - 2) / 10)
    end

    if key_w < KEY_MIN_W then return nil end

    local ui = layout()
    local rows = #KEY_ROWS + 1
    local key_h = ui.box

    -- taller keys are easier to hit, but not at the list's expense
    if ui.pager_top - ui.list_top - 2 - (rows * key_h + 2) < LIST_ROOM then
        key_h = 1
    end

    local box = rows * key_h + 2
    local top = ui.pager_top - 1 - box

    if top - ui.list_top - 1 < LIST_MIN then return nil end

    key_w = math.min(key_w, KEY_MAX_W)

    return {
        key_w = key_w,
        key_h = key_h,
        gap = gap,
        span = 10 * (key_w + gap) - gap,
        top = top,
        height = box,
        keys_top = top + 1,
    }
end

-- Entries that fill completely drop off the queue; one that comes up short keeps
-- its remainder and anything past a failure is left untouched, so pressing pull
-- again picks up where this left off.
local function pull()
    local filled, failure = 0, nil
    local remaining = {}

    for _, entry in ipairs(queue) do
        if failure then
            remaining[#remaining + 1] = entry
        else
            local moved, problem = dispense(entry.id, entry.amount)
            entry.amount = entry.amount - moved
            failure = problem

            if entry.amount <= 0 then
                filled = filled + 1
            else
                remaining[#remaining + 1] = entry
            end
        end
    end

    queue = remaining
    return filled, failure
end

-- the tab bar, a gap, the search field, a gap, then the list, a gap, whatever
-- the keyboard is taking, the pager and the rows the request bar drops into
local function list_rows()
    local ui = layout()
    local keyboard = key_metrics()
    local bottom = (keyboard and keyboard.top or ui.pager_top) - 2

    return math.max(1, bottom - ui.list_top + 1)
end

local function per_page()
    if not monitor then return 1 end
    return list_rows() * layout().columns
end

local function page_count()
    return math.max(1, math.ceil(#items / per_page()))
end

local function clear(screen)
    screen.setBackgroundColour(colours.black)
    screen.clear()
end

local function draw_bar(screen, time)
    local w = screen.getSize()

    screen.setBackgroundColour(colours.lightGrey)
    screen.setTextColour(colours.black)

    screen.setCursorPos(1, 1)
    screen.write(string.rep(" ", w))

    screen.setCursorPos(2, 1)
    screen.write("Manifest")

    screen.setCursorPos(w - #time, 1)
    screen.write(time)
end

local function draw_button(x, y, width, label, bg, fg, height)
    local pad = width - #label
    local left = math.floor(pad / 2)
    local middle = math.floor(((height or 1) - 1) / 2)

    monitor.setBackgroundColour(bg)
    monitor.setTextColour(fg)

    for row = 0, (height or 1) - 1 do
        monitor.setCursorPos(x, y + row)
        if row == middle then
            monitor.write(string.rep(" ", left) .. label .. string.rep(" ", pad - left))
        else
            monitor.write(string.rep(" ", width))
        end
    end
end

local function draw_tabs(time)
    local ui = layout()
    local x = 1

    monitor.setBackgroundColour(colours.lightGrey)
    for row = 1, ui.box do
        monitor.setCursorPos(1, row)
        monitor.write(string.rep(" ", ui.w))
    end

    tabs = {}
    for i, name in ipairs(TABS) do
        local width = #name + ui.u * 2
        tabs[i] = { x = x, w = width, h = ui.box }

        draw_button(x, 1, width, name, i == tab and colours.white or colours.lightGrey,
            i == tab and colours.black or colours.grey, ui.box)

        x = x + width
    end

    monitor.setBackgroundColour(colours.lightGrey)
    monitor.setTextColour(colours.black)
    monitor.setCursorPos(ui.w - #time, 1 + ui.mid)
    monitor.write(time)
end

local function tab_at(x, y)
    for i, box in ipairs(tabs) do
        if y <= box.h and x >= box.x and x < box.x + box.w then
            return i
        end
    end
end

-- the tabs below own everything under the bar, so each one wipes the lot before
-- drawing rather than trusting whatever the last tab left behind
local function clear_body()
    local w, h = monitor.getSize()

    monitor.setBackgroundColour(colours.black)
    for row = layout().box + 1, h do
        monitor.setCursorPos(1, row)
        monitor.write(string.rep(" ", w))
    end
end

local function draw_search()
    local ui = layout()
    local w = ui.w
    local matches = query ~= "" and (#items .. " found") or ""
    local text = (query == "" and "Search" or query):sub(1, w - 4 - #matches)

    -- the gap row above keeps the field from reading as part of the tab bar
    monitor.setBackgroundColour(colours.black)
    monitor.setCursorPos(1, ui.box + 1)
    monitor.write(string.rep(" ", w))

    monitor.setBackgroundColour(colours.grey)
    for row = ui.search_top, ui.search_top + ui.box - 1 do
        monitor.setCursorPos(1, row)
        monitor.write(string.rep(" ", w))
    end

    monitor.setCursorPos(2, ui.search_top + ui.mid)
    monitor.setTextColour(query == "" and colours.lightGrey or colours.white)
    monitor.write(text)

    if matches ~= "" then
        monitor.setCursorPos(w - #matches - 1, ui.search_top + ui.mid)
        monitor.setTextColour(colours.lightGrey)
        monitor.write(matches)
    end
end

-- Columns keep a fixed width and fill top to bottom before wrapping, so a count
-- always sits a readable distance from its name rather than being flung to the
-- far edge of the screen when the list happens to be short.
local function list_shape()
    local ui = layout()
    local rows = list_rows()

    return ui, ui.columns, rows, (page - 1) * rows * ui.columns
end

local function draw_list()
    local ui, cols, used, offset = list_shape()

    monitor.setBackgroundColour(colours.black)
    for line = 0, list_rows() - 1 do
        monitor.setCursorPos(1, ui.list_top + line)
        monitor.write(string.rep(" ", ui.w))
    end

    for c = 0, cols - 1 do
        local left = math.floor(c * ui.w / cols) + 1
        local width = math.floor((c + 1) * ui.w / cols) - left + 1

        for i = 1, used do
            local item = items[offset + c * used + i]

            if item then
                local entry = queued(item.id)
                local count = commas(item.count)
                local tag = entry and ("x" .. commas(entry.amount) .. "  ") or ""
                local name = item.name:sub(1, width - 4 - #count - #tag)
                local gap = width - 4 - #name - #count - #tag
                local highlighted = item.id == selected

                monitor.setCursorPos(left, ui.list_top + i - 1)
                monitor.setBackgroundColour(highlighted and colours.green or colours.black)
                monitor.setTextColour(highlighted and colours.black or colours.white)
                monitor.write("  " .. name .. string.rep(" ", gap))
                monitor.setTextColour(highlighted and colours.black or colours.orange)
                monitor.write(tag)
                monitor.setTextColour(highlighted and colours.black or colours.lightGrey)
                monitor.write(count .. "  ")
            end
        end
    end
end

local function item_at(x, y)
    local ui, cols, used, offset = list_shape()
    local row = y - ui.list_top + 1

    if row < 1 or row > used then return nil end

    local column = math.min(cols - 1, math.floor((x - 1) * cols / ui.w))

    return items[offset + column * used + row]
end

local function draw_key(key, bg, fg)
    local pad = key.w - #key.label
    local left = math.floor(pad / 2)
    local middle = math.floor((key.h - 1) / 2)

    monitor.setBackgroundColour(bg)
    monitor.setTextColour(fg)

    for row = 0, key.h - 1 do
        monitor.setCursorPos(key.x, key.y + row)
        if row == middle then
            monitor.write(string.rep(" ", left) .. key.label .. string.rep(" ", pad - left))
        else
            monitor.write(string.rep(" ", key.w))
        end
    end
end

-- Every row is centred on the ten-key number row, so the letter rows sit
-- staggered under it the way a real keyboard does.
local function key_layout(keyboard)
    local w = monitor.getSize()
    local step = keyboard.key_w + keyboard.gap
    local left = math.floor((w - keyboard.span) / 2) + 1
    local top = keyboard.keys_top
    local laid = {}

    for row, chars in ipairs(KEY_ROWS) do
        local span = #chars * step - keyboard.gap
        local x = left + math.floor((keyboard.span - span) / 2)

        for i = 1, #chars do
            local char = chars:sub(i, i)
            laid[#laid + 1] = {
                x = x + (i - 1) * step,
                y = top + (row - 1) * keyboard.key_h,
                w = keyboard.key_w,
                h = keyboard.key_h,
                label = char,
                char = char,
            }
        end
    end

    local action = math.max(5, math.floor((keyboard.span - keyboard.gap * 2) / 4))
    local space = keyboard.span - 2 * (action + keyboard.gap)
    local y = top + #KEY_ROWS * keyboard.key_h

    laid[#laid + 1] = { x = left, y = y, w = action, h = keyboard.key_h,
        label = "back", action = "back" }
    laid[#laid + 1] = { x = left + action + keyboard.gap, y = y, w = space, h = keyboard.key_h,
        label = "space", char = " " }
    laid[#laid + 1] = { x = left + keyboard.span - action, y = y, w = action, h = keyboard.key_h,
        label = "clear", action = "clear" }

    return laid
end

local function draw_keyboard()
    local keyboard = key_metrics()

    if not keyboard then
        keys = {}
        return
    end

    local w = monitor.getSize()

    keys = key_layout(keyboard)

    monitor.setBackgroundColour(colours.black)
    monitor.setCursorPos(1, keyboard.top - 1)
    monitor.write(string.rep(" ", w))

    monitor.setBackgroundColour(colours.grey)
    for row = keyboard.top, keyboard.top + keyboard.height - 1 do
        monitor.setCursorPos(1, row)
        monitor.write(string.rep(" ", w))
    end

    for _, key in ipairs(keys) do
        draw_key(key, colours.lightGrey, key.action == "clear" and colours.red or colours.black)
    end
end

local function key_at(x, y)
    for _, key in ipairs(keys) do
        if x >= key.x and x < key.x + key.w and y >= key.y and y < key.y + key.h then
            return key
        end
    end
end

local function draw_pager()
    local ui = layout()
    local pages = page_count()
    local label = page .. "/" .. pages
    local label_x = math.floor((ui.w - #label) / 2) + 1
    local y = ui.pager_top

    pager.y = y
    pager.h = ui.box
    pager.w = ui.pager_button
    pager.prev_x = label_x - PAGER_GAP - ui.pager_button
    pager.next_x = label_x + #label + PAGER_GAP

    monitor.setBackgroundColour(colours.black)
    for row = y - 1, ui.pager_bottom do
        monitor.setCursorPos(1, row)
        monitor.write(string.rep(" ", ui.w))
    end

    draw_button(pager.prev_x, y, ui.pager_button, "<", colours.grey,
        page > 1 and colours.white or colours.lightGrey, ui.box)
    draw_button(pager.next_x, y, ui.pager_button, ">", colours.grey,
        page < pages and colours.white or colours.lightGrey, ui.box)

    monitor.setCursorPos(label_x, y + ui.mid)
    monitor.setBackgroundColour(colours.black)
    monitor.setTextColour(colours.white)
    monitor.write(label)
end

-- Fills the blank rows the pager was already keeping clear, so selecting an item
-- doesn't reflow the list out from under the finger that just tapped it. The
-- name gets the top row to itself; the row below carries the controls.
local function draw_request()
    local ui = layout()
    local w, h = ui.w, ui.h
    local top = ui.request_top
    local item = selected and selected_item()
    local showing = status and os.clock() < status.expires

    request.top = top
    request.mode = nil
    request.steps = {}

    if not item and #queue == 0 and not showing then
        monitor.setBackgroundColour(colours.black)
        for row = top, h do
            monitor.setCursorPos(1, row)
            monitor.write(string.rep(" ", w))
        end
        return
    end

    local y = top + 1
    request.y = y
    request.h = ui.box
    request.step_w = ui.step
    request.button_w = ui.request_button
    request.clear_w = ui.clear_button

    monitor.setBackgroundColour(colours.lightGrey)
    for row = top, h do
        monitor.setCursorPos(1, row)
        monitor.write(string.rep(" ", w))
    end

    local label, limit, label_y = nil, w - 2, top

    if item then
        request.mode = "item"

        local entry = queued(item.id)
        local qty = commas(amount)
        -- the counter only takes the width its digits need, and the group is
        -- pinned to the button, so growing it eats into the gap on the left
        local field = math.max(QTY_MIN * ui.u, #qty + 2 * ui.u)

        request.button_x = w - ui.request_button

        local x = request.button_x - 2 - (ui.step * 4 + field)
        local field_x = x + ui.step * 2

        request.steps = {
            { x = x, delta = -5, label = "-5", colour = colours.red },
            { x = x + ui.step, delta = -1, label = "-1", colour = colours.red },
            { x = field_x + field, delta = 1, label = "+1", colour = colours.lime },
            { x = field_x + field + ui.step, delta = 5, label = "+5", colour = colours.lime },
        }

        for _, step in ipairs(request.steps) do
            draw_button(step.x, y, ui.step, step.label, step.colour, colours.white, ui.box)
        end

        draw_button(field_x, y, field, qty, colours.grey, colours.white, ui.box)
        draw_button(request.button_x, y, ui.request_button, entry and "remove" or "add",
            colours.grey, colours.white, ui.box)

        -- with width to spare the name sits on the controls row rather than
        -- floating on a line of its own above them
        if x - 4 >= NAME_MIN then
            label_y, limit = y + ui.mid, x - 4
        end

        label = item.name
    elseif #queue > 0 then
        request.mode = "queue"
        request.button_x = w - ui.request_button
        request.clear_x = request.button_x - 1 - ui.clear_button

        local total = 0
        for _, entry in ipairs(queue) do
            total = total + entry.amount
        end

        draw_button(request.clear_x, y, ui.clear_button, "clear", colours.grey, colours.white, ui.box)
        draw_button(request.button_x, y, ui.request_button, "pull", colours.grey,
            output and colours.white or colours.lightGrey, ui.box)

        if request.clear_x - 3 >= NAME_MIN then
            label_y, limit = y + ui.mid, request.clear_x - 3
        end

        label = #queue .. (#queue == 1 and " item  " or " items  ") .. commas(total)
    end

    monitor.setCursorPos(2, label_y)
    monitor.setBackgroundColour(colours.lightGrey)
    monitor.setTextColour(colours.black)
    monitor.write(((showing and status.text or label) or ""):sub(1, limit))
end

local function spatial_ports()
    local found = {}

    for _, name in ipairs(peripheral.getNames()) do
        if is_spatial(name) then
            found[#found + 1] = name
        end
    end

    table.sort(found)
    return found
end

-- The port has two slots. A cell goes into the first, and AE2 moves it into the
-- second once the transfer finishes. The first is insert-only as far as CC is
-- concerned, which is why pulling a cell back out of it quietly does nothing.
local PORT_IN, PORT_OUT = 1, 2

local function port_slots(name)
    local ok, slots = pcall(peripheral.call, name, "list")
    if not ok or not slots then return nil end
    return slots
end

-- A relay sits against the port and is driven over the wired network, so every
-- one of its sides goes high; the computer can only ever reach what it touches,
-- so there the side has to be picked.
local function pulse()
    if not relay then
        redstone.setOutput(pulse_side, true)
        sleep(0.5)
        redstone.setOutput(pulse_side, false)
        return
    end

    if not peripheral.isPresent(relay) then return "relay is gone" end

    for _, side in ipairs(SIDE_ORDER) do
        peripheral.call(relay, "setOutput", side, true)
    end

    sleep(0.5)

    for _, side in ipairs(SIDE_ORDER) do
        peripheral.call(relay, "setOutput", side, false)
    end
end

local function relays()
    local found = {}

    for _, name in ipairs(peripheral.getNames()) do
        if is_relay(name) then
            found[#found + 1] = name
        end
    end

    table.sort(found)
    return found
end

-- getItemDetail is far too slow to call on every redraw, but a cell only needs
-- looking up once per state: the nbt hash changes when its contents do. Anvil
-- names come through here, which is the only way to tell two cells apart.
local function cell_label(inv, slot, item)
    local key = item.nbt or item.name
    local known = cell_names[key]
    if known then return known end

    local ok, detail = pcall(peripheral.call, inv, "getItemDetail", slot)
    local label = ok and detail and detail.displayName or format_name(item.name)

    -- displayName carries a superscript 3 the terminal font has no glyph for
    label = label:gsub("[\128-\255]", "")
    cell_names[key] = label

    return label
end

-- One pulse does whichever transfer the cell calls for: an empty cell captures
-- the region, a loaded one puts it back. So there is only ever one thing to do
-- to a cell, and the port is left empty afterwards rather than holding onto it.
local function use_cell(slot)
    local port = spatial_ports()[1]
    if not port then return "no spatial IO port" end

    local slots = port_slots(port)
    if not slots then return "port unreadable" end
    if slots[PORT_IN] then return "port is busy" end
    if slots[PORT_OUT] then return "clear the port first" end

    if peripheral.call(barrel, "pushItems", port, slot, 1, PORT_IN) == 0 then
        return "could not move the cell"
    end

    local failure = pulse()
    if failure then return failure end

    -- the transfer is not instant, so wait for the cell to come out the far side
    for _ = 1, 20 do
        sleep(0.25)

        local now = port_slots(port)
        if now and now[PORT_OUT] then
            if peripheral.call(port, "pushItems", barrel, PORT_OUT, 1, slot) == 0 then
                return "barrel is full"
            end
            return
        end
    end

    return "transfer did not finish"
end

-- a cell put in by hand through the AE2 screen is waiting in the input slot
-- with nothing to press, so it gets a pulse of its own
local function trigger_port(port)
    local slots = port_slots(port)
    if not slots then return "port unreadable" end
    if not slots[PORT_IN] then return "no cell waiting" end

    return pulse()
end

local function clear_port(port)
    if not barrel then return "no cell barrel set" end

    local slots = port_slots(port)
    if not slots then return "port unreadable" end
    if not slots[PORT_OUT] then return "nothing to put away" end

    if peripheral.call(port, "pushItems", barrel, PORT_OUT, 1) == 0 then
        return "barrel is full"
    end
end

-- Nothing readable on the item says whether a cell is holding a region, so the
-- mark set when one was used is what the list goes on. It is keyed by slot,
-- which is why use_cell is careful to put a cell back where it found it.
local function barrel_cells()
    local ok, slots = pcall(peripheral.call, barrel, "list")
    if not ok or not slots then return nil end

    local found = {}
    for slot, item in pairs(slots) do
        found[#found + 1] = { slot = slot, label = cell_label(barrel, slot, item),
            loaded = loaded[slot] or false }
    end

    table.sort(found, function(a, b) return a.slot < b.slot end)
    return found
end

-- Every peripheral read the tab needs, collected before a single character is
-- painted. Calls over a wired modem yield, and yielding after the body has been
-- wiped leaves the blank frame on screen long enough to flicker.
local function spatial_view()
    local ports = {}

    for _, name in ipairs(spatial_ports()) do
        local slots = port_slots(name)
        local state = "ready"

        if not slots then
            state = "unreadable"
        elseif slots[PORT_IN] then
            state = "busy"
        elseif slots[PORT_OUT] then
            state = "finished"
        end

        ports[#ports + 1] = { name = name, state = state }
    end

    local inventories = {}

    for _, name in ipairs(peripheral.getNames()) do
        -- the output is where requested items land, so it is never the barrel
        if is_inventory(name) and not is_spatial(name) and name ~= output then
            inventories[#inventories + 1] = name
        end
    end
    table.sort(inventories)

    return {
        ports = ports,
        inventories = inventories,
        cells = barrel and barrel_cells() or nil,
    }
end

local function draw_pulse_row(ui, y)
    local target = relay and (relay:gsub("^redstone_", "")):sub(1, 10) or "computer"
    local width = #target + 2 * ui.u
    local x = ui.option_x

    monitor.setBackgroundColour(colours.black)
    monitor.setCursorPos(2, y + ui.mid)
    monitor.setTextColour(colours.lightGrey)
    monitor.write("Pulse")

    controls[#controls + 1] = { x = x, y = y, w = width, h = ui.box, kind = "target" }
    draw_button(x, y, width, target, colours.green, colours.black, ui.box)

    -- a relay gets every side, so the side only means anything for the computer
    if not relay then
        x = x + width + ui.u
        width = 8 * ui.u

        controls[#controls + 1] = { x = x, y = y, w = width, h = ui.box, kind = "side" }
        draw_button(x, y, width, pulse_side, colours.green, colours.black, ui.box)
    end
end

local function draw_barrel_picker(ui, y, bottom, found)
    local w = ui.w

    monitor.setCursorPos(2, y)
    monitor.setTextColour(colours.lightGrey)
    monitor.write("Where do the cells live?")
    y = y + 1

    local room = math.max(1, bottom - y)
    local rows = #found > room and math.max(1, room - ui.box) or room

    if barrel_offset >= #found then
        barrel_offset = 0
    end

    for i = 1, rows do
        local name = found[barrel_offset + i]
        if not name then break end

        local row_y = y + i - 1
        local chosen = name == barrel
        local text = name:sub(1, w - 4)

        controls[#controls + 1] = { x = 2, y = row_y, w = w - 2, h = 1, kind = "barrel", value = name }

        monitor.setCursorPos(2, row_y)
        monitor.setBackgroundColour(chosen and colours.green or colours.black)
        monitor.setTextColour(chosen and colours.black or colours.white)
        monitor.write(" " .. text .. string.rep(" ", w - 4 - #text) .. " ")
    end

    if #found > rows then
        local more_y = y + rows

        controls[#controls + 1] = { x = 2, y = more_y, w = ui.more_button, h = ui.box,
            kind = "barrel_more", value = rows }
        draw_button(2, more_y, ui.more_button, "more", colours.grey, colours.white, ui.box)
    end
end

local function draw_spatial()
    local view = spatial_view()
    local ui = layout()
    local w, h = ui.w, ui.h
    local pulse_y = h - ui.box
    local y = ui.box + 2

    controls = {}
    clear_body()

    if barrel_picking or not barrel then
        draw_barrel_picker(ui, y, pulse_y - 1, view.inventories)
        draw_pulse_row(ui, pulse_y)
        return
    end

    monitor.setCursorPos(2, y)
    monitor.setTextColour(colours.lightGrey)
    monitor.write("Spatial IO")
    y = y + 1

    if #view.ports == 0 then
        monitor.setCursorPos(2, y)
        monitor.setTextColour(colours.grey)
        monitor.write("No ports on the network")
        y = y + 2
    else
        for _, port in ipairs(view.ports) do
            if y >= pulse_y - 1 then break end

            -- normally there is nothing to press here; the buttons are for
            -- digging out a cell the port held onto
            local action = (port.state == "finished" and "clear")
                or (port.state == "busy" and "pulse") or nil
            local button_x = w - ui.store_button
            local room = (action and button_x or w) - 3
            local text = port.name:sub(1, math.max(1, room - #port.state - 2))

            monitor.setBackgroundColour(colours.black)
            monitor.setCursorPos(2, y)
            monitor.setTextColour(colours.white)
            monitor.write(text)

            monitor.setTextColour(port.state == "unreadable" and colours.red
                or port.state == "ready" and colours.grey or colours.lightGrey)
            monitor.write(("  " .. port.state):sub(1, room - #text))

            if action then
                controls[#controls + 1] = { x = button_x, y = y, w = ui.store_button, h = 1,
                    kind = action, value = port.name }
                draw_button(button_x, y, ui.store_button, action, colours.grey, colours.white, 1)
            end

            y = y + 1
        end

        y = y + 1
    end

    local change_x = w - ui.change_button

    monitor.setBackgroundColour(colours.black)
    monitor.setCursorPos(2, y)
    monitor.setTextColour(colours.lightGrey)
    monitor.write("Cells")

    controls[#controls + 1] = { x = change_x, y = y, w = ui.change_button, h = 1, kind = "change" }
    draw_button(change_x, y, ui.change_button, "change", colours.black, colours.grey, 1)
    y = y + 1

    local cells = view.cells
    local room = math.max(1, pulse_y - y - 1)

    if not cells then
        monitor.setCursorPos(2, y)
        monitor.setTextColour(colours.red)
        monitor.write("barrel unreadable")
    elseif #cells == 0 then
        monitor.setCursorPos(2, y)
        monitor.setTextColour(colours.grey)
        monitor.write("no cells in " .. barrel:sub(1, w - 15))
    else
        for i = 1, math.min(#cells, room) do
            local cell = cells[i]
            local row_y = y + i - 1
            local button_x = w - ui.load_button
            local action = cell.loaded and "unload" or "load"
            local text = cell.label:sub(1, math.max(1, button_x - 4 - (cell.loaded and 8 or 0)))

            controls[#controls + 1] = { x = button_x, y = row_y, w = ui.load_button, h = 1,
                kind = action, value = cell.slot }

            monitor.setBackgroundColour(colours.black)
            monitor.setCursorPos(2, row_y)
            monitor.setTextColour(colours.white)
            monitor.write(text)

            if cell.loaded then
                monitor.setTextColour(colours.green)
                monitor.write("  loaded")
            end

            draw_button(button_x, row_y, ui.load_button, action, colours.grey, colours.white, 1)
        end
    end

    draw_pulse_row(ui, pulse_y)
end

local function draw_options(y, label, values, current, kind, suffix)
    local ui = layout()
    local x = ui.option_x

    monitor.setBackgroundColour(colours.black)
    monitor.setCursorPos(2, y + ui.mid)
    monitor.setTextColour(colours.lightGrey)
    monitor.write(label)

    for _, value in ipairs(values) do
        local text = value .. suffix
        local width = #text + 2 * ui.u
        local active = value == current

        controls[#controls + 1] = { x = x, y = y, w = width, h = ui.box, kind = kind, value = value }
        draw_button(x, y, width, text, active and colours.green or colours.grey,
            active and colours.black or colours.white, ui.box)

        x = x + width + ui.u
    end
end

local function draw_settings()
    local ui = layout()
    local w = ui.w
    local interval_y = ui.h - ui.box
    local scale_y = interval_y - ui.box - 1
    local top = ui.box + 3
    local rows = scale_y - top - 2
    local found = {}

    for _, name in ipairs(peripheral.getNames()) do
        if is_inventory(name) and not is_spatial(name) then
            found[#found + 1] = name
        end
    end
    table.sort(found)

    controls = {}
    clear_body()

    if output_offset >= #found then
        output_offset = 0
    end

    monitor.setCursorPos(2, ui.box + 2)
    monitor.setTextColour(colours.lightGrey)
    monitor.write("Output inventory")

    for i = 1, rows do
        local name = found[output_offset + i]
        if not name then break end

        local y = top + i - 1
        local chosen = name == output
        local text = name:sub(1, w - 4)

        controls[#controls + 1] = { x = 2, y = y, w = w - 2, h = 1, kind = "output", value = name }

        monitor.setCursorPos(2, y)
        monitor.setBackgroundColour(chosen and colours.green or colours.black)
        monitor.setTextColour(chosen and colours.black or colours.white)
        monitor.write(" " .. text .. string.rep(" ", w - 4 - #text) .. " ")
    end

    if #found > rows then
        local y = top + rows

        controls[#controls + 1] = { x = 2, y = y, w = ui.more_button, h = ui.box, kind = "more", value = rows }
        draw_button(2, y, ui.more_button, "more", colours.grey, colours.white, ui.box)
    end

    draw_options(scale_y, "Text scale", SCALES, scale, "scale", "")
    draw_options(interval_y, "Scan every", INTERVALS, interval, "interval", "s")
end

-- the label on each button is its kind, so a control carries everything the
-- handler needs to flash it and run it
local ACTIONS = {
    load = { run = use_cell, width = "load_button", cell = true },
    unload = { run = use_cell, width = "load_button", cell = true },
    pulse = { run = trigger_port, width = "store_button" },
    clear = { run = clear_port, width = "store_button" },
}

local function control_at(x, y)
    for _, control in ipairs(controls) do
        if y >= control.y and y < control.y + control.h
            and x >= control.x and x < control.x + control.w then
            return control
        end
    end
end

-- Failures get their own box over the list instead of the request bar, which is
-- far too narrow to show a message like "no output inventory configured".
local function draw_toast()
    if not (error_toast and os.clock() < error_toast.expires) then return end

    local w = monitor.getSize()
    local text = error_toast.text:sub(1, w - 4)
    local width = #text + 2
    local x = w - width
    -- the list repaints every row it owns, so anchoring inside it lets the next
    -- redraw wipe the toast once it expires
    local y = layout().list_top

    monitor.setBackgroundColour(colours.red)
    for row = y, y + 2 do
        monitor.setCursorPos(x, row)
        monitor.write(string.rep(" ", width))
    end

    monitor.setCursorPos(x + 1, y + 1)
    monitor.setBackgroundColour(colours.black)
    monitor.setTextColour(colours.red)
    monitor.write(text)
end

-- the list only redraws twice a second, so without a flash a tap feels dead
local function press(x, width, label, fg)
    draw_button(x, request.y, width, label, colours.white, fg)
    sleep(0.08)
end

local function draw_debug(rows)
    local w = term.getSize()
    term.setBackgroundColour(colours.black)

    for i, row in ipairs(rows) do
        local y = i + 2

        term.setCursorPos(2, y)
        term.setTextColour(colours.lightGrey)
        term.write(row[1])

        term.setCursorPos(14, y)
        term.setTextColour(colours.white)
        term.write(row[2] .. string.rep(" ", w - 13 - #row[2]))
    end
end

-- Every attached peripheral and whether we count it as storage, so an empty
-- item list can be told apart from nothing being detected in the first place
local function draw_peripherals(top)
    local w, h = term.getSize()
    local y = top

    term.setCursorPos(2, y)
    term.setTextColour(colours.lightGrey)
    term.write("Peripherals" .. string.rep(" ", w - 12))
    y = y + 1

    for _, name in ipairs(peripheral.getNames()) do
        if y > h then break end
        local storage_peripheral = is_inventory(name)
        local text = (storage_peripheral and "+ " or "- ") .. name .. " (" .. peripheral.getType(name) .. ")"

        term.setCursorPos(2, y)
        term.setTextColour(storage_peripheral and colours.white or colours.grey)
        term.write(text:sub(1, w - 2) .. string.rep(" ", math.max(0, w - 1 - #text)))
        y = y + 1
    end

    for blank = y, h do
        term.setCursorPos(1, blank)
        term.setBackgroundColour(colours.black)
        term.write(string.rep(" ", w))
    end
end

local function redraw(time)
    if not monitor then return end

    draw_tabs(time)

    if tab == 1 then
        draw_search()
        draw_list()
        draw_keyboard()
        draw_pager()
        draw_request()
        draw_toast()
    elseif tab == 2 then
        draw_spatial()
        draw_toast()
    else
        draw_settings()
    end
end

local function scan_loop()
    while true do
        local chests = storage()
        local started = os.epoch("utc")
        local counts, reached = scan(chests)

        stats.elapsed = os.epoch("utc") - started
        stats.chests = reached .. "/" .. #chests
        stock = sorted(counts)
        items = matching(stock)

        if page > page_count() then
            page = page_count()
        end

        -- stock moves under us, so a request can't outlive what's left
        local item = selected_item()
        if selected and not item then
            selected, amount = nil, 1
        elseif item and amount > item.count then
            amount = item.count
        end

        for i = #queue, 1, -1 do
            local held = counts[queue[i].id]
            if not held then
                table.remove(queue, i)
            elseif queue[i].amount > held then
                queue[i].amount = held
            end
        end

        local total = 0
        for _, item in ipairs(stock) do
            total = total + item.count
        end

        local keyboard = key_metrics()
        local size = "none"
        if monitor then
            local mw, mh = monitor.getSize()
            size = mw .. "x" .. mh
        end

        local time = textutils.formatTime(os.time(), true)
        redraw(time)

        draw_bar(term, time)
        draw_debug({
            { "Monitor", size .. " @" .. scale },
            { "Keyboard", keyboard and (keyboard.key_w .. "x" .. keyboard.key_h .. " keys")
                or (keyboard_open and "no room" or "closed") },
            { "Uptime", math.floor(os.clock()) .. "s" },
            { "World time", time },
            { "Chests", stats.chests },
            { "Item types", tostring(#stock) },
            { "Search", query ~= "" and (query .. " -> " .. #items) or "-" },
            { "Total items", commas(total) },
            { "Scan", stats.elapsed .. "ms every " .. interval .. "s" },
            { "Page", page .. "/" .. page_count() },
            { "Output", output or "none" },
            { "Queue", #queue > 0 and (#queue .. " items") or "-" },
            { "Tab", TABS[tab] },
            { "Selected", selected and (selected .. " x" .. amount) or "-" },
        })
        draw_peripherals(17)

        sleep(interval)
    end
end

local function input_loop()
    while true do
        local _, side, x, y = os.pullEvent("monitor_touch")

        if side == monitor_name then
            if y <= layout().box then
                local picked = tab_at(x, y)

                if picked and picked ~= tab then
                    tab = picked
                    clear(monitor)
                    redraw(textutils.formatTime(os.time(), true))
                end
            elseif tab == 1 then
                local ui = layout()
                local key = key_at(x, y)

                if key then
                    draw_key(key, colours.white, colours.black)
                    sleep(0.08)

                    if key.action == "back" then
                        query = query:sub(1, -2)
                    elseif key.action == "clear" then
                        query = ""
                    else
                        query = query .. key.char
                    end

                    items = matching(stock)
                    page = 1
                    redraw(textutils.formatTime(os.time(), true))
                elseif y >= ui.search_top and y < ui.search_top + ui.box then
                    keyboard_open = not keyboard_open
                    page = math.min(page, page_count())
                    redraw(textutils.formatTime(os.time(), true))
                elseif y >= pager.y and y < pager.y + pager.h then
                    local pages = page_count()

                    if x >= pager.prev_x and x < pager.prev_x + pager.w and page > 1 then
                        page = page - 1
                    elseif x >= pager.next_x and x < pager.next_x + pager.w and page < pages then
                        page = page + 1
                    end

                    redraw(textutils.formatTime(os.time(), true))
                elseif y >= ui.list_top and y < ui.list_top + list_rows() then
                    local item = item_at(x, y)

                    if item then
                        -- tapping the highlighted row again clears it
                        selected = selected ~= item.id and item.id or nil

                        -- picking up a queued item resumes its amount rather than
                        -- starting over at one
                        local entry = selected and queued(selected)
                        amount = entry and entry.amount or 1
                        status, error_toast = nil, nil
                        redraw(textutils.formatTime(os.time(), true))
                    end
                elseif y >= request.top and request.mode == "item" then
                    local item = selected_item()

                    if item then
                        local step = step_at(x)

                        if step then
                            press(step.x, request.step_w, step.label, step.colour)
                            amount = math.max(1, math.min(item.count, amount + step.delta))
                        elseif x >= request.button_x and x < request.button_x + request.button_w then
                            press(request.button_x, request.button_w, request.queued and "remove" or "add",
                                colours.grey)

                            local entry, index = queued(item.id)
                            if entry then
                                table.remove(queue, index)
                            else
                                queue[#queue + 1] = { id = item.id, amount = amount }
                            end

                            selected, amount = nil, 1
                        end

                        -- the counter is the queued amount once an item is on the
                        -- list, so stepping it edits the queue in place
                        local entry = selected and queued(selected)
                        if entry then
                            entry.amount = amount
                        end

                        redraw(textutils.formatTime(os.time(), true))
                    end
                elseif y >= request.top and request.mode == "queue" then
                    if x >= request.clear_x and x < request.clear_x + request.clear_w then
                        press(request.clear_x, request.clear_w, "clear", colours.grey)
                        queue = {}
                    elseif x >= request.button_x and x < request.button_x + request.button_w then
                        press(request.button_x, request.button_w, "pull", colours.grey)

                        local wanted = #queue
                        local filled, failure = pull()
                        status, error_toast = nil, nil

                        if failure then
                            error_toast = { text = failure, expires = os.clock() + 3 }
                        elseif filled < wanted then
                            status = { text = "Sent " .. filled .. " of " .. wanted, expires = os.clock() + 3 }
                        else
                            status = { text = "Sent " .. filled .. (filled == 1 and " request" or " requests"),
                                expires = os.clock() + 3 }
                        end
                    end

                    redraw(textutils.formatTime(os.time(), true))
                end
            elseif tab == 2 then
                local ui = layout()
                local control = control_at(x, y)

                if control then
                    if control.kind == "barrel" then
                        barrel = control.value
                        barrel_picking = false
                    elseif control.kind == "change" then
                        barrel_picking = true
                    elseif ACTIONS[control.kind] then
                        local action = ACTIONS[control.kind]

                        draw_button(control.x, control.y, ui[action.width], control.kind,
                            colours.white, colours.grey)
                        sleep(0.08)

                        local failure = action.run(control.value)

                        -- one pulse does whichever transfer the cell was due, so
                        -- a run that worked always flips which side it is on
                        if action.cell and not failure then
                            loaded[control.value] = not loaded[control.value] or nil
                            save_config()
                        end

                        error_toast = failure and { text = failure, expires = os.clock() + 3 } or nil
                    elseif control.kind == "side" then
                        local at = 1
                        for i, name in ipairs(SIDE_ORDER) do
                            if name == pulse_side then at = i end
                        end
                        pulse_side = SIDE_ORDER[at % #SIDE_ORDER + 1]
                    elseif control.kind == "target" then
                        -- the computer itself leads, then whatever relays are out there
                        local choices = { false }
                        for _, name in ipairs(relays()) do
                            choices[#choices + 1] = name
                        end

                        local at = 1
                        for i, name in ipairs(choices) do
                            if name == relay then at = i end
                        end

                        relay = choices[at % #choices + 1] or nil
                    else
                        barrel_offset = barrel_offset + control.value
                    end

                    if control.kind == "barrel" or control.kind == "side"
                        or control.kind == "target" then
                        save_config()
                    end

                    redraw(textutils.formatTime(os.time(), true))
                end
            elseif tab == 3 then
                local control = control_at(x, y)

                if control then
                    if control.kind == "output" then
                        output = control.value
                    elseif control.kind == "scale" then
                        scale = control.value
                        monitor.setTextScale(scale)
                        clear(monitor)
                    elseif control.kind == "interval" then
                        interval = control.value
                    else
                        output_offset = output_offset + control.value
                    end

                    if control.kind ~= "more" then
                        save_config()
                    end

                    redraw(textutils.formatTime(os.time(), true))
                end
            end
        end
    end
end

local config = load_config()
output = config.output
scale = config.scale or scale
interval = config.interval or interval
barrel = config.barrel
pulse_side = config.pulse or pulse_side
relay = config.relay

for slot in (config.loaded or ""):gmatch("%d+") do
    loaded[tonumber(slot)] = true
end

if not (output and peripheral.isPresent(output)) then
    shell.run("config")
    output = load_config().output
end

clear(term)
term.setCursorBlink(false)
if monitor then
    monitor.setTextScale(scale)
    clear(monitor)
end

parallel.waitForAll(scan_loop, input_loop)
