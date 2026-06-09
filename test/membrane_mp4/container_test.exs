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
    <<partial::binary-size(data_size), _last::binary-size(1)>> = data
    assert {:ok, boxes, <<_rest::binary>>} = Container.parse(partial)
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

  test "skip box" do
    {boxes, <<>>} =
      @cmaf_fixtures |> Path.join("with_skip.m4s") |> File.read!() |> Container.parse!()

    assert Keyword.has_key?(boxes, :skip)
  end

  test "unknown box is skipped" do
    <<compact_size::32, "styp", box_rest::binary>> =
      @cmaf_fixtures |> Path.join("ref_audio_segment1.m4s") |> File.read!()

    styp_content_size = compact_size - 8
    <<_styp_content::binary-size(styp_content_size), remaining::binary>> = box_rest

    # Replace styp with a name that is not a known atom — box should be silently skipped
    data = <<compact_size::32, "abcd", box_rest::binary>>
    {boxes, <<>>} = Container.parse!(data)

    {expected_boxes, <<>>} = Container.parse!(remaining)
    assert boxes == expected_boxes
  end

  test "box with unknown name does not create new atoms" do
    unknown_name = "zz9z"
    unknown_content = <<0, 1, 2, 3>>

    unknown_box =
      <<8 + byte_size(unknown_content)::32, unknown_name::binary, unknown_content::binary>>

    known_data = @cmaf_fixtures |> Path.join("ref_audio_segment1.m4s") |> File.read!()
    {expected_boxes, <<>>} = Container.parse!(known_data)

    atom_count_before = :erlang.system_info(:atom_count)
    {boxes, <<>>} = Container.parse!(unknown_box <> known_data)
    atom_count_after = :erlang.system_info(:atom_count)

    assert boxes == expected_boxes
    assert atom_count_after == atom_count_before
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
