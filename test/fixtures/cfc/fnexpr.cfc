component {

  // Methods defined as top-level function expressions (`name = function(){}`),
  // including the `localmode=` attribute after the parameter list.
  double = function(n) localmode="modern" {
    return arguments.n * 2;
  }

  triple = function(required numeric n) {
    return arguments.n * 3;
  }

  // A normal method that calls a function-expression sibling.
  function sextuple(x) {
    return double(arguments.x) + triple(arguments.x);
  }
}
