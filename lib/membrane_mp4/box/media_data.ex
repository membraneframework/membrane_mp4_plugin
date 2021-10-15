defmodule Membrane.MP4.Box.MediaData do
  @moduledoc """
  A module containing a function for assembling an MPEG-4 media data box.

  The media data box (`mdat` atom) is a top-level box that contains actual media data
  (e.g. encoded video frames or audio samples). The data is logically divided into so
  called "chunks" that consist of "samples". There are no assumptions made about chunks
  arrangement or sizes in the MPEG-4 specification and chunks belonging to different tracks
  can (and should) be interleaved.

  For more information about media data box, refer to
  [ISO/IEC 14496-12](https://www.iso.org/standard/74428.html).
  """
  alias Membrane.MP4.Container

  @spec assemble(binary) :: Container.t()
  def assemble(media_data) do
    [
      mdat: %{
        content: media_data
      }
    ]
  end
end
