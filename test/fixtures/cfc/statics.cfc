<cfscript>
component {

	static {
		GREETING = "hello";
		LIMIT = 3;
		WORDS = ["a", "b", "c"];
	}

	static function greeting() {
		return static.GREETING;
	}

	static function under_limit(required numeric n) localmode=true {
		return arguments.n < static.LIMIT;
	}

	// Bare call to a sibling static method from a static method.
	static function shout() {
		return ucase(greeting());
	}

	static function word_count() {
		count = 0;
		for (w in static.WORDS) {
			count++;
		}
		return count;
	}

	// Instance method reading a static.
	function combined(required string name) localmode=true {
		return static.GREETING & " " & arguments.name;
	}
}
