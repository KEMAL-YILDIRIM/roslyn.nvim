local M = {}

---@param config? RoslynNvimConfig
function M.setup(config)
    if vim.fn.has("nvim-0.11") == 0 then
        return vim.notify("roslyn.nvim requires at least nvim 0.11", vim.log.levels.WARN, { title = "roslyn.nvim" })
    end

    local group = vim.api.nvim_create_augroup("roslyn.nvim", { clear = true })

    require("roslyn.config").setup(config)

    vim.lsp.enable("roslyn")

    vim.api.nvim_create_autocmd("FileType", {
        group = group,
        pattern = "cs",
        callback = function()
            require("roslyn.commands").create_roslyn_commands()
        end,
    })

    vim.treesitter.language.register("c_sharp", "csharp")

    vim.api.nvim_create_autocmd({ "BufReadCmd" }, {
        group = group,
        pattern = "roslyn-source-generated://*",
        callback = function(args)
            vim.bo[args.buf].modifiable = true
            vim.bo[args.buf].swapfile = false

            -- This triggers FileType event which should fire up the lsp client if not already running
            vim.bo[args.buf].filetype = "cs"
            local client = vim.lsp.get_clients({ name = "roslyn" })[1]
            assert(client, "Must have a `roslyn` client to load roslyn source generated file")

            local content
            local function handler(err, result)
                assert(not err, vim.inspect(err))
                content = result.text
                if content == nil then
                    content = ""
                end
                local normalized = string.gsub(content, "\r\n", "\n")
                local source_lines = vim.split(normalized, "\n", { plain = true })
                vim.api.nvim_buf_set_lines(args.buf, 0, -1, false, source_lines)
                vim.b[args.buf].resultId = result.resultId
                vim.bo[args.buf].modifiable = false
            end

            local params = {
                textDocument = {
                    uri = args.match,
                },
                resultId = nil,
            }

            local co = coroutine.create(function()
                local root = utils.root(opt.buf)
                vim.b.roslyn_root = root

                local multiple, solution = utils.predict_target(root)

                if multiple then
                    vim.notify(
                        "Multiple potential target files found. Use `:Roslyn target` to select a target.",
                        vim.log.levels.INFO,
                        { title = "roslyn.nvim" }
                    )

                    -- If the user has `lock_target = true` then wait for them
                    -- to choose a target explicitly before starting the LSP.
                    if roslyn_config.lock_target then
                        return
                    end
                end

                if solution then
                    vim.g.roslyn_nvim_selected_solution = solution
                    vim.api.nvim_echo({ { "Solution file found: ", "Normal" } }, true, {})
                    return roslyn_lsp.start(opt.buf, vim.fs.dirname(solution), roslyn_lsp.on_init_sln(solution))
                elseif root.projects then
                    local dir = root.projects.directory
                    return roslyn_lsp.start(opt.buf, dir, roslyn_lsp.on_init_project(root.projects.files))
                end

                -- Fallback to the selected solution if we don't find anything.
                -- This makes it work kind of like vscode for the decoded files
                if selected_solution then
                    local sln_dir = vim.fs.dirname(selected_solution)
                    return roslyn_lsp.start(opt.buf, sln_dir, roslyn_lsp.on_init_sln(selected_solution))
                end
            end)
            coroutine.resume(co)
        end,
    })
end

return M
