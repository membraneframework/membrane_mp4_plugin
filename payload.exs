
defmodule Payload do
  use Membrane.Pipeline

  def handle_init(_opts) do
    children = [
      # src: %Membrane.File.Source{
      #   location: "test/fixtures/video.h264"
      # },
      # parser: %Membrane.H264.FFmpeg.Parser{framerate: {30, 1}, attach_nalus?: true},
      # payloader: %Membrane.MP4.Payloader.H264{parameters_in_band?: true},
      # sink: %Membrane.File.Sink{location: "test/fixtures/payloaded/isom/video_payloaded"}

      # file: %Membrane.File.Source{location: "test/fixtures/audio.opus"},
      #   parser: %Membrane.Opus.Parser{input_delimitted?: true, delimitation: :undelimit},
      #   payloader: Membrane.MP4.Payloader.Opus,
      # sink: %Membrane.File.Sink{location: "test/fixtures/payloaded/isom/opus_payloaded"}

      file: %Membrane.File.Source{location: "test/fixtures/audio.aac"},
        parser: %Membrane.AAC.Parser{out_encapsulation: :none},
        payloader: Membrane.MP4.Payloader.AAC,
      sink: %Membrane.File.Sink{location: "test/fixtures/payloaded/isom/aac_payloaded"}

    ]

    links = Membrane.ParentSpec.link_linear(children)

    spec = %Membrane.ParentSpec{links: links}
    {{:ok, spec: spec, playback: :playing}, %{}}
  end

  @impl true
  def handle_element_end_of_stream(element, _ctx, state) do
    IO.inspect(element)
    {:ok, state}
  end
end

Payload.start_link()
