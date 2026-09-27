local parser = require("bend2.parser")
local workspace = require("bend2.workspace")
local M = {}

local function cursor_context()
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  return buf, vim.api.nvim_buf_get_name(buf), cursor[1] - 1, cursor[2]
end

function M.set_diagnostics(buf, parsed)
  local items = {}
  for _, diagnostic in ipairs(parsed.diagnostics) do
    local r = diagnostic.range
    items[#items + 1] = {
      lnum = r.start.line, col = r.start.character,
      end_lnum = r.finish.line, end_col = r.finish.character,
      message = diagnostic.message,
      severity = diagnostic.severity == "error" and vim.diagnostic.severity.ERROR or vim.diagnostic.severity.WARN,
      source = diagnostic.source,
    }
  end
  vim.diagnostic.set(require("bend2").namespace, buf, items, {})
end

function M.output(title, result)
  local lines = { title, string.rep("=", #title), "Exit code: " .. tostring(result.code == nil and "unavailable" or result.code) }
  if result.stderr and result.stderr ~= "" then
    lines[#lines + 1] = ""
    for line in result.stderr:gmatch("[^\n]+") do lines[#lines + 1] = line end
  end
  if result.stdout and result.stdout ~= "" then
    lines[#lines + 1] = ""
    for line in result.stdout:gmatch("[^\n]+") do lines[#lines + 1] = line end
  end
  vim.cmd("botright new")
  vim.bo.buftype, vim.bo.bufhidden, vim.bo.swapfile, vim.bo.filetype = "nofile", "wipe", false, "bend2log"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.bo.modifiable = false
end

local function publish_compiler_result(buf, path, root, result)
  local parsed = parser.parse(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"), path)
  local items = {}
  for _, diagnostic in ipairs(parsed.diagnostics) do
    local r = diagnostic.range
    items[#items + 1] = { lnum = r.start.line, col = r.start.character, end_lnum = r.finish.line, end_col = r.finish.character, message = diagnostic.message, severity = diagnostic.severity == "error" and vim.diagnostic.severity.ERROR or vim.diagnostic.severity.WARN, source = diagnostic.source }
  end
  for _, diagnostic in ipairs(result.diagnostics or {}) do
    local diagnostic_path = diagnostic.file
    if diagnostic_path and not vim.fs.is_absolute(diagnostic_path) then diagnostic_path = vim.fs.joinpath(root, diagnostic_path) end
    if diagnostic_path and vim.fs.normalize(diagnostic_path) == vim.fs.normalize(path) then
      items[#items + 1] = { lnum = diagnostic.line, col = diagnostic.col, message = diagnostic.message, severity = diagnostic.severity == "warning" and vim.diagnostic.severity.WARN or vim.diagnostic.severity.ERROR, source = "Bend 2 compiler" }
    end
  end
  vim.diagnostic.set(require("bend2").namespace, buf, items, {})
end

function M.parse_buffer(buf)
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].filetype ~= "bend" then return end
  local source = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  M.set_diagnostics(buf, parser.parse(source, vim.api.nvim_buf_get_name(buf)))
end

function M.validate_buffer(buf, immediate)
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].filetype ~= "bend" then return end
  if require("bend2").options.validation == "off" then vim.diagnostic.reset(require("bend2").namespace, buf); return end
  M.parse_buffer(buf)
  if require("bend2").options.validation == "parser" then return end
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" then return end
  local root = workspace.root(buf, require("bend2").options)
  local changedtick = vim.api.nvim_buf_get_changedtick(buf)
  require("bend2.toolchain").check(path, root, function(result)
    if not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_buf_get_changedtick(buf) ~= changedtick then return end
    if not result.compiler or not result.compiler.available then
      if result.stderr and result.stderr ~= "" then vim.notify(result.stderr, vim.log.levels.WARN, { title = "Bend 2" }) end
      return
    end
    publish_compiler_result(buf, path, root, result)
  end)
end

function M.check_current()
  local buf, path = cursor_context()
  if path == "" then vim.notify("Save the Bend 2 buffer before checking it.", vim.log.levels.WARN); return end
  local root = workspace.root(buf, require("bend2").options)
  require("bend2.toolchain").check(path, root, function(result)
    if vim.api.nvim_buf_is_valid(buf) then publish_compiler_result(buf, path, root, result) end
    M.output("Bend 2 check: " .. vim.fn.fnamemodify(path, ":."), result)
  end)
end

function M.check_workspace()
  local buf = vim.api.nvim_get_current_buf()
  local root, files = workspace.root(buf, require("bend2").options), workspace.files(workspace.root(buf, require("bend2").options))
  local index, failed, output = 1, 0, {}
  local function next_file()
    local path = files[index]
    if not path then
      M.output("Bend 2 workspace check", { code = failed == 0 and 0 or 1, stdout = table.concat(output, "\n") })
      return
    end
    require("bend2.toolchain").check(path, root, function(result)
      if result.code ~= 0 then failed = failed + 1 end
      output[#output + 1] = path .. ": " .. (result.code == 0 and "PASS" or "FAIL")
      if result.stderr and result.stderr ~= "" then output[#output + 1] = result.stderr end
      local target_buf = vim.fn.bufnr(path)
      if target_buf > 0 and vim.api.nvim_buf_is_loaded(target_buf) then publish_compiler_result(target_buf, path, root, result) end
      index = index + 1
      next_file()
    end)
  end
  next_file()
end

function M.build()
  local buf, path = cursor_context()
  if path == "" then vim.notify("Save the Bend 2 buffer before building it.", vim.log.levels.WARN); return end
  local default = vim.fn.fnamemodify(path, ":r") .. ".js"
  vim.ui.input({ prompt = "Bend 2 output file: ", default = default }, function(output)
    if not output or output == "" then return end
    require("bend2.toolchain").build(path, output, workspace.root(buf, require("bend2").options), function(result) M.output("Bend 2 build", result) end)
  end)
end

function M.run()
  local buf, path = cursor_context()
  if path == "" then vim.notify("Save the Bend 2 buffer before running it.", vim.log.levels.WARN); return end
  vim.ui.select({ "javascript", "native", "gpu" }, { prompt = "Bend 2 execution backend" }, function(profile)
    if not profile then return end
    require("bend2.toolchain").run_profile(path, workspace.root(buf, require("bend2").options), profile, function(result) M.output("Bend 2 run (" .. profile .. ")", result) end)
  end)
end

function M.show_version()
  local buf = vim.api.nvim_get_current_buf()
  local root = workspace.root(buf, require("bend2").options)
  require("bend2.toolchain").discover(root, function(info)
    M.output("Bend 2 compiler", { code = info.available and 0 or nil, stdout = "Version: " .. tostring(info.version or "unavailable") .. "\nCompatibility: " .. info.compatibility, stderr = info.error or "" })
  end, true)
end

function M.base(args)
  local root = workspace.root(vim.api.nvim_get_current_buf(), require("bend2").options)
  require("bend2.toolchain").command(vim.list_extend({ "base" }, args.fargs), root, function(result) M.output("Bend 2 base", result) end)
end

function M.gate(kind)
  local root = workspace.root(vim.api.nvim_get_current_buf(), require("bend2").options)
  require("bend2.toolchain").gate(root, kind, function(result) M.output("Bend 2 " .. kind .. " gate", result) end)
end

function M.goto_definition()
  local buf, path, row, col = cursor_context()
  local target = workspace.definition(path, row, col, workspace.root(buf, require("bend2").options))
  if not target then vim.notify("Bend 2: no definition found", vim.log.levels.INFO); return end
  local start = target.symbol.selectionRange.start
  vim.cmd.edit(vim.fn.fnameescape(target.path))
  vim.api.nvim_win_set_cursor(0, { start.line + 1, start.character })
end

function M.references()
  local buf, path, row, col = cursor_context()
  local results = workspace.references(path, row, col, workspace.root(buf, require("bend2").options))
  local qf = {}
  for _, item in ipairs(results) do qf[#qf + 1] = { filename = item.path, lnum = item.row + 1, col = item.col + 1, text = item.text } end
  vim.fn.setqflist({}, " ", { title = "Bend 2 references", items = qf })
  vim.cmd.copen()
end

function M.symbols()
  local buf, path = cursor_context()
  local docs = workspace.symbols(workspace.root(buf, require("bend2").options))
  local qf = {}
  for _, doc in ipairs(docs) do
    for _, symbol in ipairs(doc.parsed.symbols) do
      qf[#qf + 1] = { filename = doc.path, lnum = symbol.selectionRange.start.line + 1, col = symbol.selectionRange.start.character + 1, text = symbol.kind .. " " .. symbol.name }
    end
  end
  vim.fn.setqflist({}, " ", { title = "Bend 2 workspace symbols", items = qf })
  vim.cmd.copen()
end

function M.rename(new_name)
  local buf, path, row, col = cursor_context()
  local name = parser.identifier_at(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"), row, col)
  if not name or not new_name:match("^[A-Za-z_][A-Za-z0-9_]*$") then error("Bend 2 rename requires an identifier and a valid new name") end
  local refs = workspace.references(path, row, col, workspace.root(buf, require("bend2").options))
  local by_file = {}
  for _, item in ipairs(refs) do by_file[item.path] = by_file[item.path] or {}; by_file[item.path][#by_file[item.path] + 1] = item end
  for file, items in pairs(by_file) do
    local target_buf = vim.fn.bufadd(file)
    vim.fn.bufload(target_buf)
    table.sort(items, function(a, b) if a.row == b.row then return a.col > b.col end return a.row > b.row end)
    for _, item in ipairs(items) do
      vim.api.nvim_buf_set_text(target_buf, item.row, item.col, item.row, item.col + #name, { new_name })
    end
  end
end

function M.hover()
  local buf, path, row, col = cursor_context()
  local target = workspace.definition(path, row, col, workspace.root(buf, require("bend2").options))
  local lines
  if target then
    local source = workspace.document(target.path).source
    local source_lines = vim.split(source, "\n", { plain = true })
    lines = { source_lines[target.symbol.range.start.line + 1] or target.symbol.detail }
  else
    local name = parser.identifier_at(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"), row, col)
    if name then lines = { name .. " (Bend 2 symbol; type information unavailable)" } end
  end
  if lines then vim.lsp.util.open_floating_preview(lines, "bend", { border = "rounded", focusable = false }) end
end

function M.format()
  local buf = vim.api.nvim_get_current_buf()
  local source = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  local formatted = require("bend2.formatter").format(source, { tabSize = vim.bo[buf].shiftwidth, insertSpaces = vim.bo[buf].expandtab })
  if formatted ~= source then vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(formatted, "\n", { plain = true })) end
end

function M.format_expr()
  M.format()
  return 0
end

function M.complete(findstart, base)
  local buf = vim.api.nvim_get_current_buf()
  if findstart == 1 then
    local line = vim.api.nvim_get_current_line()
    return (line:sub(1, vim.fn.col(".") - 1):match("[%w_]+$") or ""):len() > 0 and (vim.fn.col(".") - 1 - #(line:sub(1, vim.fn.col(".") - 1):match("[%w_]+$") or "")) or -2
  end
  local path = vim.api.nvim_buf_get_name(buf)
  local root = workspace.root(buf, require("bend2").options)
  local parsed = parser.parse(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"), path)
  local names = { "def", "law", "type", "import", "match", "case", "return", "Nat", "IO", "Bool", "True", "False" }
  for _, doc in ipairs(workspace.symbols(root)) do for _, symbol in ipairs(doc.parsed.symbols) do names[#names + 1] = symbol.name end end
  for word in pairs(parsed.words) do names[#names + 1] = word end
  local seen, out = {}, {}
  for _, name in ipairs(names) do if name:find(base, 1, true) == 1 and not seen[name] then seen[name] = true; out[#out + 1] = { word = name, menu = "Bend 2" } end end
  table.sort(out, function(a, b) return a.word < b.word end)
  return out
end

function M.signature()
  local buf, path, row, col = cursor_context()
  local line = vim.api.nvim_get_current_line():sub(1, col)
  local name = line:match("([A-Za-z_][A-Za-z0-9_.]*)%s*%(")
  if not name then return end
  local root = workspace.root(buf, require("bend2").options)
  for _, doc in ipairs(workspace.symbols(root)) do
    for _, symbol in ipairs(doc.parsed.symbols) do
      if symbol.name == name or symbol.name:match("%.([^%.]+)$") == name then
        local source_line = vim.split(doc.source, "\n", { plain = true })[symbol.range.start.line + 1] or ""
        vim.lsp.util.open_floating_preview({ source_line }, "bend", { border = "rounded", focusable = false })
        return
      end
    end
  end
end

return M
