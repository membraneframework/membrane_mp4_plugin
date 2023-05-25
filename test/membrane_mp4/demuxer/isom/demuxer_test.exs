defmodule Membrane.MP4.Demuxer.ISOM.DemuxerTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  require Membrane.Pad
  require Membrane.RemoteControlled.Pipeline

  alias Membrane.Pad
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

  describe "Demuxer should allow for transmuxing of" do
    @tag :tmp_dir
    test "a single H264 track", %{tmp_dir: dir} do
      in_path = "test/fixtures/isom/ref_video_fast_start.mp4"
      out_path = Path.join(dir, "out")

      pipeline =
        start_testing_pipeline!(
          input_file: in_path,
          output_file: out_path
        )

      perform_test(pipeline, "video", out_path)
    end

    @tag :tmp_dir
    test "a single AAC track", %{tmp_dir: dir} do
      in_path = "test/fixtures/isom/ref_aac_fast_start.mp4"
      out_path = Path.join(dir, "out")

      pipeline =
        start_testing_pipeline!(
          input_file: in_path,
          output_file: out_path
        )

      perform_test(pipeline, "aac", out_path)
    end
  end

  describe "output pad connected after new_track_t() notification" do
    @tag :tmp_dir
    test "output pad connected after end_of_stream", %{tmp_dir: dir} do
      out_path = Path.join(dir, "out")
      filename = "test/fixtures/isom/ref_video_fast_start.mp4"

      pipeline =
        start_remote_pipeline!(
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

      structure = [
        get_child(:demuxer)
        |> via_out(Pad.ref(:output, 1))
        |> child(:sink, %Membrane.File.Sink{location: out_path})
      ]

      RemotePipeline.exec_actions(pipeline, spec: {structure, []})
      assert_receive %RemoteMessage.EndOfStream{element: :sink, pad: :input, from: _}, 2000

      RemotePipeline.terminate(pipeline, blocking?: true)

      assert_files_equal(out_path, ref_path_for("video"))
    end

    @tag :tmp_dir
    test "output pad connected after moov box has been read", %{tmp_dir: dir} do
      out_path = Path.join(dir, "out")
      filename = "test/fixtures/isom/ref_video_fast_start.mp4"

      pipeline =
        start_remote_pipeline!(
          filename: filename,
          file_source_chunk_size: File.stat!(filename).size - 1
        )

      assert_receive %RemoteMessage.Notification{
                       element: :demuxer,
                       data: {:new_track, 1, _payload},
                       from: _
                     },
                     2000

      structure = [
        get_child(:demuxer)
        |> via_out(Pad.ref(:output, 1))
        |> child(:sink, %Membrane.File.Sink{location: out_path})
      ]

      RemotePipeline.exec_actions(pipeline, spec: {structure, []})
      assert_receive %RemoteMessage.EndOfStream{element: :demuxer, pad: :input, from: _}, 2000
      assert_receive %RemoteMessage.EndOfStream{element: :sink, pad: :input, from: _}, 2000

      RemotePipeline.terminate(pipeline, blocking?: true)

      assert_files_equal(out_path, ref_path_for("video"))
    end
  end

  defp start_testing_pipeline!(opts) do
    structure = [
      child(:file, %Membrane.File.Source{location: opts[:input_file]})
      |> child(:demuxer, Membrane.MP4.Demuxer.ISOM),
      get_child(:demuxer)
      |> via_out(Pad.ref(:output, 1))
      |> child(:sink, %Membrane.File.Sink{location: opts[:output_file]})
    ]

    Pipeline.start_link_supervised!(structure: structure)
  end

  defp start_remote_pipeline!(opts) do
    structure = [
      child(:file, %Membrane.File.Source{
        location: opts[:filename],
        chunk_size: opts[:file_source_chunk_size]
      })
      |> child(:demuxer, Membrane.MP4.Demuxer.ISOM)
    ]

    actions = [spec: {structure, []}, playback: :playing]

    pipeline = RemotePipeline.start_link!()
    RemotePipeline.exec_actions(pipeline, actions)
    RemotePipeline.subscribe(pipeline, %RemoteMessage.Notification{element: _, data: _, from: _})
    RemotePipeline.subscribe(pipeline, %RemoteMessage.EndOfStream{element: _, pad: _, from: _})
    pipeline
  end
end
