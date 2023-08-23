defmodule Membrane.MP4.CustomSampleRateTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  require Membrane.Pad

  alias Membrane.MP4.Container
  alias Membrane.Pad

  alias Membrane.Testing.Pipeline

  @tag :tmp_dir
  test "an AAC track with custom sample rate after demuxing, depayloading, payloading and muxing is identical to the original one",
       %{tmp_dir: dir} do
    in_path = "test/fixtures/isom/ref_aac_fast_start_sr_22050.mp4"
    out_path = Path.join(dir, "out.mp4")

    structure = [
      child(:file, %Membrane.File.Source{location: in_path})
      |> child(:demuxer, Membrane.MP4.Demuxer.ISOM)
      |> via_out(Pad.ref(:output, 1))
      |> child(:payloadin_parser, %Membrane.AAC.Parser{
        in_encapsulation: :none,
        out_encapsulation: :ADTS
      })
      |> child(:depayloading_parser, %Membrane.AAC.Parser{
        in_encapsulation: :ADTS,
        out_encapsulation: :none,
        output_config: :esds
      })
      |> child(:muxer, %Membrane.MP4.Muxer.ISOM{
        chunk_duration: Membrane.Time.seconds(1),
        fast_start: true
      })
      |> child(:sink, %Membrane.File.Sink{location: out_path})
    ]

    pipeline = Pipeline.start_link_supervised!(structure: structure)

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
end
