--[[
    file: Harvest
    title: Gather tasks from your journal
    description: Extract and aggregate tasks from journal entries by anchor name.
    summary: Collect nested tasks under a specific anchor across journal files.
    ---
The harvest module allows you to extract tasks from your journal entries and
aggregate them into a summary file. This is useful for creating reports of
what you've accomplished under specific categories or projects.

The module exposes a single command: `:Neorg harvest <anchor> <date>`

**Usage Examples:**

1. Harvest all tasks under "Work" for December (current year):
   ```
   :Neorg harvest Work December
   ```

2. Harvest tasks for a specific date range:
   ```
   :Neorg harvest ProjectA 2025-12-01 2025-12-31
   ```

**How it works:**

Given a journal entry like this:
```norg
** Today's Tasks
   - (x) Work
   -- (x) Review pull request
   -- (x) Update documentation
   - ( ) Exercise
```

Running `:Neorg harvest Work December` will:
1. Scan all journal files in the specified month
2. Find list items that match the anchor name exactly ("Work")
3. Extract only the nested children (the `--` items)
4. Create a summary file with format: `DD.MM.YYYY task description`

**Output example:**
```
01.12.2025 Review pull request
01.12.2025 Update documentation
02.12.2025 Fix bug in API
```

The summary file is created at `journal/YYYY/MM/harvest_<anchor>.norg`
--]]

local neorg = require("neorg.core")
local config, lib, log, modules = neorg.config, neorg.lib, neorg.log, neorg.modules

local module = modules.create("external.harvest")

module.setup = function()
    return {
        success = true,
        requires = {
            "core.dirman",
            "core.integrations.treesitter",
        },
    }
end

module.load = function()
    modules.await("core.neorgcmd", function(neorgcmd)
        neorgcmd.add_commands_from_table({
            ["harvest-sessions"] = {
                min_args = 1,
                max_args = 1,
                name = "harvest-sessions",
            },
            harvest = {
                min_args = 2,
                max_args = 3,
                name = "harvest",
                complete = {
                    {},
                    { "January", "February", "March", "April", "May", "June",
                      "July", "August", "September", "October", "November", "December" },
                },
            },
        })
    end)
end

module.config.public = {
    -- Which workspace to use for the journal files.
    -- If nil, uses the current workspace.
    workspace = nil,

    -- The name for the folder in which the journal files are located.
    -- This should match your core.journal configuration.
    journal_folder = "journal",

    -- Anchors counted as personal deep work by `:Neorg harvest sessions <year>`.
    session_anchors = { "OSTEP", "Rust" },

    -- Minutes assumed for a session whose entries carry no explicit duration.
    default_session_minutes = 90,
}

--- Duration units recognised at the start of a task line, in minutes.
local DURATION_UNITS = {
    m = 1, min = 1, mins = 1, minute = 1, minutes = 1,
    h = 60, hr = 60, hrs = 60, hour = 60, hours = 60,
}

--- Parse a leading duration token: "90m ch.10 MLFQ" -> 90, "1.5h xv6" -> 90.
--- Returns nil when the line does not begin with one, so ordinary task text
--- like "004 migration guard" is not mistaken for a duration.
---@param text string
---@return number|nil minutes
local function parse_minutes(text)
    local num, unit = text:match("^(%d+%.?%d*)%s*(%a+)")
    if not num then return nil end
    local mult = DURATION_UNITS[unit:lower()]
    if not mult then return nil end
    return math.floor(tonumber(num) * mult + 0.5)
end

--- Iterate over all .norg files in a directory and call a callback for each
---@param dir_path string|PathlibPath Full path to directory
---@param callback function Called with (file_path) for each .norg file
local function for_each_norg_file(dir_path, callback)
    local dir_str = tostring(dir_path)

    local handle = vim.loop.fs_scandir(dir_str)
    if not handle then
        log.warn("Could not open directory: " .. dir_str)
        return
    end

    while true do
        local name, ftype = vim.loop.fs_scandir_next(handle)
        if not name then break end

        if ftype == "file" and name:match("%.norg$") then
            local file_path = dir_str .. config.pathsep .. name
            callback(file_path)
        end
    end
end

--- Extract date from filename (e.g., "01.norg" -> "01")
---@param file_path string
---@return string|nil day
local function get_day_from_filename(file_path)
    local filename = file_path:match("([^/]+)%.norg$")
    if filename then
        return filename
    end
    return nil
