defmodule Membrane.MP4.Box.FileType do
  @moduledoc """
    A module containing a function for assembling an MPEG-4 file type box.

    The file type box (`ftyp` atom) is a top-level box that contains specifications
    and compatibility information that media players can use to correctly interpret
    an MPEG-4 container.

    For more information about the file type box, refer to
    [ISO/IEC 14496-12](https://www.iso.org/standard/74428.html).
  """
  alias Membrane.MP4.Container

  @spec assemble(String.t(), [String.t()], integer) :: Container.t()
  def assemble(major_brand, compatible_brands, major_brand_version \\ 512) do
    [
      ftyp: %{
        children: [],
        fields: %{
          major_brand: major_brand,
          major_brand_version: major_brand_version,
          compatible_brands: compatible_brands
        }
      }
    ]
  end
end
