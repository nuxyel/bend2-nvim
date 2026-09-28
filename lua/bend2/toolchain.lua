local M = { jobs = {}, cache = {}, checks = {}, cancelled = setmetatable({}, { __mode = "k" }) }

local function config()
  return require("bend2").options
end

local function argv(args)
  local opts = config()
  local command, prefix
  if type(opts.cmd) == "table" then
    command, prefix = opts.cmd[1], vim.list_slice(opts.cmd, 2)
  else command, prefix = opts.cmd, {} end
  return vim.list_extend(vim.list_extend({ command }, prefix), vim.list_extend(vim.deepcopy(opts.cmd_args or {}), args or {}))
end

function M.run(args, root, callback, timeout_ms)
  local scheduled_callback = vim.schedule_wrap(callback)
  local done, timer, process = false, nil, nil
  local function finish(result)
    if done then return end
    done = true
    if timer then timer:stop(); timer:close() end
    if process then M.jobs[process] = nil end
    if process and M.cancelled[process] then result.cancelled = true end
    scheduled_callback(result)
  end
  local ok, proc = pcall(vim.system, argv(args), { cwd = root, text = true }, function(result)
    finish({ code = result.code, stdout = result.stdout or "", stderr = result.stderr or "", cancelled = false, timed_out = false })
  end)
  if not ok then
    finish({ code = nil, stdout = "", stderr = tostring(proc), cancelled = false, timed_out = false })
    return
  end
  process = proc
  M.jobs[process] = true
  if timeout_ms then
    timer = vim.uv.new_timer()
    timer:start(timeout_ms, 0, vim.schedule_wrap(function()
      if not done then process:kill("sigterm"); finish({ code = nil, stdout = "", stderr = "Bend 2 command timed out.", cancelled = false, timed_out = true }) end
    end))
  end
  return process
end

function M.run_binary(path, args, root, callback, timeout_ms)
  local scheduled_callback = vim.schedule_wrap(callback)
  local done, timer, process = false, nil, nil
  local function finish(result)
    if done then return end
    done = true
    if timer then timer:stop(); timer:close() end
    if process then M.jobs[process] = nil end
    if process and M.cancelled[process] then result.cancelled = true end
    scheduled_callback(result)
  end
  local command = vim.list_extend({ path }, args or {})
  local ok, proc = pcall(vim.system, command, { cwd = root, text = true }, function(result)
    finish({ code = result.code, stdout = result.stdout or "", stderr = result.stderr or "", cancelled = false, timed_out = false })
  end)
  if not ok then finish({ code = nil, stdout = "", stderr = tostring(proc), cancelled = false, timed_out = false }); return end
  process = proc; M.jobs[process] = true
  if timeout_ms then
    timer = vim.uv.new_timer()
    timer:start(timeout_ms, 0, vim.schedule_wrap(function() if not done then process:kill("sigterm"); finish({ code = nil, stdout = "", stderr = "Command timed out.", timed_out = true, cancelled = false }) end end))
  end
  return process
end

function M.cancel_all()
  for process in pairs(M.jobs) do M.cancelled[process] = true; pcall(process.kill, process, "sigterm") end
  M.jobs = {}
end

function M.cancel_check(path)
  local process = M.checks[path]
  if process then M.cancelled[process] = true; pcall(process.kill, process, "sigterm"); M.checks[path] = nil end
end

local function parse_version(output)
  return output:match("[Bb]end%s*(%d+%.%d+%.%d+)") or output:match("(%d+%.%d+%.%d+)")
end

local function compatible(version)
  if not version then return "unknown" end
  local major, minor, patch = version:match("^(%d+)%.(%d+)%.(%d+)$")
  if tonumber(major) ~= 2 then return "unsupported" end
  if tonumber(minor) > 0 or tonumber(patch) >= 28 then return "supported" end
  return "unsupported"
end

