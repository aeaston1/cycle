defmodule Mix.Tasks.Release.Artifact do
  use Mix.Task

  @shortdoc "Builds a versioned Cycle release archive"
  @moduledoc """
  Builds a versioned Cycle release archive suitable for Homebrew.

      mix release.artifact v0.1.0

  The archive is written to `dist/` with a matching `.sha256` checksum file.
  """

  @impl Mix.Task
  def run([tag]) do
    root = File.cwd!()

    with :ok <- validate_tag(tag),
         :ok <- require_clean_output(root),
         :ok <- build_escript(tag),
         {:ok, archive} <- stage_and_archive(root, tag),
         :ok <- validate_packaged_executable(archive, tag),
         :ok <- validate_archive(archive),
         {:ok, checksum} <- write_checksum(archive) do
      Mix.shell().info("Built #{Path.relative_to_cwd(archive)}")
      Mix.shell().info("SHA-256 #{checksum}")
    else
      {:error, message} -> Mix.raise(message)
    end
  end

  def run(_args), do: Mix.raise("usage: mix release.artifact vMAJOR.MINOR.PATCH")

  defp validate_tag(tag) do
    if Regex.match?(~r/^v\d+\.\d+\.\d+$/, tag) do
      :ok
    else
      {:error, "release version must be a semantic tag like v0.1.0"}
    end
  end

  defp require_clean_output(root) do
    dist = Path.join(root, "dist")
    File.mkdir_p!(dist)
    :ok
  end

  defp build_escript(tag) do
    {output, status} =
      System.cmd("mix", ["escript.build", "--force"],
        env: [{"CYCLE_VERSION", tag}, {"MIX_ENV", "prod"}],
        stderr_to_stdout: true
      )

    Mix.shell().info(output)

    cond do
      status != 0 -> {:error, "mix escript.build failed"}
      File.exists?("cycle") -> :ok
      true -> {:error, "mix escript.build did not create ./cycle"}
    end
  end

  defp stage_and_archive(root, tag) do
    name = "cycle-#{tag}"
    dist = Path.join(root, "dist")
    stage_root = Path.join(dist, "build")
    stage = Path.join(stage_root, name)
    archive = Path.join(dist, "#{name}.tar.gz")

    File.rm_rf!(stage)
    File.rm_rf!(archive)
    File.mkdir_p!(Path.join(stage, "bin"))

    File.cp!("cycle", Path.join(stage, "bin/cycle"))
    File.chmod!(Path.join(stage, "bin/cycle"), 0o755)
    File.rm!("cycle")

    copy_required_tree(root, stage)

    case System.cmd("tar", ["-czf", archive, "-C", stage_root, name], stderr_to_stdout: true) do
      {_, 0} ->
        File.rm_rf!(stage_root)
        {:ok, archive}

      {output, _} ->
        {:error, "tar failed:\n#{output}"}
    end
  end

  defp copy_required_tree(root, stage) do
    Enum.each(["README.md", "LICENSE"], fn file ->
      File.cp!(Path.join(root, file), Path.join(stage, file))
    end)

    Enum.each(["docs", "packaging"], fn dir ->
      File.cp_r!(Path.join(root, dir), Path.join(stage, dir))
    end)
  end

  defp write_checksum(archive) do
    hash = :crypto.hash(:sha256, File.read!(archive)) |> Base.encode16(case: :lower)
    checksum_path = archive <> ".sha256"
    File.write!(checksum_path, "#{hash}  #{Path.basename(archive)}\n")
    {:ok, hash}
  end

  defp validate_archive(archive) do
    case Cycle.Security.scan_archive(archive, Cycle.Security.fake_secret_values()) do
      {:ok, []} -> :ok
      {:ok, findings} -> {:error, release_scan_error(findings)}
      {:error, message} -> {:error, "release artifact validation #{message}"}
    end
  end

  defp validate_packaged_executable(archive, tag) do
    tmp =
      Path.join([
        System.tmp_dir!(),
        "cycle-artifact-smoke-#{System.unique_integer([:positive, :monotonic])}"
      ])

    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)

    try do
      with {_, 0} <- System.cmd("tar", ["-xzf", archive, "-C", tmp], stderr_to_stdout: true),
           executable <- Path.join([tmp, "cycle-#{tag}", "bin", "cycle"]),
           true <- File.exists?(executable),
           {output, 0} <- System.cmd(executable, ["--version"], stderr_to_stdout: true),
           true <- String.trim(output) == "cycle #{String.trim_leading(tag, "v")}" do
        :ok
      else
        {output, status} ->
          {:error,
           "packaged executable smoke failed with status #{status}: #{String.trim(output)}"}

        false ->
          {:error, "packaged executable smoke failed"}
      end
    after
      File.rm_rf!(tmp)
    end
  end

  defp release_scan_error(findings) do
    details =
      findings
      |> Enum.map(fn finding -> "#{finding.path}: #{finding.reason}: #{finding.value}" end)
      |> Enum.join("\n")

    "release artifact contains forbidden secret or private-repo value:\n#{details}"
  end
end
