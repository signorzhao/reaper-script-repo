-- @description Wwise to Reaper Importer (Track-View Sorting)
-- @version 4.3
-- @author Gemini & User
-- @about
--   v4.3 核心优化：
--   1. 排序页面现在只显示“轨道（容器）”，自动隐藏并合并内部的 Sound。
--   2. 极大地简化了排序操作，所见即所得。
--   3. 保持了 v4.2 的所有功能（记忆、瀑布流、智能匹配）。

local r = reaper
local ctx = r.ImGui_CreateContext('Wwise Importer v4.3')

-- -----------------------------
-- 配置与常量
-- -----------------------------
local EXT_SECTION = "WwiseImporter_TrackView"
local EXT_KEY_WWU = "LastWWU"
local EXT_KEY_ORIG = "LastOriginals"

local config = {
    wwu_path = "",
    originals_path = "",
    items = {},       -- 原始解析树
    file_map = {},    -- 硬盘文件索引
    
    export_list = {}, -- 待导入的列表 (存储的是“轨道对象”，而非原始 Item)
    view_mode = 0,    -- 0:选择页, 1:排序页
    
    scan_status = "",
    filter_text = ""
}

local TARGET_TAGS = {
    ["Sound"] = true, ["RandomSequenceContainer"] = true, ["SwitchContainer"] = true,
    ["BlendContainer"] = true, ["ActorMixer"] = true, ["WorkUnit"] = true, ["Folder"] = true
}

local GAP_SECONDS = 5.0
local START_SECONDS = 5.0

local function Log(msg) r.ShowConsoleMsg(tostring(msg) .. "\n") end

-- -----------------------------
-- 1. 基础功能：扫描与解析
-- -----------------------------
local function GetBasename(path)
    if not path then return "" end
    path = path:gsub("\\", "/")
    return path:match("([^/]+)$") or path
end

local function BuildFileMap()
    if config.originals_path == "" then return end
    local check = r.EnumerateFiles(config.originals_path, 0)
    if not check and not r.EnumerateSubdirectories(config.originals_path, 0) then end

    config.file_map = {}
    config.scan_status = "扫描中..."
    
    local function Scan(path)
        local i = 0
        repeat
            local file = r.EnumerateFiles(path, i)
            if file then config.file_map[file:lower()] = path .. "/" .. file end
            i = i + 1
        until not file
        local j = 0
        repeat
            local sd = r.EnumerateSubdirectories(path, j)
            if sd and sd ~= "." and sd ~= ".." then Scan(path .. "/" .. sd) end
            j = j + 1
        until not sd
    end
    
    r.defer(function() 
        Scan(config.originals_path)
        local count = 0
        for _ in pairs(config.file_map) do count = count + 1 end
        config.scan_status = "已索引 " .. count .. " 个文件"
        r.SetExtState(EXT_SECTION, EXT_KEY_ORIG, config.originals_path, true)
    end)
end

local function ParseWWU(filename)
    if not filename then return false end
    local file = io.open(filename, "r")
    if not file then return false end
    local content = file:read("*a")
    file:close()
    
    local items = {}
    local stack = {} 
    local pos = 1
    
    while true do
        local s, e, rawTag = string.find(content, "<(.-)>", pos)
        if not s then break end
        pos = e + 1
        
        if rawTag:sub(1, 1) == "/" then
            local closeType = rawTag:match("^/?([%w]+)")
            if #stack > 0 and stack[#stack].type == closeType then table.remove(stack) end
        elseif rawTag:find("Filename") then
            local nextTagStart = string.find(content, "<", pos)
            if nextTagStart then
                local val = string.sub(content, pos, nextTagStart - 1)
                val = val:gsub("[\r\n]", ""):match("^%s*(.-)%s*$")
                if val and val~="" and #stack>0 then
                    for i=#stack, 1, -1 do
                        if not stack[i].is_dummy then table.insert(stack[i].files, val); break end
                    end
                end
            end
        else
            local isSelfClosing = (rawTag:sub(-1) == "/")
            local cleanTag = isSelfClosing and rawTag:sub(1, -2) or rawTag
            local tagType = cleanTag:match("^([%w]+)")
            local tagName = cleanTag:match('Name="([^"]+)"')
            
            if tagType and TARGET_TAGS[tagType] then
                if not tagName then tagName = tagType end
                local parentObj = nil
                for i=#stack, 1, -1 do if not stack[i].is_dummy then parentObj=stack[i]; break end end
                
                local newItem = {
                    name = tagName, type = tagType, files = {}, 
                    selected = false, indent = #stack, parent = parentObj, is_dummy = false
                }
                table.insert(items, newItem)
                if not isSelfClosing then table.insert(stack, newItem) end
            elseif tagType and not isSelfClosing then
                table.insert(stack, { type = tagType, is_dummy = true, files = {} })
            end
        end
    end
    r.SetExtState(EXT_SECTION, EXT_KEY_WWU, filename, true)
    return true, items
