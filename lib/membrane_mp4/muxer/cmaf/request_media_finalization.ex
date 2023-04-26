defmodule Membrane.MP4.Muxer.CMAF.RequestMediaFinalization do
  @moduledoc """
  Membrane's event representing a request for a `Membrane.MP4.Muxer.CMAF` element
  to finalize the current segment as soon as possible.
  """

  @type t :: %__MODULE__{}

  defstruct []

  defimpl Membrane.EventProtocol do
    @impl true
    def async?(%@for{}) do
      true
    end

    @impl true
    def sticky?(%@for{}) do
      false
    end
  end
end
