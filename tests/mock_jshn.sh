# Test-only subset of jshn. Values are assigned by command substitution, never evaluated.
json_init() { JSON_TEST_DATA='{}'; JSON_TEST_PATH=; export JSON_TEST_DATA JSON_TEST_PATH; }
json_load() { JSON_TEST_DATA=$1; JSON_TEST_PATH=; export JSON_TEST_DATA JSON_TEST_PATH; json_test valid; }
json_get_var() { eval "$1=\$(json_test get \"\$2\")"; }
json_get_type() { eval "$1=\$(json_test type \"\$2\")"; }
json_get_keys() { eval "$1=\$(json_test keys)"; }
json_add_object() { JSON_TEST_PATH=$1; export JSON_TEST_PATH; }
json_close_object() { JSON_TEST_PATH=; export JSON_TEST_PATH; }
json_add_string() { JSON_TEST_DATA=$(json_test add string "$1" "$2"); export JSON_TEST_DATA; }
json_add_boolean() { JSON_TEST_DATA=$(json_test add boolean "$1" "$2"); export JSON_TEST_DATA; }
json_dump() { printf '%s\n' "$JSON_TEST_DATA"; }
json_test() { "$TSLAN_ROOT/bin/json_test" "$@"; }

json_load_file() { JSON_TEST_DATA=$(cat); JSON_TEST_PATH=; export JSON_TEST_DATA JSON_TEST_PATH; json_test valid; }
json_cleanup() { unset JSON_TEST_DATA JSON_TEST_PATH; }
