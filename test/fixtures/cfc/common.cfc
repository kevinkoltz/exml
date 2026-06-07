<cfcomponent displayname="Common CFC" output="false">

<!--- A hybrid tag/script CFC shell (cfcomponent + cfscript + cffunction). --->

<cfscript>

function capitalize(str) localmode=true {
	if (cfc.value::is_blank(str)) return "";
	if (len(str) == 1) return ucase(str);
	return ucase(left(str, 1)) & right(str, len(str)-1);
}

// An intentionally-unsupported sibling (for-in loop) to prove the loader skips
// functions it can't parse instead of failing the whole component.
function multi_field_sort(required data, required array sort_fields) localmode=true {
	for (var spec in sort_fields) {
		var val_a = data[spec.field];
	}
	return data;
}

</cfscript>

<cffunction name="legacy_tag_fn" returntype="any">
	<cfreturn "ignored" />
</cffunction>

</cfcomponent>