end

-- -----------------------------
-- 2. 数据处理：合并 Sound 到 Track
-- -----------------------------
local function PrepareExportList()
    -- 我们不直接把 config.items 放入列表，而是创建一个新的“轨道列表”
    config.export_list = {} 
    
    -- 辅助表，用于快速查找某个轨道是否已经存在于列表中
    local track_map = {} 
    
    for _, item in ipairs(config.items) do
        if item.selected and not item.is_dummy then
            
            -- 1. 计算该 Item 应该属于哪个轨道
            local trackName = item.name
            if item.type == "Sound" and item.parent then
                trackName = item.parent.name
            end
            
            -- 2. 收集该 Item 贡献的文件
            local files_to_add = {}
            for _, f in ipairs(item.files) do table.insert(files_to_add, f) end
            -- 智能匹配逻辑：如果是 Sound 且没文件，尝试用名字匹配
            if #files_to_add == 0 and item.type == "Sound" then
                table.insert(files_to_add, item.name)
            end

            -- 3. 如果这个 item 有贡献文件（或者它是容器本身），就处理归并
            -- 即使是空容器，如果用户勾选了，我们也创建一个轨道条目
            
            local trackEntry = track_map[trackName]
            
            if not trackEntry then
                -- 创建新的轨道条目
                trackEntry = {
                    name = trackName,    -- 轨道名
                    files = {},          -- 该轨道下所有的文件集合
                    source_type = (item.type == "Sound" and "Merged Sounds" or item.type)
                }
                table.insert(config.export_list, trackEntry)
                track_map[trackName] = trackEntry
            end
            
            -- 将文件追加到该轨道的列表中
            for _, f in ipairs(files_to_add) do
                table.insert(trackEntry.files, f)
            end
        end
    end
    
    if #config.export_list == 0 then
        r.ShowMessageBox("请至少勾选一个容器。", "提示", 0)
    else
        config.view_mode = 1 -- 进入排序界面
    end
end

