# Marco Selvatici, ms8817

# distributed algorithms, n.dulay, 4 feb 2020
# coursework, raft consensus, v1

defmodule Monitor do
  def print_color(code, string) do
    color = case code do
      :HALT      -> :red_background
      :FOLLOWER  -> :light_black_background
      :CANDIDATE -> :blue_background
      :LEADER    -> :green_background
      _ -> :black_background
    end
    IO.puts(IO.ANSI.format([color, :white, string]))
  end

  def notify(s, message) do
    send(s.config.monitorP, message)
  end

  def assert(s, val, error) do
    if not val do
      halt(s, error)
    end
  end

  def debug(s, string) do
    role = Map.get(s, :role, "n/a")
    curr_term = Map.get(s, :curr_term, "n/a")
    if s.config.debug_level == 0 do
      print_color(role, "server #{s.id}  [#{curr_term}] #{role}  #{string}")
    end
  end

  def debug(s, level, string) do
    role = Map.get(s, :role, "n/a")
    curr_term = Map.get(s, :curr_term, "n/a")
    if level >= s.config.debug_level do
      print_color(role, "server #{s.id} [#{curr_term}] #{role}  #{string}")
    end
  end

  def pad(key), do: String.pad_trailing("#{key}", 10)

  def state(s, level, string) do
    if level >= s.config.debug_level do
      state_out =
        for {key, value} <- s, into: "" do
          "\n  #{pad(key)}\t #{inspect(value)}"
        end

      print_color(s.role, "\nserver #{s.id} #{s.role}: #{inspect(s.selfP)} #{string} state = #{state_out}")
    end
  end

  def halt(string) do
    print_color(:HALT, "HALT: monitor: #{string}")
    System.halt()
  end

  def halt(s, string) do
    print_color(:HALT, "HALT: server #{s.id} #{string}")
    # debug(s, 3, "checksum #{Common.committed_checksum(s)}")
    System.halt()
  end

  def letter(s, letter) do
    if s.config.debug_level == 3, do: IO.write(letter)
  end

  def start(config) do
    state = %{
      config: config,
      clock: 0,
      requests: Map.new(),
      updates: Map.new(),
      moves: Map.new()
      # rest omitted
    }

    Process.send_after(self(), {:PRINT}, state.config.print_after)
    Monitor.next(state)
  end

  def clock(state, v), do: Map.put(state, :clock, v)

  def requests(state, i, v), do: Map.put(state, :requests, Map.put(state.requests, i, v))

  def updates(state, i, v), do: Map.put(state, :updates, Map.put(state.updates, i, v))

  def moves(state, v), do: Map.put(state, :moves, v)

  def next(state) do
    receive do
      {:DB_UPDATE, db, seqnum, command} ->
        {:move, amount, from, to} = command

        done = Map.get(state.updates, db, 0)

        if seqnum != done + 1,
          do: Monitor.halt("  ** error db #{db}: seq #{seqnum} expecting #{done + 1}")

        moves =
          case Map.get(state.moves, seqnum) do
            nil ->
              # IO.puts "db #{db} seq #{seqnum} = #{done+1}"
              Map.put(state.moves, seqnum, %{amount: amount, from: from, to: to})

            # already logged - check command
            t ->
              if amount != t.amount or from != t.from or to != t.to,
                do:
                  Monitor.halt(
                    " ** error db #{db}.#{done} [#{amount},#{from},#{to}] " <>
                      "= log #{done}/#{map_size(state.moves)} [#{t.amount},#{t.from},#{t.to}]"
                  )

              state.moves
          end

        state = Monitor.moves(state, moves)
        state = Monitor.updates(state, db, seqnum)
        Monitor.next(state)

      # client requests seen by leaders
      {:CLIENT_REQUEST, server_num} ->
        state = Monitor.requests(state, server_num, Map.get(state.requests, server_num, 0) + 1)
        Monitor.next(state)

      {:PRINT} ->
        clock = state.clock + state.config.print_after
        state = Monitor.clock(state, clock)
        sorted = state.updates |> Map.to_list() |> List.keysort(0)
        IO.puts("time = #{clock}      db updates done = #{inspect(sorted)}")
        sorted = state.requests |> Map.to_list() |> List.keysort(0)
        IO.puts("time = #{clock} client requests seen = #{inspect(sorted)}")

        # always
        if state.config.debug_level >= 0 do
          min_done = state.updates |> Map.values() |> Enum.min(fn -> 0 end)
          n_requests = state.requests |> Map.values() |> Enum.sum()

          IO.puts(
            "time = #{clock}           total seen = #{n_requests} max lag = #{
              n_requests - min_done
            }"
          )
        end

        IO.puts("")
        Process.send_after(self(), {:PRINT}, state.config.print_after)
        Monitor.next(state)

      # ** ADD ADDITIONAL MONITORING MESSAGES HERE

      unexpected ->
        Monitor.halt("monitor: unexpected message #{inspect(unexpected)}")
    end
  end
end

# Monitor
