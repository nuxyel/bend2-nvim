local parser = require("bend2.parser")
local workspace = require("bend2.workspace")
local M = {}

local function cursor_context()
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  return buf, vim.api.nvim_buf_get_name(buf), cursor[1] - 1, cursor[2]
end

local function verify_backend(root, profile, callback)
  local toolchain = require("bend2.toolchain")
  toolchain.discover(root, function(info)
    if not info.available then vim.notify(info.error or "Bend 2 compiler is unavailable.", vim.log.levels.ERROR, { title = "Bend 2" }); return end
    local capability = toolchain.backend_capability(info, profile)
    if capability == "unsupported" then vim.notify("The active Bend compiler does not advertise the " .. profile .. " backend.", vim.log.levels.ERROR, { title = "Bend 2" }); return end
    if capability == "unknown" then vim.notify("The compiler did not report " .. profile .. " capability metadata; continuing and letting Bend decide.", vim.log.levels.WARN, { title = "Bend 2" }) end
    callback(info)
  end)
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
      items[#items + 1] = { lnum = diagnostic.line, col = diagnostic.col, end_lnum = diagnostic.end_line, end_col = diagnostic.end_col, message = diagnostic.message, severity = diagnostic.severity == "warning" and vim.diagnostic.severity.WARN or diagnostic.severity == "info" and vim.diagnostic.severity.INFO or vim.diagnostic.severity.ERROR, source = "Bend 2 compiler" }
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
  local changedtick = vim.api.nvim_buf_get_changedtick(buf)
  require("bend2.toolchain").check(path, root, function(result)
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_changedtick(buf) == changedtick then publish_compiler_result(buf, path, root, result) end
    M.output("Bend 2 check: " .. vim.fn.fnamemodify(path, ":."), result)
  end)
end

function M.check_workspace()
  local buf = vim.api.nvim_get_current_buf()
  local root = workspace.root(buf, require("bend2").options)
  local files = workspace.proof_files(root)
  if #files == 0 then vim.notify("No PROOF.bend suites were found in this workspace.", vim.log.levels.INFO); return end
  local index, failed, output = 1, 0, {}
  local function next_file()
    local path = files[index]
    if not path then
      M.output("Bend 2 workspace check", { code = failed == 0 and 0 or 1, stdout = table.concat(output, "\n") })
      return
    end
    require("bend2.toolchain").check(path, root, function(result)
      if result.cancelled then
        output[#output + 1] = path .. ": CANCELLED"
        M.output("Bend 2 workspace check", { code = nil, stdout = table.concat(output, "\n"), stderr = "Workspace proof check cancelled." })
        return
      end
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
    local root = workspace.root(buf, require("bend2").options)
    local backend = profile == "JavaScript source" and "javascript" or profile == "Native executable" and "native" or "gpu"
    verify_backend(root, backend, function()
      local suffix = backend == "javascript" and ".js" or (vim.fn.has("win32") == 1 and ".exe" or "")
      local default = vim.fn.fnamemodify(path, ":r") .. suffix
      vim.ui.input({ prompt = "Bend 2 output file: ", default = default }, function(output)
        if not output or output == "" then return end
        require("bend2.toolchain").build(path, output, root, function(result) M.output("Bend 2 build (" .. profile .. ")", result) end)
      end)
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
    M.output("Bend 2 Neovim plugin and compiler", { code = info.available and 0 or nil, stdout = "Plugin version: " .. require("bend2").version .. "\nCompiler version: " .. tostring(info.version or "unavailable") .. "\nCompatibility: " .. info.compatibility, stderr = info.error or "" })
  end, true)
end

function M.base(args)
  local root = workspace.root(vim.api.nvim_get_current_buf(), require("bend2").options)
  require("bend2.toolchain").command(vim.list_extend({ "base" }, args.fargs), root, function(result) M.output("Bend 2 base", result) end)
end

function M.gate(kind)
  local root = workspace.root(vim.api.nvim_get_current_buf(), require("bend2").options)
  vim.ui.input({ prompt = "Optional target directory relative to the workspace (empty for script default)" }, function(target)
    if target == nil then return end
    require("bend2.toolchain").gate(root, kind, function(result) M.output("Bend 2 " .. kind .. " gate", result) end, target)
  end)
end

function M.probe_backend()
  local buf, path = cursor_context()
  if path == "" then vim.notify("Save the Bend 2 buffer before probing it.", vim.log.levels.WARN); return end
  vim.ui.select({ "javascript", "native", "gpu" }, { prompt = "Bend 2 backend to probe" }, function(profile)
    if not profile then return end
    local function probe()
      require("bend2.toolchain").probe(path, workspace.root(buf, require("bend2").options), profile, function(result)
        M.output("Bend 2 " .. profile .. " probe: " .. result.status, result.result or { code = nil, stderr = result.error or (result.compiler and result.compiler.error) or result.status })
      end)
    end
    if profile == "gpu" then
      vim.ui.select({ "Cancel", "Run GPU probe" }, { prompt = "This probe will execute the current Bend program on the active GPU. Continue?" }, function(choice)
        if choice == "Run GPU probe" then probe() end
      end)
      return
    end
    probe()
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
    local has_native, has_gpu = false, false
    for _, profile in ipairs(profiles) do has_native = has_native or profile == "native" or profile == "gpu"; has_gpu = has_gpu or profile == "gpu" end
    local options = {}
    local function compare()
      require("bend2.toolchain").compare(path, workspace.root(buf, require("bend2").options), profiles, function(result)
        local lines = {}
        for _, item in ipairs(result.runs or {}) do lines[#lines + 1] = string.format("%s: exit=%s", item.profile, tostring(item.result.code)) end
        lines[#lines + 1] = "Comparable: " .. tostring(result.comparable)
        lines[#lines + 1] = "Outputs match: " .. tostring(result.outputsMatch)
        if result.error then lines[#lines + 1] = result.error end
        M.output("Bend 2 backend comparison", { code = result.comparable and result.outputsMatch and 0 or 1, stdout = table.concat(lines, "\n"), stderr = result.error or "" })
      end, options)
    end
    local function ask_gpu_memory()
      if not has_gpu then compare(); return end
      vim.ui.input({ prompt = "GPU memory (on or limit such as 4GB)", default = "on" }, function(memory)
        if not memory then return end
        if not memory:match("^(on)$") and not memory:match("^%d+%.?%d*[KMGTP]B$") then vim.notify("Use 'on' or a GPU memory limit such as 4GB.", vim.log.levels.ERROR); return end
        options.gpu_memory = memory
        compare()
      end)
    end
    if not has_native then compare(); return end
    vim.ui.input({ prompt = "Optional positive thread count (empty for runtime default)" }, function(threads)
      if threads == nil then return end
      if threads ~= "" and (not threads:match("^%d+$") or tonumber(threads) < 1) then vim.notify("Threads must be a positive integer.", vim.log.levels.ERROR); return end
      options.threads = threads ~= "" and tonumber(threads) or nil
      ask_gpu_memory()
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
  vim.ui.input({ prompt = "Thread counts (comma-separated)", default = "1,2,4" }, function(thread_text)
    if not thread_text then return end
    local threads, seen = {}, {}
    for part in thread_text:gmatch("[^,]+") do
      if not part:match("^%d+$") or tonumber(part) < 1 then vim.notify("Enter positive thread counts separated by commas.", vim.log.levels.ERROR); return end
      if not seen[tonumber(part)] then threads[#threads + 1] = tonumber(part); seen[tonumber(part)] = true end
    end
    if #threads == 0 then vim.notify("Enter at least one thread count.", vim.log.levels.ERROR); return end
    vim.ui.input({ prompt = "Measured runs per configuration (warm-up is discarded)", default = "3" }, function(run_text)
      if not run_text or not run_text:match("^%d+$") or tonumber(run_text) < 1 then return end
      vim.ui.select({ "off", "on", "4GB" }, { prompt = "Bend 2 GPU mode" }, function(gpu)
        if not gpu then return end
        local results, index, root = {}, 1, workspace.root(buf, require("bend2").options)
        local function next_thread()
          local count = threads[index]
          if not count then
            local report_dir = vim.fs.joinpath(root, ".bend", "benchmarks")
            vim.fn.mkdir(report_dir, "p")
            local report = vim.fs.joinpath(report_dir, "bend2-" .. os.date("%Y%m%d-%H%M%S") .. ".json")
            local version = vim.version()
            local record = { schemaVersion = 1, generatedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"), pluginVersion = require("bend2").version, nvimVersion = version.major .. "." .. version.minor .. "." .. version.patch, host = { os = vim.uv.os_uname().sysname, arch = vim.uv.os_uname().machine }, file = vim.fs.relpath(root, path), requestedThreads = threads, gpu = gpu, runs = tonumber(run_text), results = results }
            local report_ok, report_result = pcall(vim.fn.writefile, { vim.json.encode(record) }, report)
            local report_written = report_ok and report_result == 0
            local lines = { "Compiler: " .. tostring(results[1] and results[1].compiler and results[1].compiler.version or "unknown"), "GPU: " .. gpu, "Warm-up: discarded", "Runs: " .. run_text }
            for _, result in ipairs(results) do
              if result.ok then
                lines[#lines + 1] = string.format("threads=%s: median=%.3fms, min=%.3fms, max=%.3fms, output stable=%s", tostring(result.threads or "default"), result.median_ms, result.min_ms, result.max_ms, tostring(result.outputs_match))
                lines[#lines + 1] = "  samples_ms: " .. vim.inspect(result.samples_ms)
              else lines[#lines + 1] = "threads=" .. tostring(result.threads or count) .. ": failed: " .. tostring(result.error) end
            end
            lines[#lines + 1] = report_written and ("JSON report: " .. report) or "JSON report could not be written."
            local successful = #results > 0
            for _, result in ipairs(results) do successful = successful and result.ok and result.outputs_match end
            successful = successful and report_written
            M.output("Bend 2 benchmark", { code = successful and 0 or 1, stdout = table.concat(lines, "\n"), stderr = successful and "" or "A benchmark configuration failed, produced unstable output, or its report could not be written." })
            return
          end
          require("bend2.toolchain").benchmark(path, root, run_text, function(result)
            results[#results + 1] = result
            index = index + 1
            next_thread()
          end, { threads = count, gpu = gpu, warmup = true })
        end
        next_thread()
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
    local version = vim.version()
    local options = require("bend2").options
    local report = table.concat({ "Schema version: 1", "Bend2.nvim: " .. require("bend2").version, "Neovim: " .. version.major .. "." .. version.minor .. "." .. version.patch, "Host: " .. uname.sysname .. " " .. uname.machine, "Workspace open: " .. tostring(root ~= ""), "Compiler: " .. tostring(info.version or "unavailable"), "Compiler compatibility: " .. info.compatibility, "Compiler available: " .. tostring(info.available), "Validation: " .. options.validation, "Diagnostics mode: " .. options.diagnostics_mode, "Auto-import: " .. tostring(options.auto_import), "Formatter: " .. tostring(options.formatter) }, "\n")
    local copied = pcall(vim.fn.setreg, "+", report)
    M.output(copied and "Bend 2 support report (copied to clipboard)" or "Bend 2 support report", { code = 0, stdout = report, stderr = copied and "" or "Clipboard unavailable; copy the report from this buffer." })
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
  if not name or not new_name:match("^[A-Za-z_][A-Za-z0-9_]*$") then vim.notify("Bend 2 rename needs an identifier and a valid new name.", vim.log.levels.ERROR); return end
  local root = workspace.root(buf, require("bend2").options)
  local target = workspace.definition(path, row, col, root)
  if not target then vim.notify("Bend 2 rename could not resolve a declaration at the cursor.", vim.log.levels.WARN); return end
  local old_name = target.symbol.name:match("([^%.]+)$") or target.symbol.name
  if old_name == new_name then return end
  local refs = workspace.references(path, row, col, root)
  local by_file = {}
  for _, item in ipairs(refs) do by_file[item.path] = by_file[item.path] or {}; by_file[item.path][#by_file[item.path] + 1] = item end
  local target_start = target.symbol.selectionRange.start
  for file in pairs(by_file) do
    local doc = workspace.document(file)
    for _, symbol in ipairs(doc and doc.parsed.symbols or {}) do
      local selection = symbol.selectionRange.start
      local same_target = vim.fs.normalize(file) == vim.fs.normalize(target.path) and selection.line == target_start.line and selection.character == target_start.character
      if symbol.kind ~= "import" and not same_target and (symbol.name:match("([^%.]+)$") or symbol.name) == new_name then
        vim.notify("Bend 2 rename would collide with an existing declaration '" .. new_name .. "'.", vim.log.levels.ERROR)
        return
      end
    end
  end
  for file, items in pairs(by_file) do
    local target_buf = vim.fn.bufadd(file)
    vim.fn.bufload(target_buf)
    table.sort(items, function(a, b) if a.row == b.row then return a.col > b.col end return a.row > b.row end)
    for _, item in ipairs(items) do
      vim.api.nvim_buf_set_text(target_buf, item.row, item.col, item.row, item.col + #item.name, { new_name })
    end
  end
  workspace.invalidate()
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
  if not require("bend2").options.formatter then vim.notify("Bend 2 formatting is disabled in configuration.", vim.log.levels.INFO); return end
  local buf = vim.api.nvim_get_current_buf()
  local source = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  local formatted = require("bend2.formatter").format(source, { tabSize = vim.bo[buf].shiftwidth, insertSpaces = vim.bo[buf].expandtab })
  if formatted ~= source then vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(formatted, "\n", { plain = true })) end
end

function M.complete(findstart, base)
  local buf = vim.api.nvim_get_current_buf()
  if findstart == 1 then
    local line = vim.api.nvim_get_current_line()
    local before = line:sub(1, vim.fn.col(".") - 1)
    local prefix = before:match("([A-Za-z0-9_.]+)$")
    if prefix and prefix:find(".", 1, true) then
      local alias, member = prefix:match("^([A-Za-z_][A-Za-z0-9_]*)%.([A-Za-z0-9_.]*)$")
      if alias then
        local path = vim.api.nvim_buf_get_name(buf)
        local source = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
        local imported = false
        for _, item in ipairs(parser.parse(source, path).imports) do if item.alias == alias then imported = true; break end end
        if imported then return vim.fn.col(".") - 1 - #member end
        if require("bend2").options.auto_import then return vim.fn.col(".") - 1 - #prefix end
        return vim.fn.col(".") - 1 - #member
      end
    end
    local word = before:match("[%w_]+$")
    return word and vim.fn.col(".") - 1 - #word or -2
  end
  local path = vim.api.nvim_buf_get_name(buf)
  local root = workspace.root(buf, require("bend2").options)
  local base_completion = require("bend2.base_completion")
  base_completion.request(root)
  local source = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  local parsed = parser.parse(source, path)
  local names = { "def", "law", "type", "is", "import", "as", "public", "private", "match", "case", "return", "do", "for", "exs", "where", "let", "if", "Nat", "U8", "U16", "U32", "U64", "U128", "IO", "Bool", "String", "Char", "F32", "F64", "True", "False", "Type", "Data", "Pair", "Option", "Result", "List", "Array", "Map", "Some", "None" }
  local docs, imported_paths = workspace.symbols(root), {}
  local base_names, base_set = base_completion.get(root) or {}, {}
  for _, name in ipairs(base_names) do names[#names + 1] = name; base_set[name] = true end
  for _, item in ipairs(parsed.imports) do if item.resolvedPath then imported_paths[vim.fs.normalize(item.resolvedPath)] = true end end
  for _, doc in ipairs(docs) do for _, symbol in ipairs(doc.parsed.symbols) do if symbol.kind ~= "import" then names[#names + 1] = symbol.name end end end
  for word in pairs(parsed.words) do names[#names + 1] = word end
  local seen, out = {}, {}
  for _, name in ipairs(names) do
    if name:find(base, 1, true) == 1 and not seen[name] then
      seen[name] = true
      out[#out + 1] = { word = name, menu = base_set[name] and "Bend Base" or "Bend 2" }
    end
  end
  if require("bend2").options.auto_import then
    local used_aliases = vim.deepcopy(parsed.words)
    for _, item in ipairs(parsed.imports) do used_aliases[item.alias] = true end
    local requested_alias = base:match("^([A-Za-z_][A-Za-z0-9_]*)%.")
    local alias_imported = false
    for _, item in ipairs(parsed.imports) do if item.alias == requested_alias then alias_imported = true; break end end
    if requested_alias and not alias_imported then
      local occurrences = 0
      for word in source:gmatch("[A-Za-z_][A-Za-z0-9_]*") do
        if word == requested_alias then occurrences = occurrences + 1 end
      end
      if occurrences == 1 then used_aliases[requested_alias] = nil end
    end
    for _, doc in ipairs(docs) do
      if doc.path ~= path and not imported_paths[vim.fs.normalize(doc.path)] then
        local alias = vim.fs.basename(doc.path):gsub("%.bend$", "")
        if alias:lower() == "main" then alias = vim.fs.basename(vim.fs.dirname(doc.path)) end
        alias = alias:sub(1, 1):upper() .. alias:sub(2):gsub("[^A-Za-z0-9_]", "_")
        local original, suffix = alias, 2
        while used_aliases[alias] do alias, suffix = original .. suffix, suffix + 1 end
        used_aliases[alias] = true
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
  local insert_at, lines = 0, vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for index, line in ipairs(lines) do
    if line:match("^%s*#") or line:match("^%s*import%s+") or line:match("^%s*$") then insert_at = index else break end
  end
  vim.api.nvim_buf_set_lines(buf, insert_at, insert_at, false, { "import " .. details.path .. " as " .. details.alias })
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
  local source = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  local context = require("bend2.signature").call_context(source, row, col)
  if not context then vim.notify("No Bend 2 call signature at the cursor.", vim.log.levels.INFO); return end
  local root = workspace.root(buf, require("bend2").options)
  local target = workspace.definition(path, context.line, context.character, root)
  if not target or (target.symbol.kind ~= "function" and target.symbol.kind ~= "law") then
    vim.notify("Bend 2 signature is unavailable for this call.", vim.log.levels.INFO)
    return
  end
  local doc = workspace.document(target.path)
  if not doc then return end
  local source_line = vim.split(doc.source, "\n", { plain = true })[target.symbol.range.start.line + 1] or ""
  local parsed = require("bend2.signature").parse(target.symbol.name, source_line)
  if not parsed then vim.lsp.util.open_floating_preview({ source_line }, "bend", { border = "rounded", focusable = false }); return end
  local preview, win = vim.lsp.util.open_floating_preview({ parsed.label }, "bend", { border = "rounded", focusable = false })
  local parameter = parsed.parameters[context.active_parameter + 1]
  if preview and win and parameter then
    local first = #target.symbol.name + 1
    for index, item in ipairs(parsed.parameters) do
      local start = parsed.label:find(item, first, true)
      if start then
        if index == context.active_parameter + 1 then vim.api.nvim_buf_add_highlight(preview, "LspSignatureActiveParameter", 0, start - 1, start + #item - 1); break end
        first = start + #item + 1
      end
    end
  end
end

return M
