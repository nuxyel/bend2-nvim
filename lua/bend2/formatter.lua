-- Lua adaptation of Bend 2's official bend-fmt-lsp formatter.
-- Upstream copyright 2026 HigherOrderCO; Lua port and Neovim changes copyright 2026 Renan Vinícius.
-- Licensed under Apache-2.0; see LICENSE and NOTICE.
-- Source: https://github.com/bendlang/bend/tree/main/tools/bend-fmt-lsp
-- This adapted implementation should stay synchronized with the upstream formatter contract.
local M = {}

local multi = { "<&>", ".|.", ".^.", ".&.", "==", "!=", "->", "<-", "=>", "&&", "||", "++", "<>", "<=", ">=", "<<", ">>" }
local binary = { ["="]=true, ["=="]=true, ["!="]=true, ["->"]=true, ["<-"]=true, ["=>"]=true, ["+"]=true, ["-"]=true, ["*"]=true, ["/"]=true, ["%"]=true, ["&&"]=true, ["||"]=true, ["++"]=true, ["<>"]=true, ["<&>"]=true, ["<="]=true, [">="]=true, ["<<"]=true, [">>"]=true, [".|."]=true, [".^."]=true, [".&."]=true, ["&"]=true, ["|"]=true }
local prefix_context = { ["("]=true, ["{"]=true, ["["]=true, ["<"]=true, [","]=true, [":"]=true, ["="]=true, ["for"]=true, ["case"]=true, ["~"]=true }
local angles = { ["<"]=true, [">"]=true, ["<<"]=true, [">>"]=true }
local keywords = { ["return"]=true, match=true, case=true, ["do"]=true, ["for"]=true, exs=true, where=true, is=true, import=true, def=true, type=true, law=true }

local function is_head(char) return char ~= "" and char:match("[A-Za-z_]") ~= nil end
local function is_word(char) return char ~= "" and char:match("[A-Za-z0-9_.]") ~= nil end
local function is_digit(char) return char ~= "" and char:match("%d") ~= nil end

