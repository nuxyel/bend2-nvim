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

local fake_bend = vim.fn.tempname()
vim.fn.writefile({
  "#!/bin/sh",
  "case \"$1\" in",
  "  --version|version) echo 'Bend 2.0.32'; exit 0;;",
  "  guide) echo 'JavaScript target native executable --gpu'; exit 0;;",
  "esac",
  "if [ \"$3\" = '--diagnostics=json' ]; then",
  "  printf '%s\\n' '{\"protocolVersion\":1,\"diagnostics\":[{\"file\":\"fake.bend\",\"range\":{\"start\":{\"line\":2,\"column\":3}},\"severity\":\"error\",\"message\":\"fixture error\"}]}'",
  "  exit 1",
  "fi",
  "exit 0",
}, fake_bend)
vim.fn.setfperm(fake_bend, "rwxr-xr-x")
require("bend2").setup({ cmd = fake_bend })
local toolchain, compiler_info = require("bend2.toolchain"), nil
toolchain.discover(vim.fn.getcwd(), function(info) compiler_info = info end, true)
assert(vim.wait(3000, function() return compiler_info ~= nil end), "compiler discovery callback timed out")
eq("supported", compiler_info.compatibility)
local check_result
toolchain.check("fake.bend", vim.fn.getcwd(), function(result) check_result = result end)
assert(vim.wait(3000, function() return check_result ~= nil end), "compiler check callback timed out")
eq("fixture error", check_result.diagnostics[1].message)
eq(1, check_result.diagnostics[1].line)
local parsed_diagnostics = toolchain.parse_diagnostics('{"diagnostics":[{"file":"fake.bend","range":{"start":{"line":2,"column":3}},"message":"fixture error","severity":"error"}]}', "fake.bend")
eq(1, parsed_diagnostics[1].line)
eq(2, parsed_diagnostics[1].col)
vim.fn.delete(fake_bend)

local formatter = require("bend2.formatter")
eq("def add x y = x + y\n", formatter.format("def add x y=x+y\n"), "formatter should normalize operator spacing")
eq("# comment\n", formatter.format("# comment\n"), "formatter should preserve comment-only lines")

print("Bend2 Neovim unit checks passed")
