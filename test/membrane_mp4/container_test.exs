defmodule Membrane.MP4.ContainerTest do
  use ExUnit.Case, async: true
  alias Membrane.MP4.Container

  @cmaf_fixtures "test/fixtures/cmaf"
  @isom_fixtures "test/fixtures/isom"

  test "video" do
    data = @cmaf_fixtures |> Path.join("ref_video_header.mp4") |> File.read!()
    assert data |> Container.parse!() |> Container.serialize!() == data
    data = @cmaf_fixtures |> Path.join("ref_video_segment1.m4s") |> File.read!()
    assert data |> Container.parse!() |> Container.serialize!() == data
    data = @cmaf_fixtures |> Path.join("ref_video_segment2.m4s") |> File.read!()
    assert data |> Container.parse!() |> Container.serialize!() == data
    data = @isom_fixtures |> Path.join("ref_video.mp4") |> File.read!()
    assert data |> Container.parse!() |> Container.serialize!() == data
  end

  test "audio" do
    data = @cmaf_fixtures |> Path.join("ref_audio_header.mp4") |> File.read!()
    assert data |> Container.parse!() |> Container.serialize!() == data
    data = @cmaf_fixtures |> Path.join("ref_audio_segment1.m4s") |> File.read!()
    assert data |> Container.parse!() |> Container.serialize!() == data
    data = @cmaf_fixtures |> Path.join("ref_audio_segment2.m4s") |> File.read!()
    assert data |> Container.parse!() |> Container.serialize!() == data
    data = @cmaf_fixtures |> Path.join("ref_audio_segment3.m4s") |> File.read!()
    assert data |> Container.parse!() |> Container.serialize!() == data
    data = @isom_fixtures |> Path.join("ref_aac.mp4") |> File.read!()
    assert data |> Container.parse!() |> Container.serialize!() == data
  end

  test "two tracks" do
    data = @isom_fixtures |> Path.join("ref_two_tracks.mp4") |> File.read!()
    assert data |> Container.parse!() |> Container.serialize!() == data
  end

  test "unknown box" do
    <<size::4-binary, "styp", rest::binary>> =
      @cmaf_fixtures |> Path.join("ref_audio_segment1.m4s") |> File.read!()

    data = <<size::4-binary, "abcd", rest::binary>>
    assert data |> Container.parse!() |> Container.serialize!() == data
  end

  test "parse error" do
    <<0, 0, 0, 24, pre_cut::18-binary, _cut::2-binary, post_cut::binary>> =
      @cmaf_fixtures |> Path.join("ref_video_header.mp4") |> File.read!()

    data = <<0, 0, 0, 22>> <> pre_cut <> post_cut
    assert Container.parse(data) == {:error, box: :ftyp, field: :compatible_brands, data: "mp"}
    assert_raise RuntimeError, ~r/Error parsing MP4/, fn -> Container.parse!(data) end
  end

  test "serialize error" do
    assert {:ok, mp4} =
             @cmaf_fixtures
             |> Path.join("ref_video_header.mp4")
             |> File.read!()
             |> Container.parse()

    mp4 = Container.update_box(mp4, :ftyp, [:fields, :major_brand], fn _brand -> 123 end)
    assert Container.serialize(mp4) == {:error, box: :ftyp, field: :major_brand}
    assert_raise RuntimeError, ~r/Error serializing MP4/, fn -> Container.serialize!(mp4) end
  end
end
