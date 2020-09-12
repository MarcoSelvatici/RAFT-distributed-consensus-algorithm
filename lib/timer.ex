# Marco Selvatici, ms8817

defmodule Timer do
  def start(time, msg) do
    Process.send_after(self(), msg, time)
  end

  # start timer that expires after an amout of time in the range [time, 2*time]
  def start_delta(time, msg) do
    delta = :rand.uniform(time) + time
    start(delta, msg)
  end

  def cancel(timer) do
    Process.cancel_timer(timer)
  end
end
