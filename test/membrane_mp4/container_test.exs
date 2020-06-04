defmodule Membrane.MP4.ContainerTest do
  use ExUnit.Case, async: true
  alias Membrane.MP4.Container

  test "video" do
    data = File.read!("test/fixtures/out_video_header.mp4")
    assert data |> Container.parse!() |> Container.serialize!() == data
    data = File.read!("test/fixtures/out_video_segment1.m4s")
    assert data |> Container.parse!() |> Container.serialize!() == data
    data = File.read!("test/fixtures/out_video_segment2.m4s")
    assert data |> Container.parse!() |> Container.serialize!() == data
  end

  test "audio" do
    data = File.read!("test/fixtures/out_audio_header.mp4")
    assert data |> Container.parse!() |> Container.serialize!() == data
    data = File.read!("test/fixtures/out_audio_segment1.m4s")
    assert data |> Container.parse!() |> Container.serialize!() == data
    data = File.read!("test/fixtures/out_audio_segment2.m4s")
    assert data |> Container.parse!() |> Container.serialize!() == data
    data = File.read!("test/fixtures/out_audio_segment3.m4s")
    assert data |> Container.parse!() |> Container.serialize!() == data
  end

  test "unknown box" do
    <<size::4-binary, "styp", rest::binary>> = File.read!("test/fixtures/out_audio_segment1.m4s")
    data = <<size::4-binary, "abcd", rest::binary>>
    assert data |> Container.parse!() |> Container.serialize!() == data
  end

  test "parse error" do
    <<0, 0, 0, 24, pre_cut::18-binary, _cut::2-binary, post_cut::binary>> =
      File.read!("test/fixtures/out_video_header.mp4")

    data = <<0, 0, 0, 22>> <> pre_cut <> post_cut
    assert Container.parse(data) == {:error, box: :ftyp, field: :compatible_brands, data: "mp"}
    assert_raise RuntimeError, ~r/Error parsing MP4/, fn -> Container.parse!(data) end
  end

  test "serialize error" do
    assert {:ok, mp4} = File.read!("test/fixtures/out_video_header.mp4") |> Container.parse()
    mp4 = Container.update_box(mp4, :ftyp, [:fields, :major_brand], fn _ -> 123 end)
    assert Container.serialize(mp4) == {:error, box: :ftyp, field: :major_brand}
    assert_raise RuntimeError, ~r/Error serializing MP4/, fn -> Container.serialize!(mp4) end
  end
end
