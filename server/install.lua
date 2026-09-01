-- Test installer. The server bakes in whichever host you fetched this from,
-- so the same file works over localhost or the LAN.
local base = "__BASE__"

local function fetch(path)
    local res = http.get(base .. "/" .. path)
    if not res then
        error("could not fetch " .. path, 0)
    end
    local body = res.readAll()
    res.close()
    return body
end

print("Installing from " .. base)

local count = 0
for name in fetch("files"):gmatch("[^\r\n]+") do
    local f = fs.open(name, "w")
    f.write(fetch(name))
    f.close()
    print("  " .. name)
    count = count + 1
end

print(count .. " file(s) installed. Reboot to run.")
