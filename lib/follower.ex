# Marco Selvatici, ms8817

defmodule Follower do
  def start(s, election_timer) do
    Monitor.debug(s, 3, "follower for term #{s.curr_term}")
    next(s, election_timer)
  end

  defp next(s, election_timer) do
    Monitor.assert(s, s.role == :FOLLOWER, "in Follower.next with role #{s.role}")
    curr_term = s.curr_term
    receive do
      ###### Handle (ignore) vote replies. ######

      {:VOTE_REP, _, from_id, term, _} ->
        # Ignore all vote replies.
        Monitor.debug(s, "received vote_reply for term #{term} from #{from_id} (ingoring)")
        next(s, election_timer)


      ###### Handle vote requests. ######

      {:VOTE_REQ, fromP, from_id, req_curr_term, req_last_log_term, req_last_log_index}
          when req_curr_term >= curr_term ->
        # Possibly legit vote request.
        {s, election_timer} =
          if req_curr_term > curr_term do
            # This server is not up to date. Remain FOLLOWER but update curr_term.
            Monitor.debug(s, "update term after seeing term #{req_curr_term} in vote request from #{from_id}")
            Common.stepdown(s, req_curr_term, election_timer)
          else
            {s, election_timer}
          end
        # Now req_curr_term == s.curr_term.
        # Decide wether the vote is granted.
        last_log_term = Common.get_last_log_term(s)
        last_log_index = Common.get_last_log_index(s)
        s =
          if s.voted_for == nil and
            (req_last_log_term > last_log_term or
              (req_last_log_term == last_log_term and
                req_last_log_index >= last_log_index)) do
            Monitor.debug(s, "received vote_request for term #{req_curr_term} from #{from_id} (vote)")
            Common.send_vote_reply(s, fromP)
          else
            Monitor.debug(s, "received vote_request for term #{req_curr_term} from #{from_id} (ignore)")
            s
          end
        next(s, election_timer)

      {:VOTE_REQ, _, from_id, req_curr_term, _, _} when req_curr_term < curr_term ->
        # Ignore old vote requests.
        Monitor.debug(s, "received old vote_request for term #{req_curr_term} from #{from_id} (ignored)")
        next(s, election_timer)


      ###### Handle APPEND_REQ. ######

      {:APPEND_REQ, _, from_id, term, _, _} when term > curr_term ->
        # This server is not up to date. Stepdown.
        Monitor.debug(s, "stepdown after seeing term #{term} in append request from #{from_id}")
        {s, election_timer} = Common.stepdown(s, term, election_timer)
        next(s, election_timer)

      {:APPEND_REQ, _, from_id, term, :HEARTBEAT, hb_data} when term == curr_term ->
        # Leader sent heartbeat.
        Monitor.debug(s, "received heartbeat from leader #{from_id}")
        # It may be possible that the server committed some of the entries we
        # already logged. If so, commit them locally.
        s = State.commit_index(s, min(hb_data.commit_index, length(s.log)))
        s = Common.apply_committed_entries(s)
        election_timer = Common.restart_election_timer(s, election_timer)
        next(s, election_timer)

      {:APPEND_REQ, fromP, from_id, term, :DATA, data} when term == curr_term ->
        # Leader sent data.
        Monitor.debug(s, 2, "received data from leader #{from_id}")
        success =
          (data.prev_index == 0) or # 0-based
          (data.prev_index < length(s.log) and # 0-based
            Enum.at(s.log, data.prev_index).term == data.prev_term)
        {s, index} = # 1-based
          if success do
            store_entries(s, data.prev_index, data.entries, data.commit_index)
          else
            {s, 0}
          end
        # Restart election timer.
        election_timer = Common.restart_election_timer(s, election_timer)
        Common.send_append_reply(s, fromP, success, index)
        Monitor.debug(s, "log length after update #{length(s.log)}, commit index #{s.commit_index}")
        next(s, election_timer)

      {:APPEND_REQ, fromP, from_id, term, _, _} when term < curr_term ->
        # Request from old leader. Make it stepdown.
        Monitor.debug(s, "recieved append request from old leader #{from_id}, in old term #{term}. Make it step down")
        Common.send_append_reply(s, fromP, false, 0)
        next(s, election_timer)


      ###### Handle (ignore) APPEND_REP. ######

      {:APPEND_REP, _, from_id, term, _, _} ->
        Monitor.debug(s, "received append reply from #{from_id}, from term #{term} (ignore)")
        next(s, election_timer)


      ###### Handle election timeout. ######

      :ELECTION_TIMEOUT ->
        Monitor.debug(s, "got election timeout")
        Server.on_election_timeout(s)


      ###### Handle other messages (ignore them). ######

      {:RPC_ELECTION_TIMEOUT, _} ->
        Monitor.debug(s, "rpc_election_timeout while follower (ignore)")
        next(s, election_timer)

      {:RPC_APPEND_TIMEOUT, _} ->
        Monitor.debug(s, "rpc_append_timeout while follower (ignore)")
        next(s, election_timer)

      {:CLIENT_REQUEST, _} ->
          Monitor.debug(s, "ignoring client request while follower")
          next(s, election_timer)

      unexpected ->
        Monitor.halt(s, "received unexpected #{inspect unexpected} while follower")
    end
  end

  defp store_entries(s, prev_index, entries, commit_index) do
    # Split the log into a log of entries we know are correct.
    {correct, uncertain} = Enum.split(s.log, prev_index) # 0-based
    Monitor.debug(s, "correct #{inspect correct} uncertain #{inspect uncertain} entries #{inspect entries}")
    # Replace the uncertain entries with the ones provided by the leader.
    s = State.log(s, correct ++ entries)
    s = State.commit_index(s, min(commit_index, length(s.log))) # 1-based
    # Commit entries all the way until the commit index.
    s = Common.apply_committed_entries(s)
    Monitor.debug(s, "final log #{inspect s.log}")
    {s, length(s.log)}
  end

end
