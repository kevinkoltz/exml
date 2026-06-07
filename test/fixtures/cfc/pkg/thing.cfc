component {
  // init sets public fields via index assignment (this["x"] = ...).
  function init() {
    this["label"] = "thing";
    this["count"] = 0;
    return this;
  }

  // A static method reached via a multi-segment path: cfc.pkg.thing::tag().
  static function tag() {
    return "PKG";
  }

  // Reads a public field via index access (this["x"]).
  function read_label() {
    return this["label"];
  }
}
