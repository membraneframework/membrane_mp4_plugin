defmodule Membrane.Element.MP4.CMAF.Muxer do
  use Membrane.Filter

  alias __MODULE__.{Init, Fragment}
  alias Membrane.{Buffer, Time}
  alias Membrane.Caps.MP4.Payload.{AVC1, AAC}

  def_input_pad :input, demand_unit: :buffers, caps: Membrane.Caps.MP4.Payload
  def_output_pad :output, caps: {Membrane.Caps.HTTPAdaptiveStream.Track, container: :cmaf}

  def_options fragment_duration: [
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
        sample_cnt: 0,
        sent_sample_cnt: 0,
        samples: []
      })

    {:ok, state}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, %{samples_per_subsegment: sps} = state) do
    {{:ok, demand: {:input, size * sps}}, state}
  end

  @impl true
  def handle_demand(:output, _size, :buffers, _ctx, state) do
    {:ok, state}
  end

  @impl true
  def handle_process(:input, buffer, ctx, state) do
    state =
      state
      |> Map.update!(:sample_cnt, &(&1 + 1))
      |> Map.update!(:samples, &[buffer | &1])

    %{caps: caps} = ctx.pads.input
    %{inter_frames?: inter_frames?} = caps
    %{samples_per_subsegment: samples_per_subsegment, sample_cnt: sample_cnt} = state

    cond do
      not inter_frames? and sample_cnt == samples_per_subsegment ->
        {buffer, state} = generate_fragment(caps, state)
        {{:ok, buffer: {:output, buffer}}, state}

      inter_frames? and buffer.metadata.key_frame? and sample_cnt > samples_per_subsegment ->
        {sample, state} =
          state
          |> Map.update!(:sample_cnt, &(&1 - 1))
          |> Map.get_and_update!(:samples, &{hd(&1), tl(&1)})

        {buffer, state} = generate_fragment(caps, state)
        state = %{state | samples: [sample], sample_cnt: 1}
        {{:ok, buffer: {:output, buffer}}, state}

      true ->
        {:ok, state}
    end
  end

  @impl true
  def handle_caps(:input, %Membrane.Caps.MP4.Payload{} = caps, _ctx, state) do
    state =
      state
      |> Map.put(
        :samples_per_subsegment,
        ceil(state.fragment_duration * caps.timescale / Time.seconds(caps.sample_duration))
      )

    caps = %Membrane.Caps.HTTPAdaptiveStream.Track{
      content_type:
        case caps.content do
          %AVC1{} -> :video
          %AAC{} -> :audio
        end,
      container: :cmaf,
      init_extension: ".mp4",
      fragment_extension: ".m4s",
      init:
        caps
        |> Map.take([:timescale, :width, :height, :content])
        |> Init.serialize()
    }

    {{:ok, caps: {:output, caps}, redemand: :output}, state}
  end

  @impl true
  def handle_end_of_stream(:input, ctx, state) do
    {buffer, state} = generate_fragment(ctx.pads.input.caps, state)
    {{:ok, buffer: {:output, buffer}, end_of_stream: :output}, state}
  end

  defp generate_fragment(caps, state) do
    samples = state.samples |> Enum.reverse()

    samples_table =
      samples
      |> Enum.map(
        &%{
          sample_size: byte_size(&1.payload),
          sample_flags: &1.metadata.mp4_sample_flags
        }
      )

    samples_data = samples |> Enum.map(& &1.payload) |> Enum.join()

    payload =
      Fragment.serialize(%{
        sequence_number: state.seq_num,
        sent_sample_cnt: state.sent_sample_cnt,
        timescale: caps.timescale,
        sample_duration: caps.sample_duration,
        samples_table: samples_table,
        samples_data: samples_data,
        samples_per_subsegment: state.samples_per_subsegment,
        content: caps.content
      })

    duration = Ratio.new(state.sample_cnt * Time.seconds(caps.sample_duration), caps.timescale)
    buffer = %Buffer{payload: payload, metadata: %{duration: duration}}

    state =
      %{state | samples: [], sample_cnt: 0}
      |> Map.update!(:seq_num, &(&1 + 1))
      |> Map.update!(:sent_sample_cnt, &(&1 + state.sample_cnt))

    {buffer, state}
  end
end