end

--- Collect the direct children of a list item whose text is exactly `anchor_name`.
--- Shared by `harvest` and `harvest sessions`.
---@param content string Full file contents
---@param anchor_name string Name to find (exact match)
---@return string[] child_texts One cleaned first-line per nested child
---@return string|nil state The anchor's own todo state character, e.g. "x" or " "
local function collect_anchor_children(content, anchor_name)
    local results = {}
    local anchor_state = nil

    local parser = vim.treesitter.get_string_parser(content, "norg")
    local tree = parser:parse()[1]
    if not tree then return results, nil end
    local root = tree:root()

    local lines = vim.split(content, "\n")

    --- Get text content from a treesitter node
    local function get_text(node)
        local sr, sc, er, ec = node:range()
        if sr == er then
            return lines[sr + 1] and lines[sr + 1]:sub(sc + 1, ec) or ""
        else
            local result = { lines[sr + 1] and lines[sr + 1]:sub(sc + 1) or "" }
            for i = sr + 2, er do
                table.insert(result, lines[i] or "")
            end
            if lines[er + 1] then
                table.insert(result, lines[er + 1]:sub(1, ec))
            end
            return table.concat(result, "\n")
        end
    end

    --- Extract first line and clean up list prefixes
    local function get_first_line(text)
        local line = text:match("^[^\n]*") or text
        -- Remove list prefixes like "-- (x) " or "- (x) "
        line = line:gsub("^%-+%s*%([^)]*%)%s*", "")
        -- Remove leading whitespace
        line = line:gsub("^%s+", "")
        return line
    end

    --- Recursively find a list item matching the anchor and extract its children
    local function find_list_item_with_anchor(node)
        local node_type = node:type()

        -- Check if this is a list item (unordered_list1, unordered_list2, etc.)
        if node_type:match("^unordered_list%d$") then
            -- Check if this list item's paragraph contains ONLY the anchor name
            for child in node:iter_children() do
                if child:type() == "paragraph" then
                    local para_text = get_text(child):gsub("^%s+", ""):gsub("%s+$", "")
                    if para_text == anchor_name then
                        -- Record the anchor's own todo state, e.g. "- (x) Rust"
                        local first_line = get_text(node):match("^[^\n]*") or ""
                        anchor_state = first_line:match("^%s*%-+%s*%((.)%)")

                        -- Found the anchor! Now get nested children
                        local base_type = node_type:match("^(.+)%d+$")

                        for nested_child in node:iter_children() do
                            local child_type = nested_child:type()
                            -- Children are nested if they have a higher number
                            if child_type:match("^" .. base_type .. "%d+$") and child_type ~= node_type then
                                local child_text = get_text(nested_child)
                                local task_desc = get_first_line(child_text)
                                if task_desc and #task_desc > 0 then
                                    table.insert(results, task_desc)
                                end
                            end
                        end
                        return true
                    end
                end
            end
        end

        -- Recurse into children
        for child in node:iter_children() do
            if find_list_item_with_anchor(child) then return true end
        end
        return false
    end

    find_list_item_with_anchor(root)
    return results, anchor_state
end

--- Read a journal file and return its contents, or nil.
---@param file_path string
---@return string|nil
local function read_file(file_path)
    local file = io.open(file_path, "r")
    if not file then return nil end
    local content = file:read("*all")
    file:close()
    return content
end

--- Find anchor and extract its children as individual task lines
---@param file_path string Full path to .norg file
---@param anchor_name string Name to find (exact match)
---@param year string Year (e.g., "2025")
---@param month string Month (e.g., "12")
---@return table|nil List of {date = "DD.MM.YYYY", task = "task text"}
local function find_anchor_children(file_path, anchor_name, year, month)
    local content = read_file(file_path)
    if not content then return nil end

    local day = get_day_from_filename(file_path)
    if not day then return nil end

    local date_str = string.format("%s.%s.%s", day, month, year)

    local results = {}
    for _, task in ipairs(collect_anchor_children(content, anchor_name)) do
        table.insert(results, { date = date_str, task = task })
    end

    return #results > 0 and results or nil
end

--- Number to month name, for the session log
local MONTH_NAMES = {
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
}

