local M = {}

---@param client vim.lsp.Client
function M.refresh(client)
    for buf in pairs(client.attached_buffers) do
        if vim.api.nvim_buf_is_loaded(buf) then
            local filetype = vim.api.nvim_get_option_value("filetype", { buf = buf })
            if filetype == "cs" then
                client:request(
                    vim.lsp.protocol.Methods.textDocument_diagnostic,
                    { textDocument = vim.lsp.util.make_text_document_params(buf) },
                    nil,
                    buf
                )
            end
        end
    end
end

return M
