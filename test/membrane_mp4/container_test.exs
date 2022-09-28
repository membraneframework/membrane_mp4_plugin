defmodule Membrane.MP4.ContainerTest do
  use ExUnit.Case, async: true
  alias Membrane.MP4.Container

  @cmaf_fixtures "test/fixtures/cmaf"
  @isom_fixtures "test/fixtures/isom"

  defp test_parse_serialize(fixtures, reference) do
    data = fixtures |> Path.join(reference) |> File.read!()
    assert {boxes, <<>>} = data |> Container.parse!()
    assert boxes |> Container.serialize!() == data
  end

  defp test_partial(file, boxes_expected) do
    data = @isom_fixtures |> Path.join(file) |> File.read!()
    data_size = byte_size(data) - 1
    <<data::binary-size(data_size), _last::binary-size(1)>> = data
    assert {:ok, boxes, <<_rest::binary>>} = data |> Container.parse()
    assert boxes |> Enum.map(&elem(&1, 0)) == boxes_expected
  end

  test "video" do
    test_parse_serialize(@cmaf_fixtures, "ref_video_header.mp4")
    test_parse_serialize(@cmaf_fixtures, "ref_video_segment1.m4s")
    test_parse_serialize(@cmaf_fixtures, "ref_video_segment2.m4s")
    test_parse_serialize(@isom_fixtures, "ref_video.mp4")
  end

  test "audio" do
    test_parse_serialize(@cmaf_fixtures, "ref_audio_header.mp4")
    test_parse_serialize(@cmaf_fixtures, "ref_audio_segment1.m4s")
    test_parse_serialize(@cmaf_fixtures, "ref_audio_segment2.m4s")
    test_parse_serialize(@cmaf_fixtures, "ref_audio_segment3.m4s")
    test_parse_serialize(@isom_fixtures, "ref_aac.mp4")
  end

  test "two tracks" do
    test_parse_serialize(@isom_fixtures, "ref_two_tracks.mp4")
  end

  test "partial data" do
    test_partial("ref_video.mp4", [:ftyp, :mdat])
    test_partial("ref_video_fast_start.mp4", [:ftyp, :moov])
    test_partial("ref_aac.mp4", [:ftyp, :mdat])
    test_partial("ref_aac_fast_start.mp4", [:ftyp, :moov])
  end

  test "unknown box" do
    <<size::4-binary, "styp", rest::binary>> =
      @cmaf_fixtures |> Path.join("ref_audio_segment1.m4s") |> File.read!()

    data = <<size::4-binary, "abcd", rest::binary>>
    assert {boxes, <<>>} = data |> Container.parse!()
    assert boxes |> Container.serialize!() == data
  end

  test "parse error" do
    <<0, 0, 0, 24, pre_cut::18-binary, _cut::2-binary, post_cut::binary>> =
      @cmaf_fixtures |> Path.join("ref_video_header.mp4") |> File.read!()

    data = <<0, 0, 0, 22>> <> pre_cut <> post_cut
    assert Container.parse(data) == {:error, box: :ftyp, field: :compatible_brands, data: "mp"}
    assert_raise RuntimeError, ~r/Error parsing MP4/, fn -> Container.parse!(data) end
  end

  test "serialize error" do
    assert {:ok, mp4, <<>>} =
             @cmaf_fixtures
             |> Path.join("ref_video_header.mp4")
             |> File.read!()
             |> Container.parse()

    mp4 = Container.update_box(mp4, :ftyp, [:fields, :major_brand], fn _brand -> 123 end)
    assert Container.serialize(mp4) == {:error, box: :ftyp, field: :major_brand}
    assert_raise RuntimeError, ~r/Error serializing MP4/, fn -> Container.serialize!(mp4) end
  end
end