--- Month name to number mapping
local months = {
    ["January"] = 1,
    ["February"] = 2,
    ["March"] = 3,
    ["April"] = 4,
    ["May"] = 5,
    ["June"] = 6,
    ["July"] = 7,
    ["August"] = 8,
    ["September"] = 9,
    ["October"] = 10,
    ["November"] = 11,
    ["December"] = 12,
}

module.public = {
    version = "0.1.0",

    --- Harvest tasks from journal entries
    ---@param anchor string The anchor name to search for (e.g., "Work")
    ---@param date_from string Either a month name or YYYY-MM-DD format
    ---@param date_to? string Optional end date in YYYY-MM-DD format
    harvest = function(anchor, date_from, date_to)
        local workspace = module.config.public.workspace
            or module.required["core.dirman"].get_current_workspace()[1]
        local folder_name = module.config.public.journal_folder

        local month_from, year_from

        local current_time = os.date("!*t")
        month_from = months[date_from]

        if month_from ~= nil then
            -- Month name provided (e.g., "December")
            year_from = current_time.year
        else
            -- Date range provided (e.g., "2025-12-01")
            year_from, month_from = date_from:match("^(%d%d%d%d)-(%d%d)-%d%d$")
            if not year_from then
                log.error("Invalid date format. Use month name (e.g., December) or YYYY-MM-DD")
                return
            end
            month_from = tonumber(month_from)
        end

        local workspace_path = module.required["core.dirman"].get_workspace(workspace)
        local month_str = string.format("%02d", tonumber(month_from))
        local journal_dir = tostring(workspace_path)
            .. config.pathsep .. folder_name
            .. config.pathsep .. year_from
            .. config.pathsep .. month_str

        -- Collect all tasks from all files
        local all_tasks = {}

        for_each_norg_file(journal_dir, function(file_path)
            local tasks = find_anchor_children(file_path, anchor, tostring(year_from), month_str)
            if tasks then
                for _, task in ipairs(tasks) do
                    table.insert(all_tasks, task)
                end
            end
        end)

        -- Create summary file with collected content
        if #all_tasks > 0 then
            local summary_path = year_from .. config.pathsep .. month_str .. config.pathsep
            module.required["core.dirman"].create_file(
                folder_name .. config.pathsep .. summary_path .. "harvest_" .. anchor,
                workspace
            )

            vim.schedule(function()
                local buf = vim.api.nvim_get_current_buf()
                local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

                -- Find @end line (end of metadata)
                local insert_at = #lines
                for i, line in ipairs(lines) do
                    if line:match("^@end") then
                        insert_at = i
                        break
                    end
                end

                -- Format: DD.MM.YYYY task description
                local content = { "" }
                for _, task in ipairs(all_tasks) do
                    table.insert(content, task.date .. " " .. task.task)
                end

                vim.api.nvim_buf_set_lines(buf, insert_at, insert_at, false, content)
                vim.cmd("write")

                vim.notify(
                    string.format("Harvested %d tasks for '%s'", #all_tasks, anchor),
                    vim.log.levels.INFO
                )
            end)
        else
            vim.notify("No tasks found for anchor: " .. anchor, vim.log.levels.WARN)
        end
    end,

    --- Aggregate personal deep-work sessions for a whole year into one file.
    --- `:Neorg harvest-sessions <year>` -> journal/<year>/sessions.norg
    --- One session per anchor per day; minutes come from a leading duration
    --- token on any child line, otherwise `default_session_minutes`.
    ---@param year string|number e.g. 2026
    harvest_sessions = function(year)
        local workspace = module.config.public.workspace
            or module.required["core.dirman"].get_current_workspace()[1]
        local folder_name = module.config.public.journal_folder
        local workspace_path = module.required["core.dirman"].get_workspace(workspace)

        year = tostring(year)
        if not year:match("^%d%d%d%d$") then
            log.error("Invalid year. Use a four digit year, e.g. 2026")
            return
        end

        local anchors = module.config.public.session_anchors
        local default_minutes = module.config.public.default_session_minutes

        local days = {}     -- sortable key "YYYYMMDD" -> { date = "DD.MM.YYYY", tracks = {} }
        local totals = {}   -- anchor -> { sessions = n, minutes = n }
        local grand = { sessions = 0, minutes = 0 }

        for _, anchor_name in ipairs(anchors) do
            totals[anchor_name] = { sessions = 0, minutes = 0 }
        end

        for month = 1, 12 do
            local month_str = string.format("%02d", month)
            local journal_dir = tostring(workspace_path)
                .. config.pathsep .. folder_name
                .. config.pathsep .. year
                .. config.pathsep .. month_str

            -- Months that have not happened yet are not a warning
            if vim.loop.fs_stat(journal_dir) then
            for_each_norg_file(journal_dir, function(file_path)
                local day = get_day_from_filename(file_path)
                -- Only DD.norg day files; skips harvest_*.norg and anything else
                if not day or not day:match("^%d%d$") then return end

                local content = read_file(file_path)
                if not content then return end

                for _, anchor_name in ipairs(anchors) do
                    local children, state = collect_anchor_children(content, anchor_name)
                    -- The (x) on the anchor is the whole record. Children are
                    -- optional; they only matter if one carries a duration.
                    -- "- ( ) Rust" is an intention, not a session.
                    if state == "x" then
                        local minutes, explicit = 0, false
                        for _, child in ipairs(children) do
                            local m = parse_minutes(child)
                            if m then
                                minutes = minutes + m
                                explicit = true
                            end
                        end
                        if not explicit then minutes = default_minutes end

                        local key = year .. month_str .. day
                        days[key] = days[key] or {
                            date = string.format("%s %d",
                                MONTH_NAMES[month], tonumber(day)),
                            tracks = {},
                            order = {},
                        }
                        if not days[key].tracks[anchor_name] then
                            table.insert(days[key].order, anchor_name)
                        end
                        days[key].tracks[anchor_name] = minutes

                        totals[anchor_name].sessions = totals[anchor_name].sessions + 1
                        totals[anchor_name].minutes = totals[anchor_name].minutes + minutes
                        grand.sessions = grand.sessions + 1
                        grand.minutes = grand.minutes + minutes
                    end
                end
            end)
            end
        end

        local keys = {}
        for key in pairs(days) do table.insert(keys, key) end
        table.sort(keys)

        local function hours(mins)
            return string.format("%.1f h", mins / 60)
        end

        local out = {
            "* Personal deep work - " .. year,
            "",
            "  Generated by `:Neorg harvest-sessions " .. year .. "`.",
            "  Do not edit by hand - it is rebuilt from the journal anchors on every run.",
            "",
            "** Total",
            string.format("   *%d sessions, %d minutes (%s)*",
                grand.sessions, grand.minutes, hours(grand.minutes)),
            "",
        }

        for _, anchor_name in ipairs(anchors) do
            local t = totals[anchor_name]
            table.insert(out, string.format("   - %s - %d session%s, %d minutes (%s)",
                anchor_name, t.sessions, t.sessions == 1 and "" or "s",
                t.minutes, hours(t.minutes)))
        end

        table.insert(out, "")
        table.insert(out, "** Log")

        if #keys == 0 then
            table.insert(out, "   No sessions recorded yet.")
        end

        for _, key in ipairs(keys) do
            local entry = days[key]
            local parts = {}
            for _, anchor_name in ipairs(entry.order) do
                table.insert(parts, string.format("%d minutes %s",
                    entry.tracks[anchor_name], anchor_name))
            end
            table.insert(out, string.format("   %s: %s", entry.date, table.concat(parts, ", ")))
        end
        table.insert(out, "")

        module.required["core.dirman"].create_file(
            folder_name .. config.pathsep .. year .. config.pathsep .. "sessions",
            workspace
        )

        vim.schedule(function()
            local buf = vim.api.nvim_get_current_buf()
            -- Generated file: replace wholesale rather than append
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, out)
            vim.cmd("write")

            vim.notify(
                string.format("%d sessions, %d minutes across %d days in %s",
                    grand.sessions, grand.minutes, #keys, year),
                vim.log.levels.INFO
            )
        end)
    end,
}

module.on_event = function(event)
    if event.split_type[1] == "core.neorgcmd" then
        if event.split_type[2] == "harvest-sessions" then
            module.public.harvest_sessions(event.content[1])
        elseif event.split_type[2] == "harvest" then
            local anchor = event.content[1]
            local date_from = event.content[2]
            local date_to = event.content[3]
            module.public.harvest(anchor, date_from, date_to)
        end
    end
end

module.events.subscribed = {
    ["core.neorgcmd"] = {
        ["harvest"] = true,
        ["harvest-sessions"] = true,
    },
}

return module
