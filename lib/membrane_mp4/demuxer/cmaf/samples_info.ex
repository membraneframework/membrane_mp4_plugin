defmodule Membrane.MP4.Demuxer.CMAF.SamplesInfo do
  def get_samples_info(%{children: boxes}, timescale) do
    boxes
    |> Enum.filter(fn {type, _content} -> type == :traf end)
    |> Enum.map(fn {:traf, box} -> box end)
    |> Enum.flat_map(&handle_track/1)
    |> Enum.sort_by(& &1.offset)
  end

  defp handle_track(traf_box) do
    track_id = traf_box.children[:tfhd].fields.track_id
    base_data_offset = traf_box.children[:tfhd].fields[:base_data_offset] || 0

    default_sample_duration = traf_box.children[:tfhd].fields[:default_sample_duration] || nil
    default_sample_size = traf_box.children[:tfhd].fields[:default_sample_size] || nil

    Enum.filter(traf_box.children, fn {box_name, _box} -> box_name == :trun end)
    |> Enum.flat_map(fn {:trun, trun_box} ->
      Enum.map_reduce(
        trun_box.fields.samples,
        0,#TODO: why base_data_offset + trun_box.fields.data_offset doesn't work here?
        fn sample, size_acc ->
          size = sample[:sample_size] || default_sample_size

          {%{
             duration: sample[:sample_duration] || default_sample_duration,
             size: size,
             composition_offset: sample[:composition_offset] || 0,
             offset: size_acc,
             track_id: track_id
           }, size_acc + size}
        end
      )
      |> elem(0)
    end)
  end
end
