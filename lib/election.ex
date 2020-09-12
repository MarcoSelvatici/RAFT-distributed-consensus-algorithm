# Marco Selvatici, ms8817

defmodule Election do
  # using: s for 'server/state', m for 'message'

  # Start new election.
  # Only return when a new leader is elected, and the node is either in role
  # LEADER or FOLLOWER.
  # We should not have CANDIDATE role outside this module.
  def start(s) do
    s = State.role(s, :CANDIDATE)
    s = State.curr_term(s, s.curr_term + 1)
    s = State.voted_for(s, nil)
    s = State.votes(s, 0)

    # Create a new election timer, the previous one has expired.
    election_timer = Timer.start_delta(s.config.election_timeout, :ELECTION_TIMEOUT)

    Monitor.debug(s, 3, "start election for term #{s.curr_term}")

    # Send VOTE_REQ to all other servers.
    # Save a map from server to rpc timer.
    rpc_timers =
      Enum.reduce(
        s.servers,
        Map.new(),
        fn server, rpc_timers ->
          rpc_timers = send_vote_request(s, server, rpc_timers)
          rpc_timers
        end
      )

    next(s, election_timer, rpc_timers)
  end

  defp next(s, election_timer, rpc_timers) do
    Monitor.assert(s, s.role == :CANDIDATE, "in Election.next with role #{s.role}")
    curr_term = s.curr_term
    receive do
      ###### Handle vote replies. ######

      {:VOTE_REP, _fromP, from_id, term, _vote} when term > curr_term ->
        # A node with higher term should not grant votes to servers "behind".
        Monitor.halt(s, "received vote reply with term > curr_term (#{term} > #{curr_term}) from #{from_id}. The vote should have not been granted")

      {:VOTE_REP, fromP, from_id, term, vote} when term == curr_term ->
        # Other server voting for the current election.
        # Update s if received a vote.
        s = if vote == s.selfP, do: State.votes(s, s.votes + 1), else: s
        Monitor.debug(s, "received vote_reply for current term (#{curr_term}) from #{from_id}, vote count #{s.votes}")
        # Cancel timeout for the server.
        Timer.cancel(Map.get(rpc_timers, fromP))
        # Check if elected as LEADER.
        if s.votes > s.majority do
          Monitor.debug(s, 2, "elected leader for term #{curr_term}")
          # Terminate election.
          cancel_rpc_timers(rpc_timers)
          Timer.cancel(election_timer)
          # Return new state.
          s = State.role(s, :LEADER)
          {s, nil} # nil is the election_timer.
        else
          next(s, election_timer, rpc_timers)
        end

      {:VOTE_REP, _, from_id, term, _} when term < curr_term ->
        # Ignore old vote replies.
        Monitor.debug(s, "received old vote_reply for term #{term} from #{from_id}")
        next(s, election_timer, rpc_timers)


      ###### Handle vote requests. ######

      {:VOTE_REQ, _, from_id, req_curr_term, _, _} when req_curr_term > curr_term ->
        # This server is not up to date. Go back to FOLLOWER.
        Monitor.debug(s, 2, "stepdown after seeing term #{req_curr_term} in vote request from #{from_id}")
        # Terminate election.
        cancel_rpc_timers(rpc_timers)
        Common.stepdown(s, req_curr_term, election_timer)

      {:VOTE_REQ, fromP, from_id, req_curr_term, _, _} when req_curr_term == curr_term->
        # Other server requesting vote for the current election.
        # Vote only for the node itself and if we havent voted already.
        if fromP == s.selfP and s.voted_for == nil do
          Monitor.debug(s, "received vote_request for current term (#{curr_term}) from #{from_id} (vote)")
          s = Common.send_vote_reply(s, s.selfP)
          next(s, election_timer, rpc_timers)
        else
          Monitor.debug(s, "received vote_request for current term (#{curr_term}) from #{from_id} (ignore)")
          next(s, election_timer, rpc_timers)
        end

      {:VOTE_REQ, _, from_id, req_curr_term, _, _} when req_curr_term < curr_term ->
        # Ignore old vote requests.
        Monitor.debug(s, "received old vote_request for term #{req_curr_term} from #{from_id} (ignored)")
        next(s, election_timer, rpc_timers)


      ###### Handle APPEND_REQ. ######

      {:APPEND_REQ, _, from_id, term, _, _} when term >= curr_term ->
        # This server is not up to date, or some other server became a leader
        # for this term. Stepdown.
        Monitor.debug(s, "stepdown after seeing term #{term} in append request from #{from_id}")
        # Terminate election.
        cancel_rpc_timers(rpc_timers)
        Common.stepdown(s, term, election_timer)

      {:APPEND_REQ, fromP, from_id, term, _, _} when term < curr_term ->
        # Request from old leader. Make it stepdown.
        Monitor.debug(s, "recieved append request from old leader #{from_id}, in old term #{term}. Make it step down")
        Common.send_append_reply(s, fromP, false, 0)
        next(s, election_timer, rpc_timers)


      ###### Handle (ignore) APPEND_REP. ######

      {:APPEND_REP, _, from_id, term, _, _} ->
        # Ingore append replies.
        Monitor.debug(s, "received append reply from #{from_id}, from term #{term} (ignore)")
        next(s, election_timer, rpc_timers)


      ###### Handle RPC timeouts. ######

      {:RPC_ELECTION_TIMEOUT, server} ->
        # Retransmit vote request.
        Monitor.debug(s, "rpc_election_timeout for server #{inspect server}")
        rpc_timers = send_vote_request(s, server, rpc_timers)
        next(s, election_timer, rpc_timers)


      ###### Handle split votes. ######

      :ELECTION_TIMEOUT ->
        # Failed to reach consensus in the election. Retrying.
        Monitor.debug(s, 2, "failed to reach consensus in the election. Retrying")
        cancel_rpc_timers(rpc_timers)
        start(s)


      ###### Handle (ignore) other messages. ######

      {:RPC_APPEND_TIMEOUT, _} ->
        Monitor.debug(s, "rpc_append_timeout during election (ignore)")
        next(s, election_timer, rpc_timers)

      {:CLIENT_REQUEST, _} ->
        # Ignore client requests during election.
        Monitor.debug(s, "ignoring client request during election")
        next(s, election_timer, rpc_timers)

      unexpected ->
        Monitor.halt(s, "received unexpected #{inspect unexpected} during election")

    end
  end

  # Send vote request to other server and start an RPC timer.
  # Returns the updated map of rpc_timers.
  defp send_vote_request(s, server, rpc_timers) do
    # Get the most recent log term, or -1 if log is empty.
    last_log_term = Common.get_last_log_term(s)
    last_log_index = Common.get_last_log_index(s)
    Monitor.debug(s, "send vote req: ct #{s.curr_term}, llt #{last_log_term}, lli #{last_log_index}")
    send(server, {:VOTE_REQ, s.selfP, s.id, s.curr_term, last_log_term, last_log_index})
    rpc_timers = Map.put(
      rpc_timers, server,
      Timer.start(s.config.vote_timeout, {:RPC_ELECTION_TIMEOUT, server})
    )
    rpc_timers
  end

  defp cancel_rpc_timers(rpc_timers) do
    Enum.each(rpc_timers, fn {_, timer} -> Timer.cancel(timer) end)
  end

end
