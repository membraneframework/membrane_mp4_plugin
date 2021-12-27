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
        old_input_caps: nil,
        new_output_caps: nil,
        pad_to_track: %{},
        next_track_id: 1,
        pad_to_end_timestamp: %{},
        samples: %{},
        samples_total_duration: %{},
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
        duration = sample.dts - prev_sample.dts
        prev_sample_metadata = Map.put(prev_sample.metadata, :duration, duration)
        prev_sample = %Buffer{prev_sample | metadata: prev_sample_metadata}

        put_in(state, [:pad_to_end_timestamp, pad], prev_sample.dts)
        |> put_in([:duration_resolution_queue, pad], sample)
        |> update_in([:samples, pad], &Qex.push(&1, prev_sample))
        |> update_in([:samples_total_duration, pad], &(&1 + duration))
      end

    case maybe_get_segment?(state) do
      {:ok, segment, state} ->
        {buffer, state} = generate_segment(segment, ctx, state)
        {{:ok, buffer: {:output, buffer}}, state}

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
    |> put_in([:samples, pad], Qex.new())
    |> put_in([:samples_total_duration, pad], 0)
    |> then(&{:ok, &1})
  end

  @impl true
  def handle_pad_removed(Pad.ref(:input, _id) = pad, _ctx, state),
    do:
      state
      |> Map.update!(:pads_id_mapping, &Map.delete(&1, pad))
      |> Map.update!(:pad_to_end_timestamp, &Map.delete(&1, pad))
      |> Map.update!(:samples, &Map.delete(&1, pad))
      |> Map.update!(:samples_total_duration, &Map.delete(&1, pad))
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
      header =
        state.pad_to_track
        |> Map.values()
        |> Header.serialize()

      caps_content_type =
        case caps.content do
          %AVC1{} -> :video
          %AAC{} -> :audio
        end

      caps = %Membrane.CMAF.Track{
        content_type: :video,
        # if(Enum.count(state.pad_to_track) > 1, do: :muxed_av_stream, else: caps_content_type),
        header: header
      }

      {{:ok, caps: {:output, caps}}, state}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_end_of_stream(Pad.ref(:input, _track_id) = pad, ctx, state) do
    sample = state.duration_resolution_queue[pad]

    sample_metadata =
      Map.put(sample.metadata, :duration, Qex.last!(state.samples[pad]).metadata.duration)

    sample = %Buffer{sample | metadata: sample_metadata}
    state = update_in(state, [:samples, pad], &Qex.push(&1, sample))

    if ctx.pads
       |> Map.delete(pad)
       |> Map.values()
       |> Enum.all?(&(&1.direction == :output or &1.end_of_stream?)) do
      {:ok, segment, state} = maybe_get_segment?(state, [:empty_samples_buffer])
      {buffer, state} = generate_segment(segment, ctx, state)
      {{:ok, buffer: {:output, buffer}, end_of_stream: :output}, state}
    else
      state =
        state
        |> Map.update!(:pad_to_end_timestamp, &Map.delete(&1, pad))

      {{:ok, redemand: :output}, state}
    end
  end

  defp generate_segment(acc, ctx, state) do
    use Ratio, comparison: true

    tracks_data =
      Enum.map(acc, fn {track, samples} ->
        %{timescale: timescale} = ctx.pads[track].caps
        first_sample = Qex.first!(samples)
        last_sample = state.duration_resolution_queue[track]
        samples = Enum.to_list(samples) ++ [%{dts: last_sample.dts, payload: <<>>}]

        samples_table =
          samples
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.map(fn [sample, next_sample] ->
            %{
              sample_size: byte_size(sample.payload),
              sample_flags: generate_sample_flags(sample.metadata),
              sample_duration:
                Helper.timescalify(
                  next_sample.dts - sample.dts,
                  timescale
                )
                |> Ratio.trunc()
            }
          end)

        samples_data = Enum.map_join(samples, & &1.payload)

        duration =
          (last_sample.dts - first_sample.dts) |> Ratio.trunc() |> Helper.timescalify(timescale)

        %{
          id: state.pad_to_track[track].id,
          sequence_number: state.seq_num,
          elapsed_time: state.elapsed_time,
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
      |> Enum.map(&(Enum.map(&1, fn s -> Ratio.trunc(s.metadata.duration) end) |> Enum.sum()))
      |> Enum.min()

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

  defp maybe_get_segment?(state, options \\ []) do
    durations = state.samples_total_duration |> Map.map(fn _entry -> 0 end)
    maybe_get_segment?(state, durations, %{}, options)
  end

  defp maybe_get_segment?(state, collected_duration, acc, options) do
    use Ratio, comparison: true

    segment_ready? =
      if Enum.member?(options, :empty_samples_buffer) do
        Map.values(state.samples_total_duration)
        |> Enum.any?(&(&1 == 0))
      else
        Enum.all?(
          collected_duration,
          fn {key, duration} ->
            use Ratio, comparison: true

            key_frame_next? =
              case Qex.first(state.samples[key]) do
                :empty ->
                  false

                {:value, %Buffer{metadata: metadata}} ->
                  get_in(metadata, [:mp4_payload, :key_frame?]) || true
              end

            key_frame_optional? = Keyword.get(options, :keyframe_optional?, false)

            duration >= state.segment_duration and (key_frame_optional? or key_frame_next?)
          end
        )
      end

    if segment_ready? do
      {:ok, acc, state}
    else
      {pad, _total_duration} = Enum.min_by(collected_duration, &Ratio.to_float(Bunch.value(&1)))

      case Qex.pop(state.samples[pad]) do
        {{:value, sample}, new_samples_queue} ->
          acc = Map.get(acc, pad, Qex.new()) |> Qex.push(sample) |> then(&Map.put(acc, pad, &1))

          state =
            put_in(state, [:samples, pad], new_samples_queue)
            |> update_in([:samples_total_duration, pad], &(&1 - sample.metadata.duration))

          collected_duration =
            Map.update!(collected_duration, pad, &(&1 + sample.metadata.duration))

          maybe_get_segment?(state, collected_duration, acc, options)

        {:empty, _t} ->
          {:error, :not_enough_data}
      end
    end
  end
end
