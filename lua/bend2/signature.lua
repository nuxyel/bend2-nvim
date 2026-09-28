local M = {}

local call_keywords = { ["if"]=true, ["for"]=true, match=true, case=true, def=true, law=true, type=true, where=true }
local closing = { [")"] = "(", ["]"] = "[", ["}"] = "{" }

local function mask(source)
  local chars = {}
  for i = 1, #source do chars[i] = source:sub(i, i) end
  local quote, escaped, comment = nil, false, false
  for i = 1, #chars do
    local char = chars[i]
    if comment then
      if char == "\n" then comment = false else chars[i] = " " end
    elseif quote then
      chars[i] = " "
      if escaped then escaped = false
      elseif char == "\\" then escaped = true
      elseif char == quote then quote = nil end
    elseif char == '"' or char == "'" then quote, chars[i] = char, " "
    elseif char == "#" then comment, chars[i] = true, " " end
  end
  return table.concat(chars)
end

function M.call_context(source, row, col)
  if row < 0 or col < 0 then return nil end
  local lines, offset = vim.split(source, "\n", { plain = true }), 0
  if row + 1 > #lines then return nil end
  for i = 1, row do offset = offset + #lines[i] + 1 end
  offset = offset + math.min(col, #lines[row + 1])
  local code = mask(source):sub(1, offset)
  local stack = {}
  for i = 1, #code do
    local char = code:sub(i, i)
    if char == "(" or char == "[" or char == "{" then
      stack[#stack + 1] = { character = char, offset = i }
    elseif closing[char] then
      for cursor = #stack, 1, -1 do
        if stack[cursor].character == closing[char] then
          for remove = #stack, cursor, -1 do stack[remove] = nil end
          break
        end
      end
    end
  end
  local opening
  for i = #stack, 1, -1 do if stack[i].character == "(" then opening = stack[i]; break end end
  if not opening then return nil end
  local prefix = code:sub(1, opening.offset - 1)
  local name = prefix:match("([A-Za-z_][A-Za-z0-9_%.]*)%s*$")
  if not name or name:match("%.%.") or name:sub(-1) == "." or call_keywords[name] then return nil end
  local active_parameter, nested = 0, {}
  local arguments = code:sub(opening.offset + 1)
  for i = 1, #arguments do
    local char = arguments:sub(i, i)
    if char == "(" or char == "[" or char == "{" then nested[#nested + 1] = char
    elseif closing[char] then
      for cursor = #nested, 1, -1 do
        if nested[cursor] == closing[char] then for remove = #nested, cursor, -1 do nested[remove] = nil end; break end
      end
    elseif char == "," and #nested == 0 then active_parameter = active_parameter + 1 end
  end
  local prefix_through_callee = code:sub(1, opening.offset - 1)
  local line_start = prefix_through_callee:match(".*()\n") or 0
  local line = select(2, prefix_through_callee:gsub("\n", ""))
  local name_start = opening.offset - 1 - #name - line_start
  return { name = name, line = line, character = math.max(0, name_start), active_parameter = active_parameter }
end

function M.parse(name, declaration)
  local code = mask(declaration)
  local escaped = vim.pesc(name)
  local pattern = "def%s+" .. escaped .. "%s*%("
  local keyword_start, header_end = code:find(pattern)
  if not keyword_start then pattern = "law%s+" .. escaped .. "%s*%("; keyword_start, header_end = code:find(pattern) end
  if not keyword_start then return nil end
  local opening = header_end
  local depth, start, parameters = 0, opening + 1, {}
  for index = opening, #code do
    local char = code:sub(index, index)
    if char == "(" then depth = depth + 1
    elseif char == ")" then
      depth = depth - 1
      if depth == 0 then
        local last = declaration:sub(start, index - 1):match("^%s*(.-)%s*$")
        if last ~= "" then parameters[#parameters + 1] = last end
        return { label = name .. "(" .. table.concat(parameters, ", ") .. ")", parameters = parameters }
      end
    elseif char == "," and depth == 1 then
      local parameter = declaration:sub(start, index - 1):match("^%s*(.-)%s*$")
      if parameter ~= "" then parameters[#parameters + 1] = parameter end
      start = index + 1
    end
  end
  local last = declaration:sub(start):match("^%s*(.-)%s*$")
  if last ~= "" then parameters[#parameters + 1] = last end
  return { label = name .. "(" .. table.concat(parameters, ", "), parameters = parameters }
end

return M
