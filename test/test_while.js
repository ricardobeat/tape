while(function __func(){return 0;}){
   var __reached = 1;
   break;
}
if (typeof __reached !== "undefined" && __reached !== 1) {
	throw new Error("#2: function expression inside of while expression is allowed");
}
print("ok");
