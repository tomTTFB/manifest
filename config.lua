-- Manifest setup. Picks the inventory that requested items get pushed into and
-- writes it to manifest.cfg. Safe to re-run whenever the storage setup changes.

local CONFIG = "manifest.cfg"

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

-- pushItems resolves its target through whatever the source is attached to, so
-- a chest on a wired network can only reach names that network also carries.
-- Every wired modem lists exactly those names.
local function on_network()
    local names = {}

    for _, side in ipairs(peripheral.getNames()) do
        if peripheral.getType(side) == "modem" and not peripheral.call(side, "isWireless") then
            for _, name in ipairs(peripheral.call(side, "getNamesRemote")) do
                names[name] = true
            end
        end
    end

    return names
end

local function candidates()
    local network = on_network()
    local found = {}

    for _, name in ipairs(peripheral.getNames()) do
        if is_inventory(name) then
            found[#found + 1] = {
                name = name,
                type = peripheral.getType(name),
                networked = network[name] or false,
            }
        end
    end

    table.sort(found, function(a, b)
        if a.networked ~= b.networked then return a.networked end
        return a.name < b.name
    end)

    return found
end

-- An inventory can only be fed by others attached the same way it is, which is
-- the whole trap this program exists to point out
local function suppliers(entry, list)
    local n = 0
    for _, other in ipairs(list) do
        if other.name ~= entry.name and other.networked == entry.networked then
            n = n + 1
        end
    end
    return n
end

local function saved(key)
    if not fs.exists(CONFIG) then return end
    local f = fs.open(CONFIG, "r")
    local body = f.readAll()
    f.close()
    return body:match(key .. "=([^\r\n]+)")
end

-- the settings tab keeps scale and interval in this same file, so don't drop
-- the keys this screen has no opinion about
local function save(values)
    local kept = {}

    if fs.exists(CONFIG) then
        local existing = fs.open(CONFIG, "r")
        for line in existing.readAll():gmatch("[^\r\n]+") do
            local key = line:match("^([%w_]+)=")
            if not (key and values[key]) then
                kept[#kept + 1] = line
            end
        end
        existing.close()
    end

    local f = fs.open(CONFIG, "w")
    for key, value in pairs(values) do
        f.write(key .. "=" .. value .. "\n")
    end
    for _, line in ipairs(kept) do
        f.write(line .. "\n")
    end
    f.close()
end

-- The web bridge can be any machine that this computer can reach, which is not
-- necessarily the one the files came from, so it gets asked for rather than
-- assumed. Blank falls back to the install server on the next port.
local function ask_bridge()
    print()
    print("Web bridge address, or blank to use whatever")
    print("machine Manifest was installed from:")
    write("  ")

    local answer = read(nil, nil, nil, saved("bridge"))
    return (answer:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function draw(list, pick, top, rows)
    local w, h = term.getSize()

    term.setBackgroundColour(colours.black)
    term.clear()

    term.setBackgroundColour(colours.lightGrey)
    term.setTextColour(colours.black)
    term.setCursorPos(1, 1)
    term.write(string.rep(" ", w))
    term.setCursorPos(2, 1)
    term.write("Manifest setup")

    term.setBackgroundColour(colours.black)
    term.setTextColour(colours.lightGrey)
    term.setCursorPos(2, 3)
    term.write("Where should requested items be sent?")

    for i = 0, rows - 1 do
        local entry = list[top + i]
        if not entry then break end

        local highlighted = top + i == pick
        local tag = entry.networked and "net" or "local"
        local text = (entry.name .. " (" .. entry.type .. ")"):sub(1, w - 10)
        local gap = w - 4 - #text - #tag

        term.setCursorPos(2, 5 + i)
        term.setBackgroundColour(highlighted and colours.grey or colours.black)
        term.setTextColour(highlighted and colours.white or colours.lightGrey)
        term.write(" " .. text .. string.rep(" ", gap) .. tag .. " ")
    end

    local n = suppliers(list[pick], list)

    term.setBackgroundColour(colours.black)
    term.setTextColour(n > 0 and colours.lightGrey or colours.red)
    term.setCursorPos(2, h - 1)
    if n > 0 then
        term.write(n .. (n == 1 and " inventory" or " inventories") .. " can push into it")
    else
        term.write("nothing can push into it - items will never arrive")
    end

    term.setTextColour(colours.grey)
    term.setCursorPos(2, h)
    term.write("arrows move   enter select   q quit")
end

local list = candidates()

if #list == 0 then
    print("No inventories attached.")
    print("Put wired modems on your chests and switch them on, then run")
    print("config again.")
    return
end

local rows = select(2, term.getSize()) - 6
local current = saved("output")
local pick, top = 1, 1

for i, entry in ipairs(list) do
    if entry.name == current then pick = i end
end

local chosen

while true do
    if pick < top then top = pick end
    if pick >= top + rows then top = pick - rows + 1 end

    draw(list, pick, top, rows)

    local _, key = os.pullEvent("key")

    if key == keys.up then
        pick = math.max(1, pick - 1)
    elseif key == keys.down then
        pick = math.min(#list, pick + 1)
    elseif key == keys.enter then
        chosen = list[pick].name
        break
    elseif key == keys.q then
        break
    end
end

term.setBackgroundColour(colours.black)
term.setTextColour(colours.white)
term.clear()
term.setCursorPos(1, 1)

if not chosen then
    print("No change.")
    return
end

print("Output set to " .. chosen)

local url = ask_bridge()
save({ output = chosen, bridge = url })

print()
if url == "" then
    print("Bridge follows the install server.")
else
    print("Bridge at " .. url)
end
print("Reboot to run Manifest.")
