defmodule Mix.Tasks.Compile.ZkdbNif do
  @moduledoc "Builds native/zkdb_nif with `zig build` and copies it to priv/zkdb_nif.so."
  use Mix.Task.Compiler

  @impl true
  def run(_args) do
    native = Path.expand("native/zkdb_nif")
    {out, status} = System.cmd("zig", ["build"], cd: native, stderr_to_stdout: true)
    if status != 0, do: Mix.raise("zig build failed:\n" <> out)

    src =
      Enum.find(
        ["libzkdb_nif.so", "libzkdb_nif.dylib"],
        &File.exists?(Path.join([native, "zig-out/lib", &1]))
      ) || Mix.raise("zig build produced no libzkdb_nif")

    File.mkdir_p!("priv")
    File.cp!(Path.join([native, "zig-out/lib", src]), "priv/zkdb_nif.so")
    {:ok, []}
  end
end

defmodule ZkdbElixir.MixProject do
  use Mix.Project

  def project do
    [
      app: :zkdb_elixir,
      version: "0.1.0",
      elixir: "~> 1.18",
      compilers: [:zkdb_nif] ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end
end
