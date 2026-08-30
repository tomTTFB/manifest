local monitor = peripheral.find("monitor")
if not monitor then
    print("No monitor attached.")
    return
end

monitor.setTextScale(1)
local w = monitor.getSize()

monitor.setBackgroundColour(colours.black)
monitor.clear()

local function draw_bar(time)
    monitor.setBackgroundColour(colours.lightGrey)
    monitor.setTextColour(colours.black)

    monitor.setCursorPos(1, 1)
    monitor.write(string.rep(" ", w))

    monitor.setCursorPos(2, 1)
    monitor.write("Manifest")

    monitor.setCursorPos(w - #time, 1)
    monitor.write(time)
end

local last
while true do
    local now = textutils.formatTime(os.time(), true)
    if now ~= last then
        draw_bar(now)
        last = now
    end
    sleep(0.5)
end
