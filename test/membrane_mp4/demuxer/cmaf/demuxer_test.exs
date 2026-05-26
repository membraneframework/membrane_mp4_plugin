defmodule Membrane.MP4.Demuxer.CMAF.DemuxerTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  require Membrane.RCPipeline, as: RCPipeline
  require Membrane.Pad, as: Pad

  alias Membrane.MP4.Demuxer.CMAF.Engine
  alias Membrane.MP4.Demuxer.MultiFileSource
  alias Membrane.RCMessage
  alias Membrane.Testing.Pipeline

  describe "handling skip box" do
    test "produces samples from a segment containing a skip box" do
      header = File.read!("test/fixtures/cmaf/ref_video_header.mp4")
      segment = File.read!("test/fixtures/cmaf/with_skip.m4s")

      engine = Engine.new() |> Engine.feed!(header) |> Engine.feed!(segment)
      {:ok, samples, _engine} = Engine.pop_samples(engine)
      assert samples != []
    end
  end

  describe "emsg metadata" do
    test "attaches emsg_pts_ms and emsg_message_data to samples from fragments with emsg box" do
      fixture = File.read!("test/fixtures/cmaf/emsg.mp4")

      engine = Engine.new() |> Engine.feed!(fixture)
      {:ok, samples, _engine} = Engine.pop_samples(engine)

      emsg_samples = Enum.filter(samples, &Map.has_key?(&1.metadata, :emsg_pts_ms))

      assert length(emsg_samples) == 8

      first_sample = Enum.at(emsg_samples, 0)
      assert first_sample.metadata.emsg_pts_ms == 210_058

      Enum.each(emsg_samples, fn sample ->
        assert binary_part(sample.metadata.emsg_message_data, 0, 3) == "ID3"
      end)
    end

    test "samples have empty metadata when no emsg box is present" do
      header = File.read!("test/fixtures/cmaf/ref_audio_header.mp4")
      segment = File.read!("test/fixtures/cmaf/ref_audio_segment1.m4s")

      engine = Engine.new() |> Engine.feed!(header) |> Engine.feed!(segment)
      {:ok, samples, _engine} = Engine.pop_samples(engine)

      assert samples != []
      assert Enum.all?(samples, fn sample -> sample.metadata == %{} end)
    end
  end

  # Fixtures used in demuxer tests below were generated with `chunk_duration` option set to `Membrane.Time.seconds(1)`.
  describe "CMAF demuxer" do
    @tag :tmp_dir
    test "demuxes fragmented MP4 with just audio track", %{tmp_dir: dir} do
      input_paths = get_files("test/fixtures/cmaf/", ["ref_audio_header.mp4", "ref_audio_*.m4s"])
      audio_output_path = Path.join(dir, "out.aac")

      pipeline =
        start_testing_pipeline!(
          input_paths: input_paths,
          audio_output_file: audio_output_path,
          audio_pad_ref: Pad.ref(:output, 1)
        )

      assert_end_of_stream(pipeline, :audio_sink)
      assert :ok == Pipeline.terminate(pipeline)

      assert_files_equal(audio_output_path, "test/fixtures/cmaf/ref_audio.aac")
    end

    @tag :tmp_dir
    test "demuxes fragmented MP4 with just video track", %{tmp_dir: dir} do
      video_output_path = Path.join(dir, "out.h264")

      pipeline =
        start_testing_pipeline!(
          input_paths:
            get_files("test/fixtures/cmaf", ["ref_video_header.mp4", "ref_video_segment*.m4s"]),
          video_output_file: video_output_path,
          video_pad_ref: Pad.ref(:output, 1)
        )

      assert_end_of_stream(pipeline, :video_sink)
      assert :ok == Pipeline.terminate(pipeline)

      assert_files_equal(video_output_path, "test/fixtures/cmaf/ref_video.h264")
    end

    @tag :tmp_dir
    test "demuxes fragmented MP4 with interleaved audio and video samples", %{tmp_dir: dir} do
      input_paths =
        get_files("test/fixtures/cmaf/muxed_audio_video/", ["header.mp4", "segment_*.m4s"])

      video_output_path = Path.join(dir, "out.h264")
      audio_output_path = Path.join(dir, "out.aac")

      pipeline =
        start_testing_pipeline!(
          input_paths: input_paths,
          video_output_file: video_output_path,
          audio_output_file: audio_output_path,
          video_pad_ref: Pad.ref(:output, 1),
          audio_pad_ref: Pad.ref(:output, 2)
        )

      assert_end_of_stream(pipeline, :video_sink)
      assert_end_of_stream(pipeline, :audio_sink)
      assert :ok == Pipeline.terminate(pipeline)

      assert_files_equal(video_output_path, "test/fixtures/in_video.h264")
      assert_files_equal(audio_output_path, "test/fixtures/in_audio.aac")
    end

    @tag :tmp_dir
    test "resolves tracks from fragmented MP4 and allows to link output pads when tracks are resolved",
         %{tmp_dir: dir} do
      input_paths =
        get_files("test/fixtures/cmaf/muxed_audio_video/", ["header.mp4", "segment_*.m4s"])

      spec =
        child(:file, %MultiFileSource{
          paths: input_paths
        })
        |> child(:demuxer, Membrane.MP4.Demuxer.CMAF)

      pipeline = RCPipeline.start_link!()
      RCPipeline.exec_actions(pipeline, spec: spec)
      RCPipeline.subscribe(pipeline, %RCMessage.Notification{})
      RCPipeline.subscribe(pipeline, %RCMessage.EndOfStream{})

      assert_receive %RCMessage.Notification{
                       element: :demuxer,
                       data: {:new_tracks, [{1, _payload}, {2, _payload2}]},
                       from: _
                     },
                     2000

      video_output_path = Path.join(dir, "out.h264")
      audio_output_path = Path.join(dir, "out.aac")

      structure = [
        get_child(:demuxer)
        |> via_out(Pad.ref(:output, 1))
        |> child(Membrane.AAC.Parser)
        |> child(:audio_sink, %Membrane.File.Sink{location: audio_output_path}),
        get_child(:demuxer)
        |> via_out(Pad.ref(:output, 2))
        |> child(%Membrane.H264.Parser{output_stream_structure: :annexb})
        |> child(:video_sink, %Membrane.File.Sink{location: video_output_path})
      ]

      RCPipeline.exec_actions(pipeline, spec: structure)
      assert_receive %RCMessage.EndOfStream{element: :demuxer, pad: :input}, 2000
      assert_receive %RCMessage.EndOfStream{element: :audio_sink, pad: :input}, 2000
      assert_receive %RCMessage.EndOfStream{element: :video_sink, pad: :input}, 2000
      RCPipeline.terminate(pipeline)

      assert_files_equal(video_output_path, "test/fixtures/in_video.h264")
      assert_files_equal(audio_output_path, "test/fixtures/in_audio.aac")
    end
  end

  @tag :tmp_dir
  test "CMAF demuxer accepts trun with all optional sample fields off", %{tmp_dir: dir} do
    fixture_path = "test/fixtures/cmaf"
    stem = "bun33s_frag"
    input_path = Path.join([fixture_path, "#{stem}.mp4"])

    # Input fixture taken from https://raw.githubusercontent.com/membraneframework/static/gh-pages/samples/big-buck-bunny/bun33s.mp4 |
    # ffmpeg -i bun33s.mp4 -f mp4 -c copy -movflags cmaf+separate_moof+delay_moov+skip_trailer+frag_every_frame #{input}

    video_output_path = Path.join(dir, "out.h264")
    audio_output_path = Path.join(dir, "out.aac")

    spec = [
      child(:source, %Membrane.File.Source{
        location: input_path
      })
      |> child(:demuxer, Membrane.MP4.Demuxer.CMAF),
      get_child(:demuxer)
      |> via_out(Pad.ref(:output), options: [kind: :audio])
      |> child(:audio_sink, %Membrane.File.Sink{location: audio_output_path}),
      get_child(:demuxer)
      |> via_out(Pad.ref(:output), options: [kind: :video])
      |> child(:video_sink, %Membrane.File.Sink{location: video_output_path})
    ]

    pipeline = Pipeline.start_link_supervised!(spec: spec)

    assert_end_of_stream(pipeline, :video_sink)
    assert_end_of_stream(pipeline, :audio_sink)
    assert :ok == Pipeline.terminate(pipeline)

    assert_files_equal(video_output_path, Path.join([fixture_path, "#{stem}.h264"]))
    assert_files_equal(audio_output_path, Path.join([fixture_path, "#{stem}.aac"]))
  end

  test "the PTS and DTS are properly read" do
    fixture_path = "test/fixtures/cmaf"
    input_path = Path.join([fixture_path, "bframes.mp4"])

    # Input fixture taken from https://raw.githubusercontent.com/membraneframework/static/gh-pages/samples/big-buck-bunny/bun33s.mp4
    # ffmpeg -i bun33s.mp4 -f mp4 -an -c:v libx264 -bf 2 -movflags frag_keyframe+default_base_moof+empty_moov+skip_trailer #{input_path}

    ref_path = Path.join([fixture_path, "bframes_ref.ms"])

    demuxing_spec =
      child(:file, %Membrane.File.Source{location: input_path})
      |> child(:demuxer, Membrane.MP4.Demuxer.CMAF)
      |> via_out(Pad.ref(:output), options: [kind: :video])
      |> child(:parser_video, %Membrane.H264.Parser{output_stream_structure: :annexb})
      |> child(:sink, Membrane.Testing.Sink)

    pipeline = Pipeline.start_link_supervised!(spec: demuxing_spec)
    assert_end_of_stream(pipeline, :sink, :input)
    demuxing_buffers = flush_buffers()

    ref_spec =
      child(:file, %Membrane.File.Source{location: ref_path})
      |> child(:deserializer, Membrane.Stream.Deserializer)
      |> child(:sink, Membrane.Testing.Sink)

    pipeline = Pipeline.start_link_supervised!(spec: ref_spec)
    assert_end_of_stream(pipeline, :sink, :input)

    ref_buffers = flush_buffers()
    assert demuxing_buffers == ref_buffers
  end

  defp start_testing_pipeline!(opts) do
    input_spec = [
      child(:file, %MultiFileSource{paths: opts[:input_paths]})
      |> child(:demuxer, Membrane.MP4.Demuxer.CMAF)
    ]

    video_spec =
      if opts[:video_output_file] do
        [
          get_child(:demuxer)
          |> via_out(opts[:video_pad_ref], options: [kind: :video])
          |> child(%Membrane.H264.Parser{output_stream_structure: :annexb})
          |> child(:video_sink, %Membrane.File.Sink{location: opts[:video_output_file]})
        ]
      else
        []
      end

    audio_spec =
      if opts[:audio_output_file] do
        [
          get_child(:demuxer)
          |> via_out(opts[:audio_pad_ref], options: [kind: :audio])
          |> child(:parser, Membrane.AAC.Parser)
          |> child(:audio_sink, %Membrane.File.Sink{location: opts[:audio_output_file]})
        ]
      else
        []
      end

    spec = input_spec ++ video_spec ++ audio_spec
    Pipeline.start_link_supervised!(spec: spec)
  end

  defp flush_buffers(acc \\ []) do
    receive do
      {Membrane.Testing.Pipeline, _pid, {:handle_child_notification, {{:buffer, buffer}, :sink}}} ->
        flush_buffers(acc ++ [buffer])

      _other_msg ->
        flush_buffers(acc)
    after
      0 -> acc
    end
  end

  defp assert_files_equal(file_a, file_b) do
    assert {:ok, a} = File.read(file_a)
    assert {:ok, b} = File.read(file_b)
    assert a == b
  end

  defp get_files(directory_path, regexes) do
    directory_path
    |> Path.expand()
    |> (fn path ->
          Enum.map(regexes, &Path.join([path, "/", &1]))
        end).()
    |> Enum.map(&Path.wildcard/1)
    |> List.flatten()
    |> Enum.filter(&File.regular?(&1))
  end
end
