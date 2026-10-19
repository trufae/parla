private void test_sibling_layout () {
    try {
        SafeStore.PathPolicy.validate_layout (
            Path.build_filename (Environment.get_tmp_dir (), "safestore-vault"),
            Path.build_filename (Environment.get_tmp_dir (), "safestore-mount"), false
        );
    } catch (Error error) {
        Test.fail_printf ("Sibling layout should be valid: %s", error.message);
    }
}

private void test_same_layout () {
    assert_layout_fails ("/tmp/safestore", "/tmp/safestore");
}

private void test_mount_inside_vault () {
    assert_layout_fails (
        "/tmp/safestore",
        "/tmp/safestore/plain"
    );
}

private void test_vault_inside_mount () {
    assert_layout_fails (
        "/tmp/safestore/plain/vault",
        "/tmp/safestore/plain"
    );
}

private void test_relative_layout () {
    assert_layout_fails ("vault", "mount");
}

#if !WINDOWS
private void test_private_directory_permissions () {
    string? root = null;
    try {
        root = DirUtils.make_tmp ("safestore-private-policy-XXXXXX");
        string directory = Path.build_filename (root, "private");
        assert_true (DirUtils.create (directory, 0755) == 0);

        SafeStore.PathPolicy.ensure_private_directory (directory);

        Posix.Stat info;
        assert_true (Posix.lstat (directory, out info) == 0);
        assert_true (Posix.S_ISDIR (info.st_mode));
        assert_true (info.st_uid == Posix.geteuid ());
        assert_true ((info.st_mode & 0777) == 0700);
        assert_true (DirUtils.remove (directory) == 0);
        assert_true (DirUtils.remove (root) == 0);
    } catch (Error error) {
        Test.fail_printf ("Could not verify private directory: %s", error.message);
    }
}

private void test_private_directory_rejects_symlink () {
    string? root = null;
    try {
        root = DirUtils.make_tmp ("safestore-private-symlink-XXXXXX");
        string directory = Path.build_filename (root, "private");
        string alias = Path.build_filename (root, "alias");
        assert_true (DirUtils.create (directory, 0700) == 0);
        assert_true (Posix.symlink (directory, alias) == 0);

        bool failed = false;
        try {
            SafeStore.PathPolicy.ensure_private_directory (alias);
        } catch (Error error) {
            failed = true;
        }
        assert_true (failed);
        assert_true (FileUtils.unlink (alias) == 0);
        assert_true (DirUtils.remove (directory) == 0);
        assert_true (DirUtils.remove (root) == 0);
    } catch (Error error) {
        Test.fail_printf ("Could not prepare private symlink test: %s", error.message);
    }
}

private void test_symlinked_nested_layout () {
    string? root = null;
    try {
        root = DirUtils.make_tmp ("safestore-path-policy-XXXXXX");
        string vault = Path.build_filename (root, "vault");
        string alias = Path.build_filename (root, "vault-alias");
        assert_true (DirUtils.create (vault, 0700) == 0);
        assert_true (Posix.symlink (vault, alias) == 0);
        assert_layout_fails (
            vault,
            Path.build_filename (alias, "mount")
        );
        assert_true (FileUtils.unlink (alias) == 0);
        assert_true (DirUtils.remove (vault) == 0);
        assert_true (DirUtils.remove (root) == 0);
    } catch (Error error) {
        Test.fail_printf ("Could not prepare symlink test: %s", error.message);
    }
}
#endif

private void assert_layout_fails (string vault, string mount) {
    bool failed = false;
    try {
        SafeStore.PathPolicy.validate_layout (vault, mount);
    } catch (Error error) {
        failed = true;
    }
    assert_true (failed);
}

void register_path_policy_tests () {
    Test.add_func ("/path-policy/siblings", test_sibling_layout);
    Test.add_func ("/path-policy/same", test_same_layout);
    Test.add_func ("/path-policy/mount-inside-vault", test_mount_inside_vault);
    Test.add_func ("/path-policy/vault-inside-mount", test_vault_inside_mount);
    Test.add_func ("/path-policy/relative", test_relative_layout);
#if !WINDOWS
    Test.add_func (
        "/path-policy/private-directory-permissions",
        test_private_directory_permissions
    );
    Test.add_func (
        "/path-policy/private-directory-symlink",
        test_private_directory_rejects_symlink
    );
    Test.add_func (
        "/path-policy/symlinked-nesting",
        test_symlinked_nested_layout
    );
#endif
}
