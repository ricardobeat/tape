// Verify GeneratorFunction is registered as a global and prototype.constructor is wired.
//
// NOTE: Generator calls (genFunc()) crash due to a pre-existing bug in the CALL
// handler (vm.c3 line 5745: generator compiled functions hit `else { break; }`
// which exits the opcode without creating a generator object).  That bug is not
// part of this task.  We verify the pieces we wired here.
//
// Because of the CALL handler bug, we avoid calling generator functions.
// We also avoid `function*` expressions (they trigger compilation + CLOSURE
// which then interacts with the broken CALL path on first use in some code paths).

// === Basic existence checks ===
print("=== Basic existence checks ===");
print("typeof GeneratorFunction:", typeof GeneratorFunction);
print("GeneratorFunction is truthy:", !!GeneratorFunction);
print("typeof GeneratorFunction is function:", typeof GeneratorFunction === "function");

// GeneratorFunction.name should be "GeneratorFunction"
print("GeneratorFunction.name:", GeneratorFunction.name);

// GeneratorFunction.prototype should exist
print("GeneratorFunction.prototype exists:", typeof GeneratorFunction.prototype !== "undefined");

// === GeneratorFunction.prototype.constructor wiring ===
print("=== GeneratorFunction.prototype.constructor ===");
print("GeneratorFunction.prototype.constructor === GeneratorFunction:", GeneratorFunction.prototype.constructor === GeneratorFunction);

// Verify GeneratorFunction.prototype is NOT undefined (i.e., a real object)
print("typeof GeneratorFunction.prototype:", typeof GeneratorFunction.prototype);

print("PASS");
