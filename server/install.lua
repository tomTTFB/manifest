-- Installer. Goes to GitHub unless the test server served it, which bakes its
-- own address in on the way out so local edits install exactly the same way.
local REPO = "https://raw.githubusercontent.com/tomTTFB/manifest/master"
local BAKED = "__BASE__"
local base = BAKED:find("^http") and BAKED or REPO

local function fetch(path)
    local res = http.get(base .. "/" .. path)
    if not res then
        error("could not fetch " .. path, 0)
    end
    local body = res.readAll()
    res.close()
    return body
end

-- Nothing on raw.githubusercontent lists a directory, so the released set is
-- written out here. The test server still says what it has, which is how a dev
-- script lying about the repo gets installed along with the program.
local function files()
    if base == REPO then
        return { "startup.lua", "config.lua" }
    end

    local found = {}
    for name in fetch("files"):gmatch("[^\r\n]+") do
        found[#found + 1] = name
    end
    return found
end

print("Installing from " .. base)

local names = files()

for _, name in ipairs(names) do
    local f = fs.open(name, "w")
    f.write(fetch(name))
    f.close()
    print("  " .. name)
end

print(#names .. " file(s) installed. Reboot to run.")
