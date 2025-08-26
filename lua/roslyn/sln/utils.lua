local log = require("roslyn.log")
local sln_api = require("roslyn.sln.api")

local M = {}

--- Searches for files with a specific extension within a directory.
--- Only files matching the provided extension are returned.
---
--- @param dir string The directory path for the search.
--- @param extensions string[] The file extensions to look for (e.g., ".sln").
---
--- @return string[] List of file paths that match the specified extension.
function M.find_files_with_extensions(dir, extensions)
    local matches = {}

    log.log(string.format("find_files_with_extensions dir: %s, extensions: %s", dir, vim.inspect(extensions)))

    for entry, type in vim.fs.dir(dir) do
        if type == "file" then
            for _, ext in ipairs(extensions) do
                if vim.endswith(entry, ext) then
                    matches[#matches + 1] = vim.fs.normalize(vim.fs.joinpath(dir, entry))
                end
            end
        end
    end

    return matches
end

---@param targets string[]
---@param csproj string
---@return string[]
local function filter_targets(targets, csproj)
    local config = require("roslyn.config").get()
    return vim.iter(targets)
        :filter(function(target)
            if config.ignore_target and config.ignore_target(target) then
                return false
            end

            return not csproj or sln_api.exists_in_target(target, csproj)
        end)
        :totable()
end

---@param buffer number
local function resolve_broad_search_root(buffer)
    local sln_root = vim.fs.root(buffer, function(fname, _)
        return fname:match("%.sln$") ~= nil or fname:match("%.slnx$") ~= nil
    end)

    local git_root = vim.fs.root(buffer, ".git")
    if sln_root and git_root then
        return git_root and sln_root:find(git_root, 1, true) and git_root or sln_root
    else
        return sln_root or git_root
    end
end

function M.find_solutions(bufnr)
    local results = vim.fs.find(function(name)
        return name:match("%.sln$") or name:match("%.slnx$") or name:match("%.slnf$")
    end, { upward = true, path = vim.api.nvim_buf_get_name(bufnr), limit = math.huge })
    log.log(string.format("find_solutions found: %s", vim.inspect(results)))
    return results
end

-- Dirs we are not looking for solutions inside
local ignored_dirs = {
    "obj",
    "bin",
    ".git",
}

function M.find_solutions_broad(bufnr)
    local root = resolve_broad_search_root(bufnr)
    local current_dir = vim.fn.expand("%:h") -- Get the current buffer's directory
    local slns, sln_filters, csprojs = M.find_sln_files(current_dir)
    local all = M.merge(slns, csprojs)
    log.log(
        string.format("find_solutions_broad root: %s, current_dir: %s, found: %s", root, current_dir, vim.inspect(all))
    )
    return
end

---@param bufnr number
---@param solutions string[]
---@param preselected_sln string?
function M.root_dir(bufnr, solutions, preselected_sln)
    log.log(string.format("root_dir solutions: %s, preselected_sln: %s", vim.inspect(solutions), preselected_sln))
    if #solutions == 1 then
        local result = vim.fs.dirname(solutions[1])
        log.log(string.format("root_dir single solution result: %s", result))
        return result
    end

    local csproj = vim.fs.find(function(name)
        return name:match("%.csproj$") ~= nil
    end, { upward = true, path = vim.api.nvim_buf_get_name(bufnr) })[1]

    local filtered_targets = filter_targets(solutions, csproj)
    local config = require("roslyn.config").get()
    if config.broad_search then
        filtered_targets = solutions
    end
    if #filtered_targets > 1 then
        local chosen = config.choose_target and config.choose_target(filtered_targets)
        if chosen then
            local result = vim.fs.dirname(chosen)
            log.log(string.format("root_dir chosen result: %s", result))
            return result
        else
            if preselected_sln and vim.list_contains(filtered_targets, preselected_sln) then
                local result = vim.fs.dirname(preselected_sln)
                log.log(string.format("root_dir preselected result: %s", result))
                return result
            end

            log.log("root_dir: Multiple potential target files found. Use :Roslyn target to select a target.")
            vim.notify(
                "Multiple potential target files found. Use `:Roslyn target` to select a target.",
                vim.log.levels.INFO,
                { title = "roslyn.nvim" }
            )
            return nil
        end
    else
        local selected_solution = vim.g.roslyn_nvim_selected_solution
        local result = vim.fs.dirname(filtered_targets[1])
            or selected_solution and vim.fs.dirname(selected_solution)
            or csproj and vim.fs.dirname(csproj)
        log.log(
            string.format(
                "root_dir fallback result: %s, selected solution: %s, csproj: %s",
                result,
                selected_solution,
                csproj
            )
        )
        return result
    end
end

---@param bufnr number
---@param targets string[]
---@return string?
function M.predict_target(bufnr, targets)
    local config = require("roslyn.config").get()

    local csproj = vim.fs.find(function(name)
        return name:match("%.csproj$") ~= nil
    end, { upward = true, path = vim.api.nvim_buf_get_name(bufnr) })[1]

    local filtered_targets = filter_targets(targets, csproj)
    local result
    if #filtered_targets > 1 then
        result = config.choose_target and config.choose_target(filtered_targets) or nil
    else
        result = filtered_targets[1]
    end
    log.log(string.format("predict_target targets: %s, result: %s", vim.inspect(targets), result))
    return result
end

-- alternative broad search --

local function debug(...)
    local config = require("roslyn.config").get()
    if config.debug then
        vim.notify(..., vim.log.levels.DEBUG)
    end
end

local excluded_dirs = {
    node_modules = "node_modules",
    git = ".git",
    dist = "dist",
    wwwroot = "wwwroot",
    properties = "properties",
    build = "build",
    bin = "bin",
    debug = "debug",
    obj = "obj",
}

M.is_excluded = function(name)
    for _, pattern in pairs(excluded_dirs) do
        if string.match(name:lower(), pattern) then
            return true
        end
    end
    return false
end

M.patterns = {
    sln = "%.sln[x]?$", -- % is excape char symbol
    slnf = "%.slnf$",
    csproj = "%.csproj$",
}

M.is_start_with_symbol = function(name)
    return string.match(name, "^[^0-9A-Za-z_]") ~= nil
end

M.merge = function(table1, table2)
    local merged_table = {}
    local index = 1
    for _, value in pairs(table1) do
        table.insert(merged_table, index, value)
        index = index + 1
    end
    for _, value in pairs(table2) do
        table.insert(merged_table, index, value)
        index = index + 1
    end
    return merged_table
end

---@param current_dir string
---@return string[] slns, string[] slnfs, string[] csprojs
M.find_sln_files = function(current_dir)
    local visited_dirs = {}
    local extracted_dirs = {}

    local slns = {} --- @type string[]
    local slnfs = {} --- @type string[]
    local csprojs = {} --- @type string[]

    ---finds proj or sln files in the directory
    local function find_in_dir(dir)
        if not M.is_excluded(dir) then
            visited_dirs[dir] = true
        end

        visited_dirs["find_in_dir " .. dir] = true
        local handle, err = vim.uv.fs_scandir(dir)

        if not handle then
            vim.notify("Error scanning in directory: " .. err, vim.log.levels.WARN)
            return slns, slnfs, csprojs
        end

        while true do
            local name, type = vim.uv.fs_scandir_next(handle)
            if not name then
                debug("find_in_dir no more files " .. dir)
                break
            end

            local full_path = vim.fs.normalize(vim.fs.joinpath(dir, name))

            if not visited_dirs[full_path] and not M.is_excluded(name) and not M.is_start_with_symbol(name) then
                if type == "file" then
                    if string.match(name, M.patterns.sln) ~= nil then
                        table.insert(slns, full_path)
                    elseif string.match(name, M.patterns.slnf) ~= nil then
                        table.insert(slnfs, full_path)
                    elseif string.match(name, M.patterns.csproj) ~= nil then
                        table.insert(csprojs, full_path)
                    end
                elseif type == "directory" then
                    table.insert(extracted_dirs, full_path)
                end
            end
            visited_dirs[full_path] = true
        end
    end

    local function search_upwards(path)
        local dir = path
        while true do
            find_in_dir(dir)
            if #slns > 0 or #slnfs > 0 then
                debug("\nRoslyn solution(s) found" .. vim.inspect(M.merge(slns, slnfs)) .. "\n")
                break
            end

            if #extracted_dirs > 0 then
                dir = table.remove(extracted_dirs, 1)
                debug("extracted_dirs entry used" .. dir)
            else
                local one_up_folder = vim.uv.fs_realpath(path .. "/..") -- Move to parent directory
                debug("searching one up folder " .. one_up_folder)
                if one_up_folder == path then
                    break
                end
                path = one_up_folder
                dir = one_up_folder
            end
        end
    end

    search_upwards(current_dir)
    return slns, slnfs, csprojs
end

return M
