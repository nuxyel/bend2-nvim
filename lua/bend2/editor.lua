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
  vim.ui.select({ "JavaScript source", "Native executable", "Native executable (GPU-capable)" }, { prompt = "Bend 2 build profile" }, function(profile)
    if not profile then return end
    local suffix = profile == "JavaScript source" and ".js" or (vim.fn.has("win32") == 1 and ".exe" or "")
    local default = vim.fn.fnamemodify(path, ":r") .. suffix
    vim.ui.input({ prompt = "Bend 2 output file: ", default = default }, function(output)
    if not output or output == "" then return end
      require("bend2.toolchain").build(path, output, workspace.root(buf, require("bend2").options), function(result) M.output("Bend 2 build (" .. profile .. ")", result) end)
    end)
  end)
end

function M.run()
  local buf, path = cursor_context()
  if path == "" then vim.notify("Save the Bend 2 buffer before running it.", vim.log.levels.WARN); return end
  vim.ui.select({ "javascript", "native", "gpu" }, { prompt = "Bend 2 execution backend" }, function(profile)
    if not profile then return end
    local function execute(options)
      require("bend2.toolchain").run_profile(path, workspace.root(buf, require("bend2").options), profile, function(result) M.output("Bend 2 run (" .. profile .. ")", result) end, options)
    end
    if profile == "javascript" then execute({}); return end
    vim.ui.input({ prompt = "Optional positive thread count (empty for runtime default)" }, function(threads)
      if threads == nil then return end
      if threads ~= "" and (not threads:match("^%d+$") or tonumber(threads) < 1) then vim.notify("Threads must be a positive integer.", vim.log.levels.ERROR); return end
      local options = { threads = threads ~= "" and tonumber(threads) or nil }
      if profile ~= "gpu" then execute(options); return end
      vim.ui.input({ prompt = "GPU memory (on or limit such as 4GB)", default = "on" }, function(memory)
        if not memory then return end
        if not memory:match("^(on)$") and not memory:match("^%d+%.?%d*[KMGTP]B$") then vim.notify("Use 'on' or a GPU memory limit such as 4GB.", vim.log.levels.ERROR); return end
        options.gpu_memory = memory
        execute(options)
      end)
    end)
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

function M.probe_backend()
  local buf, path = cursor_context()
  if path == "" then vim.notify("Save the Bend 2 buffer before probing it.", vim.log.levels.WARN); return end
  vim.ui.select({ "javascript", "native", "gpu" }, { prompt = "Bend 2 backend to probe" }, function(profile)
    if not profile then return end
    require("bend2.toolchain").probe(path, workspace.root(buf, require("bend2").options), profile, function(result)
      M.output("Bend 2 " .. profile .. " probe: " .. result.status, result.result or { code = nil, stderr = result.compiler and result.compiler.error or result.status })
    end)
  end)
end

function M.compare_backends()
  local buf, path = cursor_context()
  if path == "" then vim.notify("Save the Bend 2 buffer before comparing it.", vim.log.levels.WARN); return end
  vim.ui.input({ prompt = "Backends (comma-separated)", default = "javascript,native" }, function(value)
    if not value then return end
    local profiles = {}
    for profile in value:gmatch("[^,%s]+") do
      if profile ~= "javascript" and profile ~= "native" and profile ~= "gpu" then vim.notify("Unknown backend: " .. profile, vim.log.levels.ERROR); return end
      profiles[#profiles + 1] = profile
    end
    require("bend2.toolchain").compare(path, workspace.root(buf, require("bend2").options), profiles, function(result)
      local lines = {}
      for _, item in ipairs(result.runs or {}) do lines[#lines + 1] = string.format("%s: exit=%s", item.profile, tostring(item.result.code)) end
      lines[#lines + 1] = "Comparable: " .. tostring(result.comparable)
      lines[#lines + 1] = "Outputs match: " .. tostring(result.outputsMatch)
      if result.error then lines[#lines + 1] = result.error end
      M.output("Bend 2 backend comparison", { code = result.comparable and result.outputsMatch and 0 or 1, stdout = table.concat(lines, "\n"), stderr = result.error or "" })
    end)
  end)
end

function M.compare_project()
  local buf = vim.api.nvim_get_current_buf()
  require("bend2.toolchain").compare_project(workspace.root(buf, require("bend2").options), function(result)
    local lines = {}
    for _, item in ipairs(result.runs or {}) do lines[#lines + 1] = vim.fn.fnamemodify(item.file, ":.") .. ": comparable=" .. tostring(item.result.comparable) .. ", outputsMatch=" .. tostring(item.result.outputsMatch) end
    if result.error then lines[#lines + 1] = result.error end
    M.output("Bend 2 project backend comparison", { code = result.comparable and result.outputsMatch and 0 or 1, stdout = table.concat(lines, "\n"), stderr = result.error or "" })
  end)
end

function M.benchmark()
  local buf, path = cursor_context()
  if path == "" then vim.notify("Save the Bend 2 buffer before benchmarking it.", vim.log.levels.WARN); return end
  vim.ui.input({ prompt = "Benchmark repetitions", default = "3" }, function(value)
    if not value then return end
    vim.ui.input({ prompt = "Thread count (empty for runtime default)", default = "1" }, function(threads)
      if threads == nil or (threads ~= "" and (not threads:match("^%d+$") or tonumber(threads) < 1)) then return end
      vim.ui.select({ "off", "on", "4GB" }, { prompt = "Bend 2 GPU mode" }, function(gpu)
        if not gpu then return end
        require("bend2.toolchain").benchmark(path, workspace.root(buf, require("bend2").options), value, function(result)
      local lines = { "ok: " .. tostring(result.ok) }
      if result.ok then
        lines[#lines + 1] = "median_ms: " .. tostring(result.median_ms)
        lines[#lines + 1] = "min_ms: " .. tostring(result.min_ms)
        lines[#lines + 1] = "max_ms: " .. tostring(result.max_ms)
        lines[#lines + 1] = "samples_ms: " .. vim.inspect(result.samples_ms)
        local report_dir = vim.fs.joinpath(workspace.root(buf, require("bend2").options), ".bend", "benchmarks")
        vim.fn.mkdir(report_dir, "p")
        local report = vim.fs.joinpath(report_dir, "bend2-" .. os.date("%Y%m%d-%H%M%S") .. ".json")
        vim.fn.writefile({ vim.json.encode(result) }, report)
        lines[#lines + 1] = "report: " .. report
      elseif result.error then lines[#lines + 1] = result.error end
      M.output("Bend 2 benchmark", { code = result.ok and 0 or 1, stdout = table.concat(lines, "\n"), stderr = result.error or "" })
        end, { threads = threads ~= "" and tonumber(threads) or nil, gpu = gpu, warmup = true })
      end)
    end)
  end)
end

function M.environment()
  local buf = vim.api.nvim_get_current_buf()
  local root = workspace.root(buf, require("bend2").options)
  require("bend2.toolchain").discover(root, function(info)
    M.output("Bend 2 execution environment", { code = 0, stdout = table.concat({ "Neovim: " .. vim.version().major .. "." .. vim.version().minor .. "." .. vim.version().patch, "OS: " .. vim.uv.os_uname().sysname .. " / " .. vim.uv.os_uname().machine, "Workspace: " .. root, "Compiler: " .. tostring(info.version or "unavailable"), "Compatibility: " .. info.compatibility, "Compiler command: " .. tostring(require("bend2").options.cmd) }, "\n"), stderr = info.error or "" })
  end)
end

function M.support()
  local buf = vim.api.nvim_get_current_buf()
  local root = workspace.root(buf, require("bend2").options)
  require("bend2.toolchain").discover(root, function(info)
    local uname = vim.uv.os_uname()
    local report = table.concat({ "Bend2.nvim: 0.1.0", "Neovim: " .. vim.version().major .. "." .. vim.version().minor .. "." .. vim.version().patch, "Host: " .. uname.sysname .. " " .. uname.release .. " " .. uname.machine, "Workspace: " .. root, "Compiler: " .. tostring(info.version or "unavailable"), "Compiler compatibility: " .. info.compatibility, "Compiler available: " .. tostring(info.available) }, "\n")
    vim.fn.setreg("+", report)
    M.output("Bend 2 support report (copied to clipboard)", { code = 0, stdout = report })
  end)
end

function M.goto_definition()
  local buf, path, row, col = cursor_context()
  local target = workspace.definition(path, row, col, workspace.root(buf, require("bend2").options))
  if not target then vim.notify("Bend 2: no definition found", vim.log.levels.INFO); return end
  local start = target.symbol.selectionRange.start
  vim.cmd.edit(vim.fn.fnameescape(target.path))
  vim.api.nvim_win_set_cursor(0, { start.line + 1, start.character })
end

function M.type_definition()
  local buf, path, row, col = cursor_context()
  local target = workspace.definition(path, row, col, workspace.root(buf, require("bend2").options))
  if not target or target.symbol.kind ~= "type" then vim.notify("Bend 2 type definition not found.", vim.log.levels.INFO); return end
  local start = target.symbol.selectionRange.start
  vim.cmd.edit(vim.fn.fnameescape(target.path))
  vim.api.nvim_win_set_cursor(0, { start.line + 1, start.character })
end

function M.open_import()
  local buf, path, row, col = cursor_context()
  local doc = workspace.document(path)
  if not doc then return end
  for _, item in ipairs(doc.parsed.imports) do
    if item.range.start.line == row and col >= item.range.start.character and col <= item.range.finish.character then
      if item.resolvedPath then vim.cmd.edit(vim.fn.fnameescape(item.resolvedPath)) else vim.notify("Bend 2 import could not be resolved: " .. item.path, vim.log.levels.WARN) end
      return
    end
  end
  vim.notify("No Bend 2 import at the cursor.", vim.log.levels.INFO)
end

function M.call_hierarchy()
  local buf, path, row, col = cursor_context()
  local target = workspace.definition(path, row, col, workspace.root(buf, require("bend2").options))
  if not target then vim.notify("Place the cursor on a Bend 2 symbol.", vim.log.levels.WARN); return end
  vim.ui.select({ "Incoming calls", "Outgoing calls" }, { prompt = "Bend 2 call hierarchy for " .. target.symbol.name }, function(direction)
    if not direction then return end
    local root = workspace.root(buf, require("bend2").options)
    local qf, docs = {}, workspace.symbols(root)
    if direction == "Incoming calls" then
      for _, ref in ipairs(workspace.references(target.path, target.symbol.selectionRange.start.line, target.symbol.selectionRange.start.character, root)) do
        qf[#qf + 1] = { filename = ref.path, lnum = ref.row + 1, col = ref.col + 1, text = "call to " .. target.symbol.name .. ": " .. ref.text }
      end
    else
      for _, doc in ipairs(docs) do
        if doc.path == target.path then
          local lines = vim.split(doc.source, "\n", { plain = true })
          local active = false
          for row_idx, line in ipairs(lines) do
            if line:match("^%s*def%s+") then active = line:find(target.symbol.name, 1, true) ~= nil and line:find("def", 1, true) ~= nil
            elseif active then
              for start, name in line:gmatch("()([A-Za-z_][A-Za-z0-9_]*)%s*%(") do
                local found = workspace.definition(doc.path, row_idx - 1, start - 1, root)
                if found then qf[#qf + 1] = { filename = found.path, lnum = found.symbol.selectionRange.start.line + 1, col = found.symbol.selectionRange.start.character + 1, text = "called by " .. target.symbol.name .. ": " .. name .. "()" } end
              end
            end
          end
        end
      end
    end
    vim.fn.setqflist({}, " ", { title = "Bend 2 " .. direction:lower(), items = qf })
    vim.cmd.copen()
  end)
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
  local auto_imports = {}
  for _, doc in ipairs(workspace.symbols(root)) do for _, symbol in ipairs(doc.parsed.symbols) do names[#names + 1] = symbol.name end end
  for word in pairs(parsed.words) do names[#names + 1] = word end
  local seen, out = {}, {}
  for _, name in ipairs(names) do if name:find(base, 1, true) == 1 and not seen[name] then seen[name] = true; out[#out + 1] = { word = name, menu = "Bend 2" } end end
  if require("bend2").options.auto_import then
    for _, doc in ipairs(workspace.symbols(root)) do
      if doc.path ~= path then
        local alias = vim.fs.basename(doc.path):gsub("%.bend$", "")
        if alias:lower() == "main" then alias = vim.fs.basename(vim.fs.dirname(doc.path)) end
        alias = alias:sub(1, 1):upper() .. alias:sub(2):gsub("[^A-Za-z0-9_]", "_")
        for _, symbol in ipairs(doc.parsed.symbols) do
          if symbol.kind ~= "import" then
            local short = symbol.name:match("([^%.]+)$") or symbol.name
            local word = alias .. "." .. short
            if word:find(base, 1, true) == 1 and not seen[word] then
              seen[word] = true
              local relative = vim.fs.relpath(vim.fs.dirname(path), doc.path)
              if relative and relative:sub(1, 1) ~= "." then relative = "./" .. relative end
              out[#out + 1] = { word = word, menu = "Bend 2 import", user_data = vim.json.encode({ alias = alias, path = relative }) }
            end
          end
        end
      end
    end
  end
  table.sort(out, function(a, b) return a.word < b.word end)
  return out
end

function M.complete_done()
  local item = vim.v.completed_item
  if not item or not item.user_data or item.user_data == "" then return end
  local ok, details = pcall(vim.json.decode, item.user_data)
  if not ok or type(details) ~= "table" or not details.path then return end
  local buf = vim.api.nvim_get_current_buf()
  local source = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  if source:match("import%s+" .. vim.pesc(details.path) .. "%s+as%s+" .. vim.pesc(details.alias)) then return end
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "import " .. details.path .. " as " .. details.alias })
end

function M.insert_snippet()
  local templates = {
    ["Bend function"] = { "def name(x: Nat) -> Nat:", "  ?TODO" },
    ["Bend law"] = { "law name:", "  for x: Nat", "  {proposition : Bool}" },
    ["Bend proof match"] = { "match value:", "  case pattern:", "    ?TODO" },
    ["Bend parallel call"] = { "left right = leftCall rightCall" },
  }
  local names = { "Bend function", "Bend law", "Bend proof match", "Bend parallel call" }
  vim.ui.select(names, { prompt = "Bend 2 snippet" }, function(choice)
    if not choice then return end
    local lines = templates[choice]
    local cursor = vim.api.nvim_win_get_cursor(0)
    vim.api.nvim_buf_set_text(0, cursor[1] - 1, cursor[2], cursor[1] - 1, cursor[2], lines)
    vim.api.nvim_win_set_cursor(0, { cursor[1], cursor[2] + 4 })
  end)
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
