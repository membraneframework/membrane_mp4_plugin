defmodule Membrane.MP4.Payloader.AAC do
  @moduledoc """
  Payloads AAC stream so it can be embedded in MP4.

  Resources:
  - Packaging/Encapsulation And Setup Data section of https://wiki.multimedia.cx/index.php/Understanding_AAC
  """
  use Membrane.Filter

  def_input_pad :input, demand_unit: :buffers, caps: {Membrane.AAC, encapsulation: :none}

  def_output_pad :output, caps: Membrane.MP4.Payload

  def_options avg_bit_rate: [
                type: :integer,
                default: 0,
                description: "Average stream bitrate. Should be set to 0 if unknown."
              ],
              max_bit_rate: [
                type: :integer,
                default: 0,
                description: "Maximal stream bitrate. Should be set to 0 if unknown."
              ]

  @impl true
  def handle_caps(:input, caps, _ctx, state) do
    caps = %Membrane.MP4.Payload{
      content: %Membrane.MP4.Payload.AAC{
        esds: make_esds(caps, state),
        sample_rate: caps.sample_rate,
        channels: caps.channels
      },
      sample_duration: caps.samples_per_frame * caps.frames_per_buffer,
      timescale: caps.sample_rate
    }

    {{:ok, caps: {:output, caps}}, state}
  end

  @impl true
  def handle_process(:input, buffer, _ctx, state) do
    # TODO demistify sample flags constant below
    buffer = Bunch.Struct.put_in(buffer, [:metadata, :mp4_sample_flags], <<0x2000000::32>>)
    {{:ok, buffer: {:output, buffer}}, state}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  defp make_esds(caps, state) do
    aot_id = Membrane.AAC.profile_to_aot_id(caps.profile)
    frequency_id = Membrane.AAC.sample_rate_to_sampling_frequency_id(caps.sample_rate)
    channel_config_id = Membrane.AAC.channels_to_channel_config_id(caps.channels)
    frame_length_id = Membrane.AAC.samples_per_frame_to_frame_length_id(caps.samples_per_frame)

    depends_on_core_coder = 0
    extension_flag = 0

    section5 =
      <<aot_id::5, frequency_id::4, channel_config_id::4, frame_length_id::1,
        depends_on_core_coder::1, extension_flag::1>>
      |> make_esds_section(5)

    # 64 = mpeg4-audio
    object_type_id = 64
    # 5 = audio
    stream_type = 5
    upstream_flag = 0
    reserved_flag_set_to_1 = 1
    buffer_size = 0

    section4 =
      <<object_type_id, stream_type::6, upstream_flag::1, reserved_flag_set_to_1::1,
        buffer_size::24, state.max_bit_rate::32, state.avg_bit_rate::32, section5::binary>>
      |> make_esds_section(4)

    section6 = <<2>> |> make_esds_section(6)

    elementary_stream_id = 1
    stream_priority = 0

    <<elementary_stream_id::16, stream_priority, section4::binary, section6::binary>>
    |> make_esds_section(3)
  end

  defp make_esds_section(payload, section_no) do
    type_tag = <<128, 128, 128>>
    <<section_no, type_tag::binary, byte_size(payload), payload::binary>>
  end
end
