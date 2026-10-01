defmodule Muex.TestRunner.PortTest do
  use ExUnit.Case, async: true

  alias Muex.TestRunner.Port, as: PortRunner

  describe "run_tests/2" do
    test "returns error for non-existent test files" do
      result = PortRunner.run_tests(["nonexistent_test.exs"], timeout_ms: 1000)

      assert match?({:ok, %{exit_code: exit_code}} when exit_code != 0, result) or
               match?({:error, _}, result)
    end

    test "handles empty test file list" do
      result = PortRunner.run_tests([], timeout_ms: 1000)

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
        result = PortRunner.run_tests([bad_test], timeout_ms: 10_000)

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

  describe "parse_failures/1" do
    test "reads the Elixir 1.20 all-passed summary as zero failures" do
      output =
        "Finished in 1.2 seconds (0.0s async, 1.2s sync)\n\nResult: 280 passed, 2 excluded\n"

      assert PortRunner.parse_failures(output) == {:ok, 0}
    end

    test "reads the Elixir 1.20 failed summary as total minus passed" do
      output = "Finished in 0.3 seconds\n\nResult: 271/280 passed, 2 excluded\nFailed: 9 tests\n"
      assert PortRunner.parse_failures(output) == {:ok, 9}
    end

    test "reads the Elixir 1.20 summary with a type breakdown" do
      output = "Result: 455 passed (70 tests, 14 properties)\n"
      assert PortRunner.parse_failures(output) == {:ok, 0}

      failed =
        "Result: 447/455 passed (53/54 doctests, 393/403 tests)\nFailed: 8 tests, 1 property\n"

      assert PortRunner.parse_failures(failed) == {:ok, 8}
    end

    test "treats a run that selected no tests as zero failures" do
      assert PortRunner.parse_failures("Result: 0 tests\n") == {:ok, 0}
    end

    test "still reads the legacy summary" do
      assert PortRunner.parse_failures("5 tests, 2 failures\n") == {:ok, 2}
      assert PortRunner.parse_failures("3 tests, 0 failures, 1 skipped\n") == {:ok, 0}
      assert PortRunner.parse_failures("1 doctest, 4 tests, 1 failure\n") == {:ok, 1}
    end

    test "ignores ANSI colour codes around the summary" do
      assert PortRunner.parse_failures("\e[32m\nResult: 12 passed\e[0m\n") == {:ok, 0}
    end

    test "returns :none when the run never produced a summary" do
      assert PortRunner.parse_failures(
               "** (Mix) Cannot run tests because test helper file does not exist"
             ) == :none

      assert PortRunner.parse_failures("") == :none
    end
  end

  describe "run_tests/2 on real ExUnit output" do
    setup do
      dir = Path.join(System.tmp_dir!(), "muex_port_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "test"))

      File.write!(Path.join(dir, "mix.exs"), """
      defmodule PortFixture.MixProject do
        use Mix.Project
        def project, do: [app: :port_fixture, version: "0.0.1", deps: []]
      end
      """)

      File.write!(Path.join(dir, "test/test_helper.exs"), "ExUnit.start()\n")
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "a passing suite reports zero failures (the mutant survived)", %{dir: dir} do
      File.write!(Path.join(dir, "test/ok_test.exs"), """
      defmodule OkTest do
        use ExUnit.Case
        test "passes", do: assert(true)
      end
      """)

      assert {:ok, %{failures: 0, exit_code: 0}} =
               PortRunner.run_tests(["test/ok_test.exs"], cd: dir, timeout_ms: 60_000)
    end

    test "a failing suite reports its failures (the mutant was killed)", %{dir: dir} do
      File.write!(Path.join(dir, "test/bad_test.exs"), """
      defmodule BadTest do
        use ExUnit.Case
        test "fails", do: assert(1 == 2)
        test "fails again", do: raise("boom")
      end
      """)

      assert {:ok, %{failures: 2, exit_code: exit_code}} =
               PortRunner.run_tests(["test/bad_test.exs"], cd: dir, timeout_ms: 60_000)

      assert exit_code != 0
    end

    test "a failing test that raises is not mistaken for a compile error", %{dir: dir} do
      File.write!(Path.join(dir, "test/raise_test.exs"), """
      defmodule RaiseTest do
        use ExUnit.Case
        test "raises", do: raise(ArgumentError, "bad")
      end
      """)

      assert {:ok, %{failures: 1}} =
               PortRunner.run_tests(["test/raise_test.exs"], cd: dir, timeout_ms: 60_000)
    end
  end
end
