defmodule Hoplon.CheckResult do
  alias Hoplon.HexPackage
  alias Hoplon.Git

  @moduledoc false

  @type t :: %__MODULE__{}

  @type status :: :honest | :corrupt | :unresolved | :absolved

  defstruct [
    # %Hoplon.HexPackage{}
    :hex_package,
    :git_url,
    # {:tag, tag_name} | {:hash, sha-1}
    :git_ref,
    # [Hoplon.Diff.file_difference]
    :diffs,
    :error_reason,
    :absolution_message
  ]

  def new(package = %HexPackage{}) do
    %__MODULE__{
      hex_package: package
      # the rest are meant to be nil at the beginning
    }
  end

  @spec set_error_reason(t, term) :: t
  def set_error_reason(error, reason) do
    %__MODULE__{error | error_reason: reason}
  end

  @spec get_status(t()) :: status()

  def get_status(%__MODULE__{absolution_message: msg}) when msg != nil do
    :absolved
  end

  def get_status(%__MODULE__{git_url: nil}) do
    :unresolved
  end

  def get_status(%__MODULE__{git_ref: nil}) do
    :unresolved
  end

  def get_status(%__MODULE__{diffs: []}) do
    :honest
  end

  def get_status(%__MODULE__{diffs: [_ | _]}) do
    :corrupt
  end

  def get_exit_code_from_status(:absolved), do: 0
  def get_exit_code_from_status(:honest), do: 0
  def get_exit_code_from_status(:unresolved), do: 11
  def get_exit_code_from_status(:corrupt), do: 12

  def header_line() do
    "Dependency  Version  Github  LocatedBy  Status"
  end

  def representation_line(result = %__MODULE__{}) do
    status = get_status(result)
    colour_prefix = status_colour(status)
    p = result.hex_package

    git_repo_info =
      case result.git_url do
        nil ->
          "NOT_FOUND"

        url ->
          {:ok, {user, repo_name}} = Git.get_github_user_and_package_from_git_url(url)
          "#{user}/#{repo_name}"
      end

    located_by =
      case result.git_ref do
        {a, tag} when is_atom(a) -> "#{a}:#{tag}"
        nil -> "NOT_FOUND"
        other -> inspect(other)
      end

    status_representation =
      case status do
        :honest -> "HONEST"
        :unresolved -> "UNRESOLVED"
        :corrupt -> "CORRUPT: #{inspect(result.diffs)}"
        :absolved -> "ABSOLVED: #{result.hex_package.hash} - \"#{result.absolution_message}\""
      end

    line =
      "#{p.hex_name}  #{p.version}  #{git_repo_info}  #{located_by}  #{status_representation}"

    colour_prefix <> line <> reset_colour()
  end

  def reset_colour(), do: IO.ANSI.default_color()

  def status_colour(:absolved), do: IO.ANSI.green()
  def status_colour(:honest), do: IO.ANSI.green()
  def status_colour(:corrupt), do: IO.ANSI.red()
  def status_colour(:unresolved), do: IO.ANSI.yellow()
end
