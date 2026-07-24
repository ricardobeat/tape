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

var pending = [];
for (let index = 0; index < 100; index++) {
    let source = [index, index + 1, index + 2];
    pending.push(Array.fromAsync.call(Array, source).then(function (result) {
        assert(result.join(",") === index + "," + (index + 1) + "," + (index + 2),
            "deferred iterator target " + index);
    }));
}

Promise.all(pending).then(function () {
    print("=== Results:", pass, "pass,", fail, "fail ===");
});
