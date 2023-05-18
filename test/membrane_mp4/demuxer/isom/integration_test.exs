defmodule Membrane.MP4.Demuxer.ISOM.IntegrationTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  require Membrane.Pad

  alias Membrane.MP4.Container
  alias Membrane.Pad

  alias Membrane.Testing.Pipeline

  defp perform_test(pid, in_path, out_path) do
    assert_end_of_stream(pid, :sink, :input, 6000)
    refute_sink_buffer(pid, :sink, _buffer, 0)

    assert :ok == Pipeline.terminate(pid, blocking?: true)

    {in_mp4, <<>>} = File.read!(in_path) |> Container.parse!()
    {out_mp4, <<>>} = File.read!(out_path) |> Container.parse!()

    assert out_mp4[:moov].children[:mvhd] == in_mp4[:moov].children[:mvhd]

    assert out_mp4[:moov].children[:trak].children[:thkd] ==
             in_mp4[:moov].children[:trak].children[:thkd]

    assert out_mp4[:mdat] == in_mp4[:mdat]
  end

  @tag :tmp_dir
  test "single H264 track", %{tmp_dir: dir} do
    in_path = "test/fixtures/isom/ref_video_fast_start.mp4"
    out_path = Path.join(dir, "out")

    pipeline =
      start_testing_pipeline!(
        input_file: in_path,
        output_file: out_path
      )

    perform_test(pipeline, in_path, out_path)
  end

  @tag :tmp_dir
  test "single AAC track", %{tmp_dir: dir} do
    in_path = "test/fixtures/isom/ref_aac_fast_start.mp4"
    out_path = Path.join(dir, "out")

    pipeline =
      start_testing_pipeline!(
        input_file: in_path,
        output_file: out_path
      )

    perform_test(pipeline, in_path, out_path)
  end

  @tag :tmp_dir
  test "single aac track payloaded and depayloaded", %{tmp_dir: dir} do
    in_path = "test/fixtures/in_audio.aac"
    out_path = Path.join(dir, "out")
    in_changed_encapsulation_path = Path.join(dir, "out_orig")

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

  defp start_testing_pipeline!(opts) do
    structure = [
      child(:file, %Membrane.File.Source{location: opts[:input_file]})
      |> child(:demuxer, Membrane.MP4.Demuxer.ISOM)
      |> via_out(Pad.ref(:output, 1))
      |> child(:muxer, %Membrane.MP4.Muxer.ISOM{
        chunk_duration: Membrane.Time.seconds(1),
        fast_start: true
      })
      |> child(:sink, %Membrane.File.Sink{location: opts[:output_file]})
    ]

    Pipeline.start_link_supervised!(structure: structure)
  end
end
