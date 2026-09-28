local M = { cache = {}, pending = {}, retry_after = {}, generation = 0 }

local function cache_key(root)
  local options = require("bend2").options
  return vim.json.encode({
    root = vim.fs.normalize(root),
    cmd = options.cmd,
    cmd_args = options.cmd_args or {},
  })
end

function M.parse(output)
  local names, seen, inside_type = {}, {}, false
  local function add(name)
    if name and not seen[name] then
      seen[name] = true
      names[#names + 1] = name
    end
  end

  for line in (output or ""):gmatch("[^\r\n]+") do
    local top_level = line:match("^(type)%s+") or line:match("^(def)%s+") or line:match("^(law)%s+")
    if top_level then
      inside_type = top_level == "type"
      local name = line:match("^%S+%s+([A-Za-z_][A-Za-z0-9_%.]*)")
      add(name)
    elseif inside_type then
      local constructor = line:match("^%s%s+([A-Z][A-Za-z0-9_%.]*)%s*{")
      add(constructor)
    end
  end
  table.sort(names)
  return names
end

function M.get(root)
  return M.cache[cache_key(root)]
end

function M.request(root)
  local key = cache_key(root)
  if M.cache[key] or M.pending[key] then return end
  local now = vim.uv.hrtime() / 1000000000
  if M.retry_after[key] and now < M.retry_after[key] then return end

  M.pending[key] = true
  local generation = M.generation
  require("bend2.toolchain").command({ "base" }, root, function(result)
    if generation ~= M.generation then return end
    M.pending[key] = nil
    if result.code == 0 then
      M.cache[key] = M.parse(result.stdout)
      M.retry_after[key] = nil
    else
      M.retry_after[key] = vim.uv.hrtime() / 1000000000 + 30
    end
  end, 30000)
end

function M.clear()
  M.cache, M.pending, M.retry_after = {}, {}, {}
  M.generation = M.generation + 1
end

return M
