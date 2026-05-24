// Arrow function lexical this test
var result = 'fail';

function TestObj() {
    this.name = 'test';
    this.get = function() {
        // Arrow should capture this from get(), which is TestObj instance
        var arrow = () => this.name;
        return arrow();
    };
}

var obj = new TestObj();
var name = obj.get();
if (name === 'test') {
    result = 'PASS';
}
print(result + ': lexical this');
