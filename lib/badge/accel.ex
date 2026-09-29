defmodule Badge.Accel do
  @moduledoc """
  Pure maths for the SC7A20 accelerometer: decoding raw registers,
  exponential averaging, and deriving tilt orientation. No I2C, no process
  state.

  The SC7A20 in normal mode is 10-bit, left-justified in a signed 16-bit
  little-endian pair, +-2g full scale, so 1g = 16384 counts and
  `mg = raw * 1000 / 16384`, simplified here to `raw * 125 / 2048`.

  Samples are in the panel's frame, not the sensor's: x toward the panel's
  right edge, y toward its top edge, z out of the screen. A badge lying face
  up reads `{0, 0, 1000}` and one hanging upright reads `{0, 1000, 0}`.
  """

  @type mg :: {integer, integer, integer}

  @doc """
  Decodes the 6 bytes read from OUT_X_L..OUT_Z_H (0x28..0x2D) into milli-g,
  in the panel's frame.
  """
  @spec decode(binary) :: mg
  def decode(<<x::little-signed-16, y::little-signed-16, z::little-signed-16>>) do
    # The sensor faces the back of the board, so its x and z oppose the panel's.
    {-to_mg(x), to_mg(y), -to_mg(z)}
  end

  defp to_mg(raw), do: div(raw * 125, 2048)

  @doc """
  Exponential moving average, alpha = 1/4, applied per axis. `nil` as the
  previous value adopts `sample` as-is.
  """
  @spec average(mg | nil, mg) :: mg
  def average(nil, sample), do: sample

  def average({px, py, pz}, {x, y, z}) do
    {ema(px, x), ema(py, y), ema(pz, z)}
  end

  defp ema(previous, new), do: previous + div(new - previous, 4)

  @doc """
  Roll and pitch in whole degrees from a milli-g sample.

  Both are zero with the badge face up and level. Roll is positive with the
  right edge lowered, pitch positive with the top edge raised, so a badge
  hanging upright reads a pitch of 90.
  """
  @spec orientation(mg) :: {integer, integer}
  def orientation({x, y, z}) do
    roll = round(:math.atan2(-x, :math.sqrt(y * y + z * z)) * 180 / :math.pi())
    pitch = round(:math.atan2(y, z) * 180 / :math.pi())
    {roll, pitch}
  end
end
