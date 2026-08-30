local monitor = peripheral.find("monitor")
if monitor then
    monitor.setTextScale(1)
end

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

local function storage()
    local found = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "inventory") then
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
    local items = {}
    for id, count in pairs(counts) do
        items[#items + 1] = { name = format_name(id), count = count }
    end
    table.sort(items, function(a, b) return a.name < b.name end)
    return items
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

local function draw_list(items)
    local w, h = monitor.getSize()
    monitor.setBackgroundColour(colours.black)

    for y = 3, h do
        local item = items[y - 2]
        monitor.setCursorPos(1, y)

        if item then
            local count = commas(item.count)
            local name = item.name:sub(1, w - 4 - #count)
            local gap = w - 4 - #name - #count

            monitor.setTextColour(colours.white)
            monitor.write("  " .. name .. string.rep(" ", gap))
            monitor.setTextColour(colours.lightGrey)
            monitor.write(count .. "  ")
        else
            monitor.write(string.rep(" ", w))
        end
    end
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

clear(term)
term.setCursorBlink(false)
if monitor then
    clear(monitor)
end

while true do
    local chests = storage()
    local started = os.epoch("utc")
    local counts, reached = scan(chests)
    local elapsed = os.epoch("utc") - started

    local items = sorted(counts)
    local total = 0
    for _, item in ipairs(items) do
        total = total + item.count
    end

    local time = textutils.formatTime(os.time(), true)

    if monitor then
        draw_bar(monitor, time)
        draw_list(items)
    end

    draw_bar(term, time)
    draw_debug({
        { "Monitor", monitor and "connected" or "none" },
        { "Uptime", math.floor(os.clock()) .. "s" },
        { "World time", time },
        { "Chests", reached .. "/" .. #chests },
        { "Item types", tostring(#items) },
        { "Total items", commas(total) },
        { "Scan", elapsed .. "ms" },
    })

    sleep(0.5)
end
