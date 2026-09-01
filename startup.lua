local monitor = peripheral.find("monitor")
local monitor_name = monitor and peripheral.getName(monitor)
if monitor then
    monitor.setTextScale(1)
    -- default green is muddy and lime is neon, so sit the highlight between them
    monitor.setPaletteColour(colours.green, 0x6ABE5C)
end

local LIST_TOP = 3
local PAGER_BUTTON = 11
local PAGER_GAP = 6
local PAGER_PAD = 3

local items = {}
local page = 1
local selected = nil
local stats = { chests = "0/0", elapsed = 0 }
local pager = { y = 1, prev_x = 1, next_x = 1 }

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

local function storage()
    local found = {}
    for _, name in ipairs(peripheral.getNames()) do
        if is_inventory(name) then
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
        list[#list + 1] = { name = format_name(id), count = count }
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

-- row 1 is the bar, row 2 a gap, then the list, then a gap, the pager and
-- PAGER_PAD blank rows keeping it clear of the bottom edge
local function per_page()
    if not monitor then return 1 end
    local _, h = monitor.getSize()
    return h - 4 - PAGER_PAD
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

local function draw_list()
    local w = monitor.getSize()
    local rows = per_page()
    local offset = (page - 1) * rows

    monitor.setBackgroundColour(colours.black)

    for i = 1, rows do
        local item = items[offset + i]
        monitor.setCursorPos(1, LIST_TOP + i - 1)

        if item then
            local count = commas(item.count)
            local name = item.name:sub(1, w - 4 - #count)
            local gap = w - 4 - #name - #count
            local highlighted = item.name == selected

            monitor.setBackgroundColour(highlighted and colours.green or colours.black)
            monitor.setTextColour(highlighted and colours.black or colours.white)
            monitor.write("  " .. name .. string.rep(" ", gap))
            monitor.setTextColour(highlighted and colours.black or colours.lightGrey)
            monitor.write(count .. "  ")
        else
            monitor.setBackgroundColour(colours.black)
            monitor.write(string.rep(" ", w))
        end
    end
end

local function draw_button(x, y, glyph, enabled)
    local pad = PAGER_BUTTON - 1
    local left = math.floor(pad / 2)

    monitor.setCursorPos(x, y)
    monitor.setBackgroundColour(colours.grey)
    monitor.setTextColour(enabled and colours.white or colours.lightGrey)
    monitor.write(string.rep(" ", left) .. glyph .. string.rep(" ", pad - left))
end

local function draw_pager()
    local w, h = monitor.getSize()
    local pages = page_count()
    local label = page .. "/" .. pages
    local label_x = math.floor((w - #label) / 2) + 1

    local y = h - PAGER_PAD

    pager.y = y
    pager.prev_x = label_x - PAGER_GAP - PAGER_BUTTON
    pager.next_x = label_x + #label + PAGER_GAP

    monitor.setBackgroundColour(colours.black)
    for row = y - 1, h do
        monitor.setCursorPos(1, row)
        monitor.write(string.rep(" ", w))
    end

    draw_button(pager.prev_x, y, "<", page > 1)
    draw_button(pager.next_x, y, ">", page < pages)

    monitor.setCursorPos(label_x, y)
    monitor.setBackgroundColour(colours.black)
    monitor.setTextColour(colours.white)
    monitor.write(label)
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
    draw_bar(monitor, time)
    draw_list()
    draw_pager()
end

local function scan_loop()
    while true do
        local chests = storage()
        local started = os.epoch("utc")
        local counts, reached = scan(chests)

        stats.elapsed = os.epoch("utc") - started
        stats.chests = reached .. "/" .. #chests
        items = sorted(counts)

        if page > page_count() then
            page = page_count()
        end

        local total = 0
        for _, item in ipairs(items) do
            total = total + item.count
        end

        local time = textutils.formatTime(os.time(), true)
        redraw(time)

        draw_bar(term, time)
        draw_debug({
            { "Monitor", monitor and "connected" or "none" },
            { "Uptime", math.floor(os.clock()) .. "s" },
            { "World time", time },
            { "Chests", stats.chests },
            { "Item types", tostring(#items) },
            { "Total items", commas(total) },
            { "Scan", stats.elapsed .. "ms" },
            { "Page", page .. "/" .. page_count() },
            { "Selected", selected or "-" },
        })
        draw_peripherals(12)

        sleep(0.5)
    end
end

local function input_loop()
    while true do
        local _, side, x, y = os.pullEvent("monitor_touch")

        if side == monitor_name then
            local rows = per_page()

            if y == pager.y then
                local pages = page_count()

                if x >= pager.prev_x and x < pager.prev_x + PAGER_BUTTON and page > 1 then
                    page = page - 1
                elseif x >= pager.next_x and x < pager.next_x + PAGER_BUTTON and page < pages then
                    page = page + 1
                end

                redraw(textutils.formatTime(os.time(), true))
            elseif y >= LIST_TOP and y < LIST_TOP + rows then
                local item = items[(page - 1) * rows + (y - LIST_TOP + 1)]

                if item then
                    -- tapping the highlighted row again clears it
                    selected = selected ~= item.name and item.name or nil
                    redraw(textutils.formatTime(os.time(), true))
                end
            end
        end
    end
end

clear(term)
term.setCursorBlink(false)
if monitor then
    clear(monitor)
end

parallel.waitForAll(scan_loop, input_loop)
