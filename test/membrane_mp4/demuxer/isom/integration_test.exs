defmodule Membrane.MP4.Demuxer.ISOM.IntegrationTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  require Membrane.Pad

  alias Membrane.MP4.Container
  alias Membrane.Pad

  alias Membrane.Testing.Pipeline

  defmodule DebugFilter do
    use Membrane.Filter

    def_input_pad :input,
      demand_unit: :buffers,
      demand_mode: :auto,
      accepted_format: _any

    def_output_pad :output,
      demand_mode: :auto,
      accepted_format: _any

    def handle_process(:input, buffer, _ctx, state) do
      # IO.inspect(buffer, label: :buffer)
      {[buffer: {:output, buffer}], state}
    end
  end

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
  test "if a H.264 stream, after payloading, is depayloaded to the original stream", %{
    tmp_dir: dir
  } do
    in_path = "test/fixtures/in_video.h264"
    out_path = Path.join(dir, "out")

    spec = [
      child(:file, %Membrane.File.Source{location: in_path})
      |> child(:parser, %Membrane.H264.FFmpeg.Parser{framerate: {30, 1}, attach_nalus?: true})
      |> child(:payloader, Membrane.MP4.Payloader.H264)
      |> child(:depayloader, Membrane.MP4.Depayloader.H264)
      |> child(:sink, %Membrane.File.Sink{location: out_path})
    ]

    pipeline = Pipeline.start_link_supervised!(structure: spec)
    assert_end_of_stream(pipeline, :sink, :input)

    in_file = File.read!(in_path)
    out_file = File.read!(out_path)
    assert in_file == out_file
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