function M.discover(root, callback, refresh)
  if not refresh and M.cache[root] then callback(M.cache[root]); return end
  M.run({ "--version" }, root, function(version_result)
    if version_result.code ~= 0 then
      M.run({ "version" }, root, function(fallback)
        local output = fallback.stdout .. "\n" .. fallback.stderr
        local version = fallback.code == 0 and parse_version(output) or nil
        local info = { available = version ~= nil, version = version, compatibility = compatible(version), error = version and nil or (fallback.stderr ~= "" and fallback.stderr or "Bend 2 was not found. Install it or configure bend2.cmd.") }
        M.cache[root] = info
        callback(info)
      end, 3000)
      return
    end
    local output = version_result.stdout .. "\n" .. version_result.stderr
    local version = parse_version(output)
    M.run({ "guide" }, root, function(guide)
      local text = guide.stdout .. "\n" .. guide.stderr
      local lower = text:lower()
      local function capability(positive, negative)
        for _, phrase in ipairs(negative) do if lower:find(phrase, 1, true) then return "unsupported" end end
        for _, phrase in ipairs(positive) do if lower:find(phrase, 1, true) then return "supported" end end
        return "unknown"
      end
      local info = { available = true, version = version, compatibility = compatible(version), capabilities = {
        javascript = capability({ "javascript target", "js backend", "file.js" }, { "javascript unavailable", "javascript not supported", "javascript unsupported", "javascript disabled" }),
        native = capability({ "native executable", "native binary", "compile to c", "clang" }, { "native unavailable", "native not supported", "native unsupported", "native disabled" }),
        gpu = capability({ "--gpu", "gpu" }, { "gpu unavailable", "gpu not supported", "gpu unsupported", "gpu disabled" }),
        threads = capability({ "--threads", "thread count", "cpu threads" }, { "threads unavailable", "threads not supported", "threads unsupported", "threads disabled" }),
      } }
      M.cache[root] = info
      callback(info)
    end, 5000)
  end, 3000)
end

