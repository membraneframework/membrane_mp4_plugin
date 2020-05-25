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

  test "parse error" do
    <<0, 0, 0, 24, pre_cut::18-binary, _cut::2-binary, post_cut::binary>> =
      File.read!("test/fixtures/out_video_header.mp4")

    data = <<0, 0, 0, 22>> <> pre_cut <> post_cut
    assert Container.parse(data) == {:error, box: :ftyp, field: :compatible_brands, data: "mp"}
    assert_raise RuntimeError, ~r/Error parsing MP4/, fn -> Container.parse!(data) end
  end
end
