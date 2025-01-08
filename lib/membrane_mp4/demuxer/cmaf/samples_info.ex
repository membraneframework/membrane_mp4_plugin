defmodule Membrane.MP4.Demuxer.CMAF.SamplesInfo do
  @moduledoc false

  alias Membrane.MP4.MovieBox.SampleTableBox

  @type sample_description :: %{
          duration: non_neg_integer(),
          ts: non_neg_integer(),
          size: non_neg_integer(),
          composition_offset: non_neg_integer(),
          offset: non_neg_integer(),
          track_id: non_neg_integer()
        }

  @spec read_moov(moov_box :: map()) :: %{non_neg_integer() => struct()}
  def read_moov(%{children: boxes}) do
    tracks =
      boxes
      |> Enum.filter(fn {type, _content} -> type == :trak end)
      |> Enum.into(%{}, fn {:trak, %{children: boxes}} ->
        {boxes[:tkhd].fields.track_id, boxes}
      end)

    Map.new(tracks, fn {track_id, boxes} ->
      sample_table =
        SampleTableBox.unpack(
          boxes[:mdia].children[:minf].children[:stbl],
          boxes[:mdia].children[:mdhd].fields.timescale
        )

      {track_id, sample_table.sample_description}
    end)
  end

  @spec get_samples_info(moof_box :: map()) :: [sample_description()]
  def get_samples_info(%{children: boxes}) do
    boxes
    |> Enum.filter(fn {type, _content} -> type == :traf end)
    |> Enum.map(fn {:traf, box} -> box end)
    |> Enum.flat_map(&handle_track/1)
    |> Enum.sort_by(& &1.offset)
  end

  defp handle_track(traf_box) do
    track_id = traf_box.children[:tfhd].fields.track_id

    base_data_offset =
      case traf_box.children[:tfhd].fields[:base_data_offset] do
        [] -> 0
        other -> other
      end

    default_sample_duration =
      case traf_box.children[:tfhd].fields[:default_sample_duration] do
        [] -> 0
        other -> other
      end

    default_sample_size =
      case traf_box.children[:tfhd].fields[:default_sample_size] do
        [] -> nil
        other -> other
      end

    base_media_decode_time =
      case traf_box.children[:tfdt].fields.base_media_decode_time do
        [] -> 0
        other -> other
      end

    Enum.filter(traf_box.children, fn {box_name, _box} -> box_name == :trun end)
    |> Enum.flat_map_reduce(base_media_decode_time, fn {:trun, trun_box}, ts_acc ->
      {samples, {_size_acc, ts_acc}} =
        Enum.map_reduce(
          trun_box.fields.samples,
          {base_data_offset + trun_box.fields.data_offset, ts_acc},
          fn sample, {size_acc, ts_acc} ->
            size =
              case sample[:sample_size] do
                [] -> default_sample_size
                other -> other
              end

            duration =
              case sample[:sample_duration] do
                [] -> default_sample_duration
                other -> other
              end

            {%{
               duration: duration,
               ts: ts_acc,
               size: size,
               composition_offset: sample[:composition_offset] || 0,
               offset: size_acc,
               track_id: track_id
             }, {size_acc + size, ts_acc + duration}}
          end
        )

      {samples, ts_acc}
    end)
    |> elem(0)
  end
end
