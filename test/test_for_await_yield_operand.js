var pass = 0;
var fail = 0;

function assert(cond, msg) {
    if (cond) {
        pass++;
    } else {
        fail++;
        print("FAIL:", msg);
    }
}

async function* arrayDefault() {
    for await ([value = yield "array"] of [[]]) {
        assert(value === 11, "array default resume value");
    }
}

async function* objectDefault() {
    for await ({value = yield "object"} of [{}]) {
        assert(value === 22, "object default resume value");
    }
}

var arrayIterator = arrayDefault();
var objectIterator = objectDefault();
assert(arrayIterator.next() instanceof Promise, "array generator starts");
assert(arrayIterator.next(11) instanceof Promise, "array generator resumes");
assert(objectIterator.next() instanceof Promise, "object generator starts");
assert(objectIterator.next(22) instanceof Promise, "object generator resumes");
print("=== Results:", pass, "pass,", fail, "fail ===");
