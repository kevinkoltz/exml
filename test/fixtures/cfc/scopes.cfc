<cfscript>
component {

	// No localmode (classic): an unscoped assignment lands in the shared
	// `variables` scope, so it persists on the instance.
	function classic_set() {
		leaked = "classic";
	}

	// localmode modern: an unscoped assignment lands in `local`, so it does NOT
	// leak into `variables`.
	function modern_set() localmode="modern" {
		contained = "modern";
	}

	// An explicit `var` is always local, even in a classic function.
	function var_set() {
		var explicit = "varred";
	}

	function variables_has(required string name) localmode="modern" {
		return structKeyExists(variables, arguments.name);
	}
}
