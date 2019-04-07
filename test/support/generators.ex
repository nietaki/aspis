defmodule Support.Generators do
  import ExUnitProperties
  import StreamData

  alias Hoplon.Data
  require Hoplon.Data
  require Record

  def input_package() do
    gen all ecosystem <- frequency([{5, proper_string()}, {1, constant(:asn1_DEFAULT)}]),
            name <- proper_string(),
            version <- proper_string() do
      Data.package(ecosystem: ecosystem, name: name, version: version)
    end
  end

  def input_audit() do
    gen all package <- input_package(),
            v <- optional(verdict()),
            message <- optional(proper_string()),
            public_key_fingerprint <- proper_string(),
            created_at <- integer(),
            audited_by_author <- boolean() do
      Data.audit(
        package: package,
        verdict: v,
        message: message,
        publicKeyFingerprint: public_key_fingerprint,
        createdAt: created_at,
        auditedByAuthor: audited_by_author
      )
    end
  end

  def verdict do
    one_of(~w{dangerous suspicious lgtm safe}a)
  end

  def optional(gen) do
    frequency([{4, gen}, {1, constant(:asn1_NOVALUE)}])
  end

  def has_default_values?(record) when is_tuple(record) do
    record
    |> Tuple.to_list()
    |> Enum.any?(&(&1 == :asn1_DEFAULT))
  end

  def proper_string() do
    string(:printable)
  end

  def fill_in_defaults(package) when Record.is_record(package, :Package) do
    case Data.package(package, :ecosystem) do
      :asn1_DEFAULT ->
        Data.package(package, ecosystem: "hex.pm")

      _ ->
        package
    end
  end

  def fill_in_defaults(audit) when Record.is_record(audit, :Audit) do
    package = Data.audit(audit, :package)
    package = fill_in_defaults(package)
    Data.audit(audit, package: package)
  end
end