# White-box tests compile private helpers intentionally; neither application
# nor the public API test can see those implementation types.
unit = executable('unit-tests',
  'unit_tests.vala', 'path_policy_test.vala', 'accounts_path_test.vala',
  'backend_test.vala', 'lifecycle_test.vala', safestore_sources, frontend_sources[0],
  dependencies: safestore_core_deps, include_directories: safestore_inc,
  vala_args: safestore_vala_args + ['--define=SAFESTORE_TESTS'], c_args: safestore_c_args)
test('unit', unit)

public_api = executable('public-api-test', 'public_api_test.vala',
  dependencies: safestore_dep, c_args: safestore_c_args)
test('public-api', public_api)
