<cfcomponent>

<!--- A recoverable parse error mid-body: the function still loads; the bad
      statement raises only if reached, and the statements around it work. --->
<cffunction name="recovers">
	<cfscript>
		local.a = 1;
		@ this is not valid cfscript @;
		local.b = 2;
		return local.a + local.b;
	</cfscript>
</cffunction>

<!--- Unknown attribute on a supported tag (typo / unimplemented option). --->
<cffunction name="bad_attr">
	<cfquery name="q" frobnicate="yes">SELECT 1</cfquery>
	<cfreturn q>
</cffunction>

<!--- Unsupported tag: the function loads and names the tag if called. --->
<cffunction name="unsupported_tag">
	<cffile action="read" file="/tmp/x" variable="out">
	<cfreturn out>
</cffunction>

</cfcomponent>
