local scanner = {}

-- Supported extensions
local valid_extensions = {
    ["vstpreset"] = true,
    ["fxp"] = true,
    ["fxb"] = true,
    ["nksf"] = true,
    ["rpl"] = true
}

local function get_extension(filename)
    return filename:match("^.+(%..+)$"):sub(2):lower()
end

function scanner.ScanDirectory(path, allowed_extensions)
    -- reaper.ShowConsoleMsg("Scanning: " .. path .. "\n")
    local tree = {}
    local i = 0
    
    -- Ensure path ends with separator
    local sep = package.config:sub(1,1)
    if path:sub(-1) ~= sep then path = path .. sep end

    -- Scan Subdirectories
    while true do
        local subdir = reaper.EnumerateSubdirectories(path, i)
        if not subdir then break end
        
        local full_path = path .. subdir
        local children = scanner.ScanDirectory(full_path, allowed_extensions) -- Recursion
        
        table.insert(tree, {
            name = subdir,
            path = full_path,
            is_dir = true,
            children = children
        })
        i = i + 1
    end

    -- Scan Files
    i = 0
    while true do
        local file = reaper.EnumerateFiles(path, i)
        if not file then break end
        
        local ext = file:match("^.+(%..+)$")
        if ext then
            ext = ext:sub(2):lower()
            -- Check against allowed_extensions
            if allowed_extensions and allowed_extensions[ext] then
                -- reaper.ShowConsoleMsg("  Found file: " .. file .. "\n")
                table.insert(tree, {
                    name = file,
                    path = path .. file,
                    is_dir = false,
                    ext = ext
                })
            else
                -- reaper.ShowConsoleMsg("  Skipped (ext): " .. file .. " [" .. tostring(ext) .. "]\n")
            end
        end
        i = i + 1
    end

    -- Sort the tree: directories first, then files, both alphabetically
    table.sort(tree, function(a, b)
        if a.is_dir and not b.is_dir then
            return true
        elseif not a.is_dir and b.is_dir then
            return false
        else
            return a.name:lower() < b.name:lower()
        end
    end)

    return tree
end

return scanner
