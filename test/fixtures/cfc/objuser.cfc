<cfcomponent>

<!--- Top-level <cfobject> (pseudo-constructor): instantiates a component. --->
<cfobject component="cfc.pkg.thing" name="helper">

<cffunction name="helper_label" returntype="string">
	<cfreturn helper.read_label()>
</cffunction>

</cfcomponent>
