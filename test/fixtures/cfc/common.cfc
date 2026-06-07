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

<!--- Tag-bodied function exercising cfargument/cfif/cfset/cfreturn conversion. --->
<cffunction name="describe_sign" returntype="string" output="false">
	<cfargument name="n" required="true" type="numeric">
	<cfset var label = "">
	<cfif arguments.n GT 0>
		<cfset label = "positive">
	<cfelseif arguments.n LT 0>
		<cfset label = "negative">
	<cfelse>
		<cfset label = "zero">
	</cfif>
	<cfreturn label>
</cffunction>

<!--- Tag-bodied function exercising cfswitch/cfcase/cfdefaultcase conversion. --->
<cffunction name="day_name" returntype="string" output="false">
	<cfargument name="dow" required="true" type="numeric">
	<cfset var name = "">
	<cfswitch expression="#arguments.dow#">
		<cfcase value="1"><cfset name = "Mon"></cfcase>
		<cfcase value="2"><cfset name = "Tue"></cfcase>
		<cfdefaultcase><cfset name = "Other"></cfdefaultcase>
	</cfswitch>
	<cfreturn name>
</cffunction>

<!--- Tag-bodied function exercising cfloop (from/to) conversion. --->
<cffunction name="tag_loop_fn" returntype="string">
	<cfset var out = "">
	<cfloop from="1" to="3" index="i">
		<cfset out = out & i>
	</cfloop>
	<cfreturn out>
</cffunction>

<!--- Tag-bodied function exercising cfloop (list) conversion. --->
<cffunction name="tag_list_loop_fn" returntype="string">
	<cfargument name="items" required="true">
	<cfset var out = "">
	<cfloop list="#arguments.items#" item="local.item">
		<cfset out = out & ucase(item)>
	</cfloop>
	<cfreturn out>
</cffunction>

<!--- Unconvertible tag body (cfquery): must be dropped, not emitted broken. --->
<cffunction name="tag_query_fn" returntype="string">
	<cfquery name="q">SELECT 1</cfquery>
	<cfreturn "never">
</cffunction>

</cfcomponent>
