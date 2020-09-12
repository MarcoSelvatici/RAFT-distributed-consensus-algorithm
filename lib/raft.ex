# Marco Selvatici, ms8817

# distributed algorithms, n.dulay, 4 feb 2020
# coursework, raft consensus, v1

defmodule Raft do
  def start do
    config = DAC.node_init()
    IO.puts("Raft at #{DAC.node_ip_addr()}")

    Raft.start(config.start_function, config)
  end

  def start(:multi_node_wait, _), do: :skip

  def start(:multi_node_start, config) do
    # spawn monitor process in top-level raft node
    monitorP = spawn(Monitor, :start, [config])
    config = Map.put(config, :monitorP, monitorP)

    # co-locate 1 server and 1 database at each server node
    servers =
      for id <- 1..config.n_servers do
        databaseP =
          Node.spawn(:"server#{id}_#{config.node_suffix}", Database, :start, [config, id])

        _serverP =
          Node.spawn(:"server#{id}_#{config.node_suffix}", Server, :start, [config, id, databaseP])
      end

    # pass list of servers to each server
    for server <- servers, do: send(server, {:BIND, servers})

    # create 1 client at each client node
    for id <- 1..config.n_clients do
      _clientP =
        Node.spawn(:"client#{id}_#{config.node_suffix}", Client, :start, [config, id, servers])
    end

    # crash servers after some time. Send them an unexpected message
    Enum.each(
      config.crash_servers,
      fn {id, time} ->
        Timer.start(time, {:CRASH ,Enum.at(servers, id - 1)})
      end
    )

    next()
  end

  defp next() do
    # crash processes when it is time
    receive do
      {:CRASH, server} -> send(server, :CRASH)
    end
    next()
  end
end

# module ------------------------------
