defmodule Membrane.MP4.Container.Schema.Parser do
  @moduledoc false
  alias Membrane.MP4.Container.Schema

  @spec parse(Schema.schema_def_t()) :: Schema.t()
  def parse(schema) do
    Map.new(schema, &parse_box/1)
  end

  defp parse_box({name, schema}) do
    schema =
      if schema[:black_box?] do
        Map.new(schema)
      else
        {schema, children} = schema |> Keyword.split([:version, :fields, :black_box?])

        schema
        |> Map.new()
        |> Map.merge(%{black_box?: false, children: parse(children)})
        |> Map.update(:fields, [], &parse_fields/1)
        |> case do
          %{version: _version, fields: fields} when not is_map_key(fields, :version) ->
            raise "Version requirement provided for box #{name}, but field version is absent"

          %{version: version} = schema when is_integer(version) ->
            %{schema | version: [version]}

          schema ->
            schema
        end
      end

    {name, schema}
  end

  defp parse_fields(fields) do
    Enum.map(fields, &parse_field/1)
  end

  defp parse_field({name, subfields}) when is_list(subfields) do
    {name, parse_fields(subfields)}
  end

  defp parse_field({:reserved, _reserved} = field), do: field

  defp parse_field({name, type}) when is_atom(type) do
    type =
      case Atom.to_string(type) do
        "int" <> s ->
          {:int, String.to_integer(s)}

        "uint" <> s ->
          {:uint, String.to_integer(s)}

        "bin" ->
          :bin

        "bin" <> s ->
          {:bin, String.to_integer(s)}

        "str" ->
          :str

        "str" <> s ->
          {:str, String.to_integer(s)}

        "fp" <> rest ->
          {s1, "d" <> s2} = Integer.parse(rest)
          {:fp, s1, String.to_integer(s2)}
      end

    {name, type}
  end

  defp parse_field({name, {:list, type}}) do
    {name, type} = parse_field({name, type})
    {name, {:list, type}}
  end

  defp parse_field({name, {type, opts}}) when is_atom(name) and is_list(opts) do
    Keyword.validate!(opts, [:store, :when])
    {name, type} = parse_field({name, type})
    type = {type, Map.new(opts)}
    {name, type}
  end
end
