defmodule Membrane.MP4.Demuxer.ISOM.IntgerationTest do
  use ExUnit.Case, async: true

  import Membrane.ParentSpec
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

    children = [
      file: %Membrane.File.Source{
        location: in_path
      },
      demuxer: Membrane.MP4.Demuxer.ISOM,
      muxer: %Membrane.MP4.Muxer.ISOM{
        chunk_duration: Membrane.Time.seconds(1),
        fast_start: true
      },
      sink: %Membrane.File.Sink{location: out_path}
    ]

    links = [
      link(:file) |> to(:demuxer),
      link(:demuxer)
      |> via_out(Pad.ref(:output, 1))
      |> to(:muxer),
      link(:muxer) |> to(:sink)
    ]

    assert {:ok, pid} = Pipeline.start_link(children: children, links: links)
    perform_test(pid, in_path, out_path)
  end

  @tag :tmp_dir
  test "single AAC track", %{tmp_dir: dir} do
    in_path = "test/fixtures/isom/ref_aac_fast_start.mp4"
    out_path = Path.join(dir, "out")

    children = [
      file: %Membrane.File.Source{
        location: in_path
      },
      demuxer: Membrane.MP4.Demuxer.ISOM,
      muxer: %Membrane.MP4.Muxer.ISOM{
        chunk_duration: Membrane.Time.seconds(1),
        fast_start: true
      },
      sink: %Membrane.File.Sink{location: out_path}
    ]

    links = [
      link(:file) |> to(:demuxer),
      link(:demuxer)
      |> via_out(Pad.ref(:output, 1))
      |> to(:muxer),
      link(:muxer) |> to(:sink)
    ]

    assert {:ok, pid} = Pipeline.start_link(children: children, links: links)
    perform_test(pid, in_path, out_path)
  end
end
