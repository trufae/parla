int main (string[] args) {
    if (args.length > 2 && args[1].has_prefix ("--")) return lifecycle_child (args);
    Test.init (ref args);
    register_path_policy_tests ();
    register_accounts_path_tests ();
    register_backend_tests ();
    register_lifecycle_tests (args[0]);
    return Test.run ();
}
