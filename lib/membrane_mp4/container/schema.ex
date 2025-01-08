defmodule Membrane.MP4.Container.Schema do
  @moduledoc """
  MP4 structure schema used for parsing and serialization.

  Useful resources:
  - https://www.iso.org/standard/79110.html
  - https://www.iso.org/standard/61988.html
  - https://developer.apple.com/library/archive/documentation/QuickTime/QTFF/QTFFChap2/qtff2.html
  - https://github.com/DicomJ/mpeg-isobase/tree/eb09f82ff6e160715dcb34b2bf473330c7695d3b
  """

  alias Membrane.MP4.Container.SchemaDef

  @schema_def SchemaDef.schema_def()

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

  The schema definition is the following:
  ```
  #{inspect(@schema_def, pretty: true)}
  ```
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
  @type t :: %{
          (box_name :: atom) =>
            %{black_box?: true}
            | %{
                black_box?: false,
                version: non_neg_integer,
                fields: [field_t],
                children: map
              }
        }

  @schema SchemaDef.parse(@schema_def)

  @doc """
  Returns `t:#{inspect(__MODULE__)}.t/0`
  """
  @spec schema() :: t
  def schema(), do: @schema
end
