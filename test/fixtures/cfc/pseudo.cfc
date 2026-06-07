component {

  // Pseudo-constructor statements written directly in the component body:
  // they run once per instance, into the variables scope, in order.
  base = 10;
  opts = { factor: 3 };
  total = base * opts.factor;
  this.label = "pc";

  function describe_state() {
    return "base=" & variables.base & " total=" & total & " label=" & this.label;
  }
}
