defmodule Membrane.MP4.PayloaderDepayloaderTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  require Membrane.Pad

  alias Membrane.Testing.Pipeline

  @tag :tmp_dir
  test "if a H.264 track, after payloading, is depayloaded to the original stream", %{
    tmp_dir: dir
  } do
    in_path = "test/fixtures/in_video.h264"
    out_path = Path.join(dir, "out.h264")

    spec = [
      child(:file, %Membrane.File.Source{location: in_path})
      |> child(:parser, %Membrane.H264.Parser{
        generate_best_effort_timestamps: %{framerate: {30, 1}}
      })
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

  @tag :tmp_dir
  test "if an AAC track, after payloading, is depayloaded to the original stream", %{tmp_dir: dir} do
    in_path = "test/fixtures/in_audio.aac"
    out_path = Path.join(dir, "out.aac")

    structure = [
      child(:file, %Membrane.File.Source{location: in_path})
      |> child({:parser, :in}, %Membrane.AAC.Parser{
        in_encapsulation: :ADTS,
        out_encapsulation: :none
      })
      |> child(:payloader, Membrane.MP4.Payloader.AAC)
      |> child(:depayloader, Membrane.MP4.Depayloader.AAC)
      |> child({:parser, :out}, %Membrane.AAC.Parser{
        in_encapsulation: :none,
        out_encapsulation: :ADTS
      })
      |> child(:sink, %Membrane.File.Sink{location: out_path})
    ]

    pipeline = Pipeline.start_link_supervised!(structure: structure)

    assert_end_of_stream(pipeline, :sink, :input, 6000)
    refute_sink_buffer(pipeline, :sink, _buffer, 0)

    assert :ok == Pipeline.terminate(pipeline)

    in_aac = File.read!(in_path)
    out_aac = File.read!(out_path)

    assert in_aac == out_aac
  end
end
