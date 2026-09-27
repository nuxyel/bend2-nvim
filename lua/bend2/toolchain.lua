local M = { jobs = {}, cache = {}, checks = {} }

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
  local done, timer, process = false, nil, nil
  local function finish(result)
    if done then return end
    done = true
    if timer then timer:stop(); timer:close() end
    if process then M.jobs[process] = nil end
    callback(result)
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
  local done, timer, process = false, nil, nil
  local function finish(result)
    if done then return end
    done = true
    if timer then timer:stop(); timer:close() end
    if process then M.jobs[process] = nil end
    callback(result)
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
  for process in pairs(M.jobs) do pcall(process.kill, process, "sigterm") end
  M.jobs = {}
end

function M.cancel_check(path)
  local process = M.checks[path]
  if process then pcall(process.kill, process, "sigterm"); M.checks[path] = nil end
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
      local function has(pattern) return text:match(pattern) ~= nil end
      local info = { available = true, version = version, compatibility = compatible(version), capabilities = { javascript = has("JavaScript") and "supported" or "unknown", native = has("native") and "supported" or "unknown", gpu = has("GPU") and "supported" or "unknown", threads = has("threads") and "supported" or "unknown" } }
      M.cache[root] = info
      callback(info)
    end, 5000)
  end, 3000)
end

local function parse_diagnostics(output, default_file)
  local diagnostics = {}
  local function add(file, line, col, severity, message)
    diagnostics[#diagnostics + 1] = { file = file, line = math.max(0, tonumber(line or 1) - 1), col = math.max(0, tonumber(col or 1) - 1), severity = severity, message = message }
  end
  local ok, decoded = pcall(vim.json.decode, output, { luanil = { object = true } })
  if not ok then decoded = nil end
  if type(decoded) == "table" then
    local records = decoded.diagnostics or { decoded }
    for _, item in ipairs(records) do
      local r = item.range or {}
      local start = r.start or item
      if type(item.message) == "string" and start.line then
        add(item.file or default_file, tonumber(start.line) or 1, tonumber(start.column or start.character) or 1, item.severity or "error", item.message)
      end
    end
  else
    for line in output:gmatch("[^\n]+") do
      local file, row, col, message = line:match("^(.+):(%d+):(%d+):%s*(.-)%s*$")
      if file then add(file, row, col, "error", message)
      elseif line:match("[Ee]rror") or line:match("[Ww]arning") then add(default_file, 1, 1, line:match("[Ww]arning") and "warning" or "error", line) end
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
    local process = M.run(args, root, function(result)
      M.checks[path] = nil
      local combined = result.stdout .. "\n" .. result.stderr
      local diagnostics = parse_diagnostics(combined, path)
      if config().diagnostics_mode == "json" and #diagnostics == 0 and combined:match("unknown%s+option") then
        local fallback_process = M.run({ path, "--check-only" }, root, function(fallback)
          M.checks[path] = nil
          fallback.diagnostics = parse_diagnostics(fallback.stdout .. "\n" .. fallback.stderr, path)
          fallback.compiler = info
          callback(fallback)
        end)
        M.checks[path] = fallback_process
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

function M.build(path, output, root, callback)
  M.run({ path, "-o", output }, root, callback, 120000)
end

function M.run_profile(path, root, profile, callback)
  profile = profile or "javascript"
  if profile == "javascript" then
    M.run({ path }, root, callback, 120000)
    return
  end
  local directory = vim.fn.tempname()
  vim.fn.mkdir(directory, "p")
  local executable = vim.fs.joinpath(directory, "bend2-program")
  M.build(path, executable, root, function(build)
    if build.code ~= 0 then vim.fn.delete(directory, "rf"); callback(build); return end
    local args = {}
    if profile == "gpu" then args = { "--gpu", "on" } end
    M.run_binary(executable, args, root, function(result)
      vim.fn.delete(directory, "rf")
      callback(result)
    end, 120000)
  end)
end

function M.compare(path, root, profiles, callback)
  local runs, index = {}, 1
  local function next_run()
    local profile = profiles[index]
    if not profile then
      local hashes, comparable = {}, #runs == #profiles
      for _, item in ipairs(runs) do
        if item.result.code ~= 0 then comparable = false else hashes[vim.fn.sha256(item.result.stdout)] = true end
      end
      local count = 0; for _ in pairs(hashes) do count = count + 1 end
      callback({ runs = runs, comparable = comparable, outputsMatch = comparable and count == 1 })
      return
    end
    M.run_profile(path, root, profile, function(result)
      runs[#runs + 1] = { profile = profile, result = result }
      index = index + 1
      next_run()
    end)
  end
  if #profiles < 2 then callback({ comparable = false, outputsMatch = false, error = "Choose at least two backends." }); return end
  next_run()
end

function M.gate(root, kind, callback)
  local candidates = kind == "sabotage" and { "scripts/sabotage.sh", "scripts/sabotage" } or { "scripts/check.sh", "scripts/check", "scripts/project-gate.sh" }
  for _, relative in ipairs(candidates) do
    local path = vim.fs.joinpath(root, relative)
    if vim.uv.fs_stat(path) then M.run({ path }, root, callback, 120000); return end
  end
  callback({ code = nil, stdout = "", stderr = "Bend 2 " .. kind .. " gate was not found under scripts/" })
end

function M.benchmark(path, root, runs, callback)
  runs = math.max(1, math.min(20, tonumber(runs) or 3))
  local directory = vim.fn.tempname(); vim.fn.mkdir(directory, "p")
  local executable, samples, index = vim.fs.joinpath(directory, "bend2-benchmark"), {}, 0
  M.build(path, executable, root, function(build)
    if build.code ~= 0 then vim.fn.delete(directory, "rf"); callback({ ok = false, error = build.stderr, compile = build }); return end
    local function execute()
      if index >= runs then
        vim.fn.delete(directory, "rf")
        table.sort(samples)
        local median = samples[math.ceil(#samples / 2)]
        callback({ ok = true, samples_ms = samples, median_ms = median, min_ms = samples[1], max_ms = samples[#samples] })
        return
      end
      local started = vim.uv.hrtime()
      M.run_binary(executable, {}, root, function(result)
        if result.code ~= 0 then vim.fn.delete(directory, "rf"); callback({ ok = false, error = result.stderr, compile = build }); return end
        samples[#samples + 1] = (vim.uv.hrtime() - started) / 1000000
        index = index + 1
        execute()
      end, 120000)
    end
    execute()
  end)
end

function M.parse_diagnostics(output, path) return parse_diagnostics(output, path) end
function M.compatibility(version) return compatible(version) end

return M
