defmodule Membrane.MP4.Muxer do
  @moduledoc """
  Puts payloaded streams into an MPEG-4 container.
  """
  use Membrane.Filter

  def_input_pad :input,
    availability: :on_request,
    demand_unit: :buffers,
    caps: Membrane.MP4.Payload,
    options: [
      encoding: [
        spec: :AAC | :H264,
        description: "Track encoding"
      ]
    ]
  def_output_pad :output, caps: Membrane.MP4

  @impl true
  def handle_init(options) do
    state =
      options
      |> Map.from_struct()
      |> Map.merge(%{
        seq_num: 0,
        elapsed_time: 0,
        samples: []
      })

    {:ok, state}
  end

  @impl true
  def handle_demand(:output, _size, _unit, _ctx, state) do
  end

  @impl true
  def handle_process(:input, sample, ctx, state) do
  end

  @impl true
  def handle_caps(:input, %Membrane.MP4.Payload{} = caps, ctx, state) do
  end

  @impl true
  def handle_end_of_stream(:input, ctx, state) do
  end
end
