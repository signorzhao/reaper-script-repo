local preset_name_extractor = {}

-- Try to extract preset name from VST chunk data
function preset_name_extractor.ExtractPresetName(chunk)
    if not chunk or chunk == "" then return nil end
    
    -- Strategy 1: Standard FXP Header (first 60 bytes)
    -- Offset 28 is prgName (28 bytes)
    if #chunk >= 56 then
        -- Check if it looks like an FXP header (CcnK magic number at offset 0)
        local magic = chunk:sub(1, 4)
        if magic == "CcnK" then
            -- Extract name at offset 28 (1-based index 29)
            local raw_name = chunk:sub(29, 29 + 27)
            local name = raw_name:match("^[^%z]+") -- Read until null terminator
            
            if name and #name > 0 then
                -- Sanitize
                name = name:gsub("^%s+", ""):gsub("%s+$", "")
                if #name > 0 then
                    return name
                end
            end
        end
    end
    
    -- Strategy 2: Search for printable strings in the first 2KB (for Opaque Chunks)
    -- Limit search to first 2KB
    local search_chunk = chunk:sub(1, math.min(2048, #chunk))
    
    -- Look for null-terminated strings that look like names
    local best_match = nil
    local best_score = 0
    
    local pos = 1
    while pos < #search_chunk do
        local null_pos = search_chunk:find("\0", pos, true)
        if not null_pos then break end
        
        local str = search_chunk:sub(pos, null_pos - 1)
        
        -- Heuristic: Length 3-30, mostly alphanumeric
        if #str >= 3 and #str <= 30 then
            local alpha_count = 0
            for i = 1, #str do
                local b = str:byte(i)
                if (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 32 or b == 95 or b == 45 then
                    alpha_count = alpha_count + 1
                end
            end
            
            local score = alpha_count / #str
            -- Prefer strings that are mostly alphanumeric and longer
            if score > 0.8 and #str > 3 then
                -- Boost score for common name patterns (e.g. starts with capital)
                if str:match("^[A-Z]") then score = score + 0.1 end
                
                if score > best_score then
                    best_score = score
                    best_match = str
                end
            end
        end
        
        pos = null_pos + 1
        if pos > 2000 then break end
    end
    
    return best_match
end

return preset_name_extractor
