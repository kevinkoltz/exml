<cfcomponent>
<cffunction name="boom">
	<cfset var x = 1>
	<cfthrow message="kaboom" type="MyError">
</cffunction>
</cfcomponent>
