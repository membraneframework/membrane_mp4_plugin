defmodule Membrane.Element.MP4.CMAF.Muxer do
  use Membrane.Filter

  alias __MODULE__.{Init, Fragment}
  alias Membrane.{Buffer, Time}

  def_input_pad :input, demand_unit: :buffers, caps: Membrane.Caps.MP4.Payload
  def_output_pad :output, caps: {Membrane.Caps.HTTPAdaptiveStream.Channel, container: :cmaf}

  @impl true
  def handle_init(_) do
    {:ok,
     %{
       samples_per_subsegment: 125,
       pts_delay_in_samples: 2,
       seq_num: 0,
       sample_cnt: 0,
       samples: []
     }}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {{:ok, demand: {:input, size * state.samples_per_subsegment}}, state}
  end

  @impl true
  def handle_process(
        :input,
        %Buffer{} = sample,
        _ctx,
        %{samples_per_subsegment: per_subs, sample_cnt: cnt} = state
      )
      when cnt < per_subs - 1 do
    {:ok, state |> Map.update!(:sample_cnt, &(&1 + 1)) |> Map.update!(:samples, &[sample | &1])}
  end

  @impl true
  def handle_process(:input, %Buffer{} = sample, ctx, state) do
    state = Map.update!(state, :samples, &[sample | &1])
    buffer = generate_fragment(ctx.pads.input.caps, state)
    state = %{state | sample_cnt: 0, samples: []} |> Map.update!(:seq_num, &(&1 + 1))
    {{:ok, buffer: {:output, buffer}}, state}
  end

  @impl true
  def handle_caps(:input, %Membrane.Caps.MP4.Payload{} = caps, _ctx, state) do
    caps = %Membrane.Caps.HTTPAdaptiveStream.Channel{
      container: :cmaf,
      init_name: "init.mp4",
      fragment_prefix: "fileSequence",
      fragment_extension: "m4s",
      init:
        caps
        |> Map.take([:timescale, :width, :height, :content_type, :type_specific])
        |> Init.serialize()
    }

    {{:ok, caps: {:output, caps}}, state}
  end

  @impl true
  def handle_end_of_stream(:input, ctx, state) do
    buffer = generate_fragment(ctx.pads.input.caps, state)
    {{:ok, buffer: {:output, buffer}, end_of_stream: :output}, state}
  end

  defp generate_fragment(caps, state) do
    samples = state.samples |> Enum.reverse()

    samples_table =
      samples
      |> Enum.map(
        &%{sample_size: byte_size(&1.payload), sample_flags: &1.metadata.mp4_sample_flags}
      )

    samples_data = samples |> Enum.map(& &1.payload) |> Enum.join()

    payload =
      Fragment.serialize(%{
        sequence_number: state.seq_num,
        timescale: caps.timescale,
        sample_duration: caps.sample_duration,
        pts_delay: state.pts_delay_in_samples * caps.sample_duration,
        samples_table: samples_table,
        samples_data: samples_data,
        samples_per_subsegment: state.samples_per_subsegment
      })

    duration = Ratio.new(length(samples) * Time.seconds(caps.sample_duration), caps.timescale)
    %Buffer{payload: payload, metadata: %{duration: duration}}
  end
end
