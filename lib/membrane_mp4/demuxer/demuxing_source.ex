defmodule Membrane.MP4.Demuxer.DemuxingSource do
  @moduledoc """
  A Membrane Source capable of reading streams from the MP4 file.

  It requires specifying `provide_data_callback` - a function that will be called 
  each time data from MP4 needs to be read.
  Once the Demuxer identifies the tracks in the MP4, `t:new_tracks_t/0` notification 
  is sent for each of the tracks. The parent can then link `Pad.ref(:output, track_id)` for desired tracks.
  """
  use Membrane.Source
  alias Membrane.MP4.Demuxer.ISOM.Engine

  @typedoc """
  Notification sent when the tracks are identified in the MP4.

  Upon receiving the notification, `Pad.ref(:output, track_id)` pads should be linked
  for the desired `track_id`s in the list.
  The `content` field contains the stream format describing given track.
  """
  @type new_tracks_t() ::
          {:new_tracks, [{track_id :: integer(), content :: struct()}]}

  def_output_pad :output,
    accepted_format:
      any_of(
        %Membrane.AAC{config: {:esds, _esds}},
        %Membrane.H264{
          stream_structure: {_avc, _dcr},
          alignment: :au
        },
        %Membrane.H265{
          stream_structure: {_hevc, _dcr},
          alignment: :au
        },
        %Membrane.Opus{self_delimiting?: false}
      ),
    availability: :on_request,
    flow_control: :manual

  def_options provide_data_cb: [
                spec: Engine.provide_data_cb(),
                description: """
                A function that will be called each time the `#{inspect(__MODULE__)}` 
                needs data. It should read desired number of bytes from MP4 file,
                starting at given position.
                """
              ],
              start_at_ms: [
                spec: non_neg_integer(),
                default: 0,
                description: """
                Specifies the decoding timestamp (represented in milliseconds) of 
                the first sample that should be read from each of the tracks.

                If there is no sample with exactly such a timestamp, that sample
                will be the first sample with DTS greater than provided timestamp.
                """
              ]

  @impl true
  def handle_init(_ctx, opts) do
    state =
      Map.from_struct(opts)
      |> Map.merge(%{
        engine: nil
      })

    {[], state}
  end

  @impl true
  def handle_setup(_ctx, state) do
    engine = Engine.new(state.provide_data_cb)
    track_ids = Engine.get_tracks_info(engine) |> Map.keys()
    engine = Enum.reduce(track_ids, engine, &Engine.seek_in_samples(&2, &1, state.start_at_ms))
    {[], %{state | engine: engine}}
  end

  @impl true
  def handle_playing(_ctx, state) do
    new_tracks =
      state.engine
      |> Engine.get_tracks_info()
      |> reject_unsupported_sample_types()
      |> Enum.map(fn {track_id, table} ->
        {track_id, table.sample_description}
      end)

    {[{:notify_parent, {:new_tracks, new_tracks}}], state}
  end

  @impl true
  def handle_demand(Pad.ref(:output, track_id) = pad, _demand_size, _demand_unit, ctx, state) do
    case Engine.read_sample(state.engine, track_id) do
      :end_of_stream ->
        {[end_of_stream: pad], state}

      {:ok, sample, engine} ->
        buffer = %Membrane.Buffer{
          payload: sample.payload,
          pts: Ratio.new(sample.pts) |> Membrane.Time.milliseconds(),
          dts: Ratio.new(sample.dts) |> Membrane.Time.milliseconds()
        }

        state = %{state | engine: engine}

        maybe_send_stream_format =
          if ctx.pads[pad].stream_format == nil do
            stream_format =
              state.engine
              |> Engine.get_tracks_info()
              |> Map.get(track_id)
              |> Map.get(:sample_description)

            [{:stream_format, {pad, stream_format}}]
          else
            []
          end

        {maybe_send_stream_format ++ [buffer: {pad, buffer}, redemand: pad], state}
    end
  end

  @impl true
  def handle_pad_added(Pad.ref(:output, track_id), _ctx, state) do
    track_ids = Engine.get_tracks_info(state.engine) |> Map.keys()

    if track_id in track_ids do
      {[], state}
    else
      raise "Unknown track id: #{inspect(track_id)}. The available tracks are: #{inspect(track_ids)}"
    end
  end

  defp reject_unsupported_sample_types(sample_tables) do
    Map.reject(sample_tables, fn {_track_id, table} -> table.sample_description == nil end)
  end
end
