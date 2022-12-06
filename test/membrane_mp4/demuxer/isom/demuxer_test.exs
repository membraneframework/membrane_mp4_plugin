defmodule Membrane.MP4.Demuxer.ISOM.DemuxerTest do
  use ExUnit.Case, async: true

  import Membrane.Testing.Assertions
  import Membrane.ParentSpec

  require Membrane.Pad
  require Membrane.RemoteControlled.Pipeline

  alias Membrane.{Pad, ParentSpec}
  alias Membrane.RemoteControlled.Message, as: RemoteMessage
  alias Membrane.RemoteControlled.Pipeline, as: RemotePipeline
  alias Membrane.Testing.Pipeline

  # Fixtures used in demuxer tests below were generated with `chunk_duration` option set to `Membrane.Time.seconds(1)`.
  defp assert_files_equal(file_a, file_b) do
    assert {:ok, a} = File.read(file_a)
    assert {:ok, b} = File.read(file_b)
    assert a == b
  end

  defp ref_path_for(filename), do: "test/fixtures/payloaded/isom/payloaded_#{filename}"

  defp perform_test(pid, filename, out_path) do
    ref_path = ref_path_for(filename)

    assert_end_of_stream(pid, :sink, :input)
    refute_sink_buffer(pid, :sink, _buffer, 0)

    assert :ok == Pipeline.terminate(pid, blocking?: true)

    assert_files_equal(out_path, ref_path)
  end

  describe "Demuxer should demux" do
    @tag :tmp_dir
    test "demux single H264 track", %{tmp_dir: dir} do
      out_path = Path.join(dir, "out")

      children = [
        file: %Membrane.File.Source{
          location: "test/fixtures/isom/ref_video_fast_start.mp4"
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
      perform_test(pid, "video", out_path)
    end

    @tag :tmp_dir
    test "demux single AAC track", %{tmp_dir: dir} do
      out_path = Path.join(dir, "out")

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

  describe "output pad connected after new_track_t() notification" do
    @tag :tmp_dir
    test "output pad connected after end_of_stream", %{tmp_dir: dir} do
      out_path = Path.join(dir, "out")
      filename = "test/fixtures/isom/ref_video_fast_start.mp4"

      {:ok, pipeline} =
        start_remote_pipeline(
          filename: filename,
          file_source_chunk_size: File.stat!(filename).size
        )

      assert_receive %RemoteMessage.Notification{
                       element: :demuxer,
                       data: {:new_track, 1, _payload},
                       from: _
                     },
                     2000

      assert_receive %RemoteMessage.EndOfStream{element: :demuxer, pad: :input, from: _}, 2000

      actions = [
        spec: %ParentSpec{
          children: [sink: %Membrane.File.Sink{location: out_path}],
          links: [
            link(:demuxer)
            |> via_out(Pad.ref(:output, 1))
            |> to(:sink)
          ]
        }
      ]

      RemotePipeline.exec_actions(pipeline, actions)
      assert_receive %RemoteMessage.EndOfStream{element: :sink, pad: :input, from: _}, 2000

      RemotePipeline.terminate(pipeline, blocking?: true)

      assert_files_equal(out_path, ref_path_for("video"))
    end

    @tag :tmp_dir
    test "output pad connected after moov box has been read", %{tmp_dir: dir} do
      out_path = Path.join(dir, "out")
      filename = "test/fixtures/isom/ref_video_fast_start.mp4"

      {:ok, pipeline} =
        start_remote_pipeline(
          filename: filename,
          file_source_chunk_size: File.stat!(filename).size - 1
        )

      assert_receive %RemoteMessage.Notification{
                       element: :demuxer,
                       data: {:new_track, 1, _payload},
                       from: _
                     },
                     2000

      actions = [
        spec: %ParentSpec{
          children: [sink: %Membrane.File.Sink{location: out_path}],
          links: [
            link(:demuxer)
            |> via_out(Pad.ref(:output, 1))
            |> to(:sink)
          ]
        }
      ]

      RemotePipeline.exec_actions(pipeline, actions)
      assert_receive %RemoteMessage.EndOfStream{element: :demuxer, pad: :input, from: _}, 2000
      assert_receive %RemoteMessage.EndOfStream{element: :sink, pad: :input, from: _}, 2000

      RemotePipeline.terminate(pipeline, blocking?: true)

      assert_files_equal(out_path, ref_path_for("video"))
    end
  end

  defp start_remote_pipeline(opts) do
    spec = %ParentSpec{
      children: [
        file: %Membrane.File.Source{
          location: opts[:filename],
          chunk_size: opts[:file_source_chunk_size]
        },
        demuxer: Membrane.MP4.Demuxer.ISOM
      ],
      links: [link(:file) |> to(:demuxer)]
    }

    actions = [spec: spec, playback: :playing]

    {:ok, pipeline} = RemotePipeline.start_link()
    RemotePipeline.exec_actions(pipeline, actions)
    RemotePipeline.subscribe(pipeline, %RemoteMessage.Notification{element: _, data: _, from: _})
    RemotePipeline.subscribe(pipeline, %RemoteMessage.EndOfStream{element: _, pad: _, from: _})
    {:ok, pipeline}
  end
end
