local M = { namespace = vim.api.nvim_create_namespace("bend2") }

local defaults = {
  cmd = "bend",
  cmd_args = {},
  root_markers = { ".git" },
  validation = "on_save",
  diagnostics_mode = "auto",
  auto_import = false,
  formatter = true,
  root_dir = nil,
}

M.options = vim.deepcopy(defaults)
local configured = false

local function command(name, fn, desc, opts)
  opts = opts or {}
  opts.desc = desc
  vim.api.nvim_create_user_command(name, fn, opts)
end

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  require("bend2.toolchain").cache = {}
  assert(({ parser = true, on_save = true, on_type = true, off = true })[M.options.validation], "bend2.validation must be parser, on_save, on_type, or off")
  assert(({ auto = true, text = true, json = true })[M.options.diagnostics_mode], "bend2.diagnostics_mode must be auto, text, or json")
  if configured then return M end
  configured = true

  local editor = require("bend2.editor")
  local group = vim.api.nvim_create_augroup("Bend2", { clear = true })
  vim.api.nvim_create_autocmd("FileType", { group = group, pattern = "bend", callback = function(event)
    vim.bo[event.buf].omnifunc = "v:lua.require'bend2.editor'.complete"
    vim.bo[event.buf].formatexpr = "v:lua.require'bend2.editor'.format_expr"
    editor.validate_buffer(event.buf)
  end })
  vim.api.nvim_create_autocmd({ "BufWritePost", "TextChanged", "TextChangedI" }, { group = group, pattern = "*.bend", callback = function(event)
    if M.options.validation == "off" then vim.diagnostic.reset(M.namespace, event.buf); return end
    if event.event == "BufWritePost" then editor.validate_buffer(event.buf, true)
    elseif M.options.validation == "on_type" then
      local tick = vim.api.nvim_buf_get_changedtick(event.buf)
      vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(event.buf) and vim.api.nvim_buf_get_changedtick(event.buf) == tick then editor.validate_buffer(event.buf) end
      end, 350)
    elseif M.options.validation == "parser" then editor.parse_buffer(event.buf) end
  end })

  command("Bend2Help", function()
    local lines = {
      "Bend 2 for Neovim", "", "Editing: :Bend2Format :Bend2Hover :Bend2Signature :Bend2Definition :Bend2References :Bend2Rename :Bend2Symbols",
      "Compiler: :Bend2Check :Bend2CheckWorkspace :Bend2Build :Bend2Run :Bend2Base :Bend2Version :Bend2Environment :Bend2Support",
      "Proofs: :Bend2Proofs :Bend2OpenProof :Bend2ProofDetails :Bend2ProofGoal :Bend2CheckProof :Bend2ReviewLawChanges",
      "Backends: :Bend2ProbeBackend :Bend2CompareBackends :Bend2CompareProjectBackends :Bend2Benchmark",
      "No default key mappings are installed. See :help bend2 for configuration and support details.",
    }
    vim.cmd.new()
    vim.bo.buftype, vim.bo.bufhidden, vim.bo.swapfile, vim.bo.filetype = "nofile", "wipe", false, "help"
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  end, "Show Bend 2 commands")
  command("Bend2Format", editor.format, "Format the current Bend 2 buffer")
  command("Bend2Definition", editor.goto_definition, "Go to Bend 2 definition")
  command("Bend2References", editor.references, "List Bend 2 references")
  command("Bend2Rename", function(args) editor.rename(args.args) end, "Rename Bend 2 symbol", { nargs = 1 })
  command("Bend2Hover", editor.hover, "Show Bend 2 symbol details")
  command("Bend2Signature", editor.signature, "Show Bend 2 function signature")
  command("Bend2Symbols", editor.symbols, "List Bend 2 workspace symbols")
  command("Bend2Check", editor.check_current, "Check the current Bend 2 file")
  command("Bend2CheckWorkspace", editor.check_workspace, "Check every Bend 2 file in the workspace")
  command("Bend2Build", editor.build, "Build the current Bend 2 file")
  command("Bend2Run", editor.run, "Run the current Bend 2 file")
  command("Bend2Version", editor.show_version, "Show the Bend 2 compiler version")
  command("Bend2Base", function(args) editor.base(args) end, "Show Bend 2 base definitions", { nargs = "*" })
  command("Bend2RunProjectGate", function() editor.gate("check") end, "Run the Bend 2 project gate")
  command("Bend2RunSabotage", function() editor.gate("sabotage") end, "Run the Bend 2 sabotage gate")
  return M
end

return M
