defmodule Membrane.MP4.Container.Schema.Parser do
  @moduledoc false

  def parse(schema) do
    Map.new(schema, &parse_child/1)
  end

  defp parse_child({name, schema}) do
    {schema, children} =
      schema |> Enum.split_with(fn {k, _v} -> k in [:version, :fields, :black_box?] end)

    schema = Map.new(schema)

    schema =
      if schema[:black_box?] do
        schema
      else
        schema
        |> Map.update(:fields, [], &parse_fields/1)
        |> Map.put(:children, parse(children))
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
          {s1, "p" <> s2} = Integer.parse(rest)
          {:fp, s1, String.to_integer(s2)}
      end

    {name, type}
  end

  defp parse_field({name, {:list, type}}) do
    {name, type} = parse_field({name, type})
    {name, {:list, type}}
  end
end
