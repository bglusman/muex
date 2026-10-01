defmodule Muex.SandboxTest do
  use ExUnit.Case

  alias Muex.Sandbox

  @project_root File.cwd!()

  describe "create_sandbox/4" do
    test "creates a sandbox directory with expected structure" do
      root = Path.join(System.tmp_dir!(), "muex_test_sandbox_#{System.system_time(:microsecond)}")

      on_exit(fn -> File.rm_rf!(root) end)

      sandbox = Sandbox.create_sandbox(root, @project_root, "test", ["test"])

      assert sandbox.root == root
      assert sandbox.project_root == @project_root

      # mix.exs should be symlinked
      assert File.exists?(Path.join(root, "mix.exs"))
      assert {:ok, _} = File.read_link(Path.join(root, "mix.exs"))

      # deps/ should be symlinked
      assert File.exists?(Path.join(root, "deps"))
      assert {:ok, _} = File.read_link(Path.join(root, "deps"))

      # lib/ should be a real directory (not a symlink) containing symlinks
      lib_dir = Path.join(root, "lib")
      assert File.dir?(lib_dir)
      # lib/ itself should NOT be a symlink
      assert {:error, _} = File.read_link(lib_dir)

      # Source files inside lib/ should be symlinks
      lib_files = Path.wildcard(Path.join([root, "lib", "**", "*.ex"]))
      assert match?([_ | _], lib_files)

      for file <- lib_files do
        assert {:ok, _target} = File.read_link(file),
               "Expected #{file} to be a symlink"
      end

      # test/ should be symlinked
      assert File.exists?(Path.join(root, "test"))

      # _build should exist
      assert File.dir?(Path.join(root, "_build"))
    end
  end

  describe "apply_mutation/4 and restore/2" do
    setup do
      root = Path.join(System.tmp_dir!(), "muex_test_sandbox_#{System.system_time(:microsecond)}")
      sandbox = Sandbox.create_sandbox(root, @project_root, "test", ["test"])
      on_exit(fn -> File.rm_rf!(root) end)
      %{sandbox: sandbox}
    end

    test "replaces a source file symlink with mutated content", %{sandbox: sandbox} do
      target_file = "lib/muex.ex"
      sandbox_path = Path.join(sandbox.root, target_file)

      # Before: should be a symlink
      assert {:ok, _} = File.read_link(sandbox_path)

      # Apply mutation
      {:ok, _precompiled} = Sandbox.apply_mutation(sandbox, target_file, "# mutated content", nil)

      # After: should be a real file with mutated content
      assert {:error, _} = File.read_link(sandbox_path)
      assert File.read!(sandbox_path) == "# mutated content"

      # Original file should be untouched
      original = File.read!(Path.join(@project_root, target_file))
      refute original == "# mutated content"
    end

    test "restore recovers original content", %{sandbox: sandbox} do
      target_file = "lib/muex.ex"
      sandbox_path = Path.join(sandbox.root, target_file)

      {:ok, _precompiled} = Sandbox.apply_mutation(sandbox, target_file, "# mutated", nil)
      assert File.read!(sandbox_path) == "# mutated"

      :ok = Sandbox.restore(sandbox, target_file)

      # Content should match original
      original = File.read!(Path.join(@project_root, target_file))
      assert File.read!(sandbox_path) == original
    end
  end

  describe "create_pool/2" do
    test "creates the requested number of sandboxes" do
      sandboxes = Sandbox.create_pool(3, project_root: @project_root, test_paths: ["test"])
      on_exit(fn -> Sandbox.cleanup(sandboxes) end)

      assert length(sandboxes) == 3

      # Each sandbox should have its own root
      roots = Enum.map(sandboxes, & &1.root)
      assert roots == Enum.uniq(roots)

      # Each should have lib/ with files
      for sandbox <- sandboxes do
        lib_files = Path.wildcard(Path.join([sandbox.root, "lib", "**", "*.ex"]))
        assert match?([_ | _], lib_files)
      end
    end
  end

  describe "cleanup/1" do
    test "removes all sandbox directories" do
      sandboxes = Sandbox.create_pool(2, project_root: @project_root, test_paths: ["test"])
      roots = Enum.map(sandboxes, & &1.root)

      for root <- roots, do: assert(File.dir?(root))

      Sandbox.cleanup(sandboxes)

      for root <- roots, do: refute(File.dir?(root))
    end

    test "handles empty list" do
      assert :ok = Sandbox.cleanup([])
    end
  end

  describe "isolation" do
    test "mutations in one sandbox don't affect another" do
      sandboxes = Sandbox.create_pool(2, project_root: @project_root, test_paths: ["test"])
      on_exit(fn -> Sandbox.cleanup(sandboxes) end)

      [sb1, sb2] = sandboxes
      target_file = "lib/muex.ex"

      # Mutate in sandbox 1
      {:ok, _precompiled} = Sandbox.apply_mutation(sb1, target_file, "# sandbox 1 mutation", nil)

      # Sandbox 2 should still have the original (via symlink)
      sb2_path = Path.join(sb2.root, target_file)
      sb2_content = File.read!(sb2_path)
      original = File.read!(Path.join(@project_root, target_file))
      assert sb2_content == original

      # Sandbox 1 should have mutated content
      sb1_path = Path.join(sb1.root, target_file)
      assert File.read!(sb1_path) == "# sandbox 1 mutation"

      # Restore sandbox 1
      :ok = Sandbox.restore(sb1, target_file)
      assert File.read!(sb1_path) == original
    end
  end

  describe "harness_paths/1" do
    test "names the helper and support directory of each test root once" do
      assert Sandbox.harness_paths(["test/foo_test.exs", "test/sub"]) == [
               "test/test_helper.exs",
               "test/support"
             ]

      assert Sandbox.harness_paths(["apps/a/test/x_test.exs"]) == [
               "apps/a/test/test_helper.exs",
               "apps/a/test/support"
             ]

      assert Sandbox.harness_paths(["spec/x.exs"]) == []
    end
  end

  describe "create_sandbox/4 with a single test file" do
    test "still links the test helper and support files" do
      project = Path.join(System.tmp_dir!(), "muex_proj_#{System.unique_integer([:positive])}")
      root = Path.join(System.tmp_dir!(), "muex_sb_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(project) && File.rm_rf!(root) end)

      File.mkdir_p!(Path.join(project, "lib"))
      File.mkdir_p!(Path.join(project, "test/support"))
      File.write!(Path.join(project, "mix.exs"), "")
      File.write!(Path.join(project, "test/test_helper.exs"), "ExUnit.start()")
      File.write!(Path.join(project, "test/support/case.ex"), "")
      File.write!(Path.join(project, "test/a_test.exs"), "")
      File.write!(Path.join(project, "test/b_test.exs"), "")

      Sandbox.create_sandbox(root, project, "test", ["test/a_test.exs"])

      assert File.exists?(Path.join(root, "test/a_test.exs"))
      assert File.exists?(Path.join(root, "test/test_helper.exs"))
      assert File.exists?(Path.join(root, "test/support/case.ex"))
      refute File.exists?(Path.join(root, "test/b_test.exs"))
    end
  end

  describe "apply_mutation/4 on a single-app project" do
    setup do
      root =
        Path.join(System.tmp_dir!(), "muex_test_sandbox_#{System.unique_integer([:positive])}")

      sandbox = Sandbox.create_sandbox(root, @project_root, "test", ["test"])
      on_exit(fn -> File.rm_rf!(root) end)
      %{sandbox: sandbox}
    end

    test "copies the project's own build, never a dependency's, and leaves the real beam alone",
         %{sandbox: sandbox} do
      app = to_string(Mix.Project.config()[:app])

      real_beam =
        Path.join([@project_root, "_build", "test", "lib", app, "ebin", "Elixir.Muex.beam"])

      before = File.read!(real_beam)

      source = File.read!("lib/muex.ex") <> "\n"
      assert {:ok, _precompiled} = Sandbox.apply_mutation(sandbox, "lib/muex.ex", source, Muex)

      sandbox_app_build = Path.join([sandbox.root, "_build", "test", "lib", app])
      assert {:error, _} = File.read_link(sandbox_app_build)
      assert File.read!(real_beam) == before
    end

    test "never deletes the real beam when the mutant does not compile", %{sandbox: sandbox} do
      app = to_string(Mix.Project.config()[:app])

      real_beam =
        Path.join([@project_root, "_build", "test", "lib", app, "ebin", "Elixir.Muex.beam"])

      before = File.read!(real_beam)

      assert {:ok, false} =
               Sandbox.apply_mutation(
                 sandbox,
                 "lib/muex.ex",
                 "defmodule Muex do\n  def x(, do: 1\nend",
                 Muex
               )

      assert File.read!(real_beam) == before

      refute File.exists?(
               Path.join([sandbox.root, "_build", "test", "lib", app, "ebin", "Elixir.Muex.beam"])
             )
    end
  end

  describe "apply_mutation/4 after a mutant that does not compile" do
    test "the next mutant finds the module's beam again" do
      root =
        Path.join(System.tmp_dir!(), "muex_test_sandbox_#{System.unique_integer([:positive])}")

      sandbox = Sandbox.create_sandbox(root, @project_root, "test", ["test"])
      on_exit(fn -> File.rm_rf!(root) end)

      app = to_string(Mix.Project.config()[:app])
      beam = Path.join([sandbox.root, "_build", "test", "lib", app, "ebin", "Elixir.Muex.beam"])
      good = File.read!("lib/muex.ex")

      assert {:ok, false} =
               Sandbox.apply_mutation(
                 sandbox,
                 "lib/muex.ex",
                 "defmodule Muex do\n  def x(, do: 1\nend",
                 Muex
               )

      refute File.exists?(beam)

      Sandbox.restore(sandbox, "lib/muex.ex")
      # A failed child compile empties the sandbox's app build; simulate it.
      File.rm_rf!(Path.dirname(beam))

      assert {:ok, true} = Sandbox.apply_mutation(sandbox, "lib/muex.ex", good, Muex)
      assert File.exists?(beam)

      real_ebin = Path.join([@project_root, "_build", "test", "lib", app, "ebin"])
      assert length(File.ls!(Path.dirname(beam))) == length(File.ls!(real_ebin))
    end
  end
end
