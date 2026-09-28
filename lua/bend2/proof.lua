local parser = require("bend2.parser")
local workspace = require("bend2.workspace")
local M = {}

local function escaped(text) return (text:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")) end

function M.body(source, law_name)
  local lines, first = vim.split(source, "\n", { plain = true }), nil
  for index, line in ipairs(lines) do
    local name = line:match("^%s*def%s+([A-Za-z_][A-Za-z0-9_.]*)")
    if name and (name == law_name or name == "Laws." .. law_name) then first = index; break end
  end
  if not first then return nil end
  local out = { lines[first] }
  for index = first + 1, #lines do
    if lines[index]:match("^%s*def%s+") then break end
    out[#out + 1] = lines[index]
  end
  return table.concat(out, "\n"), first - 1
end

function M.goal(source, law_name)
  local body, first = M.body(source, law_name)
  if not body then return nil end
  local masked_lines = {}
  for line in (body .. "\n"):gmatch("(.-)\n") do masked_lines[#masked_lines + 1] = parser.code_only(line) end
  local masked = table.concat(masked_lines, "\n")
  local offset = masked:find("%?[%w_]+")
  if not offset then return nil end
  local before = masked:sub(1, offset - 1)
  local line = select(2, before:gsub("\n", ""))
  local last_newline = before:match(".*()\n") or 0
  return { token = body:match("%?[%w_]+", offset), line = first + line, character = #before - last_newline }
end

function M.dependencies(source, law_name)
  local body = M.body(source, law_name)
  if not body then return {} end
  local dependencies = {}
  local lines = {}
  for line in (body .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = parser.code_only(line) end
  body = table.concat(lines, "\n")
  for name in body:gmatch("([A-Za-z_][A-Za-z0-9_%.]*)%s*%(") do
    if name ~= law_name and name ~= "if" and name ~= "for" and name ~= "match" and name ~= "case" and name ~= "def" and name ~= "law" then dependencies[name] = true end
  end
  local out = {}; for name in pairs(dependencies) do out[#out + 1] = name end; table.sort(out)
  return out
end

function M.allowlist(source)
  local entries = {}
  for line in source:gmatch("[^\n]+") do
    line = line:gsub("%s+#.*$", ""):gsub("%s+", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" and line:sub(1, 1) ~= "#" then entries[line] = true end
  end
  return entries
end

function M.status(source, law_name, compiler_status, compiler_available)
  if not source or source == "" then return "missing proof" end
  local body = M.body(source, law_name)
  if not body then return "missing proof" end
  local lines = {}
  for line in (body .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = parser.code_only(line) end
  body = table.concat(lines, "\n")
  if compiler_status == "failed" then return "failed" end
  if body:match("@unsafe%f[%W]") then return "unsafe" end
  if body:match("%f[%w]foreign%f[%W]") then return "foreign" end
  if compiler_status == "passed" then return "proved" end
  if body:match("%?[%w_]+") then return "open" end
  return compiler_available and "proved" or "not checked"
end

local function read(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and table.concat(lines, "\n") or ""
end

local function law_entries(root)
  local entries = {}
  for _, law_path in ipairs(vim.fs.find("LAWS.bend", { path = root, type = "file", limit = 250 })) do
    if not law_path:find("/node_modules/", 1, true) then
      local proof_path = vim.fs.joinpath(vim.fs.dirname(law_path), "PROOF.bend")
      local unsafe_path = vim.fs.joinpath(vim.fs.dirname(law_path), "UNSAFE_OK")
      local law_source, proof_source = read(law_path), read(proof_path)
      for line_idx, line in ipairs(vim.split(law_source, "\n", { plain = true })) do
        local name = line:match("^%s*law%s+([A-Za-z_][A-Za-z0-9_]*)")
        if name then
          local deps, allow = M.dependencies(proof_source, name), M.allowlist(read(unsafe_path))
          local reviewed, unlisted = {}, {}
          for _, dependency in ipairs(deps) do table.insert(allow[dependency] and reviewed or unlisted, dependency) end
          entries[#entries + 1] = { name = name, law_path = law_path, proof_path = proof_path, line = line_idx - 1, proof_source = proof_source, dependencies = deps, status = M.status(proof_source, name), reviewed = reviewed, unlisted = unlisted }
        end
      end
    end
  end
  table.sort(entries, function(a, b) if a.law_path == b.law_path then return a.name < b.name end return a.law_path < b.law_path end)
  return entries
end

local function display(entries)
  local lines = { "Bend 2 Proof Explorer", "Enter opens the law. :Bend2ProofDetails shows details.", "" }
  for _, entry in ipairs(entries) do
    lines[#lines + 1] = string.format("%-13s %s  [%s]  %s", entry.status, entry.name, vim.fn.fnamemodify(entry.law_path, ":."), #entry.dependencies > 0 and table.concat(entry.dependencies, ", ") or "")
  end
  if #entries == 0 then lines[#lines + 1] = "No LAWS.bend files found in this workspace." end
  return lines
end

local function update_explorer(buf, root)
  local entries = law_entries(root)
  for _, entry in ipairs(entries) do entry.root = root end
  local generation = (vim.b[buf].bend2_proof_generation or 0) + 1
  vim.b[buf].bend2_proof_generation = generation
  vim.b[buf].bend2_proof_root = root
  vim.b[buf].bend2_proof_entries = entries
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, display(entries))
  vim.bo[buf].modifiable = false
  local checked = {}
  for _, entry in ipairs(entries) do
    if not checked[entry.proof_path] and vim.fn.filereadable(entry.proof_path) == 1 then
      checked[entry.proof_path] = true
      require("bend2.toolchain").check(entry.proof_path, root, function(result)
        if not result.compiler or not result.compiler.available or result.cancelled or result.timed_out or not vim.api.nvim_buf_is_valid(buf) then return end
        if vim.b[buf].bend2_proof_generation ~= generation then return end
        local compiler_status = result.code == 0 and "passed" or "failed"
        for _, law in ipairs(entries) do
          if law.proof_path == entry.proof_path then law.status = M.status(law.proof_source, law.name, compiler_status, true) end
        end
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, display(entries))
        vim.bo[buf].modifiable = false
        vim.b[buf].bend2_proof_entries = entries
      end)
    end
  end
end

function M.open_explorer()
  local root = workspace.root(vim.api.nvim_get_current_buf(), require("bend2").options)
  local buf = vim.fn.bufnr("Bend2Proofs")
  if buf <= 0 or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "Bend2Proofs")
    vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].filetype = "nofile", "wipe", "bend2proofs"
  end
  update_explorer(buf, root)
  local win = vim.fn.bufwinid(buf)
  if win < 0 then
    vim.cmd("botright split")
    vim.api.nvim_win_set_buf(0, buf)
  else
    vim.api.nvim_set_current_win(win)
  end
  vim.keymap.set("n", "<CR>", function()
    local item = vim.b[buf].bend2_proof_entries[vim.api.nvim_win_get_cursor(0)[1] - 3]
    if not item then return end
    vim.cmd.edit(vim.fn.fnameescape(item.law_path))
    vim.api.nvim_win_set_cursor(0, { item.line + 1, 0 })
  end, { buffer = buf, desc = "Open Bend 2 law" })
  vim.keymap.set("n", "o", M.open_proof, { buffer = buf, desc = "Open Bend 2 proof" })
  vim.keymap.set("n", "d", M.details, { buffer = buf, desc = "Show Bend 2 proof details" })
  vim.keymap.set("n", "g", M.goal_command, { buffer = buf, desc = "Jump to Bend 2 proof goal" })
  vim.keymap.set("n", "c", M.check_proof, { buffer = buf, desc = "Check Bend 2 proof" })
  vim.keymap.set("n", "r", M.refresh_explorer, { buffer = buf, desc = "Refresh Bend 2 Proof Explorer" })
end

function M.refresh_explorer()
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].filetype ~= "bend2proofs" then
    buf = vim.fn.bufnr("Bend2Proofs")
    if buf <= 0 or not vim.api.nvim_buf_is_valid(buf) then M.open_explorer(); return end
  end
  local root = vim.b[buf].bend2_proof_root
  if not root then M.open_explorer(); return end
  update_explorer(buf, root)
  local win = vim.fn.bufwinid(buf)
  if win >= 0 then vim.api.nvim_set_current_win(win) end
end

function M.current_entry()
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].filetype == "bend2proofs" then
    local entry = vim.b[buf].bend2_proof_entries[vim.api.nvim_win_get_cursor(0)[1] - 3]
    if entry then return entry end
  end
  local name = parser.identifier_at(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"), vim.api.nvim_win_get_cursor(0)[1] - 1, vim.api.nvim_win_get_cursor(0)[2])
  local path = vim.api.nvim_buf_get_name(buf)
  if not name or not path:match("LAWS%.bend$") then return nil end
  local proof = read(vim.fs.joinpath(vim.fs.dirname(path), "PROOF.bend"))
  return { name = name, law_path = path, proof_path = vim.fs.joinpath(vim.fs.dirname(path), "PROOF.bend"), proof_source = proof, dependencies = M.dependencies(proof, name), status = M.status(proof, name), root = workspace.root(buf, require("bend2").options) }
end

function M.open_proof()
  local entry = M.current_entry()
  if not entry then vim.notify("Place the cursor on a law or proof explorer item.", vim.log.levels.WARN); return end
  if vim.fn.filereadable(entry.proof_path) == 0 then vim.notify("No PROOF.bend exists for this law.", vim.log.levels.INFO); return end
  vim.cmd.edit(vim.fn.fnameescape(entry.proof_path))
  local _, body_line = M.body(entry.proof_source, entry.name)
  local goal = M.goal(entry.proof_source, entry.name)
  if goal then vim.api.nvim_win_set_cursor(0, { goal.line + 1, goal.character })
  elseif body_line then vim.api.nvim_win_set_cursor(0, { body_line + 1, 0 }) end
end

function M.details()
  local entry = M.current_entry()
  if not entry then vim.notify("Place the cursor on a law or proof explorer item.", vim.log.levels.WARN); return end
  local lines = { "Law: " .. entry.name, "Status: " .. entry.status, "Dependencies: " .. (#entry.dependencies > 0 and table.concat(entry.dependencies, ", ") or "none"), "", "Statement:", read(entry.law_path):match("[^\n]*law%s+" .. escaped(entry.name) .. "[^\n]*") or ("law " .. entry.name), "", "Proof:" }
  for line in entry.proof_source:gmatch("[^\n]+") do lines[#lines + 1] = line end
  if #entry.proof_source == 0 then lines[#lines + 1] = "No proof file or definition found." end
  if #(entry.unlisted or {}) > 0 then lines[#lines + 1] = "Unlisted unsafe/foreign dependencies: " .. table.concat(entry.unlisted, ", ") end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].modifiable = "nofile", "wipe", false
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buf)
end

function M.goal_command()
  local entry = M.current_entry()
  if not entry then vim.notify("Place the cursor on a law or proof explorer item.", vim.log.levels.WARN); return end
  local goal = M.goal(entry.proof_source, entry.name)
  if not goal then vim.notify("No open proof goal was found.", vim.log.levels.INFO); return end
  vim.cmd.edit(vim.fn.fnameescape(entry.proof_path))
  vim.api.nvim_win_set_cursor(0, { goal.line + 1, goal.character })
end

function M.check_proof()
  local entry = M.current_entry()
  if not entry then vim.notify("Place the cursor on a law or proof explorer item.", vim.log.levels.WARN); return end
  if vim.fn.filereadable(entry.proof_path) == 0 then vim.notify("No PROOF.bend exists for this law.", vim.log.levels.WARN); return end
  local root = entry.root or workspace.root(vim.api.nvim_get_current_buf(), require("bend2").options)
  require("bend2.toolchain").check(entry.proof_path, root, function(result)
    require("bend2.editor").output("Bend 2 proof check: " .. entry.name, result)
  end)
end

function M.review_changes()
  local root = workspace.root(vim.api.nvim_get_current_buf(), require("bend2").options)
  local paths = {}
  for _, path in ipairs(workspace.files(root)) do if vim.fs.basename(path) == "LAWS.bend" then paths[#paths + 1] = path end end
  if #paths == 0 then vim.notify("No LAWS.bend files were found in this workspace.", vim.log.levels.INFO); return end
  local function diff(path)
    local relative = vim.fs.relpath(root, path) or path
    require("bend2.toolchain").run_binary("git", { "diff", "--no-ext-diff", "--unified=80", "HEAD", "--", relative }, root, function(result)
      if result.code == 0 and result.stdout == "" then result.stdout = relative .. ": no changes relative to HEAD.\n" end
      require("bend2.editor").output("Bend 2 law changes (review only): " .. relative, result)
    end, 30000)
  end
  if #paths == 1 then diff(paths[1]); return end
  vim.ui.select(paths, { prompt = "Choose a LAWS.bend file to compare with HEAD", format_item = function(path) return vim.fs.relpath(root, path) or path end }, function(path)
    if path then diff(path) end
  end)
end

return M
