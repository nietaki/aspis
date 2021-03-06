defmodule Hoplon do
  @moduledoc false

  alias Hoplon.Diff
  alias Hoplon.Git
  alias Hoplon.Utils
  alias Hoplon.HexPackage
  alias Hoplon.CheckResult
  alias Hoplon.Lockfile

  @program_dependencies ["git", "diff", "elixir", "openssl"]

  @doc """
  checks if the host machine has access to the command line utilities
  Hoplon uses under the hood
  """
  def check_required_programs() do
    missing_programs =
      @program_dependencies
      |> Enum.reject(&Utils.program_exists?/1)

    case missing_programs do
      [] -> {:ok, :all_required_programs_present}
      missing_programs -> {:error, {:missing_required_programs, missing_programs}}
    end
  end

  @doc """
  Creates a fresh clone of the given repository under the given path.

  If the local repository already exists, it tries to return it to a clean
  state, in case it was, for example, in the middle of a bisect operation.
  """
  def prepare_repo(git_url, path) do
    with {:ok, _} <- Git.ensure_repo(git_url, path),
         {:ok, _} <- Git.bisect_reset(path),
         {:ok, _} <- Git.arbitrary(["checkout", "--quiet", "master"], path),
         {:ok, _} <- Git.arbitrary(["pull", "--quiet", "origin", "master"], path),
         {:ok, _} <- Git.arbitrary(["fetch", "--quiet", "--tags"], path),
         {:ok, _} <- Git.arbitrary(["reset", "--quiet", "--hard", "HEAD"], path) do
      {:ok, :repo_prepared}
    end
  end

  @doc """
  Attempts to check out the tag corresponding to the provided version
  in the git repository in the provided directory.
  """
  def checkout_version_by_tag(version, cd_path) do
    case Git.attempt_checkout(version, cd_path) do
      success = {:ok, _} ->
        success

      {:error, _} ->
        Git.attempt_checkout("v" <> version, cd_path)
    end
  end

  @doc """
  Given a version and a directory containing a git repository,
  attempts to find the first commit where the Elixir project is in the version.
  """
  def checkout_version_by_git_bisect(version, cd_path) do
    version_checker_path = Path.join(__DIR__, "../scripts/project_version_checker.exs")
    # NOTE assumptions here
    mix_exs_path = Path.join(cd_path, "mix.exs")
    script = ["elixir", version_checker_path, mix_exs_path, version]

    {:ok, master_commit} = Git.get_commit_hash(cd_path, "master")
    {:ok, initial_commit} = Git.get_initial_commit(cd_path)

    if master_commit == initial_commit do
      # one commit repo, bisect would be confused
      {:ok, master_commit}
    else
      {:ok, _} = Git.bisect_start(cd_path, initial_commit, "master")

      {:ok, bisect_output} = Git.bisect_run(cd_path, script)
      {:ok, _} = Git.bisect_reset(cd_path)
      {:ok, commit} = extract_bisected_commit(bisect_output)
      {:ok, _} = Git.arbitrary(["checkout", "--quiet", commit], cd_path)
      {:ok, commit}
    end
  end

  defp extract_bisected_commit(bisect_output) do
    output_lines =
      bisect_output
      |> Utils.split_lines()
      |> Enum.map(&String.trim/1)

    if Enum.any?(output_lines, &(&1 == "bisect run success")) do
      commit =
        output_lines
        |> Enum.reverse()
        |> Enum.find_value(fn line ->
          case Regex.run(~r/^([0-9a-f]{40}) is the first [a-z]* commit$/, line) do
            [_whole, commit] -> commit
            nil -> nil
          end
        end)

      if commit do
        {:ok, commit}
      else
        {:error, :commit_couldnt_be_found_in_bisect_output}
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
  Given the hex package description, the directory where the cloned dependency repos
  are supposed to be and the lockfile struct containing absolved packages, checks
  the package for honesty.
  """
  def check_package(package = %HexPackage{}, git_parent_directory, lf = %Lockfile{}) do
    {:ok, project_deps_path} = Utils.get_project_deps_path()
    dep_path = Path.join(project_deps_path, Atom.to_string(package.name))
    result = CheckResult.new(package)

    result_tuple =
      with {:ok, result} <- add_git_url(result),
           repo_subpath = get_repo_subpath(result.git_url),
           repo_path = Path.join(git_parent_directory, repo_subpath),
           {:ok, _} <- Hoplon.prepare_repo(result.git_url, repo_path),
           {:ok, result} <- checkout_version(result, repo_path),
           diffs = Hoplon.get_relevant_file_diffs(repo_path, dep_path),
           result = %CheckResult{result | diffs: diffs} do
        {:ok, result}
      end

    # temporary workaround, having it inside the with was hard for dialyzer to comprehend
    result =
      case result_tuple do
        {:ok, result = %CheckResult{}} ->
          result

        {:error, result = %CheckResult{}} ->
          result
      end

    maybe_absolution_entry = get_in(lf.absolved, [package.hex_name, package.hash])

    case maybe_absolution_entry do
      nil -> result
      msg when is_binary(msg) -> %CheckResult{result | absolution_message: msg}
    end
  end

  defp get_repo_subpath(git_url) do
    {user, repo} = Utils.get_user_and_repo_name(git_url)
    subpath = Path.join(user, repo)
    String.replace(subpath, ~r/[^a-zA-Z0-9_\/-]/, "_")
  end

  defp add_git_url(result) do
    case Utils.get_github_git_url(result.hex_package.hex_name) do
      {:ok, git_url} ->
        {:ok, %CheckResult{result | git_url: git_url}}

      {:error, reason} ->
        {:error, CheckResult.set_error_reason(result, reason)}
    end
  end

  defp checkout_version(result, repo_path) do
    case Hoplon.checkout_version_by_tag(result.hex_package.version, repo_path) do
      {:ok, version_tag} ->
        {:ok, %CheckResult{result | git_ref: {:tag, version_tag}}}

      {:error, {:invalid_ref, _}} ->
        {:ok, commit} = checkout_version_by_git_bisect(result.hex_package.version, repo_path)
        {:ok, %CheckResult{result | git_ref: {:bisect, commit}}}
    end
  end

  def get_relevant_file_diffs(baseline_dir, dependency_dir) do
    all_diffs = Diff.diff_files_in_directories(baseline_dir, dependency_dir)

    all_diffs
    |> Enum.reject(fn diff ->
      case diff do
        # extra stuff in the repo
        {:only_in_left, _} ->
          true

        # things hex puts in
        {:only_in_right, ".hex"} ->
          true

        {:only_in_right, ".fetch"} ->
          true

        {:only_in_right, "hex_metadata.config"} ->
          true

        {:only_in_right, relative_path} ->
          if Path.basename(relative_path) == ".DS_Store" do
            true
          else
            false
          end

        # the rest is relevant
        _ ->
          false
      end
    end)
  end
end
