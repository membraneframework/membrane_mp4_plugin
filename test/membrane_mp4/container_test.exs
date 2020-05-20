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
end
