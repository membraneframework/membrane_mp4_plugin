defmodule Membrane.MP4.Container.PackedList do
  @moduledoc """
  A list of fixed-width entries kept in their serialized form and decoded on enumeration.

  Boxes such as `stsz` or `stco` can hold hundreds of thousands of entries, so decoding
  them eagerly into maps costs an order of magnitude more memory than the box itself.
  """

  alias Membrane.MP4.Container.ParseHelper

  @enforce_keys [:data, :width, :type, :context]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          data: bitstring(),
          width: pos_integer(),
          type: term(),
          context: %{atom() => integer()}
        }

  @doc "Takes the first entry off the list."
  @spec pop(t()) :: {term(), t()} | :empty
  def pop(%{data: <<>>}) do
    :empty
  end

  def pop(%{data: data, width: width} = list) do
    <<entry::bitstring-size(^width), rest::bitstring>> = data
    {expand(list, entry), %{list | data: rest}}
  end

  @doc false
  @spec expand(t(), bitstring()) :: term()
  def expand(list, entry) do
    {:ok, {term, <<>>}, _context} =
      ParseHelper.parse_field(entry, {:entry, list.type}, list.context)

    term
  end

  defimpl Enumerable do
    alias Membrane.MP4.Container.PackedList

    @impl true
    def count(%{data: data, width: width}), do: {:ok, div(bit_size(data), width)}

    @impl true
    def member?(_list, _entry), do: {:error, __MODULE__}

    @impl true
    def slice(%{data: data, width: width} = list) do
      slicer = fn start, length, step ->
        for index <- start..(start + (length - 1) * step)//step do
          offset = index * width

          <<_skipped::bitstring-size(^offset), entry::bitstring-size(^width), _rest::bitstring>> =
            data

          PackedList.expand(list, entry)
        end
      end

      {:ok, div(bit_size(data), width), slicer}
    end

    @impl true
    def reduce(_list, {:halt, acc}, _fun) do
      {:halted, acc}
    end

    def reduce(list, {:suspend, acc}, fun) do
      {:suspended, acc, &reduce(list, &1, fun)}
    end

    def reduce(list, {:cont, acc}, fun) do
      case PackedList.pop(list) do
        :empty -> {:done, acc}
        {entry, rest} -> reduce(rest, fun.(entry, acc), fun)
      end
    end
  end

  defimpl Inspect do
    @impl true
    def inspect(list, _opts),
      do: "#Membrane.MP4.Container.PackedList<#{Enum.count(list)} entries>"
  end
end
