defmodule Membrane.MP4.Payloader.Opus do
  @moduledoc """
  MP4 Payloader for Opus codec.
  """
  use Membrane.Filter

  alias Membrane.MP4.Payload
  alias Membrane.Opus

  def_input_pad :input,
    availability: :always,
    accepted_format: %Opus{self_delimiting?: false},
    demand_unit: :buffers

  def_output_pad :output,
    availability: :always,
    accepted_format: Payload

  @impl true
  def handle_init(_ctx, _opts) do
    {[], %{}}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {[demand: {:input, size}], state}
  end

  @impl true
  def handle_stream_format(:input, stream_format, _ctx, state) do
    stream_format = %Payload{
      content: stream_format,
      timescale: 48_000
    }

    {[stream_format: {:output, stream_format}], state}
  end

  @impl true
  def handle_process(:input, buffer, _ctx, state) do
    {[buffer: {:output, buffer}], state}
  end
end
