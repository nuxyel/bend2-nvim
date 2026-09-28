vim.opt.rtp:prepend(".")

local function eq(expected, actual, message)
  assert(vim.deep_equal(expected, actual), (message or "values differ") .. "\nexpected: " .. vim.inspect(expected) .. "\nactual: " .. vim.inspect(actual))
end

local package_manifest = vim.json.decode(table.concat(vim.fn.readfile("pkg.json"), "\n"))
eq("bend2-nvim", package_manifest.name, "vim.pack manifest should identify the plugin")
eq(">=0.11.0", package_manifest.engines.nvim, "vim.pack manifest should match the supported Neovim baseline")

local parser = require("bend2.parser")
local plugin_version = require("bend2.version")
assert(plugin_version:match("^%d+%.%d+%.%d+%-dev$") or plugin_version:match("^%d+%.%d+%.%d+$"), "plugin version must be a development identifier or semantic release version")
if not plugin_version:match("%-dev$") then
  local changelog = table.concat(vim.fn.readfile("CHANGELOG.md"), "\n")
  assert(changelog:match("## " .. vim.pesc(plugin_version)), "stable plugin version must have a matching changelog heading")
end
local compiler_pins = vim.json.decode(table.concat(vim.fn.readfile("tests/dogfood/compiler-versions.json"), "\n"))
local ci_workflow = table.concat(vim.fn.readfile(".github/workflows/ci.yml"), "\n")
for _, pin in ipairs({ compiler_pins.minimum, compiler_pins.latest }) do
  assert(#pin.linuxX64Sha256 == 64 and #pin.darwinArm64Sha256 == 64, "compiler archive checksums must be SHA-256 values")
  assert(ci_workflow:find(pin.version, 1, true) and ci_workflow:find(pin.linuxX64Sha256, 1, true) and ci_workflow:find(pin.darwinArm64Sha256, 1, true), "CI compiler matrix must match the checked-in compatibility pins")
end
local dogfood_matrix = ci_workflow:match("  dogfood:(.*)") or ""
local dogfood_entries = 0
for _ in dogfood_matrix:gmatch("%- os:") do dogfood_entries = dogfood_entries + 1 end
assert(dogfood_entries == 8 and dogfood_matrix:find('nvim: "0.11.7"', 1, true) and dogfood_matrix:find('nvim: "0.12.5"', 1, true) and dogfood_matrix:find("ubuntu-24.04", 1, true) and dogfood_matrix:find("macos-14", 1, true), "compiler dogfood must cover both supported Neovim versions on pinned Linux and macOS runners")
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
local base_names = require("bend2.base_completion").parse([[
# Types
type BendBaseChoice is Data:
  BendBaseFirst{}
  BendBaseSecond{value: Nat}

def BendBaseFunction(x) = x
law BendBaseLaw = True
  ignored_internal_name = 1
]])
eq({ "BendBaseChoice", "BendBaseFirst", "BendBaseFunction", "BendBaseLaw", "BendBaseSecond" }, base_names, "Bend Base completion should include declarations and constructors only")
local compiler_syntax = parser.parse("public def Math.add(x) = x\ntype Option is Data:\n  Some{}\n  Some{}\ndef run?() = 0")
eq("Math.add", compiler_syntax.symbols[1].name, "public qualified declarations should parse")
assert(compiler_syntax.diagnostics[1].message:match("Duplicate declaration 'Option.Some'"), "duplicate constructors should be diagnosed")
assert(not compiler_syntax.diagnostics[#compiler_syntax.diagnostics].message:match("Open proof goal"), "the unsafe function suffix is not a proof hole")

local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/.git", "p")
vim.fn.writefile({ "def add x y = x + y" }, root .. "/math.bend")
vim.fn.writefile({ "import ./math as Math", "def main = Math.add(1, 2)" }, root .. "/main.bend")
vim.fn.mkdir(root .. "/.bend", "p")
vim.fn.writefile({ "def stale = 0" }, root .. "/.bend/stale.bend")
local workspace = require("bend2.workspace")
local target = workspace.definition(root .. "/main.bend", 1, 18, root)
eq(root .. "/math.bend", target and target.path, "qualified import definition should resolve")
eq("add", target and target.symbol.name)
eq({ root .. "/main.bend", root .. "/math.bend" }, workspace.files(root), "workspace scan should ignore generated Bend cache files")
local refs = workspace.references(root .. "/main.bend", 1, 18, root)
eq(2, #refs, "reference search should include the declaration and its qualified use")
eq(root .. "/main.bend", refs[1].path)
eq(16, refs[1].col, "qualified rename range should cover the member, not its import alias")
vim.fn.writefile({ "def updated x = x" }, root .. "/math.bend")
vim.fn.writefile({ "import ./math as Math", "def main = Math.updated(1)" }, root .. "/main.bend")
workspace.refresh_path(root .. "/math.bend")
workspace.refresh_path(root .. "/main.bend")
local updated_target = workspace.definition(root .. "/main.bend", 1, 20, root)
eq("updated", updated_target and updated_target.symbol.name, "cached workspace indexes should refresh saved or edited documents")
vim.fn.writefile({ "def another x = x" }, root .. "/library.bend")
workspace.refresh_path(root .. "/library.bend")
local completion_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(completion_buf, root .. "/main.bend")
vim.api.nvim_buf_set_lines(completion_buf, 0, -1, false, { "import ./math as Math", "def main = Math.a" })
vim.api.nvim_set_current_buf(completion_buf)
vim.bo[completion_buf].filetype = "bend"
vim.api.nvim_win_set_cursor(0, { 2, #"def main = Math.a" - 1 })
eq(#"def main = Math.", require("bend2.editor").complete(1), "member completion should start after an imported module alias")
local member_items, has_member = require("bend2.editor").complete(0, "up"), false
for _, item in ipairs(member_items) do if item.word == "updated" then has_member = true end end
assert(has_member, "imported module members should be included in omnifunc completions")
require("bend2").options.auto_import = true
vim.api.nvim_buf_set_lines(completion_buf, 0, -1, false, { "def main = Library.an" })
vim.api.nvim_win_set_cursor(0, { 1, #"def main = Library.an" })
local import_items, auto_import_item = require("bend2.editor").complete(0, "Library.an"), nil
for _, item in ipairs(import_items) do if item.word == "Library.another" then auto_import_item = item end end
assert(auto_import_item and auto_import_item.user_data, "auto-import completion should create a safe import edit")
require("bend2").options.auto_import = false
vim.api.nvim_buf_delete(completion_buf, { force = true })
vim.fn.delete(root, "rf")

local worktree_parent = vim.fn.tempname()
local worktree_root = worktree_parent .. "/repo"
vim.fn.mkdir(worktree_root .. "/nested", "p")
vim.fn.writefile({ "gitdir: ../.git/worktrees/repo" }, worktree_root .. "/.git")
vim.fn.writefile({ "def main = 0" }, worktree_root .. "/nested/main.bend")
local worktree_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(worktree_buf, worktree_root .. "/nested/main.bend")
eq(vim.uv.fs_realpath(worktree_root), workspace.root(worktree_buf, { root_markers = { ".git" } }), "workspace root detection should accept .git files used by linked worktrees")
vim.api.nvim_buf_delete(worktree_buf, { force = true })
vim.fn.delete(worktree_parent, "rf")

local homonym_root = vim.fn.tempname()
vim.fn.mkdir(homonym_root .. "/.git", "p")
vim.fn.writefile({ "def helper() = 1" }, homonym_root .. "/lib.bend")
vim.fn.writefile({ "def helper() = 2" }, homonym_root .. "/other.bend")
vim.fn.writefile({ "import ./lib as Lib", "import ./other as Other", "def helper() = 3", "def main = Lib.helper() + Other.helper() + helper()", "# Lib.helper()" }, homonym_root .. "/main.bend")
local lib_target = workspace.definition(homonym_root .. "/main.bend", 3, 14, homonym_root)
eq(homonym_root .. "/lib.bend", lib_target and lib_target.path, "imported homonyms should resolve through their selected alias")
local lib_refs = workspace.references(homonym_root .. "/main.bend", 3, 14, homonym_root)
eq(2, #lib_refs, "references must exclude local and imported homonyms and comments")
eq(homonym_root .. "/lib.bend", lib_refs[1].path)
eq(homonym_root .. "/main.bend", lib_refs[2].path)
vim.fn.delete(homonym_root, "rf")

local fake_bend = vim.fn.tempname()
vim.fn.writefile({
  "#!/bin/sh",
  "case \"$1\" in",
  "  --version|version) echo 'Bend 2.0.32'; exit 0;;",
  "  guide) echo 'JavaScript target native executable --gpu'; exit 0;;",
  "  base) printf '%s\\n' 'type BendBaseChoice is Data:' '  BendBaseVariant{}' 'def BendBaseFunction(x) = x' 'law BendBaseLaw = True'; exit 0;;",
  "esac",
  "if [ \"$1\" = 'racing.bend' ]; then sleep 0.15; fi",
  "if [ \"$3\" = '--diagnostics=json' ]; then",
  "  printf '%s\\n' '{\"protocolVersion\":1,\"diagnostics\":[{\"file\":\"fake.bend\",\"range\":{\"start\":{\"line\":2,\"column\":3}},\"severity\":\"error\",\"message\":\"fixture error\"}]}'",
  "  exit 1",
  "fi",
  "exit 0",
}, fake_bend)
vim.fn.setfperm(fake_bend, "rwxr-xr-x")
require("bend2").setup({ cmd = fake_bend })
local base_completion = require("bend2.base_completion")
local completion_root = vim.fn.getcwd()
eq(nil, base_completion.get(completion_root), "Bend Base symbols should not block the first completion request")
base_completion.request(completion_root)
assert(vim.wait(3000, function() return base_completion.get(completion_root) ~= nil end, 10), "Bend Base completion request timed out")
local base_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(base_buf, completion_root .. "/base-completion-test.bend")
vim.api.nvim_buf_set_lines(base_buf, 0, -1, false, { "def main = BendBase" })
vim.bo[base_buf].filetype = "bend"
vim.api.nvim_set_current_buf(base_buf)
local base_items, base_item = require("bend2.editor").complete(0, "BendBase"), nil
for _, item in ipairs(base_items) do if item.word == "BendBaseVariant" then base_item = item end end
assert(base_item and base_item.menu == "Bend Base", "compiler-derived Bend Base symbols should appear in completion results")
vim.api.nvim_buf_delete(base_buf, { force = true })
for _, name in ipairs({ "Bend2Check", "Bend2CheckWorkspace", "Bend2Build", "Bend2Run", "Bend2RunProjectGate", "Bend2RunSabotage", "Bend2Proofs", "Bend2RefreshProofExplorer", "Bend2ProofGoal", "Bend2ProbeBackend", "Bend2CompareBackends", "Bend2CompareProjectBackends", "Bend2Benchmark", "Bend2Environment", "Bend2Support", "Bend2TypeDefinition", "Bend2CallHierarchy", "Bend2Cancel" }) do
  eq(2, vim.fn.exists(":" .. name), "public command " .. name .. " must be registered")
end
local toolchain, compiler_info = require("bend2.toolchain"), nil
toolchain.discover(vim.fn.getcwd(), function(info) compiler_info = info end, true)
assert(vim.wait(3000, function() return compiler_info ~= nil end), "compiler discovery callback timed out")
eq("supported", compiler_info.compatibility)
eq("supported", toolchain.backend_capability(compiler_info, "javascript"))
eq("supported", toolchain.backend_capability(compiler_info, "native"))
eq("supported", toolchain.backend_capability(compiler_info, "gpu"))
local unavailable_root, unavailable_info = vim.fn.tempname(), nil
require("bend2").setup({ cmd = unavailable_root .. "/missing-bend", validation = "parser" })
toolchain.discover(unavailable_root, function(info) unavailable_info = info end, true)
assert(vim.wait(3000, function() return unavailable_info ~= nil end), "missing compiler discovery callback timed out")
assert(not unavailable_info.available and unavailable_info.compatibility == "unknown", "editor setup and feature discovery should remain usable without Bend installed")
vim.fn.delete(unavailable_root, "rf")
require("bend2").setup({ cmd = fake_bend, validation = "on_save" })
local check_result
toolchain.check("fake.bend", vim.fn.getcwd(), function(result) check_result = result end)
assert(vim.wait(3000, function() return check_result ~= nil end), "compiler check callback timed out")
eq("fixture error", check_result.diagnostics[1].message)
eq(1, check_result.diagnostics[1].line)
local unsupported_root = vim.fn.tempname()
toolchain.cache[unsupported_root] = { available = true, version = "2.0.32", compatibility = "supported", capabilities = { native = "unsupported" } }
local unsupported_probe
toolchain.probe("unused.bend", unsupported_root, "native", function(result) unsupported_probe = result end)
eq("unsupported", unsupported_probe.status, "backend probes should honor explicit compiler capability metadata")
toolchain.cache[unsupported_root] = nil
local validation_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(validation_buf, 0, -1, false, { "def open = ?TODO" })
vim.api.nvim_buf_set_name(validation_buf, vim.fn.getcwd() .. "/validation.bend")
vim.bo[validation_buf].filetype = "bend"
assert(#vim.diagnostic.get(validation_buf) > 0, "parser diagnostics should initialize on Bend filetype")
require("bend2").setup({ cmd = fake_bend, validation = "off" })
eq(0, #vim.diagnostic.get(validation_buf), "validation=off should clear diagnostics from already-loaded buffers")
vim.api.nvim_buf_delete(validation_buf, { force = true })
require("bend2").setup({ cmd = fake_bend, validation = "on_save" })
local old_check, new_check
toolchain.check("racing.bend", vim.fn.getcwd(), function(result) old_check = result end)
vim.defer_fn(function() toolchain.check("racing.bend", vim.fn.getcwd(), function(result) new_check = result end) end, 30)
assert(vim.wait(3000, function() return old_check ~= nil and new_check ~= nil end, 10), "replacement check callbacks timed out")
assert(old_check.cancelled, "superseded compiler checks should report cancellation")
assert(not new_check.cancelled and new_check.code == 1, "cancelling an old check must not lose the new in-flight process")
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
vim.fn.writefile({ "printf 'target:%s\\n' \"$1\"" }, gate_root .. "/scripts/check.sh")
local target_gate
toolchain.gate(gate_root, "check", function(result) target_gate = result end, "subproject")
assert(vim.wait(3000, function() return target_gate ~= nil end, 10), "target gate process callback timed out")
eq("target:subproject\n", target_gate.stdout, "gate runner should pass a safe workspace-relative target")
local unsafe_gate
toolchain.gate(gate_root, "check", function(result) unsafe_gate = result end, "../outside")
assert(unsafe_gate and unsafe_gate.code == nil and unsafe_gate.stderr:match("inside the Bend 2 workspace"), "gate runner must reject workspace traversal")
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
eq("def add x y = x +y\n", formatter.format("def add x y=x+y\n"), "formatter should match the upstream formatter's operator rules")
eq("# comment\n", formatter.format("# comment\n"), "formatter should preserve comment-only lines")
eq("def negate x = -x\n", formatter.format("def negate x=-x\n"), "formatter should preserve unary operators")
eq("@unsafe\n", formatter.format("@unsafe\n"), "formatter should not split annotations")
eq("def add(x: Nat) -> Nat:\r\n  # keep this comment\r\n  x + 1n", formatter.format("def  add(x:Nat)->Nat:\r\n    # keep this comment\r\n    x+1n", { tabSize = 2, insertSpaces = true }), "formatter should preserve line endings and official spacing rules")
eq("def tuple = Pair <a, b>\n", formatter.format("def tuple=Pair <a,b>\n"), "formatter should preserve generic angle spacing")
eq('def broken():\n  "unterminated', formatter.format('def broken():\n  "unterminated'), "formatter must leave incomplete literals untouched")
local once = formatter.format("def add x y=x+y\n")
eq(once, formatter.format(once), "formatter should be idempotent")

local signature = require("bend2.signature")
local nested_call = signature.call_context("def main():\n  calculate(first(1, 2), \n    nested(value, more))\n", 2, 18)
eq({ name = "nested", line = 2, character = 4, active_parameter = 1 }, nested_call, "signature help should follow nested calls across lines")
eq(nil, signature.call_context('def main():\n  "fake(1, 2)"\n', 1, 13), "signature help should ignore calls inside literals")
eq(nil, signature.call_context("def main():\n  # fake(1, 2)\n", 1, 15), "signature help should ignore calls inside comments")
local parsed_signature = signature.parse("combine", "def combine(left: Nat, pair: Pair(Nat, Nat)):")
eq("combine(left: Nat, pair: Pair(Nat, Nat))", parsed_signature.label)
eq({ "left: Nat", "pair: Pair(Nat, Nat)" }, parsed_signature.parameters)

print("Bend2 Neovim unit checks passed")
