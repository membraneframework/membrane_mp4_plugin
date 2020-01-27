defmodule Membrane.Element.MP4.Payloader.AAC do
  use Membrane.Filter

  alias Membrane.Buffer
  def_input_pad :input, demand_unit: :buffers, caps: Membrane.Caps.AAC

  def_output_pad :output, caps: Membrane.Caps.MP4.Payload

  @impl true
  def handle_caps(:input, caps, _ctx, state) do
    caps = %Membrane.Caps.MP4.Payload{
      content: %Membrane.Caps.MP4.Payload.AAC{
        esds: make_esds(caps),
        sample_rate: caps.sample_rate,
        channels: caps.channels
      },
      sample_duration: caps.samples_per_frame * caps.frames_per_buffer,
      timescale: caps.sample_rate
    }

    {{:ok, caps: {:output, caps}}, state}
  end

  @impl true
  def handle_process(:input, %Buffer{payload: payload}, _ctx, state) do
    buffer = %Buffer{payload: payload, metadata: %{mp4_sample_flags: <<0x2000000::32>>}}
    {{:ok, buffer: {:output, buffer}}, state}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  defp make_esds(caps) do
    type_tag = <<128, 128, 128>>
    es_id = 1
    priority = 0
    section3_length = 34

    section3 = <<3, type_tag::binary, section3_length, es_id::16, priority>>

    section4_length = 20
    object_id = 64
    stream_type = 5
    upstream_flag = 0
    buffer_size = 0
    max_bit_rate = 62875
    avg_bit_rate = 62875

    section4 =
      <<4, type_tag::binary, section4_length, object_id, stream_type::6, upstream_flag::1, 1::1,
        buffer_size::24, max_bit_rate::32, avg_bit_rate::32>>

    section5_length = 2
    {:ok, profile_id} = Membrane.Caps.AAC.profile_to_profile_id(caps.profile)
    {:ok, frequency_id} = Membrane.Caps.AAC.sample_rate_to_sampling_frequency_id(caps.sample_rate)
    {:ok, channel_setup_id} = Membrane.Caps.AAC.channels_to_channel_setup_id(caps.channels)

    {:ok, frame_length_id} =
      Membrane.Caps.AAC.samples_per_frame_to_frame_length_id(caps.samples_per_frame)

    depends_on_core_coder = 0
    extension_flag = 0

    section5 =
      <<5, type_tag::binary, section5_length, profile_id::5, frequency_id::4, channel_setup_id::4,
        frame_length_id::1, depends_on_core_coder::1, extension_flag::1>>

    section6_length = 1
    section6 = <<6, type_tag::binary, section6_length, 2>>
    section3 <> section4 <> section5 <> section6
  end
end
