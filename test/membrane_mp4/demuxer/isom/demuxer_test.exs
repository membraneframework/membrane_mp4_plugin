defmodule Membrane.MP4.Demuxer.ISOM.IntegrationTest do
  use ExUnit.Case, async: true

  import Membrane.Testing.Assertions
  import Membrane.ParentSpec

  require Membrane.Pad

  alias Membrane.Pad
  alias Membrane.Testing.Pipeline

  # Fixtures used in demuxer tests below were generated with `chunk_duration` option set to `Membrane.Time.seconds(1)`.
  defp assert_files_equal(file_a, file_b) do
    assert {:ok, a} = File.read(file_a)
    assert {:ok, b} = File.read(file_b)
    assert a == b
  end

  defp get_out_path(),
    do:
      "tmp/out_" <>
        (:crypto.strong_rand_bytes(16) |> Base.url_encode64() |> binary_part(0, 16))

  defp ref_path_for(filename), do: "test/fixtures/payloaded/isom/payloaded_#{filename}"

  defp prepare_dir() do
    out_path = get_out_path()
    File.rm(out_path)
    on_exit(fn -> File.rm(out_path) end)
    out_path
  end

  defp perform_test(pid, filename, out_path) do
    ref_path = ref_path_for(filename)

    assert_end_of_stream(pid, :sink, :input)
    refute_sink_buffer(pid, :sink, _buffer, 0)

    assert :ok == Pipeline.terminate(pid, blocking?: true)

    assert_files_equal(out_path, ref_path)
  end

  test "demux single H264 track" do
    out_path = prepare_dir()

    children = [
      file: %Membrane.File.Source{
        location: "test/fixtures/isom/ref_video_new_fast_start.mp4"
      },
      demuxer: Membrane.MP4.Demuxer.ISOM,
      sink: %Membrane.File.Sink{location: out_path}
    ]

    links = [
      link(:file) |> to(:demuxer),
      link(:demuxer)
      |> via_out(Pad.ref(:output, 1))
      |> to(:sink)
    ]

    assert {:ok, pid} = Pipeline.start_link(children: children, links: links)
    perform_test(pid, "video_new", out_path)
  end

  test "demux single AAC track" do
    out_path = prepare_dir()

    children = [
      file: %Membrane.File.Source{location: "test/fixtures/isom/ref_aac_fast_start.mp4"},
      demuxer: Membrane.MP4.Demuxer.ISOM,
      sink: %Membrane.File.Sink{location: out_path}
    ]

    links = [
      link(:file) |> to(:demuxer),
      link(:demuxer)
      |> via_out(Pad.ref(:output, 1))
      |> to(:sink)
    ]

    assert {:ok, pid} = Pipeline.start(children: children, links: links)
    perform_test(pid, "aac", out_path)
  end
end