local function lex(code)
  local tokens, i, had_gap = {}, 1, false
  while i <= #code do
    local char = code:sub(i, i)
    if char:match("%s") then
      had_gap, i = true, i + 1
    else
      local start, kind = i, "symbol"
      if char == '"' or char == "'" then
        kind = "literal"
        local quote, escaped = char, false
        i = i + 1
        while i <= #code do
          local next_char = code:sub(i, i)
          i = i + 1
          if escaped then escaped = false
          elseif next_char == "\\" then escaped = true
          elseif next_char == quote then break end
        end
        if code:sub(i - 1, i - 1) ~= quote or escaped then error("unterminated literal") end
      elseif is_head(char) then
        kind, i = "word", i + 1
        while i <= #code and is_word(code:sub(i, i)) do i = i + 1 end
      elseif is_digit(char) then
        kind, i = "number", i + 1
        while is_digit(code:sub(i, i)) do i = i + 1 end
        if code:sub(i, i) == "." and is_digit(code:sub(i + 1, i + 1)) then
          i = i + 1
          while is_digit(code:sub(i, i)) do i = i + 1 end
        end
        local exponent = code:sub(i, i)
        local next_char, after_next = code:sub(i + 1, i + 1), code:sub(i + 2, i + 2)
        if (exponent == "e" or exponent == "E") and (is_digit(next_char) or ((next_char == "+" or next_char == "-") and is_digit(after_next))) then
          i = i + 1
          if code:sub(i, i) == "+" or code:sub(i, i) == "-" then i = i + 1 end
          while is_digit(code:sub(i, i)) do i = i + 1 end
        end
        if code:sub(i, i) == "n" then i = i + 1 end
      else
        local found
        for _, candidate in ipairs(multi) do
          if code:sub(i, i + #candidate - 1) == candidate then found = candidate; break end
        end
        i = i + (found and #found or 1)
      end
      tokens[#tokens + 1] = { text = code:sub(start, i - 1), kind = kind, gap = had_gap }
      had_gap = false
    end
  end
  return tokens
end

local function split_line(text)
  local indent = text:match("^[\t ]*") or ""
  local source = text:sub(#indent + 1)
  local quote, escaped, comment_at = nil, false, nil
  for i = 1, #source do
    local char = source:sub(i, i)
    if quote then
      if escaped then escaped = false
      elseif char == "\\" then escaped = true
      elseif char == quote then quote = nil end
    elseif char == '"' or char == "'" then quote = char
    elseif char == "#" then comment_at = i; break end
  end
  if quote then error("unterminated literal") end
  local code = (comment_at and source:sub(1, comment_at - 1) or source):match("^%s*(.-)%s*$") or ""
  local comment = comment_at and source:sub(comment_at) or ""
  return { indent = indent, code = code, comment = comment, tokens = lex(code) }
end

local function unary(tokens, index)
  local token = tokens[index] and tokens[index].text
  if not token or not ({ ["+"]=true, ["-"]=true, ["~"]=true, ["?"]=true, ["@"]=true, ["&"]=true, ["%"]=true })[token] then return false end
  local previous, next_token = tokens[index - 1] and tokens[index - 1].text, tokens[index + 1]
  if not next_token then return false end
  local at_prefix = index == 1 or prefix_context[previous] or binary[previous]
  if token == "~" or token == "%" then return not not at_prefix end
  if token == "+" or token == "-" then return next_token.kind == "word" and (not next_token.gap or (index > 1 and at_prefix)) end
  return (next_token.kind == "word" or next_token.kind == "number") and not not at_prefix
end

local function needs_space(tokens, index)
  local left, right = tokens[index - 1], tokens[index]
  if not left then return false end
  if right.text:match("^[%),%]};]$") then return false end
  if right.text == ":" then return right.gap end
  if left.text == "(" or left.text == "[" or left.text == "{" then return false end
  if left.text == "," then return true end
  if right.text == "!" and (left.kind == "word" or left.text == ")" or left.text == "]" or left.text == "}") then return false end
  if left.text == "!" and right.text == "(" then return false end
  if right.text == "(" or right.text == "[" then
    local suffix = (left.kind == "word" and not keywords[left.text]) or left.kind == "number" or left.kind == "literal" or left.text == ")" or left.text == "]" or left.text == "}" or left.text == ">" or left.text == ">>"
    return not suffix
  end
  if right.text == "{" and ((left.kind == "word" and left.text ~= "return" and left.text ~= "case") or left.text == ">" or left.text == ">>" or left.text == "}") then return false end
  if left.text == "\\" and right.text == "{" then return false end
  if left.text == "." or right.text == "." then return false end
  local previous = tokens[index - 2]
  if left.kind == "number" and left.text:sub(-1) == "n" and (right.text == "+" or right.text == "++") then return right.gap end
  if (left.text == "+" or left.text == "++") and previous and previous.kind == "number" and previous.text:sub(-1) == "n" then return right.gap end
  if unary(tokens, index - 1) then return false end
  if unary(tokens, index) then return not (left.text == "(" or left.text == "[" or left.text == "{" or left.text == "<") end
  if angles[left.text] or angles[right.text] then return right.gap end
  if binary[left.text] or binary[right.text] then return true end
  if left.text == ":" then return true end
  return true
end

local function format_tokens(tokens)
  local output = {}
  for i, token in ipairs(tokens) do
    if needs_space(tokens, i) then output[#output + 1] = " " end
    output[#output + 1] = token.text
  end
  return table.concat(output)
end

local function indent_depths(lines)
  local depths, stack = {}, { 0 }
  for _, line in ipairs(lines) do
    if line.code == "" and line.comment == "" then
      depths[#depths + 1] = -1
    else
      local width = 0
      for i = 1, #line.indent do width = width + (line.indent:sub(i, i) == "\t" and (8 - width % 8) or 1) end
      while #stack > 1 and width < stack[#stack] do table.remove(stack) end
      if width > stack[#stack] then stack[#stack + 1] = width
      elseif width ~= stack[#stack] then stack[#stack] = width end
      depths[#depths + 1] = #stack - 1
    end
  end
  return depths
end

local function fingerprint(lines)
  local depths, rows = indent_depths(lines), {}
  for i, line in ipairs(lines) do
    local tokens = {}
    for _, token in ipairs(line.tokens) do tokens[#tokens + 1] = token.text end
    rows[i] = #tokens == 0 and "" or (depths[i] .. ":" .. table.concat(tokens, "^@"))
  end
  return table.concat(rows, "\n")
end

function M.format(source, options)
  options = options or {}
  local eol = source:find("\r\n", 1, true) and "\r\n" or "\n"
  local final_eol = source:sub(-1) == "\n"
  local normalized = source:gsub("\r\n", "\n")
  local lines = vim.split(normalized, "\n", { plain = true })
  if final_eol then table.remove(lines) end
  local ok, parsed = pcall(function()
    local result = {}
    for _, line in ipairs(lines) do result[#result + 1] = split_line(line) end
    return result
  end)
  if not ok then return source end
  local depths, width, spaces = indent_depths(parsed), math.max(1, tonumber(options.tabSize) or 2), options.insertSpaces ~= false
  local formatted = {}
  for i, line in ipairs(parsed) do
    if line.code == "" and line.comment == "" then
      formatted[i] = ""
    else
      local depth = math.max(0, depths[i])
      local prefix = spaces and string.rep(" ", depth * width) or string.rep("\t", depth)
      local code = format_tokens(line.tokens)
      formatted[i] = code == "" and (prefix .. line.comment) or (prefix .. code .. (line.comment == "" and "" or "  " .. line.comment))
    end
  end
  local output = table.concat(formatted, eol) .. (final_eol and eol or "")
  local verify_ok, check_lines = pcall(function()
    local result = {}
    local rows = vim.split(output:gsub("\r\n", "\n"), "\n", { plain = true })
    if final_eol then table.remove(rows) end
    for _, line in ipairs(rows) do result[#result + 1] = split_line(line) end
    return result
  end)
  if not verify_ok or fingerprint(parsed) ~= fingerprint(check_lines) then return source end
  return output
end

return M
