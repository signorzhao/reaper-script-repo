local gui = {}
local utils = require("utils")
local scanner = require("scanner")
local loader = require("loader")
local saver = require("saver")

local ctx
local state = {
    last_plugin_name = nil,
    root_path = nil,
    tree = nil,
    selected_file = nil,
    track = nil,
    fx_index = nil
}

function gui.Init()
    ctx = reaper.ImGui_CreateContext("Preset Manager")
end

-- Recursive function to draw tree
local function DrawTree(nodes)
    if not nodes then return end
    
    for _, node in ipairs(nodes) do
        if node.is_dir then
            if reaper.ImGui_TreeNode(ctx, node.name) then
                DrawTree(node.children)
                reaper.ImGui_TreePop(ctx)
            end
        else
            local flags = reaper.ImGui_SelectableFlags_None()
            if state.selected_file == node.path then
                flags = reaper.ImGui_SelectableFlags_Disabled()
            end
            
            if reaper.ImGui_Selectable(ctx, node.name, state.selected_file == node.path) then
                state.selected_file = node.path
                loader.LoadPreset(state.track, state.fx_index, node.path)
            end
        end
    end
end

function gui.Draw()
    local visible, open = reaper.ImGui_Begin(ctx, "Preset Manager", true)
    if visible then
        -- 1. Get Current Context
        local track, fx_idx, fx_name = utils.GetSelectedFX()
        
        if not track then
            reaper.ImGui_Text(ctx, "Please select a track and focus an FX.")
        else
            -- Update state if plugin changed
            if fx_name ~= state.last_plugin_name then
                state.last_plugin_name = fx_name
                state.track = track
                state.fx_index = fx_idx
                state.root_path = utils.LoadPath(fx_name)
                state.extensions_str = utils.LoadExtensions(fx_name)
                
                -- Parse extensions
                state.allowed_extensions = {}
                for ext in state.extensions_str:gmatch("[^,%s]+") do
                    -- Remove leading * and . (e.g. *.ffp -> ffp, .fxp -> fxp)
                    local clean_ext = ext:gsub("^[%*%.]+", ""):lower()
                    state.allowed_extensions[clean_ext] = true
                end
                
                if state.root_path and state.root_path ~= "" then
                    state.tree = scanner.ScanDirectory(state.root_path, state.allowed_extensions)
                else
                    state.tree = nil
                end
            end
            
            -- Header
            reaper.ImGui_Text(ctx, "Plugin: " .. fx_name)
            if state.root_path then
                reaper.ImGui_TextColored(ctx, 0xAAAAAAFF, state.root_path)
                reaper.ImGui_SameLine(ctx)
            end
            
            if reaper.ImGui_Button(ctx, "Set Folder") then
                if reaper.JS_Dialog_BrowseForFolder then
                    local retval, path = reaper.JS_Dialog_BrowseForFolder("Select Preset Folder for " .. fx_name, "")
                    if retval and path and path ~= "" then
                        utils.SavePath(fx_name, path)
                        state.root_path = path
                        state.tree = scanner.ScanDirectory(path, state.allowed_extensions)
                    end
                else
                    reaper.ShowMessageBox("Please install js_ReaScriptAPI to browse folders.", "Missing Dependency", 0)
                end
            end
            
            -- Save State Button
            reaper.ImGui_SameLine(ctx)
            if reaper.ImGui_Button(ctx, "Overwrite Selected") then
                if not state.selected_file or state.selected_file == "" then
                    reaper.ShowMessageBox("Please select a preset first.", "Error", 0)
                else
                    -- Get the base filename without extension
                    local base_name = state.selected_file:match("([^/\\]+)%.[^%.]+$") or "preset"
                    -- Replace extension with .fxp
                    local save_path = state.selected_file:gsub("%.[^%.]+$", ".fxp")
                    
                    -- Confirm overwrite
                    local result = reaper.ShowMessageBox(
                        "Overwrite preset:\n" .. base_name .. ".fxp\n\nThis will save the current plugin state.",
                        "Confirm Overwrite",
                        4  -- Yes/No
                    )
                    
                    if result == 6 then  -- Yes
                        if saver.SaveCurrentState(state.track, state.fx_index, save_path) then
                            reaper.ShowMessageBox("Preset overwritten successfully!", "Success", 0)
                            -- Rescan to refresh
                            state.tree = scanner.ScanDirectory(state.root_path, state.allowed_extensions)
                        end
                    end
                end
            end
            
            -- Extensions Input
            reaper.ImGui_SameLine(ctx)
            reaper.ImGui_SetNextItemWidth(ctx, 200)
            local changed, new_ext = reaper.ImGui_InputText(ctx, "Extensions", state.extensions_str)
            if changed then
                state.extensions_str = new_ext
                utils.SaveExtensions(fx_name, new_ext)
                
                -- Re-parse and Re-scan
                state.allowed_extensions = {}
                for ext in new_ext:gmatch("[^,%s]+") do
                    local clean_ext = ext:gsub("^[%*%.]+", ""):lower()
                    state.allowed_extensions[clean_ext] = true
                end
                
                if state.root_path then
                    state.tree = scanner.ScanDirectory(state.root_path, state.allowed_extensions)
                end
            end
            
            reaper.ImGui_Separator(ctx)
            
            -- Body
            if state.tree then
                if #state.tree == 0 then
                    reaper.ImGui_Text(ctx, "No presets found in folder.")
                else
                    reaper.ImGui_BeginChild(ctx, "TreeRegion", 0, 0, 0)
                    DrawTree(state.tree)
                    reaper.ImGui_EndChild(ctx)
                end
            else
                reaper.ImGui_Text(ctx, "No preset folder linked.")
            end
        end
        
        reaper.ImGui_End(ctx)
    end
    
    if not open then
        reaper.ImGui_DestroyContext(ctx)
    end
    
    return open
end

return gui
