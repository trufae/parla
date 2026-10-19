private void test_environment_wins () {
    Environment.set_variable ("DC_ACCOUNTS_PATH", "/tmp/dc/accounts/", true);
    assert_true (SafeStore.AccountsPath.resolve () == "/tmp/dc/accounts");
    assert_true (SafeStore.AccountsPath.mount_path () == "/tmp/dc/accounts");
    assert_true (
        SafeStore.AccountsPath.vault_path () == "/tmp/dc/accounts.vault");
    assert_true (SafeStore.AccountsPath.source () == "DC_ACCOUNTS_PATH");
    Environment.unset_variable ("DC_ACCOUNTS_PATH");
}

private void test_empty_environment_ignored () {
    Environment.set_variable ("DC_ACCOUNTS_PATH", "   ", true);
    assert_true (SafeStore.AccountsPath.source () != "DC_ACCOUNTS_PATH");
    Environment.unset_variable ("DC_ACCOUNTS_PATH");
}

private void test_vault_beside_mount () {
    Environment.unset_variable ("DC_ACCOUNTS_PATH");
    string accounts = SafeStore.AccountsPath.resolve ();
    assert_true (accounts.length > 0);
    assert_true (Path.is_absolute (accounts));
    assert_true (SafeStore.AccountsPath.mount_path () == accounts);
    assert_true (SafeStore.AccountsPath.zip_path () == accounts + ".zip");
    assert_true (
        SafeStore.AccountsPath.vault_path () == accounts + ".vault");
}

private void test_layout_policy_accepts_derived_paths () {
    Environment.set_variable ("DC_ACCOUNTS_PATH",
        Path.build_filename (Environment.get_tmp_dir (), "safestore-accounts"), true);
    try {
        SafeStore.PathPolicy.validate_layout (
            SafeStore.AccountsPath.vault_path (),
            SafeStore.AccountsPath.mount_path (), false
        );
    } catch (Error error) {
        Test.fail_printf (
            "Derived layout should be valid: %s", error.message);
    }
    Environment.unset_variable ("DC_ACCOUNTS_PATH");
}

void register_accounts_path_tests () {
    Test.add_func ("/accounts-path/environment-wins", test_environment_wins);
    Test.add_func ("/accounts-path/empty-environment-ignored",
                   test_empty_environment_ignored);
    Test.add_func ("/accounts-path/vault-beside-mount",
                   test_vault_beside_mount);
    Test.add_func ("/accounts-path/layout-policy",
                   test_layout_policy_accepts_derived_paths);
}
