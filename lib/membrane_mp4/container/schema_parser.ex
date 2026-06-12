defmodule Membrane.MP4.Container.Schema.Parser do
  @moduledoc false
  alias Membrane.MP4.Container.Schema

  @option_keys [:version, :fields, :black_box?]

  @spec parse(Schema.schema_def_t()) :: {MapSet.t(String.t()), Schema.boxes_t()}
  def parse(schema_def) do
    whitelist = schema_def |> extract_box_names() |> MapSet.new()
    {whitelist, build_boxes(schema_def)}
  end

  defp build_boxes(schema_def) do
    Map.new(schema_def, &parse_box/1)
  end

  defp extract_box_names(schema_def) do
    Enum.flat_map(schema_def, fn {key, value} ->
      if key in @option_keys do
        []
      else
        child_names = if is_list(value), do: extract_box_names(value), else: []
        [Atom.to_string(key) | child_names]
      end
    end)
  end

  defp parse_box({name, schema}) do
    schema =
      if schema[:black_box?] do
        Map.new(schema)
      else
        {schema, children} = schema |> Keyword.split([:version, :fields, :black_box?])

        schema
        |> Map.new()
        |> Map.merge(%{black_box?: false, children: build_boxes(children)})
        |> Map.update(:fields, [], &parse_fields/1)
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

  defp parse_field({name, {type, store: context_name, when: {context_name, opts}}})
       when is_atom(name) do
    {name, type} = parse_field({name, type})
    type = {type, store: context_name, when: {context_name, opts}}
    {name, type}
  end

  defp parse_field({name, {type, store: context_name}}) when is_atom(name) do
    {name, type} = parse_field({name, type})
    type = {type, store: context_name}
    {name, type}
  end

  defp parse_field({name, {type, when: {context_name, opts}}}) when is_atom(name) do
    {name, type} = parse_field({name, type})
    type = {type, when: {context_name, opts}}
    {name, type}
  end

  defp parse_field({name, {:list, type}}) do
    {name, type} = parse_field({name, type})
    {name, {:list, type}}
  end

  defp parse_field({name, {:list, type, length: length}}) when is_atom(length) do
    {name, type} = parse_field({name, type})
    {name, {:list, type, length: length}}
  end
end
