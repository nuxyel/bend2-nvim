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

local run_file = fixture .. "/run.bend"
local function await_result(label, start)
  local result
  start(function(value) result = value end)
  assert(vim.wait(120000, function() return result ~= nil end, 10), label .. " timed out")
  return result
end
local javascript = await_result("JavaScript backend run", function(done)
  toolchain.run_profile(run_file, root, "javascript", done)
end)
assert(javascript.code == 0 and javascript.stdout:find("Bend2 Neovim dogfood", 1, true), "JavaScript backend should run the dogfood program")
local native = await_result("native backend run", function(done)
  toolchain.run_profile(run_file, root, "native", done)
end)
assert(native.code == 0 and native.stdout == javascript.stdout, "native and JavaScript output should match")
local comparison = await_result("backend comparison", function(done)
  toolchain.compare(run_file, root, { "javascript", "native" }, done)
end)
assert(comparison.comparable and comparison.outputsMatch, "backend comparison should report matching runnable output")
local probe = await_result("native backend probe", function(done)
  toolchain.probe(run_file, root, "native", done)
end)
assert(probe.status == "ready", "native backend probe should compile without executing the program")
local benchmark = await_result("native benchmark", function(done)
  toolchain.benchmark(run_file, root, 1, done, { threads = 1, gpu = "off", warmup = true })
end)
assert(benchmark.ok and benchmark.outputs_match and #benchmark.samples_ms == 1, "native benchmark should discard warm-up and keep stable output")

vim.cmd.edit(vim.fn.fnameescape(fixture .. "/main.bend"))
local proof = require("bend2.proof")
assert(#require("bend2.workspace").proof_files(root) == 1, "workspace checks should discover proof suites, not every source module")
proof.open_explorer()
local explorer = vim.fn.bufnr("Bend2Proofs")
assert(explorer > 0, "Proof Explorer should open")
assert(vim.wait(120000, function()
  local lines = vim.api.nvim_buf_get_lines(explorer, 0, -1, false)
  for _, line in ipairs(lines) do if line:find("proved", 1, true) then return true end end
  return false
end, 10), "Proof Explorer should reflect compiler-verified status")
proof.refresh_explorer()
assert(vim.fn.bufnr("Bend2Proofs") == explorer, "refresh should reuse the existing Proof Explorer buffer")
assert(#vim.fn.win_findbuf(explorer) == 1, "refresh should not create duplicate explorer windows")

print("Bend2 Neovim dogfood passed with Bend " .. tostring(info.version))