-- -----------------------------
-- 3. 执行导入 (瀑布流 + 强制定位)
-- -----------------------------
local function ImportWaterfall()
    local proj = 0 
    r.Undo_BeginBlock()
    r.PreventUIRefresh(1)
    
    local track_cache = {}
    local function GetOrCreateTrack(trackName)
        if track_cache[trackName] then return track_cache[trackName] end
        r.InsertTrackAtIndex(r.CountTracks(proj), true)
        local tr = r.GetTrack(proj, r.CountTracks(proj) - 1)
        r.GetSetMediaTrackInfo_String(tr, "P_NAME", trackName, true)
        track_cache[trackName] = tr
        return tr
    end

    local global_timeline_pos = START_SECONDS 
    local success_count = 0

    -- 遍历经过排序和合并的“轨道列表”
    for _, trackEntry in ipairs(config.export_list) do
        
        -- 过滤该轨道下的重复文件
        local unique_files = {}
        local seen = {}
        for _, f in ipairs(trackEntry.files) do
            if not seen[f] then seen[f]=true; table.insert(unique_files, f) end
        end

        if #unique_files > 0 then
            local track = GetOrCreateTrack(trackEntry.name)
            r.SetOnlyTrackSelected(track)
            
            for _, fname in ipairs(unique_files) do
                local search_name = GetBasename(fname):lower()
                if not search_name:match("%.wav$") then search_name = search_name .. ".wav" end
                
                local disk_path = config.file_map[search_name]
                if disk_path then
                    r.SetEditCurPos(global_timeline_pos, false, false) -- 保险
                    local ok = r.InsertMedia(disk_path, 0)
                    
                    if ok then
                        local item_idx = r.GetTrackMediaItem(track, r.CountTrackMediaItems(track)-1)
                        if item_idx then
                            -- 强制定位
                            r.SetMediaItemPosition(item_idx, global_timeline_pos, true)
                            
                            local len = r.GetMediaItemInfo_Value(item_idx, "D_LENGTH")
                            global_timeline_pos = global_timeline_pos + len + GAP_SECONDS
                            success_count = success_count + 1
                        end
                    end
                end
            end
        else
            -- 如果轨道没文件，如果需要也可以创建一个空轨道，这里已经由 GetOrCreateTrack 逻辑覆盖（只要列表里有，就会创建）
            if #unique_files == 0 then
                 GetOrCreateTrack(trackEntry.name)
            end
        end
    end
    
    r.PreventUIRefresh(-1)
    r.Undo_EndBlock("Wwise Import", -1)
    r.TrackList_AdjustWindows(false)
    r.UpdateArrange()
    
    config.view_mode = 0 
    r.ShowMessageBox("导入完成！\n共导入 " .. success_count .. " 个文件。", "成功", 0)
end

-- -----------------------------
-- 4. 初始化
-- -----------------------------
local function Init()
    local last_wwu = r.GetExtState(EXT_SECTION, EXT_KEY_WWU)
    local last_orig = r.GetExtState(EXT_SECTION, EXT_KEY_ORIG)
    
    if last_wwu and last_wwu ~= "" then
        local f = io.open(last_wwu, "r")
        if f then f:close(); config.wwu_path = last_wwu; local ok, res = ParseWWU(last_wwu); if ok then config.items = res end
        else config.wwu_path = "" end
    end
    if last_orig and last_orig ~= "" then
        config.originals_path = last_orig; BuildFileMap()
    end
end

-- -----------------------------
-- 5. GUI
-- -----------------------------
local function BrowseForWWU()
    if r.JS_Dialog_BrowseForOpenFiles then
        local rv, f = r.JS_Dialog_BrowseForOpenFiles("WWU", "", "", "WWU\0*.wwu\0", false)
        if rv==1 then return f end
    end
    local rv, f = r.GetUserFileNameForRead("", "WWU", ".wwu")
    return rv and f or nil
end
local function BrowseForFolder()
    if r.JS_Dialog_BrowseForFolder then
        local rv, f = r.JS_Dialog_BrowseForFolder("Originals", "")
        if rv==1 then return f end
    end
    return nil
end

