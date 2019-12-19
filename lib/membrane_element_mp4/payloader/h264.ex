defmodule Membrane.Element.MP4.Payloader.H264 do
  use Bunch
  use Membrane.Filter

  alias Membrane.Buffer

  @nalu_length_size 4

  def_input_pad :input,
    demand_unit: :buffers,
    caps: {Membrane.Caps.Video.H264, stream_format: :byte_stream, alignment: :nal}

  def_output_pad :output, caps: {Membrane.Caps.MP4.Payload, content_type: :avc1}

  @impl true
  def handle_init(_) do
    {:ok, %{au: [], au_info: nil}}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  @impl true
  def handle_process(:input, %Buffer{} = buffer, ctx, state) do
    {actions, state} = maybe_send_au(buffer.metadata[:access_unit], ctx, state)
    state = state |> Map.update!(:au, &[buffer | &1])
    {{:ok, actions ++ [redemand: :output]}, state}
  end

  @impl true
  def handle_end_of_stream(:input, ctx, state) do
    {actions, state} = maybe_send_au(:eos, ctx, state)
    {{:ok, actions ++ [end_of_stream: :output]}, state}
  end

  @impl true
  def handle_caps(:input, _caps, _ctx, state) do
    {:ok, state}
  end

  defp maybe_send_au(nil, _ctx, state) do
    {[], state}
  end

  defp maybe_send_au(new_au_info, _ctx, %{au: []} = state) do
    {[], %{state | au_info: new_au_info}}
  end

  defp maybe_send_au(new_au_info, ctx, state) do
    au = state.au |> Enum.reverse()

    caps =
      if ctx.pads.output.caps do
        []
      else
        [caps: {:output, generate_caps(ctx.pads.input.caps, au)}]
      end

    payload = au |> Enum.map(&process_nalu/1) |> Enum.join()

    buffer =
      %Buffer{payload: payload, metadata: generate_au_metadata(state.au_info)}
      ~> [buffer: {:output, &1}]

    {caps ++ buffer, %{state | au: [], au_info: new_au_info}}
  end

  defp process_nalu(%Buffer{metadata: %{type: type}})
       when type in [:aud, :sps, :pps] do
    <<>>
  end

  defp process_nalu(buffer) do
    nalu = unprefix(buffer.payload)
    <<byte_size(nalu)::unsigned-integer-size(@nalu_length_size)-unit(8)-big, nalu::binary>>
  end

  defp unprefix(<<0, 0, 0, 1, nalu::binary>>), do: nalu
  defp unprefix(<<0, 0, 1, nalu::binary>>), do: nalu

  defp generate_caps(input_caps, au) do
    avcc = generate_avcc(au)
    {timescale, sample_duration} = input_caps.framerate

    %Membrane.Caps.MP4.Payload{
      timescale: timescale,
      sample_duration: sample_duration,
      width: input_caps.width,
      height: input_caps.height,
      content_type: :avc1,
      type_specific: %{avcc: avcc}
    }
  end

  defp generate_avcc(au) do
    %{sps: sps, pps: pps} =
      au
      |> Enum.group_by(
        fn
          %Buffer{metadata: %{type: type}} when type in [:sps, :pps] -> type
          _ -> nil
        end,
        &unprefix(&1.payload)
      )

    <<_idc_and_type, profile, compatibility, level, _::binary>> = hd(sps)

    <<1, profile, compatibility, level, 0b111111::6,
      @nalu_length_size - 1::unsigned-integer-size(2), 0b111::3,
      length(sps)::unsigned-integer-size(5), encode_parameter_sets(sps)::binary,
      length(pps)::unsigned-integer-size(8), encode_parameter_sets(pps)::binary>>
  end

  defp encode_parameter_sets(pss) do
    pss
    |> Enum.map(&<<byte_size(&1)::unsigned-integer-size(16), &1::binary>>)
    |> Enum.join()
  end

  defp generate_au_metadata(au_info) do
    %{contains_key_frame?: key_frame?} = au_info

    is_leading = 0
    depends_on = if key_frame?, do: 2, else: 1
    is_depended_on = 0
    has_redundancy = 0
    padding_value = 0
    non_sync = if key_frame?, do: 0, else: 1
    degradation_priority = 0

    flags =
      <<0::4, is_leading::2, depends_on::2, is_depended_on::2, has_redundancy::2,
        padding_value::3, non_sync::1, degradation_priority::16>>

    Map.merge(au_info, %{mp4_sample_flags: flags})
  end
end
