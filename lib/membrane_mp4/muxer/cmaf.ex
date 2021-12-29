defmodule Membrane.MP4.Muxer.CMAF do
  @moduledoc """
  Puts payloaded stream into [Common Media Application Format](https://www.wowza.com/blog/what-is-cmaf),
  an MP4-based container commonly used in adaptive streaming over HTTP.

  Currently one input stream is supported.

  If a stream contains non-key frames (like H264 P or B frames), they should be marked
  with a `mp4_payload: %{key_frame?: false}` metadata entry.
  """
  use Membrane.Filter

  require Membrane.Logger

  alias __MODULE__.{Header, Segment}
  alias Membrane.{Buffer, Time}
  alias Membrane.MP4.Payload.{AAC, AVC1}
  alias Membrane.MP4.{Track, Helper}

  def_input_pad :input,
    availability: :on_request,
    demand_unit: :buffers,
    caps: Membrane.MP4.Payload

  def_output_pad :output, caps: Membrane.CMAF.Track

  def_options segment_duration: [
                type: :time,
                default: 2 |> Time.seconds()
              ]

  @impl true
  def handle_init(options) do
    state =
      options
      |> Map.from_struct()
      |> Map.merge(%{
        seq_num: 0,
        awaiting_caps: nil,
        pad_to_track: %{},
        next_track_id: 1,
        pad_to_end_timestamp: %{},
        samples: %{},
        duration_resolution_queue: %{},
        elapsed_time: 0
      })

    {:ok, state}
  end

  @impl true
  def handle_demand(:output, _size, _unit, _ctx, state) do
    {pad, _elapsed_time} =
      Enum.min_by(state.pad_to_end_timestamp, &Ratio.to_float(Bunch.value(&1)))

    {{:ok, demand: {pad, 1}}, state}
  end

  @impl true
  def handle_process(Pad.ref(:input, _id) = pad, sample, ctx, state) do
    use Ratio, comparison: true

    state =
      if is_nil(state.duration_resolution_queue[pad]) do
        put_in(state, [:duration_resolution_queue, pad], sample)
      else
        prev_sample = state.duration_resolution_queue[pad]
        duration = Ratio.to_float(sample.dts - prev_sample.dts)
        prev_sample_metadata = Map.put(prev_sample.metadata, :duration, duration)
        prev_sample = %Buffer{prev_sample | metadata: prev_sample_metadata}

        put_in(state, [:pad_to_end_timestamp, pad], prev_sample.dts)
        |> put_in([:duration_resolution_queue, pad], sample)
        |> update_in([:samples, pad], &[prev_sample | &1])
      end

    state =
      case state.awaiting_caps do
        {{:update_with_next, ^pad}, caps} ->
          duration = state.duration_resolution_queue[pad].dts - List.last(state.samples[pad]).dts
          %{state | awaiting_caps: {duration, caps}}

        _otherwise ->
          state
      end

    {caps_action, segment} =
      if is_nil(state.awaiting_caps) do
        {[], Segment.Helper.get_segment(state, state.segment_duration)}
      else
        {duration, caps} = state.awaiting_caps
        {[caps: {:output, caps}], Segment.Helper.get_discontinuity_segment(state, duration)}
      end

    case segment do
      {:ok, segment, state} ->
        {buffer, state} = generate_segment(segment, ctx, state)
        actions = [buffer: {:output, buffer}] ++ caps_action ++ [redemand: :output]
        {{:ok, actions}, state}

      {:error, :not_enough_data} ->
        {{:ok, redemand: :output}, state}
    end
  end

  @impl true
  def handle_pad_added(Pad.ref(:input, _id) = pad, _ctx, state) do
    {track_id, state} = Map.get_and_update!(state, :next_track_id, &{&1, &1 + 1})

    state
    |> put_in([:pad_to_end_timestamp, pad], 0)
    |> put_in([:pad_to_track, pad], track_id)
    |> put_in([:samples, pad], [])
    |> then(&{:ok, &1})
  end

  @impl true
  def handle_pad_removed(Pad.ref(:input, _id) = pad, _ctx, state),
    do:
      state
      |> Map.update!(:pad_to_track, &Map.delete(&1, pad))
      |> Map.update!(:pad_to_end_timestamp, &Map.delete(&1, pad))
      |> Map.update!(:samples, &Map.delete(&1, pad))
      |> then(&{:ok, &1})

  @impl true
  def handle_caps(pad, %Membrane.MP4.Payload{} = caps, ctx, state) do
    state =
      update_in(state, [:pad_to_track, pad], fn tr ->
        track_id =
          case tr do
            %Track{} -> tr.id
            _otherwise -> tr
          end

        caps
        |> Map.from_struct()
        |> Map.take([:width, :height, :content, :timescale])
        |> Map.put(:id, track_id)
        |> Track.new()
      end)

    if Map.drop(ctx.pads, [:output, pad]) |> Map.values() |> Enum.all?(&(&1.caps != nil)) do
      caps = generate_caps(state)

      cond do
        is_nil(ctx.pads.output.caps) ->
          {{:ok, caps: {:output, caps}}, state}

        caps != ctx.pads.output.caps ->
          {:ok, %{state | awaiting_caps: {{:update_with_next, pad}, caps}}}

        true ->
          {:ok, state}
      end
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_end_of_stream(Pad.ref(:input, _track_id) = pad, ctx, state) do
    sample = state.duration_resolution_queue[pad]

    sample_metadata =
      Map.put(sample.metadata, :duration, hd(state.samples[pad]).metadata.duration)

    sample = %Buffer{sample | metadata: sample_metadata}

    state = update_in(state, [:samples, pad], &[sample | &1])

    if ctx.pads
       |> Map.delete(pad)
       |> Map.values()
       |> Enum.all?(&(&1.direction == :output or &1.end_of_stream?)) do
      with {:ok, segment, state} <- Segment.Helper.clear_samples(state) do
        {buffer, state} = generate_segment(segment, ctx, state)
        {{:ok, buffer: {:output, buffer}, end_of_stream: :output}, state}
      else
        {:error, :not_enough_data} -> {{:ok, end_of_stream: :output}, state}
      end
    else
      state = Map.update!(state, :pad_to_end_timestamp, &Map.delete(&1, pad))

      {{:ok, redemand: :output}, state}
    end
  end

  defp generate_caps(state) do
    tracks = Map.values(state.pad_to_track)

    header = Header.serialize(tracks)

    content_type =
      cond do
        length(tracks) > 1 -> :multiplex
        match?(%AAC{}, hd(tracks).content) -> :audio
        match?(%AVC1{}, hd(tracks).content) -> :video
      end

    %Membrane.CMAF.Track{
      content_type: content_type,
      header: header
    }
  end

  defp generate_segment(acc, ctx, state) do
    use Ratio, comparison: true

    tracks_data =
      Enum.map(acc, fn {track, samples} ->
        %{timescale: timescale} = ctx.pads[track].caps
        first_sample = hd(samples)
        last_sample = List.last(samples)
        samples = Enum.to_list(samples)

        samples_table =
          samples
          |> Enum.map(fn sample ->
            %{
              sample_size: byte_size(sample.payload),
              sample_flags: generate_sample_flags(sample.metadata),
              sample_duration:
                Helper.timescalify(
                  sample.metadata.duration,
                  timescale
                )
                |> Ratio.trunc()
            }
          end)

        samples_data = Enum.map_join(samples, & &1.payload)

        duration =
          (last_sample.dts - first_sample.dts + last_sample.metadata.duration)
          |> Helper.timescalify(timescale)

        %{
          id: state.pad_to_track[track].id,
          sequence_number: state.seq_num,
          elapsed_time: Helper.timescalify(state.elapsed_time, timescale) |> Ratio.trunc(),
          duration: duration,
          timescale: timescale,
          samples_table: samples_table,
          samples_data: samples_data
        }
      end)

    payload = Segment.serialize(tracks_data)

    duration =
      acc
      |> Map.values()
      |> Enum.map(&(Enum.map(&1, fn s -> Ratio.to_float(s.metadata.duration) end) |> Enum.sum()))
      |> Enum.min()
      |> floor()

    buffer = %Buffer{payload: payload, metadata: %{duration: duration}}

    state =
      state
      |> Map.update!(:elapsed_time, &(&1 + duration))
      |> Map.update!(:seq_num, &(&1 + 1))

    {buffer, state}
  end

  defp generate_sample_flags(metadata) do
    key_frame? = metadata |> Map.get(:mp4_payload, %{}) |> Map.get(:key_frame?, true)

    is_leading = 0
    depends_on = if key_frame?, do: 2, else: 1
    is_depended_on = 0
    has_redundancy = 0
    padding_value = 0
    non_sync = if key_frame?, do: 0, else: 1
    degradation_priority = 0

    <<0::4, is_leading::2, depends_on::2, is_depended_on::2, has_redundancy::2, padding_value::3,
      non_sync::1, degradation_priority::16>>
  end
end
