defmodule Membrane.MP4.PayloaderDepayloaderTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  require Membrane.Pad

  alias Membrane.Testing.Pipeline

  @tag :tmp_dir
  test "if a H.264 stream, after payloading, is depayloaded to the original stream", %{
    tmp_dir: dir
  } do
    in_path = "test/fixtures/in_video.h264"
    out_path = Path.join(dir, "out.h264")

    spec = [
      child(:file, %Membrane.File.Source{location: in_path})
      |> child(:parser, %Membrane.H264.FFmpeg.Parser{framerate: {30, 1}, attach_nalus?: true})
      |> child(:payloader, Membrane.MP4.Payloader.H264)
      |> child(:depayloader, Membrane.MP4.Depayloader.H264)
      |> child(:sink, %Membrane.File.Sink{location: out_path})
    ]

    pipeline = Pipeline.start_link_supervised!(structure: spec)
    assert_end_of_stream(pipeline, :sink, :input)
    refute_sink_buffer(pipeline, :sink, _buffer, 0)

    in_file = File.read!(in_path)
    out_file = File.read!(out_path)

    assert in_file == out_file
  end
end
