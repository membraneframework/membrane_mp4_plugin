defmodule Membrane.MP4.Container.Header do
  @moduledoc """
  A structure describing the header of the box.

  The `content_size` field is equal to the box size minus the size of the header (8 bytes).
  """

  @enforce_keys [:name, :content_size, :header_size]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          name: atom(),
          content_size: non_neg_integer(),
          header_size: non_neg_integer()
        }

  @name_size 4
  @compact_size_size 4
  @large_size_size 8

  @doc """
  Parses the header of a box.

  Returns the `t:t/0` and the leftover data.
  """
  @spec parse(binary()) :: {:ok, t, leftover :: binary()} | {:error, :not_enough_data}
  def parse(
        <<compact_size::integer-size(@compact_size_size)-unit(8), name::binary-size(@name_size),
          rest::binary>>
      ) do
    {size, rest} =
      case compact_size do
        0 ->
          {@compact_size_size + @name_size + byte_size(rest), rest}

        1 ->
          <<large_size::64, new_rest::binary>> = rest
          {large_size, new_rest}

        size ->
          {size, rest}
      end

    header_size =
      @name_size + @compact_size_size + if compact_size == 1, do: @large_size_size, else: 0

    {:ok,
     %__MODULE__{
       name: parse_box_name(name),
       content_size: size - header_size,
       header_size: header_size
     }, rest}
  end

  def parse(_data), do: {:error, :not_enough_data}

  defp parse_box_name(name) do
    name |> String.trim_trailing(" ") |> String.to_atom()
  end
end
