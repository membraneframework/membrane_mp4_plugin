defmodule Membrane.MP4.Container.Schema do
  @typedoc """
  The schema of MP4 structure.

  An MP4 file consists of boxes, that all have the same header and different internal
  structures. Boxes can be nested with one another.

  Each box has at most 4-letter name and may have the following parameters:
  - `black_box?` - if true, the box content is unspecified and is treated as an opaque
  binary. Defaults to false.
  - `version` - the box version. Versions usually differ by the sizes of particular fields.
  - `fields` - a list of key-value parameters
  - `children` - the nested boxes
  """
  @type t :: %__MODULE__{
          schema: %{
            (box_name :: atom) =>
              %{black_box?: true}
              | %{
                  black_box?: false,
                  version: non_neg_integer,
                  fields: [field_t],
                  children: map
                }
          },
          known_box_names: MapSet.t(String.t())
        }

  @type schema_def_primitive_t :: atom

  @type schema_def_field_t ::
          {:reserved, bitstring}
          | {field_name :: atom,
             schema_def_primitive_t
             | {:list, schema_def_primitive_t | [schema_def_field_t]}
             | [schema_def_field_t]}

  @type schema_def_box_t ::
          {box_name :: atom,
           [{:black_box?, true}]
           | [
               {:version, non_neg_integer}
               | {:fields, [schema_def_field_t]}
               | schema_def_box_t
             ]}

  @typedoc """
  Type describing the schema definition, that is hardcoded in this module.

  It may be useful for improving the schema definition. The actual schema that
  should be operated on, or, in other words, the parsed schema definition is
  specified by `t:#{inspect(__MODULE__)}.t/0`.

  The schema definition differs from the final schema in the following ways:
    - primitives along with their parameters are specified as atoms, for example
    `:int32` instead of `{:int, 32}`
    - child boxes are nested within their parents directly, instead of residing
    under `:children` key.
  """
  @type schema_def_t :: [schema_def_box_t]

  @typedoc """
  For fields, the following primitive types are supported:
  - `{:int, bit_size}` - a signed integer
  - `{:uint, bit_size}` - an unsigned integer
  - `:bin` - a binary lasting till the end of a box
  - `{:bin, bit_size}` - a binary of given size
  - `:str` - a string terminated with a null byte
  - `{:str, bit_size}` - a string of given size
  - `{:fp, integer_part_bit_size, fractional_part_bit_size}` - a fixed point number
  """
  @type primitive_t ::
          {:int, bit_size :: non_neg_integer}
          | {:uint, bit_size :: non_neg_integer}
          | :bin
          | {:bin, bit_size :: non_neg_integer}
          | :str
          | {:str, bit_size :: non_neg_integer}
          | {:fp, int_bit_size :: non_neg_integer, frac_bit_size :: non_neg_integer}

  @typedoc """
  A box field type.

  It may contain a primitive, a list or nested fields. Lists last till the end of a box.
  """
  @type field_t ::
          {:reserved, bitstring}
          | {field_name :: atom, primitive_t | {:list, any} | [field_t]}

  defstruct [:schema, :known_box_names]

  @spec parse(schema_def_t()) :: t()
  def parse(schema) do
    # %__MODULE__{
    #   schema: Map.new(schema, &parse_box/1),
    #   known_box_names: []
    # }
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
