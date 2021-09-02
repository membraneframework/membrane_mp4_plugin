defmodule Membrane.MP4.Muxer do
  @moduledoc """
  Puts payloaded streams into an MPEG-4 container.
  """
  use Membrane.Filter

  alias Membrane.MP4.Container
  alias __MODULE__.BoxHelper

  def_input_pad :input, demand_unit: :buffers, caps: Membrane.MP4.Payload
  def_output_pad :output, caps: :buffers

  @impl true
  def handle_init(_options) do
    state = %{caps: %{}, buffers: []}

    {:ok, state}
  end

  @impl true
  def handle_caps(:input, %Membrane.MP4.Payload{} = caps, _ctx, state) do
    caps = Map.take(caps, [:timescale, :width, :height, :content])

    {{:ok, redemand: :output}, %{state | caps: caps}}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  @impl true
  def handle_process(:input, buffer, _ctx, state) do
    state = Map.update!(state, :buffers, &[buffer | &1])

    {{:ok, redemand: :output}, state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    ftyp = BoxHelper.file_type_box()

    ordered_buffers = state.buffers |> Enum.reverse()

    mdat = BoxHelper.media_data_box(ordered_buffers)

    moov_config =
      state.caps
      |> Map.merge(%{
        first_timestamp: hd(ordered_buffers).metadata.timestamp,
        last_timestamp: hd(state.buffers).metadata.timestamp,
        payload_sizes: Enum.map(ordered_buffers, &byte_size(&1.payload))
      })

    moov = BoxHelper.movie_box([moov_config])

    mp4 = [ftyp, mdat, moov] |> Enum.map(&Container.serialize!/1) |> Enum.join()

    {{:ok, buffer: {:output, %Membrane.Buffer{payload: mp4}}, end_of_stream: :output}, state}
  end
end
