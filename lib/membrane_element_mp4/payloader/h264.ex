defmodule Membrane.Element.MP4.Payloader.H264 do
  use Bunch
  use Membrane.Filter

  alias Membrane.Buffer
  alias Membrane.Caps.MP4.Payload.AVC1

  @nalu_length_size 4

  def_input_pad :input,
    demand_unit: :buffers,
    caps: {Membrane.Caps.Video.H264, stream_format: :byte_stream, alignment: :nal}

  def_output_pad :output, caps: Membrane.Caps.MP4.Payload

  @impl true
  def handle_init(_) do
    {:ok, %{access_unit: [], access_unit_info: nil}}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  @impl true
  def handle_process(:input, %Buffer{} = buffer, ctx, state) do
    {actions, state} = maybe_send_access_unit(buffer.metadata[:access_unit], ctx, state)
    state = state |> Map.update!(:access_unit, &[buffer | &1])
    {{:ok, actions ++ [redemand: :output]}, state}
  end

  @impl true
  def handle_end_of_stream(:input, ctx, state) do
    {actions, state} = maybe_send_access_unit(:eos, ctx, state)
    {{:ok, actions ++ [end_of_stream: :output]}, state}
  end

  @impl true
  def handle_caps(:input, _caps, _ctx, state) do
    {:ok, state}
  end

  defp maybe_send_access_unit(nil, _ctx, state) do
    {[], state}
  end

  defp maybe_send_access_unit(new_access_unit_info, _ctx, %{access_unit: []} = state) do
    {[], %{state | access_unit_info: new_access_unit_info}}
  end

  defp maybe_send_access_unit(new_access_unit_info, ctx, state) do
    access_unit = state.access_unit |> Enum.reverse()

    caps =
      if ctx.pads.output.caps do
        []
      else
        [caps: {:output, generate_caps(ctx.pads.input.caps, access_unit)}]
      end

    payload = access_unit |> Enum.map(&process_nalu/1) |> Enum.join()

    buffer =
      %Buffer{payload: payload, metadata: generate_access_unit_metadata(state.access_unit_info)}
      ~> [buffer: {:output, &1}]

    {caps ++ buffer, %{state | access_unit: [], access_unit_info: new_access_unit_info}}
  end

  defp process_nalu(%Buffer{metadata: %{type: type}})
       when type in [:aud, :sps, :pps] do
    <<>>
  end

  defp process_nalu(buffer) do
    nalu = unprefix(buffer.payload)
    <<byte_size(nalu)::integer-size(@nalu_length_size)-unit(8), nalu::binary>>
  end

  defp unprefix(<<0, 0, 0, 1, nalu::binary>>), do: nalu
  defp unprefix(<<0, 0, 1, nalu::binary>>), do: nalu

  defp generate_caps(input_caps, access_unit) do
    avcc = generate_avcc(access_unit)
    {timescale, sample_duration} = input_caps.framerate

    %Membrane.Caps.MP4.Payload{
      timescale: timescale,
      sample_duration: sample_duration,
      width: input_caps.width,
      height: input_caps.height,
      content: %AVC1{avcc: avcc},
      inter_frames?: true
    }
  end

  defp generate_avcc(access_unit) do
    %{sps: sps, pps: pps} =
      access_unit
      |> Enum.group_by(
        fn
          %Buffer{metadata: %{type: type}} when type in [:sps, :pps] -> type
          _ -> nil
        end,
        &unprefix(&1.payload)
      )

    <<_idc_and_type, profile, compatibility, level, _::binary>> = hd(sps)

    <<1, profile, compatibility, level, 0b111111::6, @nalu_length_size - 1::2-integer, 0b111::3,
      length(sps)::5-integer, encode_parameter_sets(sps)::binary, length(pps)::8-integer,
      encode_parameter_sets(pps)::binary>>
  end

  defp encode_parameter_sets(pss) do
    pss
    |> Enum.map(&<<byte_size(&1)::16-integer, &1::binary>>)
    |> Enum.join()
  end

  defp generate_access_unit_metadata(access_unit_info) do
    %{key_frame?: key_frame?} = access_unit_info

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

    Map.merge(access_unit_info, %{mp4_sample_flags: flags})
  end
end
