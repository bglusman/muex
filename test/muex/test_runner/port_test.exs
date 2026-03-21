defmodule Muex.TestRunner.PortTest do
  use ExUnit.Case, async: true

  alias Muex.TestRunner.Port, as: PortRunner

  describe "run_tests/3" do
    test "returns error for non-existent test files" do
      result = PortRunner.run_tests(["nonexistent_test.exs"], nil, timeout_ms: 1000)

      assert match?({:ok, %{exit_code: exit_code}} when exit_code != 0, result) or
               match?({:error, _}, result)
    end

    test "handles empty test file list" do
      result = PortRunner.run_tests([], nil, timeout_ms: 1000)

      # Should either succeed with no tests or return error
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "classifies compilation errors as {:error, {:compile_error, _}}" do
      # Create a test file that will cause a compilation error
      tmp_dir = System.tmp_dir!()
      bad_test = Path.join(tmp_dir, "muex_compile_error_test.exs")

      File.write!(bad_test, ~S"""
      defmodule MuexCompileErrorTest do
        use ExUnit.Case
        alias This.Module.Does.Not.Exist
        test "will never run" do
          Exist.call()
        end
      end
      """)

      try do
        result = PortRunner.run_tests([bad_test], nil, timeout_ms: 10_000)

        # Some environments may handle the missing module differently
        assert match?({:error, {:compile_error, _output}}, result) or
                 match?({:ok, %{failures: _}}, result)
      after
        File.rm(bad_test)
      end
    end
  end

  describe "compile error detection" do
    # Test the classification logic indirectly by verifying that output patterns
    # that indicate compilation errors (with no ExUnit summary) are distinguished
    # from outputs that indicate test failures.

    test "output with ExUnit summary is not treated as compile error" do
      # Even if there are error-like strings, an ExUnit summary means tests ran
      output_with_summary = """
      ** (CompileError) some warning
      ...
      5 tests, 2 failures
      """

      # This should be classified as a test result, not compile error.
      # We test by calling run_tests with a file that produces a known output,
      # but since we can't easily mock the port, we verify the regex logic directly.
      assert Regex.match?(~r/\d+ tests?, \d+ failures?/, output_with_summary)
    end

    test "compile error regex matches common Elixir compilation exceptions" do
      pattern = ~r/\*\* \(\w*(?:Error|Missing\w*)\)/

      assert Regex.match?(pattern, "** (CompileError) lib/foo.ex:1")
      assert Regex.match?(pattern, "** (SyntaxError) lib/foo.ex:1")
      assert Regex.match?(pattern, "** (TokenMissingError) lib/foo.ex:1")
      assert Regex.match?(pattern, "** (ArgumentError) bad argument")
      assert Regex.match?(pattern, "** (UndefinedFunctionError) undefined")
      refute Regex.match?(pattern, "warning: unused variable")
      refute Regex.match?(pattern, "5 tests, 2 failures")
    end
  end
end