local function parse_diagnostics(output, default_file)
  local diagnostics = {}
  local function add(file, line, col, severity, message, extra)
    local item = { file = file or default_file, line = math.max(0, tonumber(line or 1) - 1), col = math.max(0, tonumber(col or 1) - 1), severity = severity, message = message }
    for key, value in pairs(extra or {}) do item[key] = value end
    diagnostics[#diagnostics + 1] = item
  end
  local function records(decoded)
    if type(decoded) ~= "table" then return end
    local values = decoded.diagnostics or (decoded.diagnostic and { decoded.diagnostic }) or { decoded }
    for _, item in ipairs(values) do
      local r = item.range or {}
      local start, finish = r.start or item.start or item, r.finish or r["end"] or item.finish or item["end"]
      if type(item.message) == "string" and start.line then
        local related = {}
        for _, note in ipairs(item.relatedInformation or {}) do
          local note_start = note.start or (note.location and note.location.range and note.location.range.start)
          related[#related + 1] = { file = note.file or (note.location and note.location.uri) or default_file, line = math.max(0, (tonumber(note_start and note_start.line) or 1) - 1), col = math.max(0, (tonumber(note_start and (note_start.column or note_start.character)) or 1) - 1), message = note.message }
        end
        local extra = {
          code = item.code, category = item.category,
          expectedType = item.expectedType or item.expected, observedType = item.observedType or item.actual,
          proofContext = item.proofContext or item.context, proofDependencies = item.proofDependencies or item.dependencies,
          relatedInformation = #related > 0 and related or nil,
          end_line = finish and finish.line and math.max(0, tonumber(finish.line) - 1) or nil,
          end_col = finish and (finish.column or finish.character) and math.max(0, tonumber(finish.column or finish.character) - 1) or nil,
        }
        add(item.file or default_file, start.line, start.column or start.character, item.severity or "error", item.message, extra)
      end
    end
  end
  local ok, decoded = pcall(vim.json.decode, output, { luanil = { object = true } })
  if ok then records(decoded) end
  if #diagnostics == 0 then
    for line in output:gmatch("[^\n]+") do
      local line_ok, value = pcall(vim.json.decode, line, { luanil = { object = true } })
      if line_ok then records(value) end
    end
  end
  if #diagnostics > 0 then
    for _, item in ipairs(diagnostics) do
      local text = (item.message or ""):lower()
      if text:find("open goal", 1, true) or text:find("unsafe", 1, true) or text:find("foreign", 1, true) then item.severity = "warning" end
    end
    return diagnostics
  end
  for line in output:gmatch("[^\n]+") do
    local file, row, col, tail = line:match("^(.+):(%d+):(%d+):%s*(.*)$")
    if not file then file, row, col, tail = line:match("^(.+)%((%d+),(%d+)%)%:%s*(.*)$") end
    if file then
      local kind, message = tail:match("^([%a]+)%s*:?[ ]*(.*)$")
      kind, message = (kind or "error"):lower(), message ~= "" and message or tail
      add(file, row, col, kind == "warning" and "warning" or kind == "note" and "info" or "error", message)
    end
  end
  if #diagnostics > 0 then return diagnostics end

  local lines = vim.split(output, "\n", { plain = true })
  for index, line in ipairs(lines) do
    if line:match("^Error:%s*") then
      local fields, location = {}, nil
      local cursor = index + 1
      while cursor <= #lines and not lines[cursor]:match("^Error:%s*") do
        if lines[cursor]:match("^Location:") then location = cursor + 1; break end
        local key, value = lines[cursor]:match("^%s*%-%s+([%a ]+)%s*:%s*(.*)$")
        if key then fields[key:lower():gsub("%s+", "")] = value end
        cursor = cursor + 1
      end
      local source_line = 1
      if location then
        for context = location, #lines do
          local number, marker = lines[context]:match("^%s*(%d+)%s*([>|])%s*%|")
          if number then source_line = tonumber(number); if marker == ">" then break end end
          if lines[context]:match("^Error:%s*") then break end
        end
      end
      local message = fields.message or ((fields.expected or fields.observed) and table.concat({ fields.expected and "expected " .. fields.expected or "", fields.observed and "observed " .. fields.observed or "" }, "; ") or "Compiler error")
      add(default_file, source_line, 1, (message:lower():find("goal", 1, true) or message:lower():find("unsafe", 1, true) or message:lower():find("foreign", 1, true)) and "warning" or "error", message, { expectedType = fields.expected, observedType = fields.observed })
    end
  end
  if #diagnostics > 0 then return diagnostics end

  local safety_header
  for index, line in ipairs(lines) do if line:match("All terms check, but %d+ defs? rel") then safety_header = index; break end end
  if safety_header then
    for index = safety_header + 1, #lines do
      local name = lines[index]:match("^%s*%-%s+(.+)%s*$")
      if name then
        local declaration_line, column, length = 1, 1, 1
        local source_ok, source_lines = pcall(vim.fn.readfile, default_file)
        if source_ok then
          for source_index, source_line in ipairs(source_lines) do
            local start = source_line:find(name:match("([^%.]+)$") or name, 1, true)
            local declaration = source_line:match("^%s*(%a+)")
            if start and (declaration == "def" or declaration == "law" or declaration == "type") then declaration_line, column, length = source_index, start, #name; break end
          end
        end
        add(default_file, declaration_line, column, "warning", "Definition '" .. name .. "' relies on unsafe or foreign code.", { category = "unsafe", end_line = declaration_line - 1, end_col = column - 1 + length })
      end
    end
  end
  return diagnostics
end

function M.check(path, root, callback)
  M.cancel_check(path)
  M.discover(root, function(info)
    if not info.available then callback({ code = nil, stderr = info.error, diagnostics = {}, compiler = info }); return end
    local args = { path, "--check-only" }
    if config().diagnostics_mode ~= "text" then args[#args + 1] = "--diagnostics=json" end
    local process
    process = M.run(args, root, function(result)
      if M.checks[path] == process then M.checks[path] = nil end
      if result.cancelled or result.timed_out then
        result.diagnostics, result.compiler = {}, info
        callback(result)
        return
      end
      local combined = result.stdout .. "\n" .. result.stderr
      local diagnostics = parse_diagnostics(combined, path)
      if config().diagnostics_mode ~= "text" and #diagnostics == 0 and combined:match("unknown%s+option") then
        local fallback_process
        fallback_process = M.run({ path, "--check-only" }, root, function(fallback)
          if M.checks[path] == fallback_process then M.checks[path] = nil end
          fallback.diagnostics = parse_diagnostics(fallback.stdout .. "\n" .. fallback.stderr, path)
          fallback.compiler = info
          callback(fallback)
        end, 120000)
        process = fallback_process
        M.checks[path] = process
      else
        result.diagnostics, result.compiler = diagnostics, info
        if result.code ~= 0 and #diagnostics == 0 then result.diagnostics = { { file = path, line = 0, col = 0, severity = "error", message = result.stderr ~= "" and result.stderr or result.stdout } } end
        callback(result)
      end
    end, 120000)
    M.checks[path] = process
  end)
end

function M.command(args, root, callback, timeout_ms)
  M.run(args, root, callback, timeout_ms or 120000)
end

function M.backend_capability(info, profile)
  return info.capabilities and info.capabilities[profile] or "unknown"
end

function M.build(path, output, root, callback)
  M.run({ path, "-o", output }, root, callback, 120000)
end

function M.run_profile(path, root, profile, callback, options)
  options = options or {}
  profile = profile or "javascript"
  M.discover(root, function(info)
    if not info.available then callback({ code = nil, stdout = "", stderr = info.error, compiler = info }); return end
    if M.backend_capability(info, profile) == "unsupported" then
      callback({ code = nil, stdout = "", stderr = "The active Bend compiler does not advertise the " .. profile .. " backend.", compiler = info })
      return
    end
    if profile == "javascript" then M.run({ path }, root, callback, 120000); return end
    local directory = vim.fn.tempname()
    vim.fn.mkdir(directory, "p")
    local executable = vim.fs.joinpath(directory, "bend2-program")
    M.build(path, executable, root, function(build)
      if build.code ~= 0 then vim.fn.delete(directory, "rf"); callback(build); return end
      local args = {}
      if options.threads then args = { "--threads", tostring(options.threads) } end
      if profile == "gpu" then vim.list_extend(args, { "--gpu", options.gpu_memory or "on" }) end
      M.run_binary(executable, args, root, function(result)
        vim.fn.delete(directory, "rf")
        callback(result)
      end, 120000)
    end)
  end)
end

function M.compare(path, root, profiles, callback, options)
  local valid_profiles, unique_profiles = { javascript = true, native = true, gpu = true }, {}
  for _, profile in ipairs(profiles) do
    if not valid_profiles[profile] or unique_profiles[profile] then callback({ comparable = false, outputsMatch = false, error = "Choose distinct javascript, native or gpu backends." }); return end
    unique_profiles[profile] = true
  end
  local runs, index = {}, 1
  local function next_run()
    local profile = profiles[index]
    if not profile then
      local hashes, comparable = {}, #runs == #profiles
      for _, item in ipairs(runs) do
        if item.result.code ~= 0 then comparable = false else hashes[vim.fn.sha256(item.result.stdout)] = true end
      end
      local count = 0; for _ in pairs(hashes) do count = count + 1 end
      local error
      for _, item in ipairs(runs) do if item.result.code ~= 0 and item.result.stderr ~= "" then error = item.result.stderr; break end end
      callback({ runs = runs, comparable = comparable, outputsMatch = comparable and count == 1, error = error })
      return
    end
    M.run_profile(path, root, profile, function(result)
      runs[#runs + 1] = { profile = profile, result = result }
      if result.cancelled or result.timed_out then callback({ runs = runs, comparable = false, outputsMatch = false, error = result.cancelled and "Comparison cancelled." or "Backend run timed out." }); return end
      index = index + 1
      next_run()
    end, options)
  end
  if #profiles < 2 then callback({ comparable = false, outputsMatch = false, error = "Choose at least two backends." }); return end
  next_run()
end

function M.probe(path, root, profile, callback)
  local function status(result)
    if result.cancelled then return "cancelled" end
    if result.timed_out then return "timed out" end
    if result.code == nil then return "unavailable" end
    return result.code == 0 and "ready" or "failed"
  end
  M.discover(root, function(info)
    if not info.available then callback({ profile = profile, status = "unavailable", compiler = info, error = info.error }); return end
    if M.backend_capability(info, profile) == "unsupported" then callback({ profile = profile, status = "unsupported", compiler = info, error = "The active Bend compiler does not advertise the " .. profile .. " backend." }); return end
    if profile == "javascript" then
      M.check(path, root, function(result) callback({ profile = profile, status = status(result), compiler = info, result = result }) end)
    elseif profile == "native" then
      local directory = vim.fn.tempname(); vim.fn.mkdir(directory, "p")
      M.build(path, vim.fs.joinpath(directory, "probe"), root, function(result)
        vim.fn.delete(directory, "rf")
        callback({ profile = profile, status = status(result), compiler = info, result = result })
      end)
    else
      M.run_profile(path, root, "gpu", function(result)
        callback({ profile = profile, status = status(result), compiler = info, result = result })
      end)
    end
  end)
end

function M.compare_project(root, callback)
  local manifest_path = vim.fs.joinpath(root, ".bend2", "differential.json")
  local ok, content = pcall(vim.fn.readfile, manifest_path)
  if not ok then callback({ comparable = false, outputsMatch = false, error = "Missing .bend2/differential.json." }); return end
  local valid, manifest = pcall(vim.json.decode, table.concat(content, "\n"))
  if not valid or type(manifest) ~= "table" or type(manifest.files) ~= "table" or #manifest.files == 0 then
    callback({ comparable = false, outputsMatch = false, error = "Invalid differential manifest: files must be a non-empty array." }); return
  end
  local profiles = manifest.profiles or { "javascript", "native" }
  if type(profiles) ~= "table" or #profiles < 2 then callback({ comparable = false, outputsMatch = false, error = "The differential manifest needs at least two profiles." }); return end
  local valid_profiles, unique_profiles = { javascript = true, native = true, gpu = true }, {}
  for _, profile in ipairs(profiles) do
    if not valid_profiles[profile] or unique_profiles[profile] then callback({ comparable = false, outputsMatch = false, error = "Differential profiles must be distinct javascript, native or gpu values." }); return end
    unique_profiles[profile] = true
  end
  local threads = manifest.threads
  if threads ~= nil and (type(threads) ~= "number" or threads < 1 or threads % 1 ~= 0) then callback({ comparable = false, outputsMatch = false, error = "Differential threads must be a positive integer." }); return end
  local gpu_memory = manifest.gpuMemory
  if gpu_memory ~= nil and gpu_memory ~= "on" and not (type(gpu_memory) == "string" and gpu_memory:upper():match("^%d+%.?%d*[KMGTP]B$")) then callback({ comparable = false, outputsMatch = false, error = "Differential gpuMemory must be 'on' or a memory limit such as '4GB'." }); return end
  local files = {}
  for _, relative in ipairs(manifest.files) do
    if type(relative) ~= "string" or relative:match("^[/\\]") or relative:match("%.%.[/\\]") or relative == ".." then
      callback({ comparable = false, outputsMatch = false, error = "Differential input paths must remain inside the workspace." }); return
    end
    local path = vim.fs.normalize(vim.fs.joinpath(root, relative))
    local within = vim.fs.relpath(root, path)
    if not within or within == ".." or within:match("^%.%.[/\\]") or not path:match("%.bend$") or not vim.uv.fs_stat(path) then callback({ comparable = false, outputsMatch = false, error = "Differential input must be an existing .bend file inside the workspace: " .. relative }); return end
    files[#files + 1] = path
  end
  local results, index = {}, 1
  local function next_file()
    local file = files[index]
    if not file then
      local comparable, matched = #results == #files, true
      for _, result in ipairs(results) do comparable = comparable and result.comparable; matched = matched and result.outputsMatch end
      callback({ runs = results, comparable = comparable, outputsMatch = comparable and matched }); return
    end
    M.compare(file, root, profiles, function(result)
      results[#results + 1] = { file = file, result = result }
      index = index + 1
      next_file()
    end, { threads = threads, gpu_memory = gpu_memory })
  end
  next_file()
end

function M.gate(root, kind, callback, target)
  local name = kind == "sabotage" and "sabotagem" or "check"
  local args = {}
  if target and target:match("%S") then
    if target:match("^[/\\]") or target:match("^[A-Za-z]:[/\\]") then callback({ code = nil, stdout = "", stderr = "Gate target must be a relative path inside the workspace." }); return end
    local resolved = vim.fs.normalize(vim.fs.joinpath(root, target))
    local relative = vim.fs.relpath(vim.fs.normalize(root), resolved)
    if not relative or relative == ".." or relative:match("^%.%.[/\\]") then callback({ code = nil, stdout = "", stderr = "Gate target must stay inside the Bend 2 workspace." }); return end
    args[1] = relative
  end
  local candidates = { "scripts/" .. name .. ".sh", "scripts/" .. name .. ".ps1", "scripts/" .. name .. ".cmd" }
  for _, relative in ipairs(candidates) do
    local path = vim.fs.joinpath(root, relative)
    if vim.uv.fs_stat(path) then
      local command, prefix
      if path:match("%.sh$") then command, prefix = "bash", { path }
      elseif path:match("%.ps1$") then command, prefix = "pwsh", { "-NoProfile", "-File", path }
      else command, prefix = path, {} end
      vim.list_extend(prefix, args)
      M.run_binary(command, prefix, root, callback, 120000); return
    end
  end
  callback({ code = nil, stdout = "", stderr = "Bend 2 " .. kind .. " gate was not found under scripts/" })
end

function M.benchmark(path, root, runs, callback, options)
  options = options or {}
  runs = math.max(1, math.min(20, tonumber(runs) or 3))
  M.discover(root, function(compiler)
    if not compiler.available then callback({ ok = false, error = compiler.error, compiler = compiler }); return end
    if M.backend_capability(compiler, "native") == "unsupported" then callback({ ok = false, error = "The active Bend compiler does not advertise the native backend.", compiler = compiler }); return end
    if (options.gpu or "off") ~= "off" and M.backend_capability(compiler, "gpu") == "unsupported" then callback({ ok = false, error = "The active Bend compiler does not advertise the GPU backend.", compiler = compiler }); return end
    local directory = vim.fn.tempname(); vim.fn.mkdir(directory, "p")
    local executable, samples, output_hashes, index = vim.fs.joinpath(directory, "bend2-benchmark"), {}, {}, 0
    M.build(path, executable, root, function(build)
      if build.code ~= 0 then vim.fn.delete(directory, "rf"); callback({ ok = false, error = build.stderr, compile = build, compiler = compiler }); return end
      local function execute(warmup)
        if index >= runs then
          vim.fn.delete(directory, "rf")
          table.sort(samples)
          local middle = math.floor((#samples + 1) / 2)
          local median = #samples % 2 == 0 and (samples[middle] + samples[middle + 1]) / 2 or samples[middle]
          local hashes, outputs_match = {}, true
          for _, hash in ipairs(output_hashes) do hashes[hash] = true end
          local hash_count = 0; for _ in pairs(hashes) do hash_count = hash_count + 1 end
          outputs_match = hash_count <= 1
          callback({ ok = true, compiler = compiler, threads = options.threads, gpu = options.gpu or "off", warmup = options.warmup ~= false, runs = runs, samples_ms = samples, median_ms = median, min_ms = samples[1], max_ms = samples[#samples], outputs_match = outputs_match, output_sha256 = output_hashes[1] })
          return
        end
        local started = vim.uv.hrtime()
        local args = {}
        if options.threads then args = { "--threads", tostring(options.threads) } end
        vim.list_extend(args, { "--gpu", options.gpu or "off" })
        M.run_binary(executable, args, root, function(result)
          if result.code ~= 0 then vim.fn.delete(directory, "rf"); callback({ ok = false, error = result.stderr, compile = build, compiler = compiler }); return end
          if not warmup then
            samples[#samples + 1] = (vim.uv.hrtime() - started) / 1000000
            output_hashes[#output_hashes + 1] = vim.fn.sha256(result.stdout)
            index = index + 1
          end
          execute(false)
        end, 120000)
      end
      execute(options.warmup ~= false)
    end)
  end)
end

function M.parse_diagnostics(output, path) return parse_diagnostics(output, path) end
function M.compatibility(version) return compatible(version) end

return M
