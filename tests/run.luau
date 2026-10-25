-- Runs every pickup system spec under Lune: `lune run tests/run`
local process = require("@lune/process")
local TestKit = require("./TestKit")

print("Collection")
require("./specs/Collection.spec")
print("Zones")
require("./specs/Zones.spec")
print("Spawning")
require("./specs/Spawning.spec")
print("Tutorial")
require("./specs/Tutorial.spec")
print("Contracts")
require("./specs/Contracts.spec")

local results = TestKit.results()
print(`\n{results.passed} passed, {results.failed} failed`)
if results.failed > 0 then
	print("\nFailures:")
	for _, failure in results.failures do
		print(`  {failure}`)
	end
	process.exit(1)
end
