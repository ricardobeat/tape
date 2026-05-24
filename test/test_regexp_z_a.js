try {
  var regExp = new RegExp("[z-a]");
  print("UNEXPECTED: no error thrown");
} catch (e) {
  print("Caught:", e.name ? e.name : typeof e);
}
