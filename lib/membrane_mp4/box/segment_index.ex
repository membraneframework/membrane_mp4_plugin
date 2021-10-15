defmodule Membrane.MP4.Box.SegmentIndex do
  @moduledoc """
    A module containing a function for assembling a CMAF segment index box.

    The segment index box (`sidx` atom) contains information related to presentation
    time and byte-range locations of other boxes belonging to its segment.

    For more information about segment index box refer to
    [ISO/IEC 23000-19](https://www.iso.org/standard/79106.html).
  """
  alias Membrane.MP4.Container

  @spec assemble(%{
          elapsed_time: integer,
          referenced_size: integer,
          timescale: integer,
          duration: integer
        }) :: Container.t()
  def assemble(config) do
    [
      sidx: %{
        children: [],
        fields: %{
          earliest_presentation_time: config.elapsed_time,
          first_offset: 0,
          flags: 0,
          reference_count: 1,
          reference_id: 1,
          reference_type: <<0::size(1)>>,
          referenced_size: config.referenced_size,
          sap_delta_time: 0,
          sap_type: 0,
          starts_with_sap: <<1::size(1)>>,
          subsegment_duration: config.duration,
          timescale: config.timescale,
          version: 1
        }
      }
    ]
  end
end
