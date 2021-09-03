defmodule Membrane.MP4.Muxer do
  @moduledoc """
  Puts payloaded streams into an MPEG-4 container.
  """
  use Membrane.Filter

  alias Membrane.MP4.{CommonBox, Container}
  alias __MODULE__.MovieBox

  def_input_pad :input, demand_unit: :buffers, caps: Membrane.MP4.Payload
  def_output_pad :output, caps: :buffers

  def_options timescale: [
                type: :integer,
                default: 1000,
                description: "Common timescale for all tracks in the container"
              ]

  @impl true
  def handle_init(options) do
    state = %{tracks: [], timescale: options.timescale}

    {:ok, state}
  end

  @impl true
  def handle_caps(:input, %Membrane.MP4.Payload{} = caps, _ctx, state) do
    caps = Map.take(caps, [:timescale, :width, :height, :content])

    state =
      Map.update!(state, :tracks, &[%{config: caps, sample_count: 0, buffers: Qex.new()} | &1])

    {{:ok, redemand: :output}, state}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  @impl true
  def handle_process(:input, buffer, _ctx, state) do
    state =
      Map.update!(state, :tracks, fn tracks ->
        first = hd(tracks)
        rest = tl(tracks)

        [
          first
          |> Map.update!(:buffers, &Qex.push(&1, buffer))
          |> Map.update!(:sample_count, &(&1 + 1))
          | rest
        ]
      end)

    {{:ok, redemand: :output}, state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    ftyp = CommonBox.file_type() |> Container.serialize!()

    mdat =
      state.tracks
      |> Enum.flat_map(& &1.buffers)
      |> CommonBox.media_data()
      |> Container.serialize!()

    moov = state |> Map.take([:tracks, :timescale]) |> MovieBox.serialize()

    mp4 = [ftyp, mdat, moov] |> Enum.join()

    {{:ok, buffer: {:output, %Membrane.Buffer{payload: mp4}}, end_of_stream: :output}, state}
  end
end
