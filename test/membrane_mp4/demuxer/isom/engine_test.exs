defmodule Membrane.MP4.Demuxer.ISOM.EngineTest do
  use ExUnit.Case, async: true

  alias Membrane.MP4.Demuxer.ISOM.Engine

  @fixture "test/fixtures/isom/ref_two_tracks.mp4"

  defp new_engine() do
    data = File.read!(@fixture)

    Engine.new(fn start, size, state ->
      {binary_part(data, start, min(size, byte_size(data) - start)), state}
    end)
  end

  defp read_all(engine, track_id) do
    Stream.unfold(engine, fn engine ->
      case Engine.read_sample(engine, track_id) do
        :end_of_stream -> nil
        {:ok, sample, engine} -> {sample, engine}
      end
    end)
    |> Enum.to_list()
  end

  test "reads every sample of every track in decoding order" do
    engine = new_engine()

    for {track_id, table} <- Engine.get_tracks_info(engine) do
      samples = read_all(engine, track_id)
      assert length(samples) == length(table.sample_sizes)
      assert Enum.map(samples, &byte_size(&1.payload)) == table.sample_sizes
      dts = Enum.map(samples, & &1.dts)
      assert dts == Enum.sort(dts)
      assert Enum.all?(samples, &(&1.pts >= &1.dts))
    end
  end

  test "seeking moves the cursor to the first sample with dts at or after the timestamp" do
    engine = new_engine()

    for track_id <- Map.keys(Engine.get_tracks_info(engine)) do
      all = read_all(engine, track_id)
      target = Enum.at(all, div(length(all), 2)).dts + 1
      expected = Enum.drop_while(all, &(&1.dts < target))

      sought = engine |> Engine.seek_in_samples(track_id, target) |> read_all(track_id)
      assert sought == expected
    end
  end
end
