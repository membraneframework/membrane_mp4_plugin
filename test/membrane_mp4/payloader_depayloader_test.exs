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

  @tag :tmp_dir
  test "if an AAC track, after payloading, is depayloaded to the original stream", %{tmp_dir: dir} do
    in_path = "test/fixtures/in_audio.aac"
    out_path = Path.join(dir, "out.aac")
    in_changed_encapsulation_path = Path.join(dir, "out_orig.aac")

    structure = [
      child(:file, %Membrane.File.Source{location: in_path})
      |> child({:parser, :in}, %Membrane.AAC.Parser{
        in_encapsulation: :ADTS,
        out_encapsulation: :none
      })
      |> child(:split, Membrane.Tee.Parallel)
      |> child(:payloader, Membrane.MP4.Payloader.AAC)
      |> child(:depayloader, Membrane.MP4.Depayloader.AAC)
      |> child({:sink, :depayloaded}, %Membrane.File.Sink{location: out_path}),
      # :ADTS -> :none -> :ADTS operation is not lossless so we need to compare
      # depayloaded file with the content with changed encapsulation
      get_child(:split)
      |> child({:sink, :original}, %Membrane.File.Sink{location: in_changed_encapsulation_path})
    ]

    pipeline = Pipeline.start_link_supervised!(structure: structure)

    assert_end_of_stream(pipeline, {:sink, :depayloaded}, :input, 6000)
    assert_end_of_stream(pipeline, {:sink, :original}, :input, 6000)
    refute_sink_buffer(pipeline, {:sink, :depayloaded}, _buffer, 0)

    assert :ok == Pipeline.terminate(pipeline, blocking?: true)

    in_aac = File.read!(in_changed_encapsulation_path)
    out_aac = File.read!(out_path)

    assert in_aac == out_aac
  end
end
