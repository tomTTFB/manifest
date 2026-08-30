local monitor = peripheral.find("monitor")
if monitor then
    monitor.setTextScale(1)
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

-- All placeholders until there is a scanner to report on
local function draw_debug(time)
    local w = term.getSize()
    local rows = {
        { "Monitor", monitor and "connected" or "none" },
        { "Uptime", math.floor(os.clock()) .. "s" },
        { "World time", time },
        { "Chests", "0" },
        { "Items", "0" },
        { "Last scan", "never" },
    }

    term.setBackgroundColour(colours.black)
    for i, row in ipairs(rows) do
        local label, value = row[1], row[2]
        local y = i + 2

        term.setCursorPos(2, y)
        term.setTextColour(colours.lightGrey)
        term.write(label)

        term.setCursorPos(14, y)
        term.setTextColour(colours.white)
        term.write(value .. string.rep(" ", w - 13 - #value))
    end
end

clear(term)
term.setCursorBlink(false)
if monitor then
    clear(monitor)
end

local last
while true do
    local now = textutils.formatTime(os.time(), true)

    if monitor and now ~= last then
        draw_bar(monitor, now)
        last = now
    end

    draw_bar(term, now)
    draw_debug(now)

    sleep(0.5)
end
