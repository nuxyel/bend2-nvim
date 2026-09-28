local parser = require("bend2.parser")
local M = {}

local function read_file(path)
  local fd = vim.uv.fs_open(path, "r", 438)
  if not fd then return nil end
  local stat = vim.uv.fs_fstat(fd)
  local data = stat and vim.uv.fs_read(fd, stat.size, 0) or nil
  vim.uv.fs_close(fd)
  return data
end

local function buffer_source(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) == path then
      return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"), buf
    end
  end
  return read_file(path)
end

function M.root(bufnr, opts)
  local custom = opts and opts.root_dir
  if type(custom) == "function" then
    local root = custom(bufnr)
    if root then return vim.fs.normalize(root) end
  elseif type(custom) == "string" then return vim.fs.normalize(custom) end
  local file = vim.api.nvim_buf_get_name(bufnr or 0)
  local start = file ~= "" and vim.fs.dirname(file) or vim.fn.getcwd()
  return vim.fs.root(start, opts and opts.root_markers or { ".git" }) or start
end

function M.files(root)
  return vim.fs.find(function(name) return name:match("%.bend$") ~= nil end, { path = root, type = "file", limit = 500 })
end

function M.document(path)
  local source, bufnr = buffer_source(path)
  if not source then return nil end
  return { path = path, source = source, bufnr = bufnr, parsed = parser.parse(source, path) }
end

function M.symbols(root)
  local documents = {}
  for _, path in ipairs(M.files(root)) do
    local doc = M.document(path)
    if doc then documents[#documents + 1] = doc end
  end
  return documents
end

function M.definition(path, row, col, root)
  local doc = M.document(path)
  if not doc then return nil end
  local word = parser.identifier_at(doc.source, row, col)
  if not word then return nil end
  local alias, member = word:match("^([A-Za-z_][A-Za-z0-9_]*)%.(.+)$")
  local imported_path
  if alias then
    for _, item in ipairs(doc.parsed.imports) do
      if item.alias == alias then imported_path = item.resolvedPath; break end
    end
  end
  local candidates = {}
  if imported_path then
    local imported = M.document(imported_path)
    if imported then candidates[#candidates + 1] = imported end
  else candidates = M.symbols(root or vim.fs.dirname(path)) end
  local target_name = member or word
  for _, candidate in ipairs(candidates) do
    for _, symbol in ipairs(candidate.parsed.symbols) do
      if symbol.name == target_name or symbol.name:match("%.([^%.]+)$") == target_name then
        return { path = candidate.path, symbol = symbol }
      end
    end
  end
end

function M.references(path, row, col, root)
  local target = M.definition(path, row, col, root)
  local doc = M.document(path)
  if not target or not doc then return {} end
  local name = parser.identifier_at(doc.source, row, col)
  local short = name and name:match("([^%.]+)$") or target.symbol.name
  local results = {}
  for _, candidate in ipairs(M.symbols(root or vim.fs.dirname(path))) do
    local lines = vim.split(candidate.source, "\n", { plain = true })
    for row_idx, line in ipairs(lines) do
      local code = parser.code_only(line)
      for start, word in code:gmatch("()([A-Za-z_][A-Za-z0-9_]*)") do
        if word == short or word == target.symbol.name then
          results[#results + 1] = { path = candidate.path, row = row_idx - 1, col = start - 1, text = line, name = word }
        end
      end
    end
  end
  return results
end

return M
