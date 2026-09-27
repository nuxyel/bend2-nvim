vim.opt.rtp:prepend(".")

local function eq(expected, actual, message)
  assert(vim.deep_equal(expected, actual), (message or "values differ") .. "\nexpected: " .. vim.inspect(expected) .. "\nactual: " .. vim.inspect(actual))
end

local parser = require("bend2.parser")
local parsed = parser.parse([[
import ./math as Math
type Maybe {
  Some { value: Nat }
  None
}
def add x y = x+y # comment
law open = ?TODO
]], "/tmp/main.bend")
eq(5, #parsed.symbols, "declarations and import should be indexed")
eq("Maybe.Some", parsed.symbols[3].name)
assert(#parsed.diagnostics >= 1, "open proof should be diagnosed")
eq("add", parser.identifier_at("def add x = x", 0, 5))
assert(parser.code_only("def add x = x # comment"):match("^def add x = x%s+$"))

local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/.git", "p")
vim.fn.writefile({ "def add x y = x + y" }, root .. "/math.bend")
vim.fn.writefile({ "import ./math as Math", "def main = Math.add(1, 2)" }, root .. "/main.bend")
local workspace = require("bend2.workspace")
local target = workspace.definition(root .. "/main.bend", 1, 18, root)
eq(root .. "/math.bend", target and target.path, "qualified import definition should resolve")
eq("add", target and target.symbol.name)
vim.fn.delete(root, "rf")

local formatter = require("bend2.formatter")
eq("def add x y = x + y\n", formatter.format("def add x y=x+y\n"), "formatter should normalize operator spacing")
eq("# comment\n", formatter.format("# comment\n"), "formatter should preserve comment-only lines")

print("Bend2 Neovim unit checks passed")
