# Marco Selvatici, ms8817

defmodule Leader do
  def start(s) do
    Monitor.debug(s, 3, "leader for term #{s.curr_term} ======================")

    # Monitor.halt(s, "Crash leader as soon as elected.")

    # Send HEARTBEAT to all followers.
    # Save a map from server to rpc timer.
    rpc_timers =
      Enum.reduce(
        s.servers,
        Map.new(),
        fn server, rpc_timers ->
          if server != s.selfP do
            send_heartbeat(s, server, rpc_timers)
          else
            rpc_timers
          end
        end
      )

    next(s, rpc_timers)
  end

  defp next(s, rpc_timers) do
    Monitor.assert(s, s.role == :LEADER, "in Leader.next with role #{s.role}")
    curr_term = s.curr_term
    receive do
      ###### Handle (ignore) vote replies. ######

      {:VOTE_REP, _, from_id, term, _} ->
        Monitor.debug(s, "received vote_reply for term #{term} from #{from_id} (ingoring)")
        next(s, rpc_timers)


      ###### Handle vote requests. ######

      {:VOTE_REQ, _, from_id, req_curr_term, _, _} when req_curr_term > curr_term ->
        # This server is not up to date. Stepdown.
        Monitor.debug(s, "stepdown after seeing term #{req_curr_term} in vote request from #{from_id}")
        cancel_rpc_timers(rpc_timers)
        Server.on_leader_stepdown(s, req_curr_term)

      {:VOTE_REQ, _, from_id, req_curr_term, _, _} when req_curr_term <= curr_term ->
        # Ignore old (and current) vote requests.
        Monitor.debug(s, "received old vote_request for term #{req_curr_term} from #{from_id} (ignored)")
        next(s, rpc_timers)


      ###### Handle APPEND_REQ. ######

      {:APPEND_REQ, _, from_id, term, _, _} when term > curr_term ->
        # This server is not up to date. Stepdown.
        Monitor.debug(s, "stepdown after seeing term #{term} in append request from #{from_id}")
        cancel_rpc_timers(rpc_timers)
        Server.on_leader_stepdown(s, term)

      {:APPEND_REQ, fromP, from_id, term, _, _} when term == curr_term ->
        # Another server believes to be the leader for the same term.
        # This should not be possible since elections should guarantee at most
        # one leader is elected in a term.
        if fromP != s.selfP, do: Monitor.halt(s, "received append request from same-term leader #{from_id}")
        next(s, rpc_timers)

      {:APPEND_REQ, fromP, from_id, term, _, _} when term < curr_term ->
        # Request from old leader. Make it stepdown.
        Monitor.debug(s, "recieved append request from old leader #{from_id}, in old term #{term}. Make it step down")
        Common.send_append_reply(s, fromP, false, 0)
        next(s, rpc_timers)


      ###### Handle APPEND_REP. ######

      {:APPEND_REP, _, from_id, term, _, _} when term > curr_term ->
        # This server is not up to date. Stepdown.
        Monitor.debug(s, "stepdown after seeing term #{term} in append reply from #{from_id}")
        cancel_rpc_timers(rpc_timers)
        Server.on_leader_stepdown(s, term)

      {:APPEND_REP, fromP, from_id, term, success, index} when term == curr_term ->
        # Follower replied to the request.
        Monitor.debug(s, "received append reply for current term from #{from_id}")
        s =
          if success do
            # We now know that the entries up to index are replicated on the
            # server, hence update match_index as well.
            s = State.next_index(s, fromP, index + 1)
            State.match_index(s, fromP, index)
          else
            State.next_index(s, fromP, max(1, Map.get(s.next_index, fromP) - 1))
        end
        # Possibly send new entries.
        rpc_timers =
          if Map.get(s.next_index, fromP) <= length(s.log) do
            # Send new entries to outdated follower.
            Monitor.debug(s, 2, "follower #{from_id} still out of date, send entries")
            send_append_request(s, fromP, rpc_timers)
          else
            # Simply restart the rpc timer.
            Monitor.debug(s, 2, "follower #{from_id} up to date")
            restart_append_timer(s, rpc_timers, fromP)
          end
        s = maybe_commit(s)
        next(s, rpc_timers)

      {:APPEND_REP, _, from_id, term, _} when term < curr_term ->
        # Reply to this leader, but in an old term. Ignore.
        Monitor.debug(s, "recieved and old append reply from #{from_id}, in old term #{term} (ignore)")
        next(s, rpc_timers)


      ###### Handle client requests. ######

      {:CLIENT_REQUEST, req} ->
        # Client request.
        # Check if the request with that uid has already been committed.
        case find_entry_state(s, req.uid) do
          {:COMMITTED, entry} ->
            # Just reply to the client saying it was performed already.
            send_client_reply(s, entry)
            next(s, rpc_timers)

          {:LOGGED, _} ->
            # Logged but not committed yet, ignore client.
            next(s, rpc_timers)

          {:NEW, _} ->
            # New client request.
            Monitor.notify(s, {:CLIENT_REQUEST, s.id})
            Monitor.debug(s, 2, "received client request #{inspect req.uid}")
            new_entry = %{ term: curr_term, clientP: req.clientP, uid: req.uid, cmd: req.cmd }
            s = Common.append_to_log(s, new_entry)
            rpc_timers = broadcast_append_request(s, rpc_timers)
            next(s, rpc_timers)
        end


      ###### Handle rpc append timeout. ######

      {:RPC_APPEND_TIMEOUT, targetP} ->
        # Follower did not reply. Try again.
        # If the log is empty, send simple heartbeats.
        rpc_timers =
          if Enum.empty?(s.log) or
              length(s.log) == (Map.get(s.next_index, targetP, 0) - 1) do
            # Log empty or follower up to date.
            Monitor.debug(s, "retransmit heartbeat")
            send_heartbeat(s, targetP, rpc_timers)
          else
            Monitor.debug(s, "retransmit data")
            send_append_request(s, targetP, rpc_timers)
          end
        next(s, rpc_timers)


      ###### Handle (ignore) other timeouts. ######

      :ELECTION_TIMEOUT ->
        Monitor.debug(s, "election_timeout while leader (ignore)")
        next(s, rpc_timers)

      {:RPC_ELECTION_TIMEOUT, _} ->
        Monitor.debug(s, "rpc_election_timeout while follower (ignore)")
        next(s, rpc_timers)

      unexpected ->
        Monitor.halt(s, "received unexpected #{inspect unexpected} while leader")
    end
  end

  # Send heartbeat to follower, and start a new RPC timer the previous one expired.
  # Returns the updated map of rpc_timers.
  defp send_heartbeat(s, targetP, rpc_timers) do
    Monitor.debug(s, "send heartbeat")
    if s.config.heartbeat_delay, do: :timer.sleep(s.config.heartbeat_delay)
    send(
      targetP,
      {:APPEND_REQ, s.selfP, s.id, s.curr_term, :HEARTBEAT, %{commit_index: s.commit_index}}
    )
    rpc_timers = Map.put(
      rpc_timers, targetP,
      Timer.start(s.config.append_entries_timeout, {:RPC_APPEND_TIMEOUT, targetP})
    )
    rpc_timers
  end

  defp cancel_rpc_timers(rpc_timers) do
    Enum.each(rpc_timers, fn {_, timer} -> Timer.cancel(timer) end)
  end

  # Send append request to all other servers, and update the RPC timers
  # accrodingly.
  defp broadcast_append_request(s, rpc_timers) do
    Enum.reduce(
      s.servers,
      rpc_timers,
      fn targetP, rpc_timers ->
        if targetP != s.selfP do
          send_append_request(s, targetP, rpc_timers)
        else
          rpc_timers
        end
      end
    )
  end

  # Send append request to follower, and restart an RPC timer.
  # Returns the updated map of rpc_timers.
  defp send_append_request(s, targetP, rpc_timers) do
    Monitor.assert(s, length(s.log) > 0, "at least one log entry must be present when sending append requests")
    # Prepare and send append request.
    default_last_log_index = length(s.log) # 1-based
    fol_last_log_index = Map.get(s.next_index, targetP, default_last_log_index) # 1-based
    s = State.next_index(s, targetP, fol_last_log_index)

    Monitor.debug(s, "log len #{length(s.log)} fol_lli #{fol_last_log_index}")
    prev_index = fol_last_log_index - 1 # 0-based
    prev_term = Enum.at(s.log, prev_index).term
    entries = Enum.slice(s.log, prev_index..-1)
    request_data = %{
      :prev_index   => prev_index, # 0-based
      :prev_term    => prev_term,
      :entries      => entries,
      :commit_index => s.commit_index # 1-based
    }
    send(targetP, {:APPEND_REQ, s.selfP, s.id, s.curr_term, :DATA, request_data})
    Monitor.debug(s, "send append request #{inspect request_data}")

    # Restart corresponding timer.
    rpc_timers = restart_append_timer(s, rpc_timers, targetP)
    rpc_timers
  end

  defp restart_append_timer(s, rpc_timers, targetP) do
    Timer.cancel(Map.get(rpc_timers, targetP))
    new_timer = Timer.start(s.config.append_entries_timeout, {:RPC_APPEND_TIMEOUT, targetP})
    rpc_timers = Map.put(rpc_timers, targetP, new_timer)
    rpc_timers
  end

  # In order to commit:
  # - check which entries are committed (using match_index)
  # - apply the newly committed commands to the database
  # - update commit_index
  # - reply to the client
  # - return new state
  defp maybe_commit(s) do
    old_commit_index = s.commit_index
    # Commit index is 1 based, so in order to start from the first uncommitted
    # entry in the log we just use the commit_index itself (and we do not add 1).
    uncommitted = Enum.slice(s.log, old_commit_index .. -1)
    new_commit_index =
      Enum.reduce_while(
        uncommitted,
        old_commit_index + 1,
        fn _entry, entry_index ->
          replications = count_known_replications(s, entry_index)
          if replications > s.majority do
            {:cont, entry_index + 1} # Continue trying the next index.
          else
            {:halt, entry_index} # Return the current entry_index.
          end
        end
      ) - 1 # Subtract one because we stopped on the first non-committed index.

    Monitor.debug(s, "===> #{inspect uncommitted} #{old_commit_index} #{new_commit_index}")
    # Update commit index and apply the entries in the database.
    s = State.commit_index(s, new_commit_index)
    s = Common.apply_committed_entries(s)

    # Reply to clients.
    newly_committed = Enum.slice(s.log, old_commit_index .. new_commit_index - 1)
    for entry <- newly_committed, do: send_client_reply(s, entry)

    Monitor.debug(s, 2, "commit #{length(newly_committed)} entries. Commit index #{old_commit_index} -> #{new_commit_index}")
    s
  end

  defp count_known_replications(s, entry_index) do
    Enum.reduce(
      s.servers, 1, # Already count this node.
      fn server, count ->
        if server != s.selfP and Map.get(s.match_index, server) >= entry_index do
          count + 1
        else
          count
        end
      end
    )
  end

  defp send_client_reply(s, entry) do
    send(entry.clientP, {:CLIENT_REPLY, %{:leaderP => s.selfP}})
  end

  defp find_entry_state(s, uid) do
    committed = try_find_committed_req(s, uid)
    if committed do
      {:COMMITTED, committed}
    else
      logged = try_find_logged_req(s, uid)
      if logged do
        {:LOGGED, logged}
      else
        {:NEW, nil}
      end
    end
  end

  # Check the committed log to find wether a request was already fulfilled.
  defp try_find_committed_req(s, uid) do
    if Enum.empty?(s.log) do
      nil
    else
      committed = Enum.slice(s.log, 0 .. s.commit_index - 1) # 1-based
      Enum.find(committed, nil, fn entry -> entry.uid == uid end)
    end
  end

  def try_find_logged_req(s, uid) do
    if Enum.empty?(s.log) do
      nil
    else
      Enum.find(s.log, nil, fn entry -> entry.uid == uid end)
    end
  end
end
