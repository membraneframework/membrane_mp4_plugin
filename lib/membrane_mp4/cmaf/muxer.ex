defmodule Membrane.MP4.CMAF.Muxer do
  @moduledoc """
  Puts payloaded stream into [Common Media Application Format](https://www.wowza.com/blog/what-is-cmaf),
  an MP4-based container commonly used in adaptive streaming over HTTP.

  Currently one input stream is supported.

  If a stream contains non-key frames (like H264 P or B frames), they should be marked
  with a `mp4_payload: %{key_frame?: false}` metadata entry.
  """
  use Membrane.Filter

  alias __MODULE__.{Header, Segment}
  alias Membrane.{Buffer, Time}
  alias Membrane.MP4.Payload.{AAC, AVC1}

  def_input_pad :input, demand_unit: :buffers, caps: Membrane.MP4.Payload
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
        elapsed_time: 0,
        samples: [],
        stale_caps: nil
      })

    {:ok, state}
  end

  @impl true
  def handle_demand(:output, _size, _unit, _ctx, state) do
    {{:ok, demand: {:input, 1}}, state}
  end

  @impl true
  def handle_process(:input, sample, ctx, state) do
    use Ratio, comparison: true
    %{caps: caps} = ctx.pads.input
    key_frame? = sample.metadata |> Map.get(:mp4_payload, %{}) |> Map.get(:key_frame?, true)

    cond do
      # if there are stale caps it means we need to generate a new segment
      # with them and next forward current caps as their propagation has been postponed
      key_frame? and state.stale_caps != nil ->
        {buffer, state} = generate_segment(state.stale_caps, sample.metadata, state)
        state = %{state | samples: [sample], stale_caps: nil}

        {{:ok, buffer: {:output, buffer}, caps: {:output, caps}, redemand: :output}, state}

      key_frame? and sample.metadata.timestamp - state.elapsed_time >= state.segment_duration ->
        {buffer, state} = generate_segment(caps, sample.metadata, state)
        state = %{state | samples: [sample]}
        {{:ok, buffer: {:output, buffer}, redemand: :output}, state}

      true ->
        state = Map.update!(state, :samples, &[sample | &1])
        {{:ok, redemand: :output}, state}
    end
  end

  @impl true
  def handle_caps(:input, %Membrane.MP4.Payload{} = caps, ctx, state) do
    caps = %Membrane.CMAF.Track{
      content_type:
        case caps.content do
          %AVC1{} -> :video
          %AAC{} -> :audio
        end,
      header:
        caps
        |> Map.take([:timescale, :width, :height, :content])
        |> Header.serialize()
    }

    # forwarding new caps action should be postponed so that
    # discontinuity event arrives after the last buffer representing old
    # caps is sent, if there are cached samples then postpone the caps propagation until a new segment gets created in handle_process
    {caps, state} =
      cond do
        # cache caps only if there are cached samples
        caps != ctx.pads.output.caps and state.samples != [] ->
          {[], %{state | stale_caps: ctx.pads.input.caps}}

        caps != ctx.pads.output.caps ->
          {[caps: {:output, caps}], state}

        true ->
          {[], state}
      end

    {{:ok, caps ++ [redemand: :output]}, state}
  end

  @impl true
  def handle_end_of_stream(:input, ctx, state) do
    last_timestamp = hd(state.samples).metadata.timestamp
    {buffer, state} = generate_segment(ctx.pads.input.caps, %{timestamp: last_timestamp}, state)
    {{:ok, buffer: {:output, buffer}, end_of_stream: :output}, state}
  end

  defp generate_segment(caps, next_metadata, state) do
    use Ratio, comparison: true
    %{timescale: timescale} = caps
    samples = state.samples |> Enum.reverse([%{metadata: next_metadata, payload: <<>>}])

    samples_table =
      samples
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [sample, next_sample] ->
        %{
          sample_size: byte_size(sample.payload),
          sample_flags: generate_sample_flags(sample.metadata),
          sample_duration:
            timescalify(next_sample.metadata.timestamp - sample.metadata.timestamp, timescale)
        }
      end)

    samples_data = samples |> Enum.map(& &1.payload) |> Enum.join()

    first_metadata = hd(samples).metadata
    duration = next_metadata.timestamp - first_metadata.timestamp
    metadata = Map.put(first_metadata, :duration, duration)

    payload =
      Segment.serialize(%{
        sequence_number: state.seq_num,
        elapsed_time: timescalify(state.elapsed_time, timescale),
        duration: timescalify(duration, timescale),
        timescale: timescale,
        samples_table: samples_table,
        samples_data: samples_data
      })

    buffer = %Buffer{payload: payload, metadata: metadata}

    state =
      %{state | samples: [], elapsed_time: next_metadata.timestamp}
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

  defp timescalify(time, timescale) do
    use Ratio
    Ratio.trunc(time * timescale / Time.second())
  end
end
