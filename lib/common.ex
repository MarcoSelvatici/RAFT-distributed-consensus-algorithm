# Marco Selvatici, ms8817

defmodule Common do
  def restart_election_timer(s, election_timer) do
    Timer.cancel(election_timer)
    Timer.start_delta(s.config.election_timeout, :ELECTION_TIMEOUT)
  end

  # Stepdown and return new FOLLOWER state. Restart election timer.
  def stepdown(s, new_term, election_timer) do
    election_timer =
      if s.role == :LEADER do
        # Leader stepping down, will have election_timer == nil, hence just
        # start new one.
        Timer.start_delta(s.config.election_timeout, :ELECTION_TIMEOUT)
      else
        # Candidate or follower, just restart the current election timer.
        restart_election_timer(s, election_timer)
      end
    s = State.curr_term(s, new_term)
    s = State.voted_for(s, nil)
    s = State.role(s, :FOLLOWER)
    {s, election_timer}
  end

  def get_last_log_term(s) do
    len = length(s.log)
    if len == 0, do: -1, else: Enum.at(s.log, len - 1).term
  end

  def get_last_log_index(s) do
    length(s.log) # Log indexes are conceptually 1-based.
  end

  # Send approval vote to server and update state.voted_for.
  def send_vote_reply(s, vote_server) do
    if s.voted_for != nil do
      Monitor.halt(s, "trying to vote again in term #{s.curr_term}, after voting #{inspect s.voted_for}")
    end
    Monitor.debug(s, "send vote reply: ct #{s.curr_term}, vf #{inspect vote_server}")
    send(vote_server, {:VOTE_REP, s.selfP, s.id, s.curr_term, vote_server})
    s = State.voted_for(s, vote_server)
    s
  end

  def send_append_reply(s, targetP, success, index) do
    Monitor.debug(s, "send append reply: ct #{s.curr_term}, succ #{success}, idx #{index}")
    if s.config.append_reply_delay, do: :timer.sleep(s.config.append_reply_delay)
    send(targetP, {:APPEND_REP, s.selfP, s.id, s.curr_term, success, index})
  end

  def append_to_log(s, new_entry) do
    log = s.log ++ [new_entry]
    State.log(s, log)
  end

  # Apply all log entries up to (including) commit_index, and update last_applied.
  def apply_committed_entries(s) do
    if s.last_applied == s.commit_index do
      Monitor.debug(s, 2, "no new changes to apply, commit index #{s.commit_index}")
      s
    else
      # We do not sum 1 to last_applied because it is 1 based, so it is already one
      # off wrt the log, which is zero based (for the same reason we have the -1).
      to_apply = Enum.slice(s.log, s.last_applied .. s.commit_index - 1)
      Monitor.debug(s, 2, "applying #{length(to_apply)} entries, until index #{s.commit_index}")
      for entry <- to_apply, do: send(s.databaseP, {:EXECUTE, entry.cmd})
      s = State.last_applied(s, s.commit_index)
      s
    end
  end

  def committed_checksum(s) do
    committed = Enum.slice(s.log, 0 .. s.commit_index - 1)
    {_, checksum} =
      Enum.reduce(
        committed,
        {0, 0},
        fn entry, acc ->
          {_, v1, v2, v3} = entry.cmd
          {idx, sum} = acc
          sum = sum + (idx + 1) * (v1 + v2 + v3)
          {idx + 1, sum}
        end)
    checksum
  end
end
