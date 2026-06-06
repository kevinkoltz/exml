<cfscript>
component {
	// Mirrors signal/cfc/value.cfc::is_blank (the dependency of common.capitalize).
	static boolean function is_blank(value) localmode=true {
		if (not structKeyExists(arguments, "value") or isNull(arguments.value)) {
			return true;
		}
		if (not isSimpleValue(arguments.value)) {
			return false;
		}
		return (arguments.value & "").trim().len() == 0;
	}

	static boolean function is_present(value) localmode=true {
		if (not structKeyExists(arguments, "value")) {
			return false;
		}
		return not cfc.value::is_blank(arguments.value);
	}
}
</cfscript>
