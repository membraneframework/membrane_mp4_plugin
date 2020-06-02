defmodule Membrane.MP4.Payloader.H264 do
  @moduledoc """
  Payloads H264 stream so it can be embedded in MP4.

  This element requires `h264.nalus` metadata entry to be present in each buffer.
  This can be achieved by setting `attach_nalus?` option to `true` in the h264
  parser.
  """
  use Bunch
  use Membrane.Filter

  alias Membrane.Buffer
  alias Membrane.MP4.Payload.AVC1

  @nalu_length_size 4

  def_input_pad :input,
    demand_unit: :buffers,
    caps: {Membrane.Caps.Video.H264, stream_format: :byte_stream, alignment: :au}

  def_output_pad :output, caps: Membrane.MP4.Payload

  @impl true
  def handle_init(_) do
    {:ok, %{}}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  @impl true
  def handle_process(:input, buffer, ctx, state) do
    %Buffer{payload: payload, metadata: metadata} = buffer
    {nalus, metadata} = process_metadata(metadata)
    nalus = Enum.map(nalus, &Map.put(&1, :payload, :binary.part(payload, &1.unprefixed_poslen)))

    caps =
      if ctx.pads.output.caps do
        []
      else
        [caps: {:output, generate_caps(ctx.pads.input.caps, nalus)}]
      end

    payload = nalus |> Enum.map(&process_nalu/1) |> Enum.join()
    buffer = %Buffer{payload: payload, metadata: metadata}
    {{:ok, caps ++ [buffer: {:output, buffer}, redemand: :output]}, state}
  end

  @impl true
  def handle_caps(:input, _caps, _ctx, state) do
    {:ok, state}
  end

  defp process_nalu(%{metadata: %{h264: %{type: type}}}) when type in [:aud, :sps, :pps] do
    <<>>
  end

  defp process_nalu(%{payload: payload}) do
    <<byte_size(payload)::integer-size(@nalu_length_size)-unit(8), payload::binary>>
  end

  defp process_metadata(metadata) do
    %{h264: %{key_frame?: key_frame?}} = metadata

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

    metadata
    |> Map.merge(%{mp4_sample_flags: flags, key_frame?: key_frame?})
    |> pop_in([:h264, :nalus])
  end

  defp generate_caps(input_caps, nalus) do
    {timescale, sample_duration} = input_caps.framerate

    %Membrane.MP4.Payload{
      timescale: timescale * 1024,
      sample_duration: sample_duration * 1024,
      width: input_caps.width,
      height: input_caps.height,
      content: %AVC1{avcc: generate_avcc(nalus)}
    }
  end

  defp generate_avcc(nalus) do
    %{sps: sps, pps: pps} = Enum.group_by(nalus, & &1.metadata.h264.type, & &1.payload)
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
end
