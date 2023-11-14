defmodule Membrane.MP4.Demuxer.ISOM.TransmuxingTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  require Membrane.Pad

  alias Membrane.MP4.Container
  alias Membrane.Pad

  alias Membrane.Testing.Pipeline

  defp perform_test(pipeline, in_path, out_path) do
    assert_end_of_stream(pipeline, :sink, :input, 6000)
    refute_sink_buffer(pipeline, :sink, _buffer, 0)

    assert :ok == Pipeline.terminate(pipeline)

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

    Pipeline.start_link_supervised!(spec: structure)
  end
end