local function Loop()
    local visible, open = r.ImGui_Begin(ctx, 'Wwise Importer v4.3', true, r.ImGui_WindowFlags_None())
    if visible then
        
        -- ====== 页面 0: 选择 ======
        if config.view_mode == 0 then
            r.ImGui_SeparatorText(ctx, "第一步：加载与选择")
            if r.ImGui_Button(ctx, '1. 加载 WWU') then
                local f = BrowseForWWU()
                if f then config.wwu_path = f; local ok, res = ParseWWU(f); config.items = ok and res or {} end
            end
            r.ImGui_SameLine(ctx); r.ImGui_Text(ctx, config.wwu_path:match("([^/\\]+)$") or "未加载")

            if r.ImGui_Button(ctx, '2. 扫描 Originals') then
                local f = BrowseForFolder()
                if f then config.originals_path = f; BuildFileMap() end
            end
            r.ImGui_SameLine(ctx); r.ImGui_Text(ctx, config.scan_status)

            r.ImGui_Separator(ctx)
            
            local border = r.ImGui_ChildFlags_Border and r.ImGui_ChildFlags_Border() or 1
            if r.ImGui_BeginChild(ctx, 'SelectRegion', 0, -40, border) then
                if #config.items > 0 then
                    if r.ImGui_Button(ctx, "全选") then for _,v in ipairs(config.items) do v.selected=true end end
                    r.ImGui_SameLine(ctx)
                    if r.ImGui_Button(ctx, "全不选") then for _,v in ipairs(config.items) do v.selected=false end end
                    
                    for i, item in ipairs(config.items) do
                        r.ImGui_Indent(ctx, item.indent * 12)
                        local chg, val = r.ImGui_Checkbox(ctx, "##"..i, item.selected)
                        if chg then 
                            item.selected = val
                            for j=i+1, #config.items do
                                if config.items[j].indent <= item.indent then break end
                                config.items[j].selected = val
                            end
                        end
                        r.ImGui_SameLine(ctx)
                        
                        local txt, col = item.name, 0xFFFFFFFF
                        if item.type == "Sound" then
                            local try = item.name:lower() .. ".wav"
                            if config.file_map[try] or #item.files > 0 then col = 0x88FF88FF else col = 0xAAAAAAFF end
                            txt = "♪ " .. txt
                        else
                            txt = "������ " .. txt
                        end
                        r.ImGui_TextColored(ctx, col, txt)
                        r.ImGui_Unindent(ctx, item.indent * 12)
                    end
                else
                    r.ImGui_TextDisabled(ctx, "等待文件加载...")
                end
                r.ImGui_EndChild(ctx)
            end
            
            if r.ImGui_Button(ctx, '下一步：排序并预览 >', -1, 30) then
                if #config.file_map == 0 and next(config.file_map) == nil then
                    r.ShowMessageBox("请先扫描 Originals 目录。", "警告", 0)
                else
                    PrepareExportList()
                end
            end

        -- ====== 页面 1: 排序 (轨道视图) ======
        elseif config.view_mode == 1 then
            r.ImGui_SeparatorText(ctx, "第二步：调整轨道顺序")
            r.ImGui_TextWrapped(ctx, "以下是即将生成的轨道列表。Sound 已合并入轨道。请调整轨道顺序：")
            r.ImGui_Spacing(ctx)
            
            local border = r.ImGui_ChildFlags_Border and r.ImGui_ChildFlags_Border() or 1
            if r.ImGui_BeginChild(ctx, 'SortRegion', 0, -40, border) then
                for i, trackEntry in ipairs(config.export_list) do
                    r.ImGui_PushID(ctx, i)
                    if r.ImGui_ArrowButton(ctx, "##up", r.ImGui_Dir_Up()) and i > 1 then
                        config.export_list[i], config.export_list[i-1] = config.export_list[i-1], config.export_list[i]
                    end
                    r.ImGui_SameLine(ctx)
                    if r.ImGui_ArrowButton(ctx, "##down", r.ImGui_Dir_Down()) and i < #config.export_list then
                        config.export_list[i], config.export_list[i+1] = config.export_list[i+1], config.export_list[i]
                    end
                    r.ImGui_SameLine(ctx)
                    if r.ImGui_Button(ctx, "X") then
                        table.remove(config.export_list, i)
                    end
                    r.ImGui_SameLine(ctx)
                    
                    -- 显示轨道名和文件数
                    local fileCount = 0
                    local seen = {}
                    for _, f in ipairs(trackEntry.files) do if not seen[f] then fileCount=fileCount+1; seen[f]=true end end
                    
                    r.ImGui_Text(ctx, string.format("%d. 轨道: %s (含 %d 个文件)", i, trackEntry.name, fileCount))
                    
                    r.ImGui_PopID(ctx)
                end
                r.ImGui_EndChild(ctx)
            end
            
            if r.ImGui_Button(ctx, '< 返回', 100, 30) then
                config.view_mode = 0
            end
            r.ImGui_SameLine(ctx)
            
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x228822FF)
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x33AA33FF)
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), 0x116611FF)
            
            if r.ImGui_Button(ctx, '执行导入', -1, 30) then
                ImportWaterfall()
            end
            
            r.ImGui_PopStyleColor(ctx, 3)
        end

        r.ImGui_End(ctx)
    end
    if open then r.defer(Loop) end
end

Init()
r.defer(Loop)
