# Marco Selvatici, ms8817

# distributed algorithms, n.dulay, 4 feb 2020
# coursework, raft consensus, v1

# various helper functions

defmodule DAC do
  def node_ip_addr do
    # get interfaces
    {:ok, interfaces} = :inet.getif()
    # get data for 1st interface
    {address, _gateway, _mask} = hd(interfaces)
    # get octets for address
    {a, b, c, d} = address
    "#{a}.#{b}.#{c}.#{d}"
  end

  def random(n), do: Enum.random(1..n)

  # --------------------------------------------------------------------------

  # nicely stop and exit the node
  def node_exit do
    # System.halt(1) for a hard non-tidy node exit
    System.stop(0)
  end

  def exit_after(duration) do
    Process.sleep(duration)
    IO.puts("Exiting #{node()}")
    node_exit()
  end

  # get node arguments and spawn a process to exit node after max_time
  def node_init do
    config = Map.new()
    config = Map.put(config, :max_time, String.to_integer(Enum.at(System.argv(), 0)))
    config = Map.put(config, :node_suffix, Enum.at(System.argv(), 1))
    config = Map.put(config, :n_servers, String.to_integer(Enum.at(System.argv(), 2)))
    config = Map.put(config, :n_clients, String.to_integer(Enum.at(System.argv(), 3)))
    config = Map.put(config, :start_function, :"#{Enum.at(System.argv(), 4)}")

    config = more_parameters(config)

    spawn(DAC, :exit_after, [config.max_time])
    config
  end

  defp more_parameters(config) do
    Map.merge(config, %{
      # debug level 0
      debug_level: 3,
      # print transaction log summary every print_after millisecs
      print_after: 2_000,
      # max requests each client will make
      client_requests: 100,
      # time to sleep before sending next request
      client_sleep: 20,
      # time after which client should stop sending requests
      client_stop: 25_000,
      # timeout for expecting reply to client request
      client_timeout: 500,
      # number of active bank accounts
      n_accounts: 100,
      # max amount moved between accounts
      max_amount: 1_000,
      # timeout(ms) for election, randomly from this to 2*this value
      election_timeout: 400,
      # timeout(ms) for expecting reply to append_entries request
      append_entries_timeout: 50,
      # timeout(ms) for expecting reply to vote requests
      vote_timeout: 50,
      # artificial message delays (nil for no delay)
      heartbeat_delay: nil,
      append_reply_delay: nil,
      # %{ server_num => crash_after_time, ...}
      crash_servers: %{}
    })
  end
end

# module -----------------------
