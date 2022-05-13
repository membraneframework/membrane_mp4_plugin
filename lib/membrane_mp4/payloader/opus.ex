defmodule Membrane.MP4.Payloader.Opus do
  @moduledoc """
  MP4 Payloader for Opus codec
  """
  use Membrane.Filter

  alias Membrane.{Buffer, Opus}
  alias Membrane.MP4.Payload

  def_input_pad :input,
    availability: :always,
    caps: {Opus, self_delimiting?: false},
    demand_unit: :buffers

  def_output_pad :output,
    availability: :always,
    caps: Payload

  @impl true
  def handle_init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  @impl true
  def handle_caps(:input, caps, _ctx, state) do
    caps = %Payload{
      content: caps,
      timescale: 48_000
    }

    {{:ok, caps: {:output, caps}}, state}
  end

  @impl true
  def handle_process(:input, %Buffer{} = buffer, _ctx, state) do
    buffer = %Buffer{buffer | dts: Buffer.get_dts_or_pts(buffer)}
    {{:ok, buffer: {:output, buffer}}, state}
  end
end
