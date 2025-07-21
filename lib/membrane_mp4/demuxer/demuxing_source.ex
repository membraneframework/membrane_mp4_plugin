defmodule Membrane.MP4.Demuxer.DemuxingSource do
  use Membrane.Source

  alias Membrane.MP4.Demuxer.ISOM.Engine

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
    flow_control: :manual,
    options: [
      kind: [
        spec: :video | :audio | nil,
        default: nil,
        description: """
        Specifies, what kind of data can be handled by a pad.
        """
      ]
    ]

  def_options provide_data_callback: [
                spec: function()
              ],
              start_at: [
                spec: non_neg_integer(),
                default: 0
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
    engine = Engine.new(state.provide_data_callback)
    track_ids = Engine.get_tracks_info(engine) |> Map.keys()
    engine = Enum.reduce(track_ids, engine, &Engine.seek_in_samples(&2, &1, state.start_at))
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
      {:ok, sample, engine} ->
        buffer = %Membrane.Buffer{
          payload: sample.payload,
          pts: Ratio.new(sample.pts) |> Membrane.Time.seconds(),
          dts: Ratio.new(sample.dts) |> Membrane.Time.seconds()
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

      :end_of_stream ->
        {[end_of_stream: pad], state}
    end
  end

  @impl true
  def handle_pad_added(Pad.ref(:output, track_id), _ctx, state) do
    track_ids = Engine.get_tracks_info(state.engine) |> Map.keys()

    if track_id not in track_ids do
      raise "Unknown track id: #{inspect(track_id)}. The available tracks are: #{inspect(track_ids)}"
    else
      {[], state}
    end
  end

  defp reject_unsupported_sample_types(sample_tables) do
    Map.reject(sample_tables, fn {_track_id, table} -> table.sample_description == nil end)
  end
end
