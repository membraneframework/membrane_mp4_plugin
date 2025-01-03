defmodule Membrane.MP4.Demuxer.CMAF.SamplesInfo do
  def get_samples_info(%{children: boxes}) do
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
    |> Enum.flat_map_reduce(traf_box.children[:tfdt].fields.base_media_decode_time, fn {:trun, trun_box}, ts_acc ->
        {samples, {_size_acc, ts_acc}} = Enum.map_reduce(
        trun_box.fields.samples,
        {0, ts_acc}, #TODO: why base_data_offset + trun_box.fields.data_offset doesn't work here?
        fn sample, {size_acc, ts_acc} ->
          size = sample[:sample_size] || default_sample_size
          duration = sample[:sample_duration] || default_sample_duration
          {%{
             duration: duration,
             ts: ts_acc,
             size: size,
             composition_offset: sample[:composition_offset] || 0,
             offset: size_acc,
             track_id: track_id
           }, {size_acc + size, ts_acc+duration}}
        end)

      {samples, ts_acc}
    end) |> elem(0)
  end
end
