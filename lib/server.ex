# Marco Selvatici, ms8817

# distributed algorithms, n.dulay, 4 feb 2020
# coursework, raft consenus, v1

# Valid messages:
# :VOTE_REQ, fromP, from_id, curr_term, last_log_term, last_log_index
# :VOTE_REP, fromP, from_id, term, vote
#
# :APPEND_REQ, fromP, from_id, term, type, %{prev_index, prev_term, entries, commit_index}
#  where type can be either :DATA, or :HEARTBEAT.
# :APPEND_REP, fromP, from_id, term, success, index
#
# Log entry:
# %{ term: int, clientP: PID, uid: _, cmd: map }
# Log indexes are 1 based.
# New entries appended at the end of the list, for easiness.

defmodule Server do
  # Using: s for 'server/state', m for 'message'.

  def start(config, server_id, databaseP) do
    receive do
      {:BIND, servers} ->
        s = State.initialise(config, server_id, servers, databaseP)
        # Start timeouts.
        election_timer = Timer.start_delta(config.election_timeout, :ELECTION_TIMEOUT)

        # Start all nodes as followers.
        Follower.start(s, election_timer)
        Monitor.halt(s, "follower returned at top level. This should not happen.")
    end
  end

  def on_election_timeout(s) do
    Monitor.assert(s, s.role == :FOLLOWER, "on_election_timeout triggered by #{s.role}")
    Monitor.debug(s, "triggered on_election_timeout")
    # Start election.
    {s, election_timer} = Election.start(s)
    Monitor.debug(s, 2, "finished election")
    case {s.role, election_timer} do
      {:FOLLOWER, election_timer} when election_timer != nil -> Follower.start(s, election_timer)
      {:LEADER, nil} -> Leader.start(s)
      other -> Monitor.halt(s, "finished election with result #{inspect other}")
    end
  end

  def on_leader_stepdown(s, new_term) do
    # Leader is stepping down because it saw a newer term.
    Monitor.assert(s, s.role == :LEADER, "on_leader_stepdown triggered by #{s.role}")
    {s, election_timer} = Common.stepdown(s, new_term, nil)
    Follower.start(s, election_timer)
  end
end
