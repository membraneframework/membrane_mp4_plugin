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
        # end_timestamp: %{},
        samples: %{}
        # duration_resolution_queue: %{},
        # elapsed_time: %{}
      })

    {:ok, state}
  end

  @impl true
  def handle_demand(:output, _size, _unit, _ctx, state) do
    {pad, _elapsed_time} =
      state.pad_to_track
      |> Stream.map(fn {key, value} -> {key, value.end_timestamp} end)
      |> Stream.reject(&is_nil(Bunch.value(&1)))
      |> Enum.min_by(&Ratio.to_float(Bunch.value(&1)))

    {{:ok, demand: {pad, 1}}, state}
  end

  @impl true
  def handle_process(Pad.ref(:input, _id) = pad, sample, ctx, state) do
    use Ratio, comparison: true

    state =
      state
      |> process_duration_queue(pad, sample)
      |> update_awaiting_caps(pad)

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

    track_data = %{
      id: track_id,
      track: nil,
      elapsed_time: 0,
      end_timestamp: 0,
      duration_resolution_queue: nil
    }

    state
    |> put_in([:pad_to_track, pad], track_data)
    |> put_in([:samples, pad], [])
    |> then(&{:ok, &1})
  end

  @impl true
  def handle_caps(pad, %Membrane.MP4.Payload{} = caps, ctx, state) do
    state =
      update_in(state, [:pad_to_track, pad], fn tr ->
        track =
          caps
          |> Map.from_struct()
          |> Map.take([:width, :height, :content, :timescale])
          |> Map.put(:id, tr.id)
          |> Track.new()

        %{tr | track: track}
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
    sample = state.pad_to_track[pad].duration_resolution_queue

    sample_metadata =
      Map.put(sample.metadata, :duration, hd(state.samples[pad]).metadata.duration)

    sample = %Buffer{sample | metadata: sample_metadata}

    state = update_in(state, [:samples, pad], &[sample | &1])

    if ctx.pads
       |> Map.drop([:output, pad])
       |> Map.values()
       |> Enum.all?(& &1.end_of_stream?) do
      with {:ok, segment, state} <- Segment.Helper.clear_samples(state) do
        {buffer, state} = generate_segment(segment, ctx, state)
        {{:ok, buffer: {:output, buffer}, end_of_stream: :output}, state}
      else
        {:error, :not_enough_data} -> {{:ok, end_of_stream: :output}, state}
      end
    else
      state = put_in(state, [:pad_to_track, pad, :end_timestamp], nil)

      {{:ok, redemand: :output}, state}
    end
  end

  defp generate_caps(state) do
    tracks = Enum.map(state.pad_to_track, fn {_pad, track_data} -> track_data.track end)

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
      Enum.map(acc, fn {pad, samples} ->
        %{timescale: timescale} = ctx.pads[pad].caps
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

        duration = last_sample.dts - first_sample.dts + last_sample.metadata.duration

        %{
          pad: pad,
          id: state.pad_to_track[pad].id,
          sequence_number: state.seq_num,
          elapsed_time:
            Helper.timescalify(state.pad_to_track[pad].elapsed_time, timescale) |> Ratio.trunc(),
          unscaled_duration: duration,
          duration: Helper.timescalify(duration, timescale),
          timescale: timescale,
          samples_table: samples_table,
          samples_data: samples_data
        }
      end)

    payload = Segment.serialize(tracks_data)

    duration =
      tracks_data
      |> Enum.map(& &1.unscaled_duration)
      |> Enum.max()
      |> floor()

    buffer = %Buffer{payload: payload, metadata: %{duration: duration}}

    state =
      Enum.reduce(tracks_data, state, fn %{unscaled_duration: duration, pad: pad}, state ->
        update_in(state, [:pad_to_track, pad, :elapsed_time], &(&1 + duration))
      end)
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

  defp process_duration_queue(state, pad, sample) do
    use Ratio

    prev_sample = state.pad_to_track[pad].duration_resolution_queue

    if is_nil(prev_sample) do
      put_in(state, [:pad_to_track, pad, :duration_resolution_queue], sample)
    else
      duration = Ratio.to_float(sample.dts - prev_sample.dts)
      prev_sample_metadata = Map.put(prev_sample.metadata, :duration, duration)
      prev_sample = %Buffer{prev_sample | metadata: prev_sample_metadata}

      put_in(state, [:pad_to_track, pad, :end_timestamp], prev_sample.dts)
      |> put_in([:pad_to_track, pad, :duration_resolution_queue], sample)
      |> update_in([:samples, pad], &[prev_sample | &1])
    end
  end

  defp update_awaiting_caps(%{awaiting_caps: {{:update_with_next, pad}, caps}} = state, pad) do
    use Ratio

    duration =
      state.pad_to_track[pad].duration_resolution_queue.dts - List.last(state.samples[pad]).dts

    %{state | awaiting_caps: {duration, caps}}
  end

  defp update_awaiting_caps(state, _pad), do: state
end
