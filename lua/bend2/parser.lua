local M = {}

local function range(line, start_col, end_col)
  return { start = { line = line, character = start_col }, finish = { line = line, character = end_col } }
end

function M.code_only(line)
  local chars = {}
  for i = 1, #line do chars[i] = line:sub(i, i) end
  local quote, escaped = nil, false
  for i = 1, #chars do
    local ch = chars[i]
    if quote then
      chars[i] = " "
      if escaped then escaped = false
      elseif ch == "\\" then escaped = true
      elseif ch == quote then quote = nil end
    elseif ch == '"' or ch == "'" then quote, chars[i] = ch, " "
    elseif ch == "#" then
      for j = i, #chars do chars[j] = " " end
      break
    end
  end
  return table.concat(chars)
end

local function exists_file(path)
  local stat = vim.uv.fs_stat(path)
  return stat and stat.type == "file"
end

function M.resolve_import(file, import_path)
  if not file or import_path:sub(1, 1) ~= "." then return nil end
  local base = vim.fs.normalize(vim.fs.joinpath(vim.fs.dirname(file), import_path))
  for _, candidate in ipairs({ base, base .. ".bend", vim.fs.joinpath(base, "main.bend") }) do
    if exists_file(candidate) then return candidate end
  end
end

local function parallel_warning(line, line_number)
  local code = M.code_only(line)
  local rhs = code:match("^%s*[A-Za-z_][A-Za-z0-9_]*%s+[A-Za-z_][A-Za-z0-9_]*%s*=%s*(.+)$")
  if not rhs then return nil end
  local depth, quote, escaped = 0, nil, false
  for i = 1, #rhs do
    local ch = rhs:sub(i, i)
    if quote then
      if escaped then escaped = false elseif ch == "\\" then escaped = true elseif ch == quote then quote = nil end
    elseif ch == '"' or ch == "'" then quote = ch
    elseif ch:match("[({%[<]") then depth = depth + 1
    elseif ch:match("[)}%]>]") then depth = math.max(0, depth - 1)
    elseif ch:match("%s") and depth == 0 and i > 1 then
      local left, right = rhs:sub(1, i - 1):gsub("%s+$", ""), rhs:sub(i):gsub("^%s+", "")
      if left:match("[%w_]+%s*%(") and right:match("[%w_]+%s*%(") then
        local lsize, rsize = #left:gsub("%s", ""), #right:gsub("%s", "")
        if math.min(lsize, rsize) > 0 and math.max(lsize, rsize) >= math.min(lsize, rsize) * 3 then
          return { message = "Parallel branches have very different syntactic sizes; measure before relying on a performance gain.", severity = "warning", source = "bend2-parser", range = range(line_number, 0, #line) }
        end
        break
      end
    end
  end
end

function M.parse(source, file)
  local result = { symbols = {}, diagnostics = {}, words = {}, imports = {} }
  local seen, active_type = {}, nil
  local lines = vim.split(source, "\n", { plain = true })
  for line_idx, line in ipairs(lines) do
    line = line:gsub("\r$", "")
    local line_number, code = line_idx - 1, M.code_only(line)
    for word in code:gmatch("[A-Za-z_][A-Za-z0-9_]*") do result.words[word] = true end
    if active_type and code:match("%S") and not line:match("^%s") then active_type = nil end
    local indent = code:match("^(%s*)") or ""
    local declaration = code:sub(#indent + 1)
    if declaration:match("^public%s+") then declaration = declaration:gsub("^public%s+", "")
    elseif declaration:match("^private%s+") then declaration = declaration:gsub("^private%s+", "") end
    local keyword, name = declaration:match("^(%a+)%s+([A-Za-z_][A-Za-z0-9_.]*)")
    if keyword == "def" or keyword == "law" or keyword == "type" then
      local start_col = (code:find(name, #indent + 1, true) or 1) - 1
      local item = { name = name, kind = keyword == "def" and "function" or keyword, detail = keyword .. " " .. name, range = range(line_number, #indent, #line), selectionRange = range(line_number, start_col, start_col + #name) }
      if seen[name] then
        result.diagnostics[#result.diagnostics + 1] = { message = "Duplicate declaration '" .. name .. "'.", severity = "error", source = "bend2-parser", range = item.selectionRange }
      else seen[name], result.symbols[#result.symbols + 1] = item, item end
      active_type = keyword == "type" and name or nil
    elseif active_type and line:match("^%s+") then
      local ctor = code:match("^%s*([A-Za-z_][A-Za-z0-9_.]*)%s*{")
      if ctor then
        local full_name = active_type .. "." .. ctor
        local pos = code:find(ctor, 1, true) - 1
        result.symbols[#result.symbols + 1] = { name = full_name, kind = "constructor", detail = "constructor " .. full_name, range = range(line_number, pos, #line), selectionRange = range(line_number, pos, pos + #ctor) }
      end
    end
    local path, alias = code:match("^%s*import%s+([^%s]+)%s+as%s+([A-Za-z_][A-Za-z0-9_]*)")
    if not path then path = code:match("^%s*import%s+([^%s]+)") end
    if path then
      alias = alias or vim.fs.basename(path):gsub("%.bend$", "")
      local start_col = (code:find(path, 1, true) or 1) - 1
      local import = { path = path, alias = alias, range = range(line_number, start_col, start_col + #path), resolvedPath = M.resolve_import(file, path) }
      result.imports[#result.imports + 1] = import
      result.symbols[#result.symbols + 1] = { name = alias, kind = "import", detail = "import " .. path, range = range(line_number, 0, #line), selectionRange = import.range }
      if path:sub(1, 1) == "." and not import.resolvedPath then
        result.diagnostics[#result.diagnostics + 1] = { message = "Cannot resolve local import '" .. path .. "'.", severity = "error", source = "bend2-parser", range = import.range }
      end
    end
    for token in code:gmatch("%?[%w_]+") do
      local pos = code:find(token, 1, true) - 1
      result.diagnostics[#result.diagnostics + 1] = { message = "Open proof goal '" .. token .. "'.", severity = "warning", source = "bend2-proof", range = range(line_number, pos, pos + #token) }
    end
    for _, marker in ipairs({ "@unsafe", "foreign" }) do
      local start = code:find("^%s*" .. marker)
      if start then
        result.diagnostics[#result.diagnostics + 1] = { message = marker == "@unsafe" and "Unsafe proof marker requires explicit UNSAFE_OK review." or "Foreign proof dependency requires explicit review.", severity = "warning", source = "bend2-proof", range = range(line_number, start - 1, start - 1 + #marker) }
      end
    end
    local warning = parallel_warning(line, line_number)
    if warning then result.diagnostics[#result.diagnostics + 1] = warning end
  end
  return result
end

function M.identifier_at(source, row, col)
  local line = vim.split(source, "\n", { plain = true })[row + 1] or ""
  local code = M.code_only(line)
  for start, word in code:gmatch("()([A-Za-z_][A-Za-z0-9_]*)") do
    if col >= start - 1 and col <= start - 1 + #word then return word, start - 1 end
  end
end

return M
