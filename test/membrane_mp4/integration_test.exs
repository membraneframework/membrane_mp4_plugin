defmodule Membrane.MP4.IntegrationTest do
  use ExUnit.Case, async: true
  import Membrane.Testing.Assertions
  alias Membrane.Testing

  defmodule Timestamper do
    use Membrane.Filter

    def_input_pad :input, caps: :any, demand_unit: :buffers
    def_output_pad :output, caps: :any

    @impl true
    def handle_init(_) do
      {:ok, 0}
    end

    @impl true
    def handle_demand(:output, size, :buffers, _ctx, state) do
      {{:ok, demand: {:input, size}}, state}
    end

    @impl true
    def handle_process(:input, buffer, ctx, timestamp) do
      buffer = Bunch.Struct.put_in(buffer, [:metadata, :timestamp], trunc(timestamp))
      {num, denom} = ctx.pads.input.caps.framerate
      time = Membrane.Time.second() * denom / num
      {{:ok, buffer: {:output, buffer}}, timestamp + time}
    end
  end

  test "video" do
    children = [
      file: %Membrane.Element.File.Source{location: "test/fixtures/in_video.h264"},
      parser: %Membrane.Element.FFmpeg.H264.Parser{alignment: :nal, framerate: {30, 1}},
      timestamper: Timestamper,
      payloader: Membrane.MP4.Payloader.H264,
      cmaf: Membrane.MP4.CMAF.Muxer,
      sink: Membrane.Testing.Sink
    ]

    assert {:ok, pipeline} =
             Testing.Pipeline.start_link(%Testing.Pipeline.Options{
               elements: children
             })

    :ok = Testing.Pipeline.play(pipeline)
    assert_pipeline_playback_changed(pipeline, _, :playing)

    assert_sink_caps(pipeline, :sink, %Membrane.CMAF.Track{header: header, content_type: :video})
    assert header == File.read!("test/fixtures/out_video_header.mp4")
    assert_sink_buffer(pipeline, :sink, buffer)
    assert buffer.payload == File.read!("test/fixtures/out_video_segment1.m4s")
    assert_sink_buffer(pipeline, :sink, buffer)
    assert buffer.payload == File.read!("test/fixtures/out_video_segment2.m4s")
    assert_end_of_stream(pipeline, :sink)
    refute_sink_buffer(pipeline, :sink, _)
  end
end
