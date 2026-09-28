local parser = require("bend2.parser")
local M = {}
local indexes = {}
local index_ttl_ns = 5 * 1000000000

local ignored_directories = { [".git"] = true, [".bend"] = true, ["node_modules"] = true, ["dist"] = true, ["build"] = true, ["target"] = true }
local workspace_file_limit = 5000

local function read_file(path)
  local fd = vim.uv.fs_open(path, "r", 438)
  if not fd then return nil end
  local stat = vim.uv.fs_fstat(fd)
  local data = stat and vim.uv.fs_read(fd, stat.size, 0) or nil
  vim.uv.fs_close(fd)
  return data
end

local function buffer_source(path)
  path = vim.fs.normalize(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) ~= "" and vim.fs.normalize(vim.api.nvim_buf_get_name(buf)) == path then
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

local function walk(root, out, predicate)
  if #out >= workspace_file_limit then return end
  local scan = vim.uv.fs_scandir(root)
  if not scan then return end
  while #out < workspace_file_limit do
    local name, kind = vim.uv.fs_scandir_next(scan)
    if not name then break end
    local path = vim.fs.joinpath(root, name)
    if kind == "directory" and not ignored_directories[name] then
      walk(path, out, predicate)
    elseif kind == "file" and predicate(name) then
      out[#out + 1] = path
    end
  end
end

function M.files(root)
  local files = {}
  walk(vim.fs.normalize(root), files, function(name) return name:match("%.bend$") ~= nil end)
  table.sort(files)
  return files
end

function M.proof_files(root)
  local files = {}
  walk(vim.fs.normalize(root), files, function(name) return name == "PROOF.bend" end)
  table.sort(files)
  return files
end

function M.document(path)
  local source, bufnr = buffer_source(path)
  if not source then return nil end
  return { path = vim.fs.normalize(path), source = source, bufnr = bufnr, parsed = parser.parse(source, path) }
end

function M.symbols(root)
  root = vim.fs.normalize(root)
  local index = indexes[root]
  if not index or vim.uv.hrtime() - index.created_at > index_ttl_ns then
    index = { documents = {}, created_at = vim.uv.hrtime() }
    for _, path in ipairs(M.files(root)) do
      local doc = M.document(path)
      if doc then index.documents[vim.fs.normalize(path)] = doc end
    end
    indexes[root] = index
  end
  local documents = {}
  for _, doc in pairs(index.documents) do documents[#documents + 1] = doc end
  table.sort(documents, function(a, b) return a.path < b.path end)
  return documents
end

function M.invalidate(root)
  if root then indexes[vim.fs.normalize(root)] = nil else indexes = {} end
end

function M.refresh_path(path)
  if not path or path == "" or not path:match("%.bend$") then return end
  path = vim.fs.normalize(path)
  for root, index in pairs(indexes) do
    local relative = vim.fs.relpath(root, path)
    if relative and relative ~= ".." and not relative:match("^%.%.[/\\]") then
      local doc = M.document(path)
      if doc then index.documents[path] = doc else index.documents[path] = nil end
    end
  end
end

local function local_name(name) return name:match("([^%.]+)$") or name end

local function find_in_document(document, name)
  if not document then return nil end
  for _, symbol in ipairs(document.parsed.symbols) do
    if symbol.kind ~= "import" and symbol.name == name then return symbol end
  end
  for _, symbol in ipairs(document.parsed.symbols) do
    if symbol.kind ~= "import" and local_name(symbol.name) == local_name(name) then return symbol end
  end
end

local function resolve(doc, word, by_path, symbols_by_name)
  local alias, member = word:match("^([A-Za-z_][A-Za-z0-9_]*)%.(.+)$")
  if alias then
    for _, import in ipairs(doc.parsed.imports) do
      if import.alias == alias and import.resolvedPath then
        local target = by_path[vim.fs.normalize(import.resolvedPath)] or M.document(import.resolvedPath)
        local symbol = find_in_document(target, member)
        if symbol then return { path = target.path, symbol = symbol } end
      end
    end
  end
  local local_symbol = find_in_document(doc, word)
  if local_symbol then return { path = doc.path, symbol = local_symbol } end
  local candidates = symbols_by_name[word] or symbols_by_name[local_name(word)] or {}
  local source_dir, same_directory = vim.fs.dirname(doc.path), nil
  for _, candidate in ipairs(candidates) do
    if vim.fs.dirname(candidate.path) == source_dir then same_directory = candidate; break end
  end
  return same_directory or candidates[1]
end

local function document_index(documents)
  local by_path, symbols_by_name = {}, {}
  local function add(name, item)
    symbols_by_name[name] = symbols_by_name[name] or {}
    symbols_by_name[name][#symbols_by_name[name] + 1] = item
  end
  for _, doc in ipairs(documents) do
    by_path[vim.fs.normalize(doc.path)] = doc
    for _, symbol in ipairs(doc.parsed.symbols) do
      if symbol.kind ~= "import" then
        local item = { path = doc.path, symbol = symbol }
        add(symbol.name, item)
        local short = local_name(symbol.name)
        if short ~= symbol.name then add(short, item) end
      end
    end
  end
  return by_path, symbols_by_name
end

function M.definition(path, row, col, root)
  local docs = M.symbols(root or vim.fs.dirname(path))
  local by_path, symbols_by_name = document_index(docs)
  local doc = by_path[vim.fs.normalize(path)] or M.document(path)
  if not doc then return nil end
  local word = parser.identifier_at(doc.source, row, col)
  if not word then return nil end
  return resolve(doc, word, by_path, symbols_by_name)
end

function M.references(path, row, col, root)
  local workspace_root = root or vim.fs.dirname(path)
  local documents = M.symbols(workspace_root)
  local by_path, symbols_by_name = document_index(documents)
  local source_doc = by_path[vim.fs.normalize(path)] or M.document(path)
  if not source_doc then return {} end
  local word = parser.identifier_at(source_doc.source, row, col)
  local target = word and resolve(source_doc, word, by_path, symbols_by_name)
  if not target then return {} end
  local target_start = target.symbol.selectionRange.start
  local target_key = target.path .. ":" .. target_start.line .. ":" .. target_start.character
  local target_name = local_name(target.symbol.name)
  local target_doc = by_path[target.path] or M.document(target.path)
  local candidates = {}
  if target_doc then candidates[#candidates + 1] = target_doc end
  for _, doc in ipairs(documents) do
    if doc.path ~= target.path then
      for _, import in ipairs(doc.parsed.imports) do
        if import.resolvedPath and vim.fs.normalize(import.resolvedPath) == target.path then candidates[#candidates + 1] = doc; break end
      end
    end
  end
  if not by_path[source_doc.path] then candidates[#candidates + 1] = source_doc end
  local results = {}
  for _, candidate in ipairs(candidates) do
    local lines = vim.split(candidate.source, "\n", { plain = true })
    for row_idx, line in ipairs(lines) do
      local code = parser.code_only(line)
      for start, identifier in code:gmatch("()([A-Za-z_][A-Za-z0-9_.]*)") do
        identifier = identifier:gsub("%.$", "")
        local member_start = identifier:match("^.*()%.")
        local name_start = start - 1 + (member_start or 1)
        if local_name(identifier) == target_name then
          local resolved = resolve(candidate, identifier, by_path, symbols_by_name)
          if resolved then
            local resolved_start = resolved.symbol.selectionRange.start
            local key = resolved.path .. ":" .. resolved_start.line .. ":" .. resolved_start.character
            if key == target_key then
              results[#results + 1] = { path = candidate.path, row = row_idx - 1, col = name_start, text = line, name = target_name }
            end
          end
        end
      end
    end
  end
  table.sort(results, function(a, b) if a.path == b.path then if a.row == b.row then return a.col < b.col end return a.row < b.row end return a.path < b.path end)
  return results
end

return M
