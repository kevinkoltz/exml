component {

  // Memoize a component instance on the `cfc` scope (the CFML caching idiom),
  // then use it via member access — distinct from the `cfc.X` *path* used by
  // `new` / `::`.
  cfc.helper = createObject("component", "cfc.pkg.thing");

  function helper_label() {
    return cfc.helper.read_label();
  }

  // The path namespace still works for new/::, even though `cfc` is also a cache.
  function via_new() {
    return new cfc.pkg.thing().read_label();
  }
}
