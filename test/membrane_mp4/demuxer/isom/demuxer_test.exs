defmodule Membrane.MP4.Demuxer.ISOM.IntegrationTest do
  use ExUnit.Case, async: true

  import Membrane.Testing.Assertions

  alias Membrane.ParentSpec
  alias Membrane.Testing.Pipeline

  # Fixtures used in demuxer tests below were generated with `chunk_duration` option set to `Membrane.Time.seconds(1)`.

  defp assert_files_equal(file_a, file_b) do
    assert {:ok, a} = File.read(file_a)
    assert {:ok, b} = File.read(file_b)
    assert a == b
  end

  defp out_path_for(filename), do: "/tmp/out_#{filename}"
  defp ref_path_for(filename), do: "test/fixtures/payloaded_#{filename}"

  defp prepare_test(filename) do
    out_path = out_path_for(filename)
    File.rm(out_path)
    on_exit(fn -> File.rm(out_path) end)
  end

  defp perform_test(pid, filename) do
    out_path = out_path_for(filename)
    ref_path = ref_path_for(filename)

    assert_end_of_stream(pid, :sink, :input)
    refute_sink_buffer(pid, :sink, _buffer, 0)

    assert :ok == Pipeline.terminate(pid, blocking?: true)

    assert_files_equal(out_path, ref_path)
  end

  describe "Demuxer.ISOM should demux" do
    @tag :skip
    test "single H264 track" do
      prepare_test("video")

      children = [
        file: %Membrane.File.Source{location: "test/fixtures/isom/ref_video_fast_start.mp4"},
        demuxer: Membrane.MP4.Demuxer.ISOM,
        sink: %Membrane.File.Sink{location: out_path_for("video")}
      ]

      assert {:ok, pid} = Pipeline.start_link(links: ParentSpec.link_linear(children))
      perform_test(pid, "video")
    end

    @tag :skip
    test "single AAC track" do
      prepare_test("aac")

      children = [
        file: %Membrane.File.Source{location: "test/fixtures/isom/ref_audio_fast_start.mp4"},
        demuxer: Membrane.MP4.Demuxer.ISOM,
        sink: %Membrane.File.Sink{location: out_path_for("aac")}
      ]

      assert {:ok, pid} = Pipeline.start(links: ParentSpec.link_linear(children))
      perform_test(pid, "aac")
    end
  end
end
