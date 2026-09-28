local M = {}

local multi = { "<&>", ".|.", ".^.", ".&.", "==", "!=", "->", "<-", "=>", "&&", "||", "++", "<>", "<=", ">=", "<<", ">>" }
local binary = { ["="]=true,["=="]=true,["!="]=true,["->"]=true,["<-"]=true,["=>"]=true,["+"]=true,["-"]=true,["*"]=true,["/"]=true,["%"]=true,["&&"]=true,["||"]=true,["++"]=true,["<>"]=true,["<&>"]=true,["<="]=true,[">="]=true,["<<"]=true,[">>"]=true,[".|."]=true,[".^."]=true,[".&."]=true,["&"]=true,["|"]=true }
local keywords = { ["return"]=true, match=true, case=true, ["do"]=true, ["for"]=true, exs=true, where=true, is=true, import=true, def=true, type=true, law=true }

local function tokenize(code)
  local tokens, i, gap = {}, 1, false
  while i <= #code do
    local ch = code:sub(i, i)
    if ch:match("%s") then gap, i = true, i + 1
    else
      local start, kind = i, "symbol"
      if ch == '"' or ch == "'" then
        kind = "literal"
        local quote, escaped = ch, false
        i = i + 1
        while i <= #code do
          local c = code:sub(i, i)
          if escaped then escaped = false elseif c == "\\" then escaped = true elseif c == quote then i = i + 1; break end
          i = i + 1
        end
        if code:sub(i - 1, i - 1) ~= quote then return nil end
      elseif ch:match("[A-Za-z_]") then
        kind, i = "word", i + 1
        while i <= #code and code:sub(i, i):match("[A-Za-z0-9_.]") do i = i + 1 end
      elseif ch:match("%d") then
        kind, i = "number", i + 1
        while i <= #code and code:sub(i, i):match("[%d.]" ) do i = i + 1 end
      else
        local found
        for _, candidate in ipairs(multi) do if code:sub(i, i + #candidate - 1) == candidate then found = candidate; break end end
        i = i + (found and #found or 1)
      end
      tokens[#tokens + 1] = { text = code:sub(start, i - 1), kind = kind, gap = gap }
      gap = false
    end
  end
  return tokens
end

local prefix_context = { ["("]=true, ["{"]=true, ["["]=true, ["<"]=true, [","]=true, [":"]=true, ["="]=true, ["for"]=true, ["case"]=true, ["~"]=true }

local function unary(tokens, index)
  local token = tokens[index] and tokens[index].text
  if not token or not ({ ["+"]=true, ["-"]=true, ["~"]=true, ["?"]=true, ["@"]=true, ["&"]=true, ["%"]=true })[token] then return false end
  local previous, next_token = tokens[index - 1] and tokens[index - 1].text, tokens[index + 1]
  if not next_token then return false end
  local at_prefix = index == 1 or prefix_context[previous] or binary[previous]
  if token == "~" or token == "%" then return not not at_prefix end
  if token == "+" or token == "-" then return next_token.kind == "word" and not not at_prefix end
  return (next_token.kind == "word" or next_token.kind == "number") and not not at_prefix
end

local function needs_space(tokens, i)
  local left, right = tokens[i - 1], tokens[i]
  if not left then return false end
  if right.text:match("^[%),%]};]$") then return false end
  if right.text == ":" then return right.gap end
  if left.text == "(" or left.text == "[" or left.text == "{" then return false end
  if left.text == "," then return true end
  if right.text == "!" and (left.kind == "word" or left.text:match("^[%)%]}>]$")) then return false end
  if left.text == "!" and right.text == "(" then return false end
  if right.text == "(" or right.text == "[" then
    local suffix = (left.kind == "word" and not keywords[left.text]) or left.kind == "number" or left.kind == "literal" or left.text:match("^[%)%]}>]$")
    return not suffix
  end
  if right.text == "{" and ((left.kind == "word" and left.text ~= "return" and left.text ~= "case") or left.text == ">" or left.text == "}" or left.text == ">>") then return false end
  if left.text == "." or right.text == "." then return false end
  if unary(tokens, i - 1) then return false end
  if unary(tokens, i) then return not (left.text == "(" or left.text == "[" or left.text == "{" or left.text == "<") end
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

function M.format(source, options)
  options = options or {}
  local eol = source:find("\r\n", 1, true) and "\r\n" or "\n"
  local final_eol = source:sub(-1) == "\n"
  local lines = vim.split(source:gsub("\r\n", "\n"), "\n", { plain = true })
  if final_eol then table.remove(lines) end
  local stack, formatted, fingerprints = { 0 }, {}, {}
  local width = tonumber(options.tabSize) or 2
  local use_spaces = options.insertSpaces ~= false
  for _, raw in ipairs(lines) do
    local indent = raw:match("^[\t ]*") or ""
    local source_line = raw:sub(#indent + 1)
    local quote, escaped, comment_at = nil, false, nil
    for i = 1, #source_line do
      local ch = source_line:sub(i, i)
      if quote then if escaped then escaped = false elseif ch == "\\" then escaped = true elseif ch == quote then quote = nil end
      elseif ch == '"' or ch == "'" then quote = ch
      elseif ch == "#" then comment_at = i; break end
    end
    local code = (comment_at and source_line:sub(1, comment_at - 1) or source_line):gsub("%s+$", "")
    local comment = comment_at and source_line:sub(comment_at) or ""
    local tokens = tokenize(code)
    if not tokens then return source end
    local fingerprint = {}
    for _, token in ipairs(tokens) do fingerprint[#fingerprint + 1] = token.text end
    fingerprints[#fingerprints + 1] = table.concat(fingerprint, "\31")
    if #tokens > 0 or comment ~= "" then
      local current_width = 0
      for i = 1, #indent do current_width = current_width + (indent:sub(i, i) == "\t" and (8 - current_width % 8) or 1) end
      while #stack > 1 and current_width < stack[#stack] do table.remove(stack) end
      if current_width > stack[#stack] then stack[#stack + 1] = current_width
      elseif current_width ~= stack[#stack] then stack[#stack] = current_width end
      local depth = #stack - 1
      local prefix = use_spaces and string.rep(" ", depth * width) or string.rep("\t", depth)
      local text = format_tokens(tokens)
      formatted[#formatted + 1] = text == "" and prefix .. comment or prefix .. text .. (comment ~= "" and "  " .. comment or "")
    else formatted[#formatted + 1] = "" end
  end
  local out = table.concat(formatted, eol) .. (final_eol and eol or "")
  if #formatted ~= #lines then return source end
  local check_lines = vim.split(out:gsub("\r\n", "\n"), "\n", { plain = true })
  if final_eol then table.remove(check_lines) end
  for index, line in ipairs(check_lines) do
    local code = line:match("^(.-)#") or line
    local tokens, current = tokenize(code), {}
    if not tokens then return source end
    for _, token in ipairs(tokens) do current[#current + 1] = token.text end
    if table.concat(current, "\31") ~= fingerprints[index] then return source end
  end
  return out
end

return M
