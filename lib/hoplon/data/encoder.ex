defmodule Hoplon.Data.Encoder do
  require Record

  require Hoplon.Data
  alias Hoplon.Data
  @record_tags [:Package, :Audit, :SignedAudit]

  def encode(package) when Record.is_record(package) and elem(package, 0) in @record_tags do
    tag = elem(package, 0)
    :HoplonMessages.encode(tag, package)
  end

  def decode(message, tag) do
    case do_decode(message, tag) do
      {:ok, record} ->
        {:ok, fixup_decoded(record)}

      other ->
        other
    end
  end

  defp do_decode(message, tag) when is_binary(message) and tag in @record_tags do
    :HoplonMessages.decode(tag, message)
  end

  defp fixup_decoded(record) when Record.is_record(record, :Package) do
    # it seems like Erlang returns to us charlist default values instead of binary ones
    fixup_tuple_string(record, 1)
  end

  defp fixup_decoded(record) when Record.is_record(record, :Audit) do
    package = Data.audit(record, :package)
    package = fixup_decoded(package)
    Data.audit(record, package: package)
  end

  defp fixup_decoded(other) do
    other
  end

  defp fixup_tuple_string(tuple, position) when is_binary(elem(tuple, position)) do
    tuple
  end

  defp fixup_tuple_string(tuple, position) when is_list(elem(tuple, position)) do
    charlist = elem(tuple, position)
    put_elem(tuple, position, to_string(charlist))
  end
end
