defmodule Membrane.MP4.Demuxer.ISOM.DemuxerTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  require Membrane.Pad
  require Membrane.RCPipeline

  alias Membrane.Pad
  alias Membrane.RCMessage
  alias Membrane.RCPipeline
  alias Membrane.Testing.Pipeline

  # Fixtures used in demuxer tests below were generated with `chunk_duration` option set to `Membrane.Time.seconds(1)`.
  defp assert_files_equal(file_a, file_b) do
    assert {:ok, a} = File.read(file_a)
    assert {:ok, b} = File.read(file_b)
    assert a == b
  end

  defp ref_path_for(filename), do: "test/fixtures/payloaded/isom/payloaded_#{filename}"

  describe "Demuxer should allow for transmuxing of" do
    @tag :tmp_dir
    test "a single fast start H264 track", %{tmp_dir: dir} do
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
    test "a single fast start AAC track", %{tmp_dir: dir} do
      in_path = "test/fixtures/isom/ref_aac_fast_start.mp4"
      out_path = Path.join(dir, "out")

      pipeline =
        start_testing_pipeline!(
          input_file: in_path,
          output_file: out_path
        )

      perform_test(pipeline, "aac", out_path)
    end

    @tag :tmp_dir
    test "a single non-fast-start H264 track", %{tmp_dir: dir} do
      in_path = "test/fixtures/isom/ref_video.mp4"
      out_path = Path.join(dir, "out")

      pipeline =
        start_testing_pipeline!(
          input_file: in_path,
          output_file: out_path
        )

      perform_test(pipeline, "video", out_path)
    end

    @tag :tmp_dir
    test "a single non-fast-start H265 track", %{tmp_dir: dir} do
      in_path = "test/fixtures/isom/ref_video_hevc.mp4"
      out_path = Path.join(dir, "out")

      pipeline =
        start_testing_pipeline!(
          input_file: in_path,
          output_file: out_path
        )

      perform_test(pipeline, "video_hevc", out_path)
    end

    @tag :tmp_dir
    test "a single non-fast-start AAC track", %{tmp_dir: dir} do
      in_path = "test/fixtures/isom/ref_aac.mp4"
      out_path = Path.join(dir, "out")

      pipeline =
        start_testing_pipeline!(
          input_file: in_path,
          output_file: out_path
        )

      perform_test(pipeline, "aac", out_path)
    end

    @tag :tmp_dir
    test "an .mp4 file with 64-bit versions of boxes", %{tmp_dir: dir} do
      in_path = "test/fixtures/isom/ref_64_bit_boxes.mp4"
      video_output_path = Path.join(dir, "out.h264")
      audio_output_path = Path.join(dir, "out.aac")

      pipeline =
        start_testing_pipeline_with_two_tracks!(
          input_file: in_path,
          video_output_file: video_output_path,
          audio_output_file: audio_output_path
        )

      assert_end_of_stream(pipeline, :video_sink)
      assert_end_of_stream(pipeline, :audio_sink)
      assert :ok == Pipeline.terminate(pipeline)
    end

    @tag :tmp_dir
    test "an .mp4 file with media chunks not starting at the beginning of the mdat box", %{
      tmp_dir: dir
    } do
      in_path = "test/fixtures/isom/ref_zeros_at_mdat_beginning.mp4"
      video_output_path = Path.join(dir, "out.h264")
      audio_output_path = Path.join(dir, "out.aac")

      pipeline =
        start_testing_pipeline_with_two_tracks!(
          input_file: in_path,
          video_output_file: video_output_path,
          audio_output_file: audio_output_path
        )

      assert_end_of_stream(pipeline, :video_sink)
      assert_end_of_stream(pipeline, :audio_sink)
      assert :ok == Pipeline.terminate(pipeline)
    end
  end

  describe "Demuxer with `non_fast_start_optimization: true` should allow for demuxing" do
    @tag :tmp_dir
    test "a single H264 track without fast_start flag", %{tmp_dir: dir} do
      in_path = "test/fixtures/isom/ref_video.mp4"
      out_path = Path.join(dir, "out")

      structure = [
        child(:file, %Membrane.File.Source{location: in_path, seekable?: true})
        |> child(:demuxer, %Membrane.MP4.Demuxer.ISOM{optimize_for_non_fast_start?: true})
        |> via_out(Pad.ref(:output, 1))
        |> child(:sink, %Membrane.File.Sink{location: out_path})
      ]

      pipeline = Pipeline.start_link_supervised!(spec: structure)

      perform_test(pipeline, "video", out_path)
    end

    @tag :tmp_dir
    test "a single H264 track with fast_start flag", %{tmp_dir: dir} do
      in_path = "test/fixtures/isom/ref_video_fast_start.mp4"
      out_path = Path.join(dir, "out")

      structure = [
        child(:file, %Membrane.File.Source{location: in_path, seekable?: true})
        |> child(:demuxer, %Membrane.MP4.Demuxer.ISOM{optimize_for_non_fast_start?: true})
        |> via_out(Pad.ref(:output, 1))
        |> child(:sink, %Membrane.File.Sink{location: out_path})
      ]

      pipeline = Pipeline.start_link_supervised!(spec: structure)

      perform_test(pipeline, "video", out_path)
    end

    @tag :tmp_dir
    test "an .mp4 file with 64-bit versions of boxes", %{tmp_dir: dir} do
      in_path = "test/fixtures/isom/ref_64_bit_boxes.mp4"
      video_output_path = Path.join(dir, "out.h264")
      audio_output_path = Path.join(dir, "out.aac")

      pipeline =
        start_testing_pipeline_with_two_tracks!(
          input_file: in_path,
          video_output_file: video_output_path,
          audio_output_file: audio_output_path
        )

      assert_end_of_stream(pipeline, :video_sink)
      assert_end_of_stream(pipeline, :audio_sink)
      assert :ok == Pipeline.terminate(pipeline)
    end

    @tag :tmp_dir
    test "an .mp4 file with media chunks not starting at the beginning of the mdat box", %{
      tmp_dir: dir
    } do
      in_path = "test/fixtures/isom/ref_zeros_at_mdat_beginning.mp4"
      video_output_path = Path.join(dir, "out.h264")
      audio_output_path = Path.join(dir, "out.aac")

      pipeline =
        start_testing_pipeline_with_two_tracks!(
          input_file: in_path,
          video_output_file: video_output_path,
          audio_output_file: audio_output_path
        )

      assert_end_of_stream(pipeline, :video_sink)
      assert_end_of_stream(pipeline, :audio_sink)
      assert :ok == Pipeline.terminate(pipeline)
    end
  end

  describe "output pad connected after new_tracks_t() notification" do
    @tag :tmp_dir
    test "output pad connected after end_of_stream", %{tmp_dir: dir} do
      out_path = Path.join(dir, "out")
      filename = "test/fixtures/isom/ref_video_fast_start.mp4"

      pipeline =
        start_remote_pipeline!(
          filename: filename,
          file_source_chunk_size: File.stat!(filename).size
        )

      assert_receive %RCMessage.Notification{
                       element: :demuxer,
                       data: {:new_tracks, [{1, _payload}]},
                       from: _
                     },
                     2000

      assert_receive %RCMessage.EndOfStream{element: :demuxer, pad: :input}, 2000

      structure =
        get_child(:demuxer)
        |> via_out(Pad.ref(:output, 1))
        |> child(:sink, %Membrane.File.Sink{location: out_path})

      RCPipeline.exec_actions(pipeline, spec: {structure, []})
      assert_receive %RCMessage.EndOfStream{element: :sink, pad: :input}, 2000

      RCPipeline.terminate(pipeline)

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

      assert_receive %RCMessage.Notification{
                       element: :demuxer,
                       data: {:new_tracks, [{1, _payload}]},
                       from: _
                     },
                     2000

      structure = [
        get_child(:demuxer)
        |> via_out(Pad.ref(:output, 1))
        |> child(:sink, %Membrane.File.Sink{location: out_path})
      ]

      RCPipeline.exec_actions(pipeline, spec: {structure, []})
      assert_receive %RCMessage.EndOfStream{element: :demuxer, pad: :input}, 2000
      assert_receive %RCMessage.EndOfStream{element: :sink, pad: :input}, 2000

      RCPipeline.terminate(pipeline)

      assert_files_equal(out_path, ref_path_for("video"))
    end
  end

  defp perform_test(pid, filename, out_path) do
    ref_path = ref_path_for(filename)

    assert_end_of_stream(pid, :sink, :input)

    assert :ok == Pipeline.terminate(pid)

    assert_files_equal(out_path, ref_path)
  end

  defp start_testing_pipeline!(opts) do
    spec =
      child(:file, %Membrane.File.Source{location: opts[:input_file]})
      |> child(:demuxer, Membrane.MP4.Demuxer.ISOM)

    pipeline = Pipeline.start_link_supervised!(spec: spec)
    assert_pipeline_notified(pipeline, :demuxer, {:new_tracks, _notification})

    spec =
      get_child(:demuxer)
      |> via_out(Pad.ref(:output, 1))
      |> child(:sink, %Membrane.File.Sink{location: opts[:output_file]})

    Pipeline.execute_actions(pipeline, spec: spec)
    pipeline
  end

  defp start_testing_pipeline_with_two_tracks!(opts) do
    spec =
      child(:file, %Membrane.File.Source{location: opts[:input_file]})
      |> child(:demuxer, Membrane.MP4.Demuxer.ISOM)

    pipeline = Pipeline.start_link_supervised!(spec: spec)

    assert_pipeline_notified(pipeline, :demuxer, {:new_tracks, _notification})

    spec = [
      get_child(:demuxer)
      |> via_out(Pad.ref(:output, 1))
      |> child(:video_sink, %Membrane.File.Sink{location: opts[:video_output_file]}),
      get_child(:demuxer)
      |> via_out(Pad.ref(:output, 2))
      |> child(:audio_sink, %Membrane.File.Sink{location: opts[:audio_output_file]})
    ]

    Pipeline.execute_actions(pipeline, spec: spec)
    pipeline
  end

  defp start_remote_pipeline!(opts) do
    spec =
      child(:file, %Membrane.File.Source{
        location: opts[:filename],
        chunk_size: opts[:file_source_chunk_size]
      })
      |> child(:demuxer, Membrane.MP4.Demuxer.ISOM)

    pipeline = RCPipeline.start_link!()
    RCPipeline.exec_actions(pipeline, spec: spec)
    RCPipeline.subscribe(pipeline, %RCMessage.Notification{})
    RCPipeline.subscribe(pipeline, %RCMessage.EndOfStream{})

    pipeline
  end
end
