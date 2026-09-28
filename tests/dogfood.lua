vim.opt.rtp:prepend(".")

local fixture = vim.fn.fnamemodify(vim.fs.normalize("tests/dogfood/proof-project"), ":p")
local compiler = vim.env.BEND2_BIN or "bend"
require("bend2").setup({ cmd = compiler, validation = "parser" })
local toolchain = require("bend2.toolchain")
local root = fixture

local info
toolchain.discover(root, function(result) info = result end, true)
assert(vim.wait(10000, function() return info ~= nil end, 10), "compiler discovery timed out")
assert(info.available, info.error or "Bend compiler unavailable")
local expected = vim.env.BEND_DOGFOOD_VERSION
if expected then assert(info.version == expected, "expected Bend " .. expected .. ", found " .. tostring(info.version)) end
assert(info.compatibility == "supported", "Bend compiler version is unsupported")

local parsed_main = require("bend2.parser").parse(table.concat(vim.fn.readfile(fixture .. "/main.bend"), "\n"), fixture .. "/main.bend")
assert(#parsed_main.symbols > 0, "dogfood main module should expose symbols")
local app = require("bend2.workspace").definition(fixture .. "/app.bend", 4, 8, root)
assert(app and app.path:match("main%.bend$"), "qualified import navigation should find main.bend")

local proof_result
toolchain.check(fixture .. "/PROOF.bend", root, function(result) proof_result = result end)
assert(vim.wait(120000, function() return proof_result ~= nil end, 10), "proof check timed out")
assert(proof_result.code == 0, "Bend proof dogfood failed: " .. (proof_result.stderr or "unknown error"))
local status = require("bend2.proof").status(table.concat(vim.fn.readfile(fixture .. "/PROOF.bend"), "\n"), "adding_zero_preserves_value", "passed", true)
assert(status == "proved", "compiler-checked law should be marked proved")

vim.cmd.edit(vim.fn.fnameescape(fixture .. "/main.bend"))
require("bend2.proof").open_explorer()
local explorer = vim.fn.bufnr("Bend2Proofs")
assert(explorer > 0, "Proof Explorer should open")
assert(vim.wait(120000, function()
  local lines = vim.api.nvim_buf_get_lines(explorer, 0, -1, false)
  for _, line in ipairs(lines) do if line:find("proved", 1, true) then return true end end
  return false
end, 10), "Proof Explorer should reflect compiler-verified status")

print("Bend2 Neovim dogfood passed with Bend " .. tostring(info.version))
