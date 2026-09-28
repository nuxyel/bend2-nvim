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
for _, name in ipairs({ "Bend2Check", "Bend2CheckWorkspace", "Bend2Build", "Bend2Run", "Bend2Proofs", "Bend2ProofGoal", "Bend2ProbeBackend", "Bend2CompareBackends", "Bend2CompareProjectBackends", "Bend2Benchmark", "Bend2Environment", "Bend2Support", "Bend2TypeDefinition", "Bend2CallHierarchy" }) do
  eq(2, vim.fn.exists(":" .. name), "public command " .. name .. " must be registered")
end
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
local text_fixture = table.concat(vim.fn.readfile("tests/fixtures/compiler-diagnostics.text"), "\n")
eq(2, #toolchain.parse_diagnostics(text_fixture, "fallback.bend"), "text diagnostics fixture should parse")
local json_fixture = table.concat(vim.fn.readfile("tests/fixtures/compiler-diagnostics.jsonl"), "\n")
eq(2, #toolchain.parse_diagnostics(json_fixture, "fallback.bend"), "JSON-lines diagnostics fixture should parse")
local envelope_fixture = table.concat(vim.fn.readfile("tests/fixtures/compiler-diagnostics.envelope.json"), "\n")
eq(8, toolchain.parse_diagnostics(envelope_fixture, "fallback.bend")[1].end_col)
local bend_error = table.concat(vim.fn.readfile("tests/fixtures/compiler-diagnostics.bend-error"), "\n")
eq("no such file: missing.bend", toolchain.parse_diagnostics(bend_error, "fallback.bend")[2].message)
local safety_path = "tests/fixtures/compiler-safety-report.bend"
local safety_report = table.concat(vim.fn.readfile("tests/fixtures/compiler-safety-report.txt"), "\n")
local safety_diagnostics = toolchain.parse_diagnostics(safety_report, safety_path)
eq("unsafe", safety_diagnostics[1].category)
eq(3, safety_diagnostics[1].line)
vim.fn.delete(fake_bend)

local invalid_root = vim.fn.tempname()
vim.fn.mkdir(invalid_root .. "/.bend2", "p")
vim.fn.writefile({ '{"files":["../escape.bend"]}' }, invalid_root .. "/.bend2/differential.json")
local invalid_manifest
toolchain.compare_project(invalid_root, function(result) invalid_manifest = result end)
assert(invalid_manifest and not invalid_manifest.comparable and invalid_manifest.error:match("inside the workspace"), "differential manifest must reject workspace traversal")
vim.fn.delete(invalid_root, "rf")

local gate_root = vim.fn.tempname()
vim.fn.mkdir(gate_root .. "/scripts", "p")
vim.fn.writefile({ "echo gate-ok" }, gate_root .. "/scripts/check.sh")
local gate_result
toolchain.gate(gate_root, "check", function(result) gate_result = result end)
assert(vim.wait(3000, function() return gate_result ~= nil end, 10), "gate process callback timed out")
eq("gate-ok\n", gate_result.stdout, "gate runner should invoke bash directly")
vim.fn.delete(gate_root, "rf")

require("bend2").setup({ cmd = { "/bin/sleep" } })
toolchain.cache = {}
local cancelled
toolchain.command({ "5" }, vim.fn.getcwd(), function(result) cancelled = result end, 10000)
vim.defer_fn(toolchain.cancel_all, 50)
assert(vim.wait(3000, function() return cancelled ~= nil end, 10), "cancelled process callback timed out")
assert(cancelled.cancelled, "active process should report cancellation")

local proof = require("bend2.proof")
local proof_source = "def Laws.add_zero =\n  ?TODO\ndef Laws.next = 0"
eq("open", proof.status(proof_source, "add_zero"))
eq("?TODO", proof.goal(proof_source, "add_zero").token)
eq("unsafe", proof.status("def Laws.safe =\n  @unsafe proof", "safe"))
eq({ "normalize", "same" }, proof.dependencies("def Laws.add_zero = normalize(x) && same(x)", "add_zero"))
eq(nil, proof.goal("def Laws.safe =\n  # ?TODO is only a comment\n  done", "safe"), "commented goals should not be treated as open proof goals")
eq({}, proof.dependencies("def Laws.safe =\n  # normalize(x) is only a comment\n  done", "safe"), "commented calls should not become proof dependencies")
assert(proof.status("def Laws.safe =\n  # @unsafe is only a comment\n  done", "safe") ~= "unsafe", "commented annotations should not affect proof status")
local reviewed = proof.allowlist("# approved entries\nnormalize\n")
assert(reviewed.normalize and not reviewed.other)

local formatter = require("bend2.formatter")
eq("def add x y = x + y\n", formatter.format("def add x y=x+y\n"), "formatter should normalize operator spacing")
eq("# comment\n", formatter.format("# comment\n"), "formatter should preserve comment-only lines")
eq("def negate x = -x\n", formatter.format("def negate x=-x\n"), "formatter should preserve unary operators")
eq("@unsafe\n", formatter.format("@unsafe\n"), "formatter should not split annotations")
local once = formatter.format("def add x y=x+y\n")
eq(once, formatter.format(once), "formatter should be idempotent")

print("Bend2 Neovim unit checks passed")
