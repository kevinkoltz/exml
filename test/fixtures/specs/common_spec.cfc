component extends="test.test_framework" {
    function run() {
        common = new cfc.common();

        describe("common.capitalize", function() {
            it("capitalizes the first letter of a string", function() {
                result = common.capitalize("hello");
                assert_equal(result, "Hello");
            });

            it("returns empty string for blank input", function() {
                assert_equal(common.capitalize(""), "");
            });
        });
    }
}
