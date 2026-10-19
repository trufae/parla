int main (string[] args) {
    Test.init (ref args);
    register_path_policy_tests ();
    register_accounts_path_tests ();
    register_backend_tests ();
    return Test.run ();
}
